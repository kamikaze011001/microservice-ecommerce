# Helm apps subchart — design spec (Plan 3)

**Date:** 2026-08-04
**Phase:** 3 of the deploy refactor
**Parent spec:** `docs/superpowers/specs/2026-08-01-deploy-refactor-design.md` (lines 893–914)
**Predecessor:** Plan 2 — `docs/superpowers/specs/2026-08-02-helm-infra-subchart-design.md` (merged, PR #52)

## Goal

Convert the 10 application Deployments under `k8s/apps/base/` plus the `local`
and `aws` Kustomize overlays into a Helm `apps` subchart at
`deploy/charts/microecom/charts/apps/`, rendered by the existing umbrella
chart.

**Side by side, not a cut-over.** `k8s/apps/` is not modified and not deleted.
A new `make k8s-apps-helm` target runs alongside the existing `make k8s-apps`.
Rolling this phase back is reverting one Makefile target. Deleting `k8s/` is
Phase 8.

## Why

`k8s/apps/` is 1,734 lines of YAML across 10 services whose Deployments are
close to identical — the same probe paths, the same port pair, the same JVM
env block, differing only in numbers. The Kustomize layout multiplies that
uniformity by ten and then multiplies it again per environment.

The concrete defect class this removes: adding a service today requires a base
directory, a line in the local overlay, an `aws/<service>/` directory with
three to four files, **and** remembering to add a path to the hand-written ALB
Ingress. Miss the last one and the service works locally and is invisible on
AWS. Under this design the ALB paths are derived from the service list, so the
divergence is not representable.

---

## 1. Approach

Three approaches were considered. The axis is **where per-service variation
lives** — in template conditionals, or in values.

- **A — one template, variation in values** (chosen). Probes, ports, env and
  resources are all value-driven with chart-level defaults; the frontend
  overrides more defaults than the others but is not a special case in the
  template.
- **B — two templates**, `jvmDeployment` for the 9 plus a standalone frontend
  template. Rejected: the frontend's differences (no management port, probes
  on `/`, no env) are all things A must parameterize anyway, because the 9 JVM
  services already differ from each other on timings and ports. Once probes are
  value-driven the frontend costs one values block, not a second template.
- **C — ten per-service template files**, a mechanical 1:1 translation.
  Rejected: keeps the 10× duplication and buys nothing over Kustomize except
  running one tool instead of two. Retained as the fallback if A's template
  turns out to need substantially more than the six escape hatches below.

---

## 2. Chart layout

```text
deploy/charts/microecom/charts/apps/
├── Chart.yaml
├── values.yaml                  # defaults{} + apps{} per-service blocks
└── templates/
    ├── _helpers.tpl             # microecom.container, microecom.labels, microecom.fqdn
    ├── deployments.yaml         # range over .Values.apps
    ├── services.yaml            # range
    ├── hpas.yaml                # range, gated per-service on .hpa
    ├── ingress.yaml             # className-selected: nginx block | alb block
    ├── gateway-rbac.yaml        # gated on apps.gateway.rbac
    ├── externalsecrets.yaml     # gated on global.secret.backend == eso
    └── irsa-serviceaccounts.yaml # gated on global.secret.backend == eso
```

Wired into the umbrella `Chart.yaml` with `condition: apps.enabled`, matching
how `infra` is wired.

### Subchart `.Values` asymmetry (carried from Plan 2)

Inside `charts/apps/templates/*`, write `.Values.defaults` and `.Values.apps`
(unprefixed). But `condition:` in the umbrella `Chart.yaml`, `--set apps.X.…`
in the test harness, and keys in the umbrella's `values.yaml` / `envs/*.yaml`
stay fully qualified (`apps.apps.gateway.…` is correct and is not a typo to
"fix"). Do not normalize one form to match the other.

---

## 3. Values schema

```yaml
defaults:
  replicas: 1
  imagePullPolicy: Always
  resources:
    requests: { cpu: 100m, memory: 512Mi }
    limits:   { cpu: 1000m, memory: 768Mi }
  probes:
    liveness:
      path: /actuator/health/liveness
      port: management
      initialDelaySeconds: 60
      periodSeconds: 15
      failureThreshold: 4
    readiness:
      path: /actuator/health/readiness
      port: management
      initialDelaySeconds: 30
      periodSeconds: 10
      failureThreshold: 6
  env:
    MALLOC_ARENA_MAX: "2"
    JAVA_OPTS: "-XX:MaxRAMPercentage=75.0 -XX:+UseG1GC"
    VAULT_TOKEN: root
    SPRING_CLOUD_VAULT_URI: http://vault.infra.svc.cluster.local:8200

apps:
  authorization-server: { port: 6666, managementPort: 19091, … }
  bff-service:          { port: 8087, managementPort: 18087 }
  frontend:             { port: 8080, managementPort: null, env: null, … }
  gateway:              { port: 6868, managementPort: 19093, rbac: true, … }
  inventory-service:    { port: 6969, managementPort: 16969, … }
  mock-paypal-service:  { port: 8585, managementPort: 18585, … }
  orchestrator-service: { port: 9999, managementPort: 19999 }
  order-service:        { port: 9696, managementPort: 19696 }
  payment-service:      { port: 8484, managementPort: 18484, … }
  product-service:      { port: 7777, managementPort: 17777, … }
```

