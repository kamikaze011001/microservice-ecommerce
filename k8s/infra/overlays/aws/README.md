# AWS infra overlay (placeholder)

This directory is the migration target when promoting the local kind setup to
EKS. **It is intentionally a stub** — the goal is to make the gap explicit, not
to ship a working AWS install yet.

## What stays the same

The Helm chart names, namespaces, and Service DNS contracts are identical to
the local overlay. App Deployments, Vault paths, and the `mysql` /
`mysql-replica` Service split all carry over. That's the whole point of the
local→AWS portability story in `docs/superpowers/specs/2026-05-09-k8s-local-design.md`.

## What changes

| Component | Local pattern | AWS pattern |
|---|---|---|
| MySQL/Mongo/MinIO/Grafana auth | `rootPassword: <plaintext>` in `values/*.yaml` | `auth.existingSecret: <name>` + `ExternalSecret` pulling from AWS Secrets Manager |
| Vault | `server.dev.enabled=true`, hardcoded `devRootToken` | `server.ha.enabled=true`, Raft or DynamoDB backend, KMS auto-unseal, AppRole auth |
| Redis | `auth.enabled=false` (kind on 127.0.0.1) | Either `auth.enabled=true`+ExternalSecret, or replace with ElastiCache and delete the chart entirely |
| MinIO | Standalone Pod with PVC | Replace with managed S3 — delete this chart, point `core-s3` Vault path at the bucket |
| Ingress | ingress-nginx + `microecom.local` hostfile | AWS Load Balancer Controller + Route53 hostname + ACM cert |
| Storage | kind hostPath | gp3 EBS via `ebs-csi-driver`, sized per workload |
| Observability | kube-prometheus-stack with 6h retention, alertmanager off | Same chart, longer retention, alertmanager wired to PagerDuty/Slack, Loki for logs |

## Required prerequisites (do these in AWS first, before applying overlays)

1. **EKS cluster** (1.30+) with at least 3 nodes, 2 AZs.
2. **External Secrets Operator** Helm-installed in the cluster:
   ```sh
   helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
   ```
3. **IRSA role** for ESO that has `secretsmanager:GetSecretValue` on the
   `microecom/*` secret name pattern.
4. **Secrets in AWS Secrets Manager**, named conventionally:
   - `microecom/mysql/root` → `{password: "..."}`
   - `microecom/mysql/app`  → `{password: "..."}`
   - `microecom/mongodb/root` → `{password: "..."}`
   - `microecom/mongodb/app`  → `{password: "..."}`
   - `microecom/grafana/admin` → `{password: "..."}`
   - `microecom/redis/auth` → `{password: "..."}`
   - `microecom/payment/paypal` → `{client_id: "...", client_secret: "..."}`
   - `microecom/mail/smtp` → `{username: "...", password: "..."}`
   - `microecom/vault/root` → `{token: "..."}` (only for emergency unseal; AppRole is the daily path)

## Skeleton structure (NOT YET IMPLEMENTED)

When this overlay is fleshed out, expect:

```
k8s/infra/overlays/aws/
├── README.md                       (this file)
├── kustomization.yaml              (top-level, references each block)
├── secret-store.yaml               (ClusterSecretStore pointing at AWS Secrets Manager via IRSA)
├── external-secrets/
│   ├── mysql.yaml                  (ExternalSecret → Secret 'mysql-root', 'mysql-app')
│   ├── mongodb.yaml
│   ├── grafana.yaml
│   ├── redis.yaml
│   └── payment-paypal.yaml
├── values-overrides/
│   ├── mysql.yaml                  (auth.existingSecret: mysql-root, primary.persistence.storageClass: gp3, etc.)
│   ├── mongodb.yaml
│   ├── redis.yaml                  (auth.enabled: true, auth.existingSecret: redis-auth)
│   ├── vault.yaml                  (server.ha.enabled: true, server.ha.raft.*, KMS seal config)
│   └── kube-prometheus-stack.yaml  (grafana.admin.existingSecret: grafana-admin, retention 30d, alertmanager on)
└── ingress/
    └── alb-ingress-class.yaml      (IngressClass for AWS Load Balancer Controller)
```

Apply with:
```sh
kubectl apply -k k8s/infra/overlays/aws/
helm upgrade --install mysql bitnami/mysql -n infra \
  -f k8s/infra/values/mysql.yaml \
  -f k8s/infra/overlays/aws/values-overrides/mysql.yaml
# (repeat per chart)
```

## Why a stub now

Two reasons. First, every `values/*.yaml` already references this directory in
its "AWS overlay must replace this with ..." comment — without the directory
existing, those comments point at nothing. Second, the migration path is the
sort of thing you regret not writing down while it's fresh; future-you (or
future teammate) will appreciate the table above existing as a contract.

When you actually start the EKS migration, replace this README's "NOT YET
IMPLEMENTED" sections with the real manifests one row at a time. Test each
swap against the local cluster first — `auth.existingSecret` is supported by
the same Bitnami charts you're already using, so you can validate the wiring
locally with a fake Secret before touching AWS.
