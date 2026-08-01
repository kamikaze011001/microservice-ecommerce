# k8s/ — local Kubernetes setup

Spec: `docs/superpowers/specs/2026-05-09-k8s-local-design.md`.

## One-shot

    make k8s-bootstrap

Brings up the minikube cluster, infra (MySQL, Mongo, Redis, Kafka, schema-registry,
kafka-connect, Vault, MinIO, ingress-nginx, and the observability stack —
VictoriaMetrics + Grafana + kube-state-metrics), seeds data + Vault, builds and
pushes all images to the local registry, applies the 8 service Deployments, and
seeds the inventory stock tables. Idempotent, safe to re-run.

Start the ingress tunnel in a separate terminal and keep it running:

    make k8s-tunnel

## Daily

| Goal | Command |
|---|---|
| Re-deploy one service after code change | `make k8s-rebuild svc=order-service` |
| Re-apply all manifests | `make k8s-apps` |
| Status table | `make k8s-status` |
| Stress test (HPA) | `make k8s-payment-stress` then `make k8s-payment-stress-logs` |
| Watch autoscaling live | `kubectl -n apps get hpa -w` |
| Tail one Pod | `kubectl -n apps logs -f deploy/<svc>` |
| Re-seed inventory stock (cart shows "0 available") | `make k8s-seed-inventory` |
| Tear it ALL down | `make k8s-down` |
| Resume after stopping | `make k8s-start` |

Dashboards: Grafana at `http://grafana.microecom.local` (admin/admin),
VictoriaMetrics UI at `http://vm.microecom.local/vmui` (scrape health at
`/targets`).

## /etc/hosts

```
127.0.0.1 microecom.local
127.0.0.1 api.microecom.local
127.0.0.1 media.microecom.local
127.0.0.1 grafana.microecom.local
127.0.0.1 vm.microecom.local
```

Frontend at `http://microecom.local`, backend at `http://api.microecom.local`,
object storage (presigned uploads + image reads) at `http://media.microecom.local`,
dashboards at `grafana`/`vm.microecom.local`. Separate hosts keep CORS/cookie
scopes clean and mirror prod (`api.<domain>`). All resolve to the ingress on :80.

## Layout

```
k8s/
├── images/                — Dockerfile.jvm, Dockerfile.cores, build.sh
├── infra/                 — Helm charts + bootstrap Jobs
│   └── jobs/              — idempotent seed Jobs (mysql, mongo, vault, minio, kafka-connect)
└── apps/
    ├── base/              — per-service manifests (deployment + service + hpa; gateway adds rbac for k8s discovery)
    └── overlays/
        ├── local/         — minikube-targeted kustomization
        └── aws/           — placeholder (LoadBalancer, EBS, IRSA come later)
```

## Monitoring with k9s

[k9s](https://k9scli.io) is a terminal UI for the cluster. Install once, then
launch with a repo-committed config (skin + namespace hotkeys):

```bash
brew install k9s          # one-time
make k9s                  # local minikube cluster (ENV=local default)
make k9s ENV=eks          # EKS context (see below)
```

The config lives in `k8s/k9s/` (shared, version-controlled). k9s's own
per-cluster state is written under `k8s/k9s/clusters/**` and is git-ignored.

**Namespace hotkeys:** `Shift-A` → `apps`, `Shift-I` → `infra`,
`Shift-B` → `bootstrap` jobs. Switch clusters live with `:ctx`.

**Infra health plugin:** select an `infra` pod (mysql / mongodb / kafka / redis)
and press `Shift-Z` for a read-only health report for that service — MySQL
replication status, MongoDB replica-set state, Kafka consumer-group lag, or Redis
`INFO` — paged through `less` (`q` to return). Defined in `k8s/k9s/plugins.yaml`.

**Read-write mode is enabled** — you can delete, scale, and restart resources
directly from the TUI (matches how this cluster is managed). It acts live against
whatever context you're on, so double-check the crumbs before destructive actions.

**EKS (future):** one-time, register the context under the alias the launcher
expects, then use `ENV=eks`:

```bash
aws eks update-kubeconfig --name <cluster-name> --alias microecom-eks
make k9s ENV=eks
```

The same committed config serves both clusters; keep the `apps`/`infra`/`bootstrap`
namespace names on EKS so the hotkeys carry over.

## AWS portability

Manifests live in `base/`; environment differences live in overlays.
Switching to EKS = a new overlay (`overlays/aws`) plus external-secrets
operator pointing at AWS Secrets Manager instead of Vault. Service / Ingress
shapes stay identical.

## Stress testing

`k8s/apps/base/k6-stress/payment-flow.js` + `payment-job.yaml`. Targets the
gateway via Service DNS (skips Ingress so latency reflects the backend only)
and drives the full payment saga — login → create order → create payment →
PayPal approve/cancel/fail — against `mock-paypal-service`, holding 50 VUs for
3 min (the SLO bar). `make k8s-payment-stress` deletes any prior Job, recreates
the `k6-payment-script` ConfigMap from `payment-flow.js`, and applies
`payment-job.yaml`; `make k8s-payment-stress-logs` tails it. Prerequisite: the
perftest users seeded by `make k8s-seed-perftest` (run automatically by
`make k8s-bootstrap`). Watch autoscaling with `kubectl -n apps get hpa -w`.
