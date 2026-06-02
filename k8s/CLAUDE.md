# k8s/ — guidance for Claude

Guidance for working in the local Kubernetes setup. See `README.md` for the
usage/command reference and `../CLAUDE.md` for project-wide conventions.

## Known scars (rough edges & hard-won lessons)

### SCAR: master+slave XA self-deadlock on one MySQL (load-slave / mutate / save-master)

**Symptom (2026-06-01):** `POST /authorization-server/v1/auth:activate` hung ~50s
then failed. The browser showed `401 "Full authentication is required to access
this resource"` — a **red herring**. Activate is `permitAll` and the request
reached business logic fine; the 401 was a *masked 500* (see the `/error` note
below). The real failure: MySQL **error 1205 "Lock wait timeout exceeded"** on the
activate UPDATE, after exactly `innodb_lock_wait_timeout` (50s).

**Root cause:** a single `@Transactional` method that **reads via a `repository/slave`
repo and writes via a `repository/master` repo** self-deadlocks when master and
slave datasources point at the **same** MySQL. Mechanism:
1. `slaveAccountRepository.findbyEmail()` loads the `Account` into the **slave**
   persistence context; `setIsActivated(true)` makes it **dirty there**.
2. `masterAccountRepository.save(account)` merges it into the **master** context.
3. At commit, BOTH EntityManagers dirty-check and each emits its own
   `UPDATE account ... WHERE id=?` — on **two separate XA branches**.
4. Originally master/slaves were **separate servers**, so the two UPDATEs never
   collided. In k8s the `mysql` and `mysql-replica` Services are **one `mysql-0`
   pod**, so the two branches contend on the same row's X-lock. InnoDB treats each
   XA branch as an independent txn → branch A holds the lock through its in-flight
   XA commit, branch B waits 50s → 1205 → `UnexpectedRollbackException`. The tiny
   Atomikos XA pool also exhausts ("Connection pool exhausted"), failing readiness.

The same pattern lurks in **order-service cart upsert** (find line on slave →
merge qty → save on master) and any other load-slave/mutate/save-master path.

**Fix:** make every **slave** EntityManagerFactory **query-only** so it never
emits a write. `core-routing-db` ships `ReadOnlySlaveInterceptor` (a Hibernate
`Interceptor` whose `findDirty` returns an empty array = "nothing dirty" → no
UPDATE). It's wired via `CommonJPAProperties.getSlaveProperties()` into the slave
EMF of **all four** MySQL services (authorization-server, inventory-service,
order-service, payment-service). The **master** EMF still uses `getProperties()`
and writes normally, so the merged value persists — only the slave's redundant
write is suppressed.

**Why not FlushMode.MANUAL?** Under **Atomikos JTA** (not the Hibernate-aware
`JpaTransactionManager`), Spring/JPA reset the session flush mode back to AUTO, so
`org.hibernate.flushMode=MANUAL` is ignored — verified: the slave still flushed.
The interceptor works inside Hibernate's flush/dirty-check itself, which JTA does
not override.

**Also fixed: the masking 401.** When a service threw a 500, Spring re-dispatched
to `/<context-path>/error`, which was **not** in authorization-server's
`permitAll()` → Spring Security challenged the anonymous error dispatch →
`AuthenticationErrorHandler` → 401. Added `/error` to the permit list so a 500
reads as a 500. Mirror this in any service with a custom `AuthenticationEntryPoint`.

**How to diagnose a lock like this:** don't trust the HTTP status. Trace the
request thread in the service log to the real exception (1205 here), then catch
the lock live — poll `performance_schema.data_lock_waits` joined to
`information_schema.innodb_trx` while reproducing; it names the blocking txn, its
held lock, and (via `events_transactions_current.XID_GTRID`) which XA branches
belong to one global transaction.

### SCAR: product detail 500 — null quantity SUM unboxed; and browser image URLs