**The snippet above is illustrative; the table below is normative.** Every
value in it is transcribed from the existing base manifests
(`k8s/apps/base/<service>/deployment.yaml`) and must match them exactly.
`initialDelaySeconds` for liveness/readiness is shown as `L/R`; where blank,
the service inherits the defaults (60/30).

| Service | port | mgmt | requests cpu/mem | limits cpu/mem | probe L/R | extras |
|---|---|---|---|---|---|---|
| authorization-server | 6666 | 19091 | 250m/512Mi | 2000m/768Mi | — | hpa, envFrom, `JAVA_OPTS` adds `-XX:+UseStringDeduplication` |
| bff-service | 8087 | 18087 | 100m/256Mi | 1000m/384Mi | — | — |
| frontend | 8080 | none | 20m/32Mi | 200m/64Mi | see §5 | ingress, no env |
| gateway | 6868 | 19093 | 200m/512Mi | 1500m/768Mi | 45/25 | hpa, rbac, ingress, `SPRING_PROFILES_ACTIVE=k8s` |
| inventory-service | 6969 | 16969 | 200m/512Mi | 1500m/768Mi | — | hpa, `extraPorts: grpc 9090` |
| mock-paypal-service | 8585 | 18585 | 50m/256Mi | 500m/384Mi | 30/15 | `MOCK_PUBLIC_BASE_URL`, no Vault env, `JAVA_OPTS` is `-XX:MaxRAMPercentage=75.0` only |
| orchestrator-service | 9999 | 19999 | 100m/512Mi | 1000m/768Mi | — | — |
| order-service | 9696 | 19696 | 200m/512Mi | 1500m/768Mi | — | hpa |
| payment-service | 8484 | 18484 | 100m/512Mi | 1000m/768Mi | — | envFrom |
| product-service | 7777 | 17777 | 200m/512Mi | 1500m/768Mi | — | hpa |

`periodSeconds` (15 liveness / 10 readiness) and `failureThreshold`
(4 liveness / 6 readiness) are uniform across all 9 JVM services.

### `managementPort` must stay explicit — do not derive it

