# AWS Phase 2 — ECR + EBS Storage + Self-Hosted Infra + First Service (Coworking Learning Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Coworking learning mode.** Same deal as Phases 0 and 1: tasks marked
> **[CHECKPOINT — HUMAN ✍️]** are *yours* to write — you get the skeleton,
> requirements, and doc links, **not** the answer. Claude scaffolds the
> mechanics (build/push scripts, the infra-apply wrapper, the kustomize overlay,
> teardown changes) and reviews what you write before you apply. You run every
> `terraform apply` and `make` target yourself (they bill your account).

**Goal:** Give the cluster a container registry and persistent block storage,
then prove both work: push your first **arm64 JVM image** to **ECR**, stand up the
self-hosted infra tier (**Kafka, Schema Registry, Kafka Connect, MongoDB,
VictoriaMetrics, Grafana**) on **EBS-backed volumes**, and run your first real
service — the **gateway** — pulled from ECR and reachable through the Phase 1 ALB.

**Architecture:** ECR repositories go in the **persistent `aws/bootstrap/` stack**
(not the ephemeral `aws/main/`) so your pushed images survive teardown — that's
why spin-up stays fast and why spec §4 says "ECR images persist between sessions."
The **EBS CSI driver** (an EKS managed add-on, authenticated by its own IRSA role)
plus a **`gp3` StorageClass marked default** turn the local manifests'
`storageClassName`-less PVCs into real AWS EBS volumes with zero manifest edits.
The infra tier is the *vehicle* for the storage lesson — Kafka and Mongo are
StatefulSets with PVCs, so "infra Ready" literally means "dynamic EBS provisioning
works." The gateway is the *vehicle* for the ECR lesson — it's the one JVM service
that boots with no Vault, DB, Redis, or Kafka dependency.

**Tech Stack:** Terraform ≥1.7, AWS provider ~> 5.0, EKS 1.31, EBS CSI driver
add-on, `gp3` volumes, ECR, arm64 Graviton nodes, the repo's existing
`k8s/images/build.sh` + `k8s/infra/install.sh` (reused, not rewritten),
`kubectl` + `kustomize` + `helm`.