Two storefront bugs found smoke-testing the running cluster:
- **`GET /v1/products/{id}` → 500.** `ProductServiceImpl.get()` unboxed
  `getQuantitySumByProductId()` (a SQL `SUM`, which returns **null** over zero
  history rows) straight into a primitive `long` → NPE. `list()`/`listByIds()`
  already null-coalesced; `get()` didn't. Fix: `quantitySum != null ? … : 0`.
  Many products have no `product_quantity_history` rows, so this hit most detail
  pages (see also the [[project_inventory_seed]] memory).
- **Product images 404 / unreachable.** Two layers: (1) seeded `image_url` used
  `http://localhost:9000/...` (docker-compose host port) and Vault
  `s3.public-base-url` used cluster-internal DNS — neither reachable from a
  browser; only :80/:443 reach the host. Fixed with a `media.microecom.local`
  Ingress → minio:9000, Vault `s3.public-base-url=http://media.microecom.local/
  ecommerce-media`, and a host rewrite in `02-mongo-seed/seed.sh`
  (`localhost:9000` → `media.microecom.local`; keeps docker/product.json as the
  shared source). (2) **The image objects never existed** — no `.jpg` in the
  repo, no upload seed, empty bucket. `make k8s-seed-images`
  (`scripts/seed/k8s-placeholder-images.sh`) generates+uploads placeholders.
  Needs `/etc/hosts`: `127.0.0.1 media.microecom.local`.

### SCAR: 02-mongo-seed/seed.sh had a stray trailing backtick (parse error)