`managementPort` is Spring Boot Actuator's separate listener
(`management.server.port` in each service's `application.yml`), carrying
`/actuator/health/{liveness,readiness}` and `/actuator/prometheus`. Both
probes target it by name, so a wrong value means permanent readiness failure.

Seven of the nine JVM services follow `port + 10000`. **Two do not:**

| Service | http | management | `port + 10000` would give |
|---|---|---|---|
| authorization-server | 6666 | **19091** | 16666 ✗ |
| gateway | 6868 | **19093** | 16868 ✗ |

Verified against `authorization-server/src/main/resources/application.yml` and
`gateway/src/main/resources/application.yml`, which match the k8s manifests
exactly. They appear to be fossils of the older shared-`9091` scheme CLAUDE.md
describes, later prefixed with `1`.

So `managementPort` is listed per service and **must never be derived in the
template**. Deriving it would render correctly for seven services and silently
point authorization-server's and gateway's probes at dead ports — both pods
failing readiness forever, with a values file that looks clean.

General rule this instance illustrates: derive a value only when the
relationship is *enforced* somewhere, not merely *observed* to hold. The ALB
paths (§6) are safe to derive because the gateway's `Path=/<service-name>/**`
routing convention enforces them. Management ports are not.

HPA min/max/target values are transcribed verbatim from the five existing
files — `k8s/apps/base/{authorization-server,gateway,inventory-service,
order-service,product-service}/hpa.yaml` — and are not redesigned here.

### Merge mechanism — three load-bearing rules

```gotemplate
{{- range $name, $svc := .Values.apps }}
{{- if $svc.enabled }}
{{- $s := mergeOverwrite (deepCopy $.Values.defaults) $svc }}
```

1. **`deepCopy` is mandatory.** Sprig's `merge` / `mergeOverwrite` wrap mergo's
   in-place API and **mutate the destination**. Without `deepCopy`, the first
   service's overrides permanently contaminate `$.Values.defaults` and every
   service rendered afterwards inherits them. Go template `range` over a map
   iterates in sorted key order, so the corruption is deterministic but looks
   arbitrary — `gateway` sorts fourth of ten, so the six services after it
   (`inventory-service`, `mock-paypal-service`, `orchestrator-service`,
   `order-service`, `payment-service`, `product-service`) would silently
   inherit gateway's `initialDelaySeconds: 45`, except where they set their
   own. This is asserted by a test (§7).
2. **`enabled` is read from raw `$svc`, before the merge.** Mergo treats falsy
   values as absent, so `enabled: false` cannot reliably survive a merge
   against a default of `true`.
3. **Deletion needs an explicit `null` sentinel, not omission.** A merge cannot
   remove an inherited key. The frontend has no `managementPort` and no `env`;
   mock-paypal-service has no Vault env pair. All three are expressed as
   `null`, and templates test truthiness (`if $s.managementPort`) rather than
   `hasKey`.

`env` is a **map**, not a list, precisely because a YAML list cannot merge
element-wise. The list-of-`{name,value}` shape appears only at render time,
emitted by `range` over the map — which is sorted, so renders are
deterministic and diffs are stable.

---

## 4. Shared template and escape hatches

`microecom.container` renders the container block: name, image
(`{{ global.appImage.registry }}/{{ $name }}:{{ tag }}`), `imagePullPolicy`,
the port list, env, envFrom, both probes, and resources.

Six escape hatches cover every non-uniformity the survey found:

| Hatch | Used by | Mechanism |
|---|---|---|
| `extraPorts` | inventory-service (grpc 9090) | appended to container ports, mirrored into the Service |
| `env` overrides | gateway, mock-paypal-service, authorization-server | map merge; a per-key `null` unsets an inherited var |
| `envFrom` | authorization-server, payment-service | `with` guard |
| `serviceAccountName` | gateway (local), authorization-server + product-service (AWS IRSA) | `with` guard |
| `hpa` | 5 services | whole block absent unless the key exists |
| `ingress` | gateway, frontend | own template, className-selected (§6) |

A seventh, `serviceAnnotations`, exists for the ALB healthcheck annotations and
is set only in `envs/aws.yaml`.

Three of the seven (`envFrom`, `serviceAccountName`, `serviceAnnotations`) are
one-line `with` guards. `extraPorts` is a `range`, `env` rides the existing
merge, `hpa` gates a whole template body, and `ingress` lives in its own file.
None of the seven adds branching logic to the container block.

### Namespace

Apps objects render into namespace `apps` (`global.namespaces.apps`, already
declared in the umbrella's `values.yaml`), set explicitly in
`metadata.namespace` on every object, as the infra subchart already does. The
Helm release namespace (`--namespace infra`) does **not** determine object
placement — never rely on it as a default.

The umbrella's `templates/namespaces.yaml` already creates `apps` (it ranges
`global.namespaces` and skips `infra`, which `--create-namespace` handles), so
no new namespace object is needed for this phase.

### Labels and selector immutability

Every object carries `app.kubernetes.io/name: {{ $name }}`,
`app.kubernetes.io/instance` and `app.kubernetes.io/managed-by`. No bare
`app:` key anywhere. This carries the Plan 2 lesson forward: kafka-connect used
a bare `app:` label where every sibling used `app.kubernetes.io/name`, and a
cross-cutting selector silently skipped it.

**Verified consequence:** the existing base manifests use bare
`app: <service-name>` as their `spec.selector.matchLabels`
(`k8s/apps/base/order-service/deployment.yaml`,
`k8s/apps/base/frontend/service.yaml`). `spec.selector` is **immutable** on a
Deployment, so the Helm apps release cannot be installed over a cluster where
`make k8s-apps` has already run, and vice versa.

This is not a new constraint. Plan 2 established the same rule for infra
(`deploy/README.md`, "The two infra bring-up paths are alternatives, not
composable, on one cluster"). It now extends to apps: **pick one path per
cluster**, and tear the cluster down before switching.

---

## 5. The frontend

Caddy serving a static Vite build. No JVM, no management port, no actuator, no
env at all (the API base URL is baked into the JS bundle at image-build time).

It is not a template special case — it is a values block that overrides more
defaults than the others:

```yaml
frontend:
  port: 8080
  managementPort: null
  env: null
  resources:
    requests: { cpu: 20m, memory: 32Mi }
    limits:   { cpu: 200m, memory: 64Mi }
  probes:
    liveness:  { path: /, port: http, initialDelaySeconds: 10, periodSeconds: 30 }
    readiness: { path: /, port: http, initialDelaySeconds: 2,  periodSeconds: 5 }
  ingress: { host: microecom.local }
```

The base frontend `readinessProbe` carries no `failureThreshold`; the merge
inherits the default (6) rather than reproducing the omission. This is a
deliberate, stated change: an inherited explicit 6 matches the Kubernetes
default the omission was already relying on.

The frontend Service listens on port 80 targeting container port 8080,
matching the base manifest.

---

## 6. Environment divergence

### Secret backend — `global.secret.backend` ∈ {`vault`, `eso`}

The AWS overlay does four things today. Three need **no template branch** —
they are pure data in `envs/aws.yaml`, applied once to `defaults` rather than
nine times via a JSON6902 component:

```yaml
apps:
  defaults:
    env:
      VAULT_TOKEN: null
      SPRING_CLOUD_VAULT_URI: null
      SPRING_CLOUD_VAULT_ENABLED: "false"
      SPRING_CONFIG_IMPORT: optional:configtree:/etc/app-config/
```

IRSA is the fourth: `serviceAccountName` on authorization-server and
product-service, an existing hatch, set in `envs/aws.yaml`.

What genuinely needs the enum:

- **the `app-config` volume** — Secret name is per-service (`<name>-config`),
  mounted read-only at `/etc/app-config`
- **`externalsecrets.yaml`** — one ExternalSecret per JVM service
- **`irsa-serviceaccounts.yaml`** — the S3 IRSA ServiceAccounts

That last file exists today at `k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml`
**referenced by no kustomization**, applied imperatively by a script. Making it
a chart object gated on the enum is a correctness win: the "present in the
directory but not wired in" state stops being representable.

### Ingress — `global.ingress.className` ∈ {`nginx`, `alb`}

One `ingress.yaml` containing two whole blocks, not a shared loop. The two are
structurally different enough that unifying them would be false economy:

| | `nginx` (local) | `alb` (AWS) |
|---|---|---|
| objects | 2 — gateway + frontend | 1 |
| hosts | `api.microecom.local`, `microecom.local` | `shop.microecom.click` |
| routing | `/` → each backend | 8 `/<service>` paths → `gateway:http`; `/` → `frontend:80` |
| annotations | 120s nginx proxy timeouts (k6 bursts) | ALB healthcheck, on the **Service** |

**The 8 ALB paths are derived, not listed:** range `.Values.apps`, skip
`gateway` and `frontend`, emit `/<name>` → `gateway:http`. That is exactly the
8 in the hand-written manifest today (authorization-server, bff-service,
inventory-service, mock-paypal-service, orchestrator-service, order-service,
payment-service, product-service), and it follows from the repo's routing
convention: each service sets `server.servlet.context-path: /<service-name>`
and the gateway routes `Path=/<service-name>/**` with no `StripPrefix`.

The nginx block's 120s proxy-timeout annotations are transcribed verbatim from
`k8s/apps/base/gateway/ingress.yaml`.

---

## 7. Verification

### `render-test.sh` — no cluster, no network

Extends the existing harness (115 assertions as of Plan 2). Governing rule,
carried from Plan 2: `helm template` output is **one flat text stream**, so an
unscoped assertion only asks "does this string appear anywhere in the release?"
Six vacuous assertions were found that way last phase.

**Standard for every new assertion: would it fail if the object it names were
deleted?** Scope by the `docs_of_kind <Kind>` helper or `--show-only`. Every
new assertion is RED-proven — break the thing it claims to prove (via `--set`
or a scratch chart copy under `/private/tmp/`), confirm it fails, restore,
confirm it passes.

**The carry-over must be honored, not skipped.** `render-test.sh:129`'s
`assert_lacks 'image: .*localhost:5000/'` is **rescoped to infra documents**,
because apps images legitimately are `localhost:5000/...`. The in-file comment
at line 127 already mandates this. Deleting the assertion would surrender the
check that caught the `global.image.registry` collision in Plan 2.

The load-bearing new assertion:

```bash
# deepCopy contamination guard — §3 rule 1, encoded as a test.
# gateway overrides liveness initialDelaySeconds to 45. If the template merges
# without deepCopy, .Values.defaults is mutated in place and every service
# sorting after "gateway" inherits 45. Asserting the sibling still gets 60
# fails loudly the moment the deepCopy is dropped.
assert_deployment_probe "order-service" liveness initialDelaySeconds 60
```

This applies the general rule earned in Plan 2: **when a lesson is "X must be
derived from Y", encode the relationship as a test.** A lesson that lives only
in a comment gets re-learned.

Remaining new assertions, all scoped:

- 10 Deployments and 10 Services rendered; names match the values keys
- inventory-service's `grpc` port present on both its Deployment and Service
- mock-paypal-service's Deployment carries **no** `VAULT_TOKEN` (null-unset)
- gateway's Deployment carries `SPRING_PROFILES_ACTIVE=k8s`; no other does
- HPA objects for exactly the 5 named services
- ServiceAccount + Role + RoleBinding for gateway only
- `className=nginx` → exactly 2 Ingress objects with the two local hosts
- `className=alb` → exactly 1 Ingress with exactly 8 `/<service>` paths plus
  the `/` catch-all
- `backend=vault` → zero ExternalSecrets, zero `app-config` volumes, zero IRSA
  ServiceAccounts
- `backend=eso` → 9 ExternalSecrets, 9 `app-config` volumes
- resources, ports and probe timings match the §3 table per service

### Live cluster

Render tests prove the YAML says the right thing. These prove it works.
`make k8s-build-reuse` runs first — app images are locally built, so unlike
Plan 2 there is no Docker Hub rate-limit exposure.

| # | Check |
|---|---|
| 1 | All 10 pods Ready, 0 restarts |
| 2 | Gateway RBAC functions — Spring Cloud Kubernetes discovery resolves services, not merely "the Role object exists" |
| 3 | Storefront browse through the ingress returns the 30 seeded products |
| 4 | inventory-service gRPC reachable on 9090 from order-service |
| 5 | Idempotence — re-install reaches revision 2 with no object churn |
| 6 | AWS gating — a full `envs/aws.yaml` render contains no nginx Ingress and no `VAULT_TOKEN` |
| 7 | **Rollback**: `make k8s-apps` (kubectl path) reaches all-Ready |

**Check 7 must run on a cluster where the Helm apps release was never
installed.** A green run on a Helm-populated cluster proves nothing, because
the objects already exist. This exact mistake was made and corrected in Plan 2.

Ordering scar to preserve in `k8s-apps-helm`'s position in the bootstrap
sequence: `k8s-seed-mysql` runs **after** apps, because `docker/ecommerce.sql`
is data-only and Hibernate `ddl-auto` creates the schema at service boot.

---

## 8. Delivery

New Makefile target `make k8s-apps-helm`, alongside the existing
`make k8s-apps`:

```make
k8s-apps-helm:
	@helm upgrade --install microecom deploy/charts/microecom \
	  --namespace infra --create-namespace \
	  -f deploy/charts/microecom/envs/$(or $(ENV),local-k8s).yaml \
	  --set apps.enabled=true \
	  --wait --timeout 30m
```

The umbrella release is shared with infra, so `apps.enabled` gates the
subchart rather than a separate release. `--timeout` stays at 30m and remains
governed by the Plan 2 drift guard, which asserts it stays
`>= activeDeadlineSeconds + 330`.

`k8s/apps/` is not modified. `git diff main HEAD -- 'k8s/**'` must be empty at
the end of this phase — the same rollback guarantee Plan 2 held to.

---

## 9. Non-goals

- **k6 stress Jobs stay on Kustomize.** `k8s/apps/base/k6-stress/` holds three
  Jobs plus three embedded JS flow files — a different resource shape needing a
  `.Files.Glob` ConfigMap. Nothing blocks on it, and folding a second shape
  into the shared template is the scope creep that forces escape hatches on
  day one.
- **`k8s/apps/` is not deleted.** That is Phase 8.
- **The dead `local-with-frontend` overlay is not fixed.** It wraps `../local`
  with its frontend line commented out. Under this design the frontend is just
  `enabled: true`, so the overlay's reason to exist disappears on its own at
  Phase 8.
- **HPA policies are not redesigned.** Existing min/max/target values are
  transcribed verbatim.
- **No new observability, no new services, no probe retuning.** Timing values
  are transcribed, not tuned.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| The `deepCopy` mutation trap silently corrupts 4 of 10 services | Encoded as a render-test assertion (§7), RED-proven |
| A transcription error in the §3 table produces a subtly wrong Deployment | Per-service render assertions on ports, resources and probe timings |
| The shared template needs more than the 7 hatches | Fallback is approach C (per-service templates); the survey found exactly these 7 |
| Selector immutability blocks a mixed cluster | Documented in `deploy/README.md` as an extension of the existing Plan 2 rule; live checks run on clean clusters |
| A vacuous assertion gives a false green | Every new assertion RED-proven before it counts |
