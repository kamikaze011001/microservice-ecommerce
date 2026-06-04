# k8s session handoff (2026-06-03)

Local kind bring-up is functional end-to-end: infra + 8 services + frontend,
storefront browse → cart → checkout → PayPal → order completion, avatar/product
image uploads, and the VictoriaMetrics + Grafana observability stack. This file
captures what changed most recently and what's still open. Detailed root-cause
write-ups for the items below live in `k8s/CLAUDE.md` (the SCARs section).

## DONE this session (2026-06-03) — verified live unless noted

- **Gateway service discovery (Eureka → Spring Cloud Kubernetes).** Every
  authenticated route 500'd ("Unexpected authentication error") — the
  `@LoadBalanced` JWKS fetch had no registry (Eureka isn't deployed in k8s).
  Added `spring-cloud-starter-kubernetes-client-loadbalancer` + a `k8s` Spring
  profile (`gateway/.../application-k8s.yml`) + a `gateway` ServiceAccount/RBAC
  (`services`,`endpoints`,`pods`). PERMIT_ALL products now 200; a bad token → 401,
  not 500.
- **Saga stuck at PROCESSING (schema-registry + Avro CDC).** orchestrator
  crash-looped on "Unknown magic byte" — the Mongo-CDC connector emitted JSON but
  the orchestrator reads Avro. Deployed schema-registry (manifest existed, never
  wired → added to `install.sh`), flipped the connector to `AvroConverter` +
  `output.format.value=schema`, purged the poison topic, recreated the connector,
  restarted orchestrator. Verified: a CDC event deserializes as Avro (subject
  registered, zero magic-byte errors).
- **Cart "0 available" (inventory seed).** `inventory_product` +
  `product_quantity_history` are never seeded by bootstrap (written reactively by
  Kafka/admin). Added `scripts/seed/k8s-inventory.sh` + `make k8s-seed-inventory`,
  wired into `k8s-bootstrap` after `k8s-apps`. *(This is the "NOT DONE"
  k8s-mysql-quantity item from the previous handoff — now done.)*
- **Browser-facing host fixes** (internal cluster DNS leaking to the browser):
  - payment `application.frontend.base-url` (PayPal 302 redirect):
    `frontend.apps.svc.cluster.local` → `http://microecom.local`.
  - core-s3 presigned upload URLs: new `s3.public-endpoint=http://media.microecom.local`
    — the `S3Presigner` signs the host, so it can't be rewritten after. Code change
    to core-s3 (rebuilt `cores` + authorization-server + product-service).
  - inventory `image_url` `localhost:9000` → `media.microecom.local` rewrite in the
    inventory seed (order-service snapshots it into `order_item`).
- **Frontend toast `crypto.randomUUID`.** Undefined on the plain-`http://` ingress
  (not a secure context) → threw and broke every toast. Added a fallback in
  `frontend/src/stores/toast.ts`.
- **Mail OTP (carried from the previous handoff) — root cause resolved.** The blank
  `spring.mail.username`/`password` keys are gone from live Vault (verified) and the
  `app-secrets` env vars are present (USER set, PW len 16). Not re-tested with an
  actual registration send this session, but the documented root cause is fixed.

## Still open

- **Nothing committed.** The whole session's work (gateway discovery,
  schema-registry/Avro, inventory seed, browser-DNS fixes, core-s3, toast, docs) is
  uncommitted on `fix/k8s-kind-containerd-registry` (~40+ files). User to decide
  grouping / when to commit.
- **HTML teaching docs** (`docs/k8s-architecture|service-architecture|k8s-eli5.html`)
  are being refreshed now (KPS→VictoriaMetrics, Eureka→k8s discovery,
  schema-registry/Avro).
- **`auth:activate` 401** observed in gateway logs but not investigated this
  session — may be the already-resolved XA/masked-500 issue (see the XA-deadlock
  SCAR in `k8s/CLAUDE.md`) or a permit gap. Low priority; activate isn't blocking.
- Cleanup: the root-owned `k8s/infra/values/{mysql,mongodb,redis,minio,kafka}.yaml`
  are already deleted (git shows `D`). Confirm `scripts/seed/k8s-placeholder-images.sh`
  is gone (abandoned approach).

## Env quirks (see also k8s/CLAUDE.md scars + memory/env_rtk_shell_garbling.md)
- The rtk Bash wrapper frequently empties/mangles output (esp. `grep`, `curl|python`).
  Route through files + Read, or parse with python reading a dumped file. Don't theorize
  on garbled output.
- `rm`/`pkill`/some `kubectl exec sh -c` get sandbox-blocked → ask user to run with `! `.
- vault-0 pod has NO python3; do JSON manipulation on the host.
- minio mc sidecar has NO tar → `kubectl cp` fails; stream files via `kubectl exec ... cat`.
- Mutable `:dev` image tag + IfNotPresent serves stale layers; the app deployments now use
  imagePullPolicy: Always, and rebuilds need node-cache purge:
  `for n in $(kind get nodes --name microecom); do docker exec $n crictl rmi localhost:5001/<svc>:dev; done`
