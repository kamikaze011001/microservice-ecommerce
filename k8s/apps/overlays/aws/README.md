# AWS apps overlay (placeholder)

Companion to `k8s/infra/overlays/aws/` — when promoting from kind to EKS,
the app manifests need a small set of patches. The base manifests in
`k8s/apps/base/` stay portable; AWS-specific changes live here as
strategic-merge patches.

## What changes vs. local

| Concern | Local pattern | AWS pattern |
|---|---|---|
| Image registry | `localhost:5001/<svc>:dev` | ECR registry hostname + immutable tag |
| Vault auth | `VAULT_TOKEN=root` env literal | AppRole login; role-id / secret-id from a k8s Secret mounted by an init container |
| Mail / PayPal creds | Already in Vault via local seed | Already in Vault via ESO from AWS Secrets Manager (`microecom/mail/smtp`, `microecom/payment/paypal`) |
| Resource requests/limits | Hand-tuned for a single Docker host | Per-node-class limits; HPA targets stay the same |
| Replicas | 1 everywhere | 2+ for gateway/auth/product/bff; 1 for stateful coordinators (orchestrator) |
| HPA | order-service only | gateway + auth-server + product-service + bff + order |
| PodDisruptionBudget | none | `minAvailable: 1` per Deployment with replicas>1 |
| Affinity | none | `topologyKey: topology.kubernetes.io/zone` antiaffinity for replicas>1 |

## Skeleton (NOT YET IMPLEMENTED)

```
k8s/apps/overlays/aws/
├── README.md                    (this file)
├── kustomization.yaml           (lists base + patches below)
├── image-overrides.yaml         (kustomize images: transformer, swaps localhost:5001 → ECR)
├── vault-approle/
│   ├── secret.yaml              (ExternalSecret → 'vault-approle' Secret per app)
│   └── init-container.yaml      (strategic-merge: adds Vault AppRole login init container)
├── replicas/
│   ├── gateway.yaml             (replicas: 3)
│   ├── authorization-server.yaml
│   ├── product-service.yaml
│   └── bff-service.yaml
├── hpa/
│   ├── gateway-hpa.yaml
│   ├── product-service-hpa.yaml
│   └── ... (one per scaled service)
├── pdb/                          (one PodDisruptionBudget per scaled Deployment)
└── affinity/
    └── topology-spread.yaml      (zone-spread for replicas>1)
```

When this overlay is real, the apply command is:

```sh
kubectl apply -k k8s/apps/overlays/aws/
```

…and it must run **after** `k8s/infra/overlays/aws/` (so ExternalSecrets,
the vault HA install, and ALB Ingress Controller are in place first).