**Spec:** `docs/superpowers/specs/2026-06-10-aws-deployment-design.md` §3 (infra
tier), §4 (ECR persists; teardown gotchas), §6 (arm64 images → Graviton), §8
(Phase 2 row: "ECR + self-hosted infra + one service"; focus "EBS CSI / storage
classes, ECR").

**Builds on Phase 1 (commits 40883c4 … 16e9882, + a5e51bc):** VPC, EKS cluster,
ALB controller, and the `make aws-up`/`aws-down`/`aws-leak-check` lifecycle are
already in place. This plan *adds to* `aws/bootstrap/` and `aws/main/` and
*extends* `down.sh`.

---

## ⚠️ Cost reality check — what Phase 2 adds to the meter

Phase 1 was ≈ **$0.20–0.25/hr**. Phase 2 adds a little, mostly storage and a bit
more compute:

| New resource | ~Cost while up |
|---|---|
| EBS gp3 volumes (Kafka 10Gi + Mongo 4Gi + VM ~8Gi ≈ 22Gi) | ~$0.002/hr (≈ $1.8/mo prorated) |
| ECR image storage (~$0.10/GB-mo, persists) | ≪ $0.01/hr — and it **stays** after teardown |
| 3rd t4g.large node (recommended for Phase 2, see Task 0) | ~$0.015–0.025/hr spot |

So Phase 2 up ≈ **$0.25–0.30/hr**. The one thing that survives `make aws-down` on
purpose is **ECR storage** (a few GB of images ≈ pennies/month) — that's the
deliberate persistent-vs-ephemeral tradeoff, not a leak. Everything else still
dies. **Rule unchanged: never end a session without `make aws-down` then
`make aws-leak-check`** — and Phase 2's leak-check now matters more, because a
leaked **EBS volume** (from a PVC you forgot to delete) bills silently.

---

## File Structure

```
aws/
├── bootstrap/
│   └── ecr.tf                  # aws_ecr_repository per service + lifecycle policy   [HUMAN ✍️]
├── main/
│   └── storage.tf              # EBS CSI IRSA role + aws_eks_addon "ebs-csi"         [HUMAN ✍️]
├── manifests/
│   ├── storageclass-gp3.yaml   # gp3 StorageClass, annotated default                [HUMAN ✍️]
│   └── (hello-nginx.yaml)      # from Phase 1 — still the cheapest ALB smoke target
k8s/apps/overlays/aws/
│   ├── kustomization.yaml      # includes base/gateway + ECR image transformer       [CLAUDE]
│   └── ingress-gateway.yaml    # ALB ingress → gateway (overlay resource)            [CLAUDE]
scripts/aws/
├── push-images.sh              # ecr login + REGISTRY=<ecr> k8s/images/build.sh      [CLAUDE]
├── infra-up.sh                 # apply Phase-2 infra subset on the EKS context       [CLAUDE]
└── down.sh                     # UPDATED: delete app/infra k8s objects + PVCs first   [CLAUDE]
```

Plus Makefile targets `aws-push`, `aws-infra-up` (thin wrappers, per repo
convention).

> 🎓 **Interview note to bank — why ECR lives in `bootstrap`, not `main`:**
> "My ephemeral stack (`main`) is created and destroyed every session — VPC,
> EKS, EBS. But a container registry is *durable shared state*: re-pushing 11
> images on every spin-up would add ~10 minutes and gain nothing. So ECR sits in
> the persistent `bootstrap` stack alongside the Terraform state bucket. The line
> I draw: **destroy compute and data every session; keep the registry and the
> state.**"

---

## Task 0: Sanity — cluster up, right context, room to schedule  [CHECKPOINT — HUMAN, quick]

Phase 2 schedules ~7 new pods (6 infra + gateway) on top of the kube-system
pods. Two small t4g.large nodes (16 GiB total) get tight, so bump to 3 nodes for
this phase.

- [ ] **Step 1:** Bring Phase 1 up if it's down: `make aws-up` (~15–20 min cold).
- [ ] **Step 2: Confirm kubectl is on EKS, not the local kind cluster** (the
  Phase 1 trap):

```bash
kubectl config current-context        # MUST be microecom-eks, not kind-microecom
kubectl get nodes -o wide             # arm64 workers, STATUS Ready
```

- [ ] **Step 3: Give the node group a third node for this phase.** Create
  `aws/main/terraform.tfvars` (gitignored) with:

```hcl
node_desired_size = 3
```

Then `AWS_PROFILE=microecom terraform -chdir=aws/main apply` — plan shows the ASG
desired count 2 → 3, **0 destroy**. (`node_max_size` is already 3 from Phase 1, so
this needs no other change.) Wait for `kubectl get nodes` to show 3 Ready.

> 🎓 **Interview note:** "Node count is a Terraform variable, not a code change —
> the managed node group is an ASG; I move `desired_size` and the cluster
> autoscaler-free path just launches another spot Graviton node." Bumping via
> tfvars (not editing `variables.tf`) keeps the default cheap and the override
> local + uncommitted.

---

## Task 1: ECR repositories — the persistent registry  [CHECKPOINT — HUMAN ✍️]

**Your raw-Terraform lesson.** Phases 0–1 leaned on community modules; here you
write bare `aws_ecr_repository` resources by hand, driven by a `for_each` over a
list of service names. This is also where you internalize the
persistent-vs-ephemeral split — these go in **`aws/bootstrap/`** (local backend,
survives teardown), *not* `aws/main/`.

**File:** Create `aws/bootstrap/ecr.tf` (Claude leaves you this skeleton).

```hcl
# aws/bootstrap/ecr.tf
#
# Create one ECR repository per image we will push. These live in the PERSISTENT
# bootstrap stack on purpose — images survive `make aws-down` so spin-up is fast.
#
# ── REQUIREMENTS ─────────────────────────────────────────────────────────────
# 1. A variable listing the image names (so the set is data, not copy-paste):
#
#      variable "service_images" {
#        type = set(string)
#        default = [
#          "maven-cores",            # shared build-cache base image
#          "gateway", "authorization-server", "bff-service",
#          "product-service", "inventory-service", "order-service",
#          "payment-service", "orchestrator-service",
#          "frontend", "mock-paypal-service",
#        ]
#      }
#
# 2. resource "aws_ecr_repository" "svc" with for_each = var.service_images
#      - name                 = each.value
#      - image_tag_mutability = "MUTABLE"   # we use the :dev mutable tag in dev
#      - image_scanning_configuration { scan_on_push = true }
#      - force_delete         = false       # spec §4 gotcha #3: keep images on
#                                           #   normal teardown; only bootstrap
#                                           #   destroy paths force-delete.
#
# 3. resource "aws_ecr_lifecycle_policy" "svc" with for_each = var.service_images
#    referencing aws_ecr_repository.svc[each.key].name, with a policy that expires
#    untagged images after a small count so old layers don't accumulate cost.
#    A minimal policy JSON (use jsonencode):
#      rules = [{
#        rulePriority = 1
#        description  = "expire untagged images, keep last 3"
#        selection    = { tagStatus = "untagged", countType = "imageCountMoreThan", countNumber = 3 }
#        action       = { type = "expire" }
#      }]
#
# 4. An output exposing the registry hostname so the push script can read it:
#      output "ecr_registry" {
#        value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
#      }
#    (aws/bootstrap likely already has a data.aws_caller_identity — reuse it; if
#     not, add `data "aws_caller_identity" "current" {}`. Check var.region exists
#     in the bootstrap stack; Phase 0 set the region there.)
#
# Docs:
#  - https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository
#  - https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy
#
# Write the resources below; ask Claude to review before applying.
```

- [ ] **Step 1: [HUMAN] Write `aws/bootstrap/ecr.tf`.**
- [ ] **Step 2: [HUMAN] Ask Claude to review** (Claude checks the `for_each`
  shape, the lifecycle JSON, `force_delete=false`, and that you reused the
  bootstrap stack's existing `region` / `aws_caller_identity`).
- [ ] **Step 3: Apply the bootstrap stack** (local backend — fast, no cluster
  touched):

```bash
AWS_PROFILE=microecom terraform -chdir=aws/bootstrap init
AWS_PROFILE=microecom terraform -chdir=aws/bootstrap fmt
AWS_PROFILE=microecom terraform -chdir=aws/bootstrap validate
AWS_PROFILE=microecom terraform -chdir=aws/bootstrap apply
```
Plan: 11 repositories + 11 lifecycle policies to add, **0 to destroy** (Phase 0's
state bucket / lock / budget are untouched). ~30 seconds.

- [ ] **Step 4: Verify the repos exist**

```bash
AWS_PROFILE=microecom aws ecr describe-repositories \
  --region ap-southeast-1 \
  --query 'repositories[].repositoryName' --output table
```
Expected: all 11 names. Note the registry host from the output:
`AWS_PROFILE=microecom terraform -chdir=aws/bootstrap output -raw ecr_registry`
→ `583178372344.dkr.ecr.ap-southeast-1.amazonaws.com`.

- [ ] **Step 5: Commit**

```bash
git add aws/bootstrap/ecr.tf
git commit -m "feat(aws): ECR repositories in the persistent bootstrap stack"
```

> 🎓 **Interview notes to bank:** (1) `for_each` over a `set(string)` vs `count` —
> why `for_each` gives stable addresses (`aws_ecr_repository.svc["gateway"]`) so
> reordering the list doesn't recreate everything; (2) ECR lifecycle policies as
> cost hygiene (untagged layers pile up on every `:dev` re-push); (3) the
> persistent-vs-ephemeral split — registry in bootstrap, compute in main.

---

## Task 2: Push your first arm64 image to ECR  [CLAUDE scaffolds, HUMAN runs]

The repo already has a parameterized builder (`k8s/images/build.sh`, driven by
`REGISTRY` + `TAG`). We don't rewrite it — we wrap it with ECR auth. Phase 2 only
needs **two** images to prove the loop: the `maven-cores` build base and
`gateway`. (Later phases push the rest with the same script.)

**File:** Create `scripts/aws/push-images.sh`.

- [ ] **Step 1: Claude creates `scripts/aws/push-images.sh`**

```bash
#!/usr/bin/env bash
# Build arm64 images and push them to ECR. Wraps the existing k8s/images/build.sh
# (which is already REGISTRY/TAG-parameterized) with `aws ecr get-login-password`.
#
# Usage: scripts/aws/push-images.sh [service ...]
#   no args  -> pushes the Phase 2 minimum: maven-cores + gateway
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
REGION="${AWS_REGION:-ap-southeast-1}"

REGISTRY="$(terraform -chdir="$ROOT/aws/bootstrap" output -raw ecr_registry)"
TAG="${TAG:-dev}"

# 1. Authenticate docker to ECR (token is valid 12h; re-run if it expires).
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# 2. Build + push via the existing builder. It builds maven-cores first, then
#    each named service against it. Default to the Phase 2 minimum.
SERVICES=("$@")
if [ ${#SERVICES[@]} -eq 0 ]; then
  SERVICES=(gateway)   # build.sh always builds maven-cores as the base first
fi

REGISTRY="$REGISTRY" TAG="$TAG" "$ROOT/k8s/images/build.sh" "${SERVICES[@]}"

echo "✅ pushed to $REGISTRY (tag: $TAG): ${SERVICES[*]} (+ maven-cores base)"
```

> ⚠️ Claude must read `k8s/images/build.sh` during execution and confirm its
> actual argument contract (does it take service names as positional args? what
> env vars select the subset?). The snippet above assumes `build.sh [services...]`
> with `REGISTRY`/`TAG` env — **adjust the wrapper to match the real script.** If
> `build.sh` builds *all* services unconditionally, the wrapper instead sets the
> documented subset variable or calls the per-service path; the goal is unchanged:
> push `maven-cores` + `gateway` to ECR.

- [ ] **Step 2: Add the Makefile target** (under the AWS help heading; remember
  recipe lines are **TAB-indented**, per the a5e51bc fix):

```makefile
.PHONY: aws-push
aws-push:
	@scripts/aws/push-images.sh $(svc)
```

- [ ] **Step 3: [HUMAN] Run it**

```bash
chmod +x scripts/aws/push-images.sh
make aws-push            # builds maven-cores + gateway, pushes to ECR
```
This builds on your Apple-Silicon machine → **native arm64** → no cross-compile
(spec §6). First build is slow (Maven deps); later builds reuse the cores layer.

- [ ] **Step 4: Verify the image landed**

```bash
AWS_PROFILE=microecom aws ecr describe-images \
  --repository-name gateway --region ap-southeast-1 \
  --query 'imageDetails[].{tag:imageTags[0],pushed:imagePushedAt,arch:imageManifestMediaType}' \
  --output table
```
Expected: a `dev`-tagged image with a recent push time.

- [ ] **Step 5: Commit**

```bash
git add scripts/aws/push-images.sh Makefile
git commit -m "feat(aws): push-images.sh — build arm64 images to ECR"
```

> 🎓 **Interview notes to bank:** (1) `aws ecr get-login-password | docker login`
> — ECR auth is a 12-hour STS-backed token, not a stored credential; (2) why the
> arch matters — you're building arm64 on an M-series Mac for arm64 Graviton
> nodes, so the *same* image runs locally and in EKS with no `--platform`
> gymnastics; (3) mutable `:dev` tag now vs immutable `:<git-sha>` for prod
> rollouts (you'd flip `imagePullPolicy` to `IfNotPresent`).

---

## Task 3: EBS CSI driver — IRSA role + add-on  [CHECKPOINT — HUMAN ✍️]

**The storage-identity lesson, and a deliberate IRSA reprise.** In Phase 1 you
gave the *ALB controller* an IRSA role. Here you do it again for the *EBS CSI
driver* — same pattern, different managed policy — so the lesson lands as a
*rule* ("every in-cluster controller that calls an AWS API gets its own IRSA
role"), not a one-off. Then you enable the driver as an **EKS managed add-on**.

Without this driver, a PVC on EKS stays `Pending` forever — there's nothing to
turn "I want 10Gi" into a real EBS volume.

**File:** Create `aws/main/storage.tf` (skeleton below).

```hcl
# aws/main/storage.tf
#
# ── PART A: IRSA role for the EBS CSI driver (you've done this shape in Phase 1) ─
# Use the same submodule as the ALB role, with the EBS flag instead:
#
#   module "ebs_csi_irsa" {
#     source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#     version = "~> 5.0"
#
#     role_name             = "${var.project}-ebs-csi"
#     attach_ebs_csi_policy = true        # the magic flag (attaches AmazonEBSCSIDriverPolicy)
#
#     oidc_providers = {
#       main = {
#         provider_arn               = module.eks.oidc_provider_arn
#         namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
#       }
#     }
#   }
#
# ── PART B: enable the driver as an EKS managed add-on ───────────────────────────
# A managed add-on means AWS installs + upgrades the driver for you (vs you
# Helm-installing it). Wire the IRSA role from Part A into it:
#
#   resource "aws_eks_addon" "ebs_csi" {
#     cluster_name             = module.eks.cluster_name
#     addon_name               = "aws-ebs-csi-driver"
#     service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
#     resolve_conflicts_on_create = "OVERWRITE"
#   }
#
# Note: addon_version is omitted so AWS picks the default compatible with EKS 1.31.
# The service account name "ebs-csi-controller-sa" is fixed by the driver — it must
# match the namespace_service_accounts entry above or the pods can't assume the role.
#
# Docs:
#  - https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon
#  - https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest/submodules/iam-role-for-service-accounts-eks
#
# Write both blocks; ask Claude to review before applying.
```

- [ ] **Step 1: [HUMAN] Write `aws/main/storage.tf` (Part A + Part B).**
- [ ] **Step 2: [HUMAN] Ask Claude to review.** (Re-run `terraform init` first —
  adding a new `module` block requires re-downloading the submodule, same as
  Phase 1.)
- [ ] **Step 3: Apply**

```bash
AWS_PROFILE=microecom terraform -chdir=aws/main init   # new module → re-init
AWS_PROFILE=microecom terraform -chdir=aws/main validate
AWS_PROFILE=microecom terraform -chdir=aws/main apply
```
Plan: an IAM role + policy attachment + the EKS add-on. ~2–3 min for the add-on.

- [ ] **Step 4: Verify the controller is running with the role**

```bash
kubectl -n kube-system get deploy ebs-csi-controller
kubectl -n kube-system get sa ebs-csi-controller-sa -o yaml | grep role-arn
```
Expected: `ebs-csi-controller` Ready, and the SA annotated with your
`microecom-ebs-csi` role ARN.

> 🎓 **Interview notes to bank:** (1) the IRSA *rule* — "ALB controller, EBS CSI
> driver, External Secrets later: each gets a least-privilege IRSA role; no shared
> node-instance-profile permissions"; (2) managed add-on vs self-managed Helm —
> AWS owns the driver lifecycle, you own the storage policy; (3) what the CSI
> driver actually does — watches PVCs, calls `ec2:CreateVolume`/`AttachVolume`,
> binds the PV.

---

## Task 4: gp3 StorageClass (default)  [CHECKPOINT — HUMAN ✍️]

**The storage-class lesson.** The driver exists, but a PVC still needs to know
*what kind* of volume to create. A StorageClass is that template. Critically, the
local manifests set **no** `storageClassName`, so they bind to whatever class is
**default** — you'll make `gp3` that default, and then the ported Kafka/Mongo
PVCs "just work" with zero edits.

**File:** Create `aws/manifests/storageclass-gp3.yaml`.

```yaml
# aws/manifests/storageclass-gp3.yaml
#
# ── REQUIREMENTS ─────────────────────────────────────────────────────────────
#  - kind: StorageClass, name: gp3
#  - provisioner: ebs.csi.aws.com          # the driver you installed in Task 3
#  - parameters:
#      type: gp3                            # gp3 = cheaper + better baseline than gp2
#      fsType: ext4
#  - volumeBindingMode: WaitForFirstConsumer  # create the volume in the AZ where the
#                                             # pod actually schedules (EBS is AZ-bound!)
#  - reclaimPolicy: Delete                  # ephemeral env — volume dies with the PVC
#  - annotate it the DEFAULT class:
#      metadata.annotations:
#        storageclass.kubernetes.io/is-default-class: "true"
#
# Write the StorageClass YAML; ask Claude to review.
```

> ⚠️ **Possible gotcha (read before applying):** some EKS versions ship a built-in
> `gp2` StorageClass already marked default. Two defaults = undefined behavior.
> After applying yours, run the check in Step 3; if `gp2` is also default, remove
> its annotation:
> ```bash
> kubectl patch storageclass gp2 -p \
>   '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
> ```

- [ ] **Step 1: [HUMAN] Write `aws/manifests/storageclass-gp3.yaml`.**
- [ ] **Step 2: [HUMAN] Ask Claude to review, then apply** (kubectl, not
  Terraform — like hello-nginx, this is an in-cluster object we keep out of TF
  state for clean teardown):

```bash
kubectl apply -f aws/manifests/storageclass-gp3.yaml
```

- [ ] **Step 3: Verify exactly one default class**

```bash
kubectl get storageclass
```
Expected: `gp3 ... (default)`. If `gp2` also shows `(default)`, run the patch in
the gotcha box above.

- [ ] **Step 4: Commit** (Tasks 3 + 4 together)

```bash
git add aws/main/storage.tf aws/manifests/storageclass-gp3.yaml
git commit -m "feat(aws): EBS CSI driver (IRSA + addon) + default gp3 StorageClass"
```

> 🎓 **Interview notes to bank:** (1) `WaitForFirstConsumer` — *the* EBS gotcha:
> an EBS volume lives in one AZ, so you must wait until the scheduler picks the
> pod's node/AZ before creating the volume, or the pod and volume can land in
> different AZs and never bind; (2) gp3 vs gp2 — gp3 decouples IOPS/throughput
> from size and is ~20% cheaper; (3) `reclaimPolicy: Delete` is right for an
> ephemeral env but you'd use `Retain` for anything you can't re-seed.

---

## Task 5: Self-hosted infra on EBS  [CLAUDE scaffolds, HUMAN runs & verifies]

Now prove dynamic EBS provisioning end-to-end by deploying the **Phase 2 infra
subset** — Kafka, Schema Registry, Kafka Connect, MongoDB, VictoriaMetrics,
Grafana. (MySQL / Redis / MinIO are **not** in Phase 2 — they come up with the
apps in Phase 3, then get swapped for RDS/ElastiCache/S3 in Phase 4. Spec §8.)

The repo already deploys all of this on kind via `k8s/infra/install.sh`. That
script uses the *current kubectl context* and `helm` — so once kubectl points at
EKS and `gp3` is the default class, the same manifests provision EBS volumes
instead of kind local-path. We wrap a **subset** of it.

**File:** Create `scripts/aws/infra-up.sh`.

- [ ] **Step 1: Claude reads `k8s/infra/install.sh`** and extracts the exact steps
  for the six Phase-2 components (mongo keyfile Secret creation; `kubectl apply`
  of `kafka.yaml`, `schema-registry.yaml`, `kafka-connect.yaml`, `mongodb.yaml`;
  `helm upgrade --install` of victoria-metrics-single + grafana with their values
  files; the grafana custom-dashboards ConfigMap; the kafka-connect register Job).
  **Do not rewrite install.sh** — mirror its commands for this subset.

- [ ] **Step 2: Claude creates `scripts/aws/infra-up.sh`** (shape below; fill the
  real commands from install.sh):

```bash
#!/usr/bin/env bash
# Deploy the Phase 2 self-hosted infra subset (Kafka, Schema Registry, Kafka
# Connect, MongoDB, VictoriaMetrics, Grafana) onto the CURRENT kubectl context.
# Mirrors the relevant steps of k8s/infra/install.sh; relies on the default gp3
# StorageClass (Task 4) for all PVCs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Guard: refuse to run against the local kind cluster by accident.
CTX="$(kubectl config current-context)"
[[ "$CTX" == "microecom-eks" ]] || { echo "✋ kubectl context is '$CTX', not microecom-eks. Aborting."; exit 1; }

# (Commands mirrored from k8s/infra/install.sh — Phase 2 subset only:)
#  - kubectl create namespace infra (idempotent)
#  - kubectl create secret generic mongodb-keyfile ... (idempotent)
#  - kubectl apply -f k8s/infra/manifests/{kafka,schema-registry,kafka-connect,mongodb}.yaml
#  - helm repo add/update; helm upgrade --install victoria-metrics + grafana with values
#  - kubectl create configmap grafana-custom-dashboards --from-file=k8s/infra/dashboards/
#  - kubectl apply -f k8s/infra/jobs/04-kafka-connect-register/ (after connect is Ready)
echo "TODO(Claude): paste the mirrored install.sh subset here during execution."
```

- [ ] **Step 3: Add the Makefile target**

```makefile
.PHONY: aws-infra-up
aws-infra-up:
	@scripts/aws/infra-up.sh
```

- [ ] **Step 4: [HUMAN] Run it**

```bash
chmod +x scripts/aws/infra-up.sh
make aws-infra-up
```

- [ ] **Step 5: Verify PVCs bound to real EBS volumes** (this is the Phase 2 money
  shot — dynamic provisioning works):

```bash
kubectl -n infra get pvc          # STATUS Bound, with VOLUME ids + STORAGECLASS gp3
kubectl -n infra get pods         # kafka, schema-registry, kafka-connect, mongodb Running/Ready
kubectl -n infra get sts          # kafka 1/1, mongodb 1/1
# Prove the PVC became an actual AWS EBS volume:
AWS_PROFILE=microecom aws ec2 describe-volumes --region ap-southeast-1 \
  --filters Name=tag:kubernetes.io/created-for/pvc/name,Values='*' \
  --query 'Volumes[].{id:VolumeId,size:Size,az:AvailabilityZone,state:State}' --output table
```
Expected: PVCs `Bound` on `gp3`; EBS volumes `in-use`, sizes 10/4/8 Gi. **If a PVC
stays `Pending`**, describe it — usual causes: gp3 not default (Task 4), or the
EBS CSI controller not Ready / missing its IRSA role (Task 3).

- [ ] **Step 6: (optional) Grafana eyeball** — `kubectl -n infra port-forward
  svc/grafana 3000:80` then open `http://localhost:3000`; the JVM/Kafka/MySQL
  dashboards from `k8s/infra/dashboards/` should be present (MySQL panels will be
  empty until Phase 3/4).

- [ ] **Step 7: Commit**

```bash
git add scripts/aws/infra-up.sh Makefile
git commit -m "feat(aws): infra-up.sh — Kafka/Mongo/observability on EBS-backed EKS"
```

> 🎓 **Interview notes to bank:** (1) StatefulSet + `volumeClaimTemplates` → one
> EBS volume per replica, stable identity — "this is why databases are
> StatefulSets, not Deployments"; (2) the spec's governing rule — "self-host the
> *rebuildable* layer (Kafka topics, the Mongo CDC stream re-seed on every
> spin-up); manage the layer where data loss hurts (orders/payments → RDS in
> Phase 4)"; (3) Kafka KRaft (no Zookeeper) keeps the footprint to one pod.

---

## Task 6: First real service — gateway from ECR through the ALB  [CLAUDE scaffolds, HUMAN verifies]

The payoff: a JVM service you built, pushed to *your* registry, pulled by EKS,
booted on arm64, and reachable from the internet. The gateway is the right first
service — `optional:vault://` means it boots with no Vault, and it needs no DB,
Redis, or Kafka. Its routes will `503` (no backends yet) — that's fine; Phase 2
proves the **image→pod→ALB** path, not the full app.

We deploy it through a **kustomize overlay** that reuses `k8s/apps/base/gateway/`
and swaps the image registry from `localhost:5001` to ECR.

**Files:** Create `k8s/apps/overlays/aws/kustomization.yaml` and
`k8s/apps/overlays/aws/ingress-gateway.yaml`.

- [ ] **Step 1: Claude reads `k8s/apps/base/gateway/`** (deployment, service,
  rbac, any existing ingress) and the AWS overlay README, then writes the overlay.

- [ ] **Step 2: Claude creates `k8s/apps/overlays/aws/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Phase 2 deploys ONLY the gateway. Phase 3 adds the rest of the services here.
resources:
  - ../../base/gateway
  - ingress-gateway.yaml

# Swap the dev registry for ECR. <ACCOUNT> resolved during execution.
images:
  - name: localhost:5001/gateway
    newName: 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com/gateway
    newTag: dev
```

> ⚠️ Claude must confirm the **exact image name** referenced in
> `base/gateway/deployment.yaml` (it may be `localhost:5001/gateway:dev` or just
> `gateway`) and match the `images[].name` to it, or the transformer silently
> no-ops.

- [ ] **Step 3: Claude creates `k8s/apps/overlays/aws/ingress-gateway.yaml`**
  (ALB ingress, mirroring the hello-nginx annotations from Phase 1):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gateway
  namespace: default          # match the namespace base/gateway deploys into
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /actuator/health
    alb.ingress.kubernetes.io/healthcheck-port: "9091"   # gateway mgmt port
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gateway
                port: { number: 8080 }
```

> ⚠️ Claude must confirm gateway's **service port** (8080?) and **management/
> health port** (CLAUDE.md says actuator is on a separate mgmt port — confirm
> it's 9091 in gateway's config, or adjust the healthcheck-port). If the base
> already ships a kind/nginx Ingress, the overlay must *replace* it (alb class),
> not add a second.

- [ ] **Step 4: [HUMAN] Deploy + verify**

```bash
kubectl apply -k k8s/apps/overlays/aws
kubectl get pods -l app=gateway -w        # wait for Running + READY 1/1
kubectl logs deploy/gateway | grep -i "Started"   # "Started GatewayApplication"
```
Pod `Ready` = the readiness probe passed = **the JVM you built booted on EKS from
your ECR image.** That's the Phase 2 service proof.

- [ ] **Step 5: Reach it through the ALB**

```bash
kubectl get ingress gateway -w            # wait for an ADDRESS (*.elb.amazonaws.com)
ALB=$(kubectl get ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -si "http://$ALB/" | head -5         # any HTTP response from gateway = success
```
A `404`/`401`/`503` is a **pass** here — it means gateway served the request.
(There are no backend services yet, so real routes 503; that's expected and gets
fixed in Phase 3.)

- [ ] **Step 6: Commit**

```bash
git add k8s/apps/overlays/aws/kustomization.yaml k8s/apps/overlays/aws/ingress-gateway.yaml
git commit -m "feat(aws): deploy gateway from ECR via aws kustomize overlay + ALB ingress"
```

> 🎓 **Interview notes to bank:** (1) kustomize `images:` transformer — same base
> manifests, per-environment registry, no copy-paste (12-factor, spec §5); (2) the
> full request path you can now draw: `browser → ALB (public subnet) → target-type:ip
> → gateway pod (private subnet) → (Phase 3) backend services`; (3) why gateway
> first — fewest dependencies, isolates "does ECR-pull + arm64 boot work" from
> "does the app wiring work."

---

## Task 7: Teardown — now with EBS volumes in play  [CLAUDE updates down.sh, HUMAN runs]

Phase 1's `down.sh` only deleted the hello-nginx Ingress. Phase 2 adds **PVCs**
(→ EBS volumes) and **more Ingresses**, all created by in-cluster controllers and
**invisible to Terraform state**. If you `terraform destroy` without deleting them
first, you leak EBS volumes (silent billing) *and* VPC deletion hangs on orphaned
ENIs. We extend `down.sh` to delete every in-cluster-created AWS resource before
destroy.

**File:** Modify `scripts/aws/down.sh`.

- [ ] **Step 1: Claude updates `scripts/aws/down.sh`** to delete the Phase 2
  objects before `terraform destroy` (additive — keep the existing hello-nginx
  line and the 60s ALB wait):

```bash
# --- inserted before `terraform destroy`, after the existing hello-nginx delete ---

# Delete app overlay (gateway + its ALB ingress) so the controller removes the ALB.
kubectl delete -k k8s/apps/overlays/aws --ignore-not-found=true || true

# Delete the infra namespace — removes StatefulSets AND their PVCs, so the EBS CSI
# driver releases the EBS volumes (reclaimPolicy: Delete). This is the EBS analogue
# of the ALB gotcha: in-cluster-created AWS resources must die before terraform.
kubectl delete namespace infra --ignore-not-found=true --wait=true || true

# Belt-and-suspenders: catch any stray PVCs in default too.
kubectl delete pvc --all --all-namespaces --ignore-not-found=true || true

echo "Waiting 60s for the ALB + EBS controllers to release AWS resources..."
sleep 60
# (existing line below) terraform -chdir="$DIR" destroy -auto-approve
```

> ⚠️ Claude must merge this into the *existing* down.sh structure (it already
> computes `$DIR`/`$ROOT`, deletes hello-nginx, sleeps 60, then destroys) — not
> duplicate the sleep/destroy. Net effect: delete hello-nginx + app overlay +
> infra namespace + stray PVCs → single 60s wait → terraform destroy.

- [ ] **Step 2: [HUMAN] Run the teardown drill**

```bash
make aws-down
make aws-leak-check
```

- [ ] **Step 3: Confirm zero leaks — especially EBS**

`leak-check` must show empty tables for ALB, available NAT, EIP, **unattached EBS
volumes**, and EKS clusters. The only intended survivors:
- Phase 0 state bucket + lock table (different stack, ≪ $1/mo)
- **Your ECR repositories + images** (persistent by design — Task 1)

```bash
# ECR is SUPPOSED to survive — confirm it's still there (not a leak):
AWS_PROFILE=microecom aws ecr describe-repositories --region ap-southeast-1 \
  --query 'repositories[].repositoryName' --output table
```
**If an EBS volume shows as `available` (unattached)**, a PVC wasn't deleted before
destroy — find it (`aws ec2 describe-volumes --filters Name=status,Values=available`)
and delete it manually, then fix down.sh ordering.

- [ ] **Step 4: Commit**

```bash
git add scripts/aws/down.sh
git commit -m "fix(aws): down.sh deletes PVCs + app/infra objects before destroy (EBS leak guard)"
```

> 🎓 **Interview note to bank — the teardown story, extended:** "In-cluster
> controllers create AWS resources Terraform can't see — the ALB controller makes
> ALBs, the EBS CSI driver makes EBS volumes. My teardown deletes the Kubernetes
> objects (Ingresses, PVCs) first, waits for the controllers to release the AWS
> resources, *then* `terraform destroy`. Skip that and you leak volumes that bill
> silently and ENIs that hang the VPC delete. ECR is the one thing I keep on
> purpose — durable shared state, not a leak."

---

## Self-Review (Claude ran this against the spec)

- **§8 Phase 2 deliverable** ("ECR + self-hosted infra (Kafka, Mongo,
  observability) + one service") → ECR (Task 1–2), infra tier (Task 5), gateway
  (Task 6). ✅
- **§8 Phase 2 learning focus** ("EBS CSI / storage classes, ECR") → EBS CSI +
  IRSA (Task 3), gp3 default StorageClass (Task 4), ECR repos + push (Tasks 1–2). ✅
- **§4 "ECR images persist between sessions" + gotcha #3 (`force_delete` only in
  bootstrap)** → ECR in the persistent `bootstrap` stack with `force_delete=false`
  (Task 1); down.sh leaves ECR alone (Task 7). ✅
- **§4 teardown gotcha #1 (in-cluster-created AWS resources before destroy)** →
  extended from ALB to PVCs/EBS in down.sh (Task 7). ✅
- **§6 arm64 images ↔ Graviton (no cross-compile)** → build on M-series Mac →
  arm64 → t4g nodes (Task 2). ✅
- **§3 infra tier list** (Kafka, Schema Registry, Kafka Connect, Mongo single-RS,
  VictoriaMetrics, Grafana) → Task 5 subset. MySQL/Redis/MinIO deliberately
  deferred to Phase 3 (apps + self-hosted DBs), per §8's "run app on self-hosted
  DBs first, then swap." ✅
- **§5 12-factor / same image on kind + EKS** → kustomize `images:` transformer,
  no Dockerfile change (Task 6). ✅
- **One-service choice rationale** → gateway is the only deployed JVM service with
  `optional:vault://` and no DB/Redis/Kafka boot dependency (verified against the
  manifests + each service's `spring.config.import`); auth-server hard-fails
  without Vault → correctly waits for Phase 3's Secrets Manager + ESO. ✅
- **Reused, not rewritten:** `k8s/images/build.sh` (push) and
  `k8s/infra/install.sh` (infra subset) are wrapped, not reimplemented — the
  executing agent must read both to fill the exact command details flagged with
  ⚠️ in Tasks 2 and 5. ✅
- **Deferred (correctly out of scope here):** Secrets Manager + ESO + all 11
  workloads (Phase 3); RDS/ElastiCache/S3 swaps (Phase 4); full saga smoke +
  interview-notes doc (Phase 5); CI/CD (Phase 6). The gateway's routes 503 because
  backends arrive in Phase 3 — expected. ✅

---

## Next phase

Phase 3 (Secrets Manager + External Secrets Operator; all 11 workloads up on
self-hosted DBs — MySQL/Redis/MinIO pods join, auth-server's hard-Vault import
gets profile-gated or `optional:`-prefixed) gets its own plan once Phase 2 applies
clean and you've banked the ECR + EBS + StorageClass + IRSA-reprise interview
notes. One phase at a time — the learning loop.
```
