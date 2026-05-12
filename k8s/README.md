# k8s/ — local Kubernetes setup

Spec: `docs/superpowers/specs/2026-05-09-k8s-local-design.md`.

## One-shot

    make k8s-bootstrap

Brings up the kind cluster, infra (MySQL, Mongo, Redis, Kafka, Vault, MinIO,
ingress-nginx, kube-prometheus-stack), seeds data + Vault, builds and pushes
all images to the local registry, and applies the 8 service Deployments.
Idempotent — safe to re-run.

## Daily

| Goal | Command |
|---|---|
| Re-deploy one service after code change | `make k8s-rebuild svc=order-service` |
| Re-apply all manifests | `make k8s-apps` |
| Status table | `make k8s-status` |
| Stress test (HPA) | `make k8s-stress` then `make k8s-stress-logs` |
| Watch autoscaling live | `kubectl -n apps get hpa -w` |
| Tail one Pod | `kubectl -n apps logs -f deploy/<svc>` |
| Tear it ALL down | `make k8s-down` |

## /etc/hosts

```
127.0.0.1 microecom.local
127.0.0.1 api.microecom.local
```

Frontend at `http://microecom.local`, backend at `http://api.microecom.local`.
Separate hosts keep CORS/cookie scopes clean and mirror prod (`api.<domain>`).

## Layout

```
k8s/
├── kind/                  — cluster.yaml + local registry shim
├── images/                — Dockerfile.jvm, Dockerfile.cores, build.sh
├── infra/                 — Helm charts + bootstrap Jobs
│   └── jobs/              — idempotent seed Jobs (mysql, mongo, vault, minio, kafka-connect)
└── apps/
    ├── base/              — per-service manifests (deployment + service + hpa + servicemonitor)
    └── overlays/
        ├── local/         — kind-targeted kustomization
        └── aws/           — placeholder (LoadBalancer, EBS, IRSA come later)
```

## AWS portability

Manifests live in `base/`; environment differences live in overlays.
Switching to EKS = a new overlay (`overlays/aws`) plus external-secrets
operator pointing at AWS Secrets Manager instead of Vault. Service / Ingress
shapes stay identical.

## Stress testing

`k8s/apps/base/k6-stress/`. Targets the gateway via Service DNS (skips
Ingress so latency reflects the backend only), ramps to 50 VUs against
`/product-service/v1/products`. Edit `script.js` then `make k8s-stress`
re-applies. ConfigMap is generated from the file via kustomize with
`disableNameSuffixHash: true` so the Job's volume reference stays stable.