`k8s/infra/jobs/02-mongo-seed/seed.sh` ended with a lone `` ` `` →
`sh -n` failed with "unexpected end of file". A fresh `make k8s-seed` would
abort the mongo-seed Job entirely (no products/api_role). Always `sh -n` the
seed scripts after editing — they run under `set -eu`, so a parse error is fatal.


### SCAR: k8s vault-seed must mirror docker/vault-configs/*.json key-for-key

`k8s/infra/jobs/03-vault-seed/seed.sh` is a hand-written reimplementation of the
docker `docker/vault-configs/*.json` secrets. It silently dropped keys the apps
need; each missing key surfaced only as a runtime crash/500 far downstream —
several times this bring-up:
- missing `authorization-server` block → `Could not resolve placeholder
  'application.access-token.life-time'` (crashloop)
- missing `spring.kafka.properties.schema.registry.url` (common `ecommerce`
  block) → `Failed to construct kafka consumer` (crashloop)
- missing `spring.data.mongodb.database=ecommerce_inventory` (common block) →
  gateway read `api_role` from the wrong DB → Mongo error 13 → every route 500.
  Gateway's mongo config uses this explicit property, NOT the URI path.

**How to apply:** when editing `seed.sh`, diff every key against the matching
`docker/vault-configs/*.json` (+ `ecommerce-common.json` for the `ecommerce`
context). A missing key won't fail the seed — it fails an app at runtime as an
opaque 500. Patching vault after apps are up needs an app restart (vault read at
boot only); and `put_if_missing` skips existing paths, so use `vault kv patch`
to add keys to an already-seeded path.

### SCAR: `put_if_missing <path>` is per-PATH — never split one service across two blocks

`put_if_missing` writes a Vault path only if it doesn't already exist. So a
SECOND `put_if_missing gateway` block is silently a no-op — the path exists from
the first block and the second block's keys are **dropped**. This bit the
gateway: its route URIs lived in a separate second `put_if_missing gateway`
block and never got written, so the gateway fell back to the application.yml
defaults `uri: lb://<SERVICE>`. With Eureka disabled (k8s DNS), `lb://` has no
instances → `503 "Unable to find instance for PRODUCT-SERVICE"` on every routed
request (storefront browse 503'd even though product-service was 1/1).

**How to apply:** exactly ONE `put_if_missing` per Vault path — merge all keys
for a service into a single call. The gateway needs jwt/jwk config AND its
`gateway.routes.<svc>.uri=http://<svc>.apps.svc.cluster.local:<port>` overrides
in the same block. Those route URIs are mandatory in k8s because Eureka is off;
without them gateway routes resolve to `lb://` and fail. (Live repair:
`vault kv patch secret/gateway gateway.routes.<svc>.uri=…` then restart gateway.)

### SCAR: gateway ingress backend port must match the Service port (6868, not 8080)

The gateway ingress backend was `port.number: 8080` (the docker-compose external
port), but the k8s gateway Service exposes `6868` (named `http`). nginx had no
matching endpoint → every request through the ingress returned `503 Service
Temporarily Unavailable` (nginx's own page, not the app's). Fixed by referencing
the named port (`port.name: http`) so it tracks the Service. See
`apps/base/gateway/ingress.yaml`.

### SCAR: seed Jobs can't use `kubectl apply -k` for out-of-tree data

The mysql/mongo seed Jobs need a *data* configMap built from `docker/ecommerce.sql`
and `docker/*.json` — the single source of truth, shared with docker-compose.
A `configMapGenerator` with `files: [../../../../docker/ecommerce.sql]` fails:
`kubectl apply -k` uses kubectl's **embedded** kustomize, which hardcodes
`LoadRestrictionsRootOnly` and exposes no `--load-restrictor` flag, so it refuses
sources outside the kustomization dir (`security; file '...' is not in or below`).

**How to apply:** `make k8s-seed` creates BOTH configMaps for these two Jobs
**imperatively** (`kubectl create configmap … --from-file=… --dry-run=client -o
yaml | kubectl apply -f -`; imperative create has no path restriction) and
applies the Job with plain **`kubectl apply -f job.yaml`**, NOT `apply -k`. The
`kustomization.yaml` in those two dirs is superseded — don't re-introduce
`apply -k` for them. The other 3 Jobs (vault/minio/kafka-connect) have no
out-of-tree refs and still use `apply -k`.

### OPEN ISSUE (not yet resolved): mysql seed runs before any schema exists

`docker/ecommerce.sql` is **data-only** (0 `CREATE TABLE`; INSERTs only). The
schema is created by Hibernate `ddl-auto` when the JPA services boot. But the
bootstrap order is `… k8s-seed → k8s-apps`, so `mysql-seed` runs *before* any
app has created tables → `ERROR 1146 ... Table 'ecommerce_dev.account' doesn't
exist`. (MongoDB is schemaless, so `mongo-seed` is unaffected.) This is a real
ordering dependency that needs a decision — see the handoff; not yet fixed.

### SCAR: don't announce a root cause from garbled/lagged terminal output

**What happened (2026-05-30, kind cluster bring-up):** While debugging
`make k8s-bootstrap` failing at `kubeadm init` (kubelet never healthy), I
announced **two** confident root causes that were both **wrong**:
1. "The OrbStack VM only has 4GB — it's out of memory." (Actually 16GB; a
   single-node test cluster came up `Ready` in seconds.)
2. "The kind nodes get a dead DNS nameserver, containerd can't pull images."
   (Actually DNS resolved fine; `crictl images` showed the images were
   already present.)

Both wrong conclusions came from **reading lagged, interleaved, or partial
tool output** — the terminal in this environment sometimes flushes output from
a *previous* command into the *current* one, or returns empty then catches up.
I treated that noise as evidence and theorized on top of it.

**The real root cause** was only found by reading the actual containerd journal
inside the retained node:
`invalid cri image config: 'mirrors' cannot be set when 'config_path' is provided`
— a containerd 2.x change (see next scar).

**Why it matters:** each wrong "root cause" would have sent us down a useless
path (buying RAM, rewriting DNS) and eroded trust. Guessing is not debugging.

**How to apply:**
- **Verify before asserting.** A root cause is a claim you can demonstrate, not
  the first plausible story. Reproduce it; read the actual error from the actual
  component (`journalctl -u containerd`, pod logs, `crictl`), not a summary.
- **Distrust lagged output.** If a tool result looks empty, contradictory, or
  out of order, re-run the single command in isolation and confirm before
  drawing any conclusion. Use `--retain` on `kind create` so a failed node can
  be autopsied instead of guessing.
- **Say "I don't know yet"** rather than narrating a guess as a finding.
- Follow `superpowers:systematic-debugging` Phase 1 literally: read the error,
  reproduce, gather evidence at the failing layer — *then* hypothesize.

### SCAR: never report success from stale / replayed tool output (esp. after compaction)

**What happened (2026-05-30, stateful migration):** the conversation was
compacted mid-task. On resume, the transcript **replayed old tool results** —
including earlier "Kafka topic round-trip OK" and "MinIO bucket created"
outputs. I treated those replayed results as current truth and:
1. Believed `manifests/minio.yaml` and `manifests/kafka.yaml` existed and were
   verified — but their `Write` calls had been **cancelled** inside an errored
   parallel batch, so the files were **never on disk**. I only caught it when a
   follow-up `Edit` failed with `File does not exist`.
2. Queued a `TaskUpdate` marking "make k8s-infra" **completed**, with a detailed
   description claiming seed Jobs succeeded and the connector was RUNNING —
   while the entire batch containing that run had been **cancelled** and the
   command had **never executed**.

Both are the same failure as the garbled-output scar, one level worse:
fabricating a *verification* and a *status* from output that was never evidence
of the current state.

**Why it matters:** "it's done and verified" is the single claim the user most
needs to trust. Reporting it falsely — even from honest confusion about replayed
output — is the most expensive mistake here.

**How to apply:**
- **A claim of success must be backed by a tool result from *this* turn.** Before
  saying "verified" / "complete" / marking a task done, re-run the check now.
  Never carry a verification across a compaction boundary.
- **When a parallel batch errors, assume every *other* call in it was cancelled**
  — its result is not real. Re-issue the ones that matter, alone.
- **After compaction, re-establish ground truth before acting:** `ls` the files
  you think you wrote, `kubectl get` the resources you think you applied. Trust
  the filesystem and the cluster, not the replayed transcript.
- **Verify file writes structurally:** if a later `Edit`/`Read` says
  `File does not exist`, the earlier `Write` did not happen — don't rationalize.

### Harness notes (local quirks that bit me)

- **Background jobs:** `nohup cmd &` from a tool call gets **reaped** when the
  call returns — the process dies. Use the tool's `run_in_background: true`
  (harness-tracked, notifies on exit) and Read its output file, or `Monitor`
  with a `grep --line-buffered` filter that covers **both** success and failure
  lines (silence ≠ success).
- **Don't over-batch unrelated commands.** One `Bash` call with a syntax error
  (or a blocked `rm`) **cancels every other call queued in the same batch** —
  including `Write`/`Edit`, which then silently never happen. Keep risky or
  destructive calls in their own turn.
- **`rm` is sandbox-blocked** for the assistant; ask the user to run it with the
  `! ` prefix. Note: `k8s/infra/values/*.yaml` are **root-owned** — even the
  user's `rm` gets `permission denied`; they need `sudo rm` (or just leave them,
  they're unreferenced).

### SCAR: kind node images are containerd 2.x — legacy `registry.mirrors` is rejected

`kindest/node` from kind ≥ 0.30 ships **containerd 2.x**, which made the inline
`[plugins."io.containerd.grpc.v1.cri".registry.mirrors...]` config **mutually
exclusive** with `config_path` (kind sets `config_path` by default). A
`containerdConfigPatches` mirrors block in `kind/cluster.yaml` makes containerd
refuse to load the **entire CRI plugin** → no `runtime.v1.ImageService` →
kubelet never healthy → `kubeadm init` times out after 4 min with a misleading
"kubelet is unhealthy / cgroups" hint.

**How to apply:** wire the local registry via the `config_path` `hosts.toml`
mechanism in `kind/registry.sh` (writes
`/etc/containerd/certs.d/localhost:5001/hosts.toml` per node), **not** via a
`containerdConfigPatches` mirrors block. This is also the officially documented
kind local-registry pattern.

### SCAR (resolved 2026-06-02): a transient quay.io 502 fails the whole bootstrap (kps `helm --wait`)

**What happened (2026-06-01):** `make k8s-bootstrap` died at `k8s-infra` with
`Deployment/monitoring/kps-grafana ... Progress deadline exceeded` (+ operator +
node-exporter). Root cause was **not** the cluster or the registry work — it was
a transient **quay.io 502 Bad Gateway** during the install window. Three
quay.io-hosted images (`prometheus-operator`, `node-exporter`, grafana's
`quay.io/kiwigrid/k8s-sidecar`) gated `helm upgrade --install kps ... --wait`, so
a few minutes of ImagePullBackOff tripped the 10-min deadline and aborted `make`.

**Resolved by removing the exposure:** kube-prometheus-stack is gone —
observability is now **VictoriaMetrics single-node + Grafana + kube-state-metrics**
in the `monitoring` namespace. VM single-node is scraper + TSDB + remote-write
receiver in one binary (`vmsingle.monitoring.svc.cluster.local:8428`; values in
`infra/values/victoria-metrics.yaml`). Services are scraped via Kubernetes
endpoint SD on the `management` port **name** (number varies per service), so
there are **no ServiceMonitors** and no Prometheus Operator — applying a
ServiceMonitor now fails (no CRD). Pod/node CPU/mem come from the **kubelet
cAdvisor** scrape, not node-exporter; restarts/OOM from kube-state-metrics.
`make k8s-stress` (k6) remote-writes to VM — view it on Grafana dashboard #19665.
All three charts pull from `docker.io` / `registry.k8s.io`, so the quay.io images
**and** the host-side pre-pull + `kind load` workaround that defended them were
deleted from `install.sh`. Rationale + the meltdown that motivated the switch:
`docs/superpowers/specs/2026-06-02-victoriametrics-observability-design.md`.

**Durable lesson (still applies):** don't blame the cluster/registry config for an
ImagePullBackOff until you've confirmed the registry host is up —
`curl -sS -o /dev/null -w '%{http_code}' https://<host>/v2/` from the host and a
`crictl pull` from inside a node settle it in seconds. If a future chart pins an
image on a flaky registry, the same defense (verify the tag with `docker manifest
inspect`, pre-pull, `kind load` with a fixed tag + `IfNotPresent`) extends.

### SCAR: Bitnami Docker Hub images are deprecated (deleted 2025-09-29)

`docker.io/bitnami/<name>:<tag>` versioned images were removed and moved to the
frozen, unsupported `docker.io/bitnamilegacy/*` archive. Any Bitnami Helm chart
pinned to a versioned image now fails with `ImagePullBackOff` /
`... : not found`.

`install.sh` historically installed 6 Bitnami charts (metrics-server, mysql,
mongodb, redis, minio, kafka). **Migration complete** off Bitnami:
- `metrics-server` → upstream `kubernetes-sigs/metrics-server` chart.
- 5 stateful services → **Docker Official Images** as plain manifests in
  `infra/manifests/`, keeping every Service DNS name unchanged so Vault seed +
  app config + seed Jobs are untouched:
  - `mysql:8.0`, `mongo:7.0`, `redis:7.4-alpine`, `minio/minio` + `minio/mc`,
    `apache/kafka:3.9.1`.
  - Seed Jobs also de-Bitnamied: `01-mysql-seed` → `mysql:8.0`,
    `02-mongo-seed` → `mongo:7.0` (both carry the needed `mysql` / `mongosh` +
    `mongoimport` CLIs).
- The old `infra/values/{mysql,mongodb,redis,minio,kafka}.yaml` are now
  **unreferenced** (root-owned, `sudo rm` to remove). `install.sh` no longer
  adds the `bitnami` helm repo.

Two manifest-specific gotchas worth keeping (full rationale in each file's
header comment):
- **MongoDB** runs `--replSet rs0 --auth --keyFile`. The replica set is
  initiated and users created by an **in-pod `bootstrap` sidecar over 127.0.0.1**
  — MongoDB's localhost exception is loopback-scoped, so a *separate* init Job
  connecting via Service DNS always fails `replSetInitiate requires
  authentication`. The sidecar shares the pod netns, so its loopback counts.
  (`mongosh` is Node/V8 — give the sidecar ≥512Mi or it OOMKills mid-createUser.)
- **Kafka** uses Apache's `KAFKA_*` env (Bitnami used `KAFKA_CFG_*` — silently
  ignored here). KRaft needs a hardcoded `CLUSTER_ID`; `--ignore-formatted`
  makes re-runs idempotent against the PVC.

**How to apply:** don't add new `bitnami/*` chart dependencies. Prefer
first-party Docker Official Images or maintained upstream charts. `bitnamilegacy`
is a short-term bridge only (frozen, removable without notice).

### SCAR: vault-agent-injector breaks `helm upgrade` idempotency (self-managed caBundle)

The HashiCorp Vault chart's **agent-injector** self-injects its CA into its own
`MutatingWebhookConfiguration` at runtime (field manager `vault-k8s` owns
`.webhooks[].clientConfig.caBundle`). A **fresh** install works, but the
**second** `helm upgrade` (i.e. any re-run of `make k8s-infra`) fails:

```
UPGRADE FAILED: conflict ... MutatingWebhookConfiguration vault-agent-injector-cfg:
Apply failed with 1 conflict ... .webhooks[name="vault.hashicorp.com"].clientConfig.caBundle
```

This is a pure **idempotency** failure — the stack is healthy, the re-apply just
can't reconcile a field the injector owns. It also leaves the helm release in
`STATUS: failed`.

**How to apply:** this stack's services read Vault directly via **Spring Cloud
Vault** (`SPRING_CLOUD_VAULT_URI` + token auth in `apps/base/*/deployment.yaml`);
nothing uses sidecar injection (no `vault.hashicorp.com/agent-inject`
annotations). So `injector.enabled: false` in `infra/values/vault.yaml` is the
right fix — it removes the webhook entirely and re-runs cleanly. If you ever
need agent injection, you must reconcile the caBundle ownership (e.g.
`--force`, or exclude the webhook from helm), not just re-run.

### SCAR: Confluent cp images need `enableServiceLinks: false` in k8s

`confluentinc/cp-schema-registry` (and other cp-* images) exit 1 at
`===> Configuring ...` — before the JVM starts — when run as a normal Deployment
in a namespace that has a `kafka` Service. Cause: Kubernetes **service-link env
injection** sets `KAFKA_PORT=tcp://10.x.x.x:9092` (plus a pile of `KAFKA_*` /
`*_PORT` vars) for every Service in the namespace. The cp image's `configure`
scripts read `KAFKA_*`-style env and choke on the `tcp://…` value. (The
`PORT is deprecated` line in the log is incidental — bare `PORT` is empty.)
Standalone `docker run` works because there's no injection; in-cluster it dies.

**How to apply:** set `enableServiceLinks: false` on the pod spec of any
Confluent cp-* workload. The service reaches Kafka via its explicit
`SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS` (Service DNS), not env discovery.
Diagnose injected env with a throwaway `kubectl run busybox -- sh -c 'echo $KAFKA_PORT'`.

### Local-dev caveat: ingress exposes :80/:443 via hostPort, not NodePort

The ingress-nginx controller reaches the host on 80/443 through **hostPort**
(bound to the control-plane node, which `cluster.yaml` maps to the host via
`extraPortMappings`). Its Service is plain **ClusterIP**. Do **not** set
`service.type: NodePort` with ports 80/443 — NodePort only allows 30000–32767,
so the chart's server-side apply is rejected
("provided port is not in the valid range"). See `infra/values/ingress-nginx.yaml`.
