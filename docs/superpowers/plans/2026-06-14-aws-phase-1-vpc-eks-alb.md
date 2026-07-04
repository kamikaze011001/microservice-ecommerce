# AWS Phase 1 — VPC + EKS + ALB Controller (Coworking Learning Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Coworking learning mode.** Same deal as Phase 0: tasks marked
> **[CHECKPOINT — HUMAN ✍️]** are *yours* to write — you get the skeleton,
> requirements, and doc links, **not** the answer. Claude scaffolds the
> boilerplate (providers, backend wiring, helm release, nginx manifest, scripts)
> and reviews what you write before you apply. You run every `terraform apply`
> yourself (it bills your account).

**Goal:** Stand up the ephemeral network + cluster foundation — one VPC (2 AZs,
single NAT), an EKS cluster with a Graviton/spot managed node group, and the AWS
Load Balancer Controller — then prove it works end-to-end by exposing a
`hello-nginx` pod to the public internet through an ALB.

**Architecture:** A second Terraform root module, `aws/main/`, this time on a
**remote** backend — the S3 bucket + DynamoDB lock table you built in Phase 0.
It uses the community `terraform-aws-modules/{vpc,eks}` modules for the big
primitives (spec §4) and a hand-written IRSA role for the ALB controller (so you
learn IAM-for-Kubernetes by hand). We apply in **three incremental steps** — VPC,
then EKS, then ALB+nginx — so each layer is verified before the next is built,
and so the Terraform Kubernetes/Helm providers (which authenticate *against* the
cluster) are only exercised after the cluster actually exists.

**Tech Stack:** Terraform ≥1.7 (you have 1.15), AWS provider ~> 5.0, Kubernetes +
Helm Terraform providers ~> 2.0, `kubectl` (1.33) + `helm` (4) CLIs, EKS 1.31,
arm64 Graviton spot nodes, region `ap-southeast-1`.

**Spec:** `docs/superpowers/specs/2026-06-10-aws-deployment-design.md` §3 (target
arch), §4 (TF layout + teardown gotchas), §7 (cost), §8 (Phase 1 row).

**Phase 0 outputs this plan consumes (already applied, commit 57a03a5):**
- state bucket: `microecom-tfstate-583178372344`
- lock table: `microecom-tfstate-lock`
- region: `ap-southeast-1`

---

## ⚠️ Cost reality check — read before you apply anything

Phase 0 cost ≪ $1/mo. **Phase 1 is the first phase that bills meaningfully while
up.** Once Task 3 applies, the meter runs:

| Resource | ~Cost while up |
|---|---|
| EKS control plane | $0.10/hr (flat, no free tier) |
| NAT gateway (single) | ~$0.045/hr + data |
| 2× t4g.large spot nodes | ~$0.03–0.05/hr total |
| ALB (Task 5) | ~$0.025/hr + LCU |

≈ **$0.20–0.25/hr** for this phase. Not scary, but **not zero** — which is exactly
why Task 6 (down + leak-check) is part of *this* plan, not deferred. Rule for the
whole workstream: **never end a session without `make aws-down` then
`make aws-leak-check`.**

---

## File Structure

```
aws/
├── main/
│   ├── versions.tf          # terraform{} + REMOTE s3 backend (Phase 0 bucket)     [CLAUDE]
│   ├── providers.tf         # aws + kubernetes + helm providers (EKS exec auth)    [CLAUDE]
│   ├── variables.tf         # region, project, cluster_name/version, cidr, nodes   [CLAUDE]
│   ├── data.tf              # aws_availability_zones (pick 2 AZs)                   [CLAUDE]
│   ├── vpc.tf               # terraform-aws-modules/vpc — subnets, single NAT, tags [HUMAN ✍️]
│   ├── eks.tf               # terraform-aws-modules/eks — cluster + spot nodegroup [HUMAN ✍️]
│   ├── alb-controller.tf    # IRSA role [HUMAN ✍️] + helm_release [CLAUDE]
│   ├── outputs.tf           # cluster_name, region, kubeconfig command             [CLAUDE]
│   └── terraform.tfvars.example                                                    [CLAUDE]
├── manifests/
│   └── hello-nginx.yaml     # Deployment + Service + ALB Ingress (smoke target)    [CLAUDE]
└── scripts/  (under repo scripts/aws/)
    ├── up.sh                # init + apply aws/main                                [CLAUDE]
    ├── down.sh              # kubectl delete ingress → wait → terraform destroy    [CLAUDE]
    └── leak-check.sh        # list still-billing resources (ALB/NAT/EIP/EBS)       [CLAUDE]
```

Plus Makefile targets `aws-up`, `aws-down`, `aws-leak-check`.

---

## Task 0: Local tooling sanity  [CHECKPOINT — HUMAN, quick]

Already verified present on your machine, just confirming the contract:

- [ ] **Step 1:** `kubectl version --client` → v1.33 ✅ (you have it)
- [ ] **Step 2:** `helm version` → v4 ✅ (you have it)
- [ ] **Step 3:** `aws sts get-caller-identity --profile microecom` still returns
  your `microecom-admin` ARN. (Your access keys haven't rotated since Phase 0.)

> 🎓 **Interview note to bank:** the Terraform *Helm provider* and the *helm CLI*
> are independent — TF talks to the cluster API directly via its own provider, it
> does not shell out to your `helm` binary. We pin the TF helm provider to `~> 2.0`
> regardless of your CLI being v4.

---

## Task 1: `aws/main` skeleton — remote backend + providers + vars  [CLAUDE scaffolds]

This is the payoff of Phase 0: `aws/main` stores its state in the bucket you
built. Backend blocks **cannot use variables** (they're read before vars are
evaluated), so the bucket name is hard-coded here — that's expected.

**Files:**
- Create: `aws/main/versions.tf`, `providers.tf`, `variables.tf`, `data.tf`, `terraform.tfvars.example`

- [ ] **Step 1: Claude creates `aws/main/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
  }

  # REMOTE backend — the S3 bucket + lock table built in Phase 0 (aws/bootstrap).
  # Hard-coded because backend blocks are evaluated before variables exist.
  backend "s3" {
    bucket         = "microecom-tfstate-583178372344"
    key            = "main/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "microecom-tfstate-lock"
    encrypt        = true
  }
}
```

- [ ] **Step 2: Claude creates `aws/main/providers.tf`**

```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "main"
    }
  }
}

# The Kubernetes + Helm providers authenticate to EKS using a short-lived token
# minted by `aws eks get-token` (exec plugin). These reference module.eks outputs
# that don't exist until the cluster is applied — which is exactly why we apply
# incrementally (VPC → EKS → ALB). On the ALB apply the cluster already exists,
# so the provider config resolves cleanly.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
```

- [ ] **Step 3: Claude creates `aws/main/variables.tf`**

```hcl
variable "region"  { type = string  default = "ap-southeast-1" }
variable "project" { type = string  default = "microecom" }

variable "cluster_name" {
  type    = string
  default = "microecom-eks"
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# Phase 1 runs small + cheap. Phase 2/3 scale the node group up when real
# workloads land. t4g = Graviton (arm64) — matches your local arm64 image builds.
variable "node_instance_types" {
  type    = list(string)
  default = ["t4g.large"]
}

variable "node_desired_size" { type = number  default = 2 }
variable "node_min_size"     { type = number  default = 2 }
variable "node_max_size"     { type = number  default = 3 }
```

- [ ] **Step 4: Claude creates `aws/main/data.tf`**

```hcl
# Pick the first 2 AZs that support EKS in this region (ap-southeast-1a/b/c).
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
```

- [ ] **Step 5: Claude creates `aws/main/terraform.tfvars.example`**

```hcl
# All Phase 1 defaults are sane; copy to terraform.tfvars only if you want to
# override (e.g. bigger nodes). The file terraform.tfvars is gitignored.
# node_instance_types = ["t4g.xlarge"]
# node_desired_size   = 3
```

- [ ] **Step 6: Init against the remote backend (this is the Phase 0 payoff moment)**

```bash
AWS_PROFILE=microecom terraform -chdir=aws/main init
```
Expected: `Successfully configured the backend "s3"!` and provider downloads.
If it says the bucket/lock table can't be found, your Phase 0 stack isn't
applied — stop and check.

- [ ] **Step 7: Commit**

```bash
git add aws/main/versions.tf aws/main/providers.tf aws/main/variables.tf \
        aws/main/data.tf aws/main/terraform.tfvars.example
git commit -m "feat(aws): main stack skeleton on remote backend + k8s/helm providers"
```

---

## Task 2: The VPC  [CHECKPOINT — HUMAN ✍️]

**This is the network lesson — you write it.** "Walk me through your VPC" is a
guaranteed interview question. You'll invoke the community VPC module, but *you*
choose the subnet layout, the NAT strategy, and — the part everyone forgets — the
**magic subnet tags** that let EKS and the ALB controller discover where to place
load balancers.

**File:** Create `aws/main/vpc.tf` (Claude leaves you this skeleton).

```hcl
# aws/main/vpc.tf
#
# Use module "vpc", source "terraform-aws-modules/vpc/aws", version "~> 5.0".
#
# ── REQUIREMENTS ─────────────────────────────────────────────────────────────
#  - name = "${var.project}-vpc",  cidr = var.vpc_cidr
#  - azs  = 2 AZs. Use slice(data.aws_availability_zones.available.names, 0, 2).
#  - private_subnets = 2 subnets (one per AZ) — the NODES live here.
#       e.g. ["10.0.1.0/24", "10.0.2.0/24"]
#  - public_subnets  = 2 subnets (one per AZ) — the ALB + NAT live here.
#       e.g. ["10.0.101.0/24", "10.0.102.0/24"]
#  - enable_nat_gateway = true
#  - single_nat_gateway = true   # ONE NAT for both AZs — deliberate cost cut.
#       (prod would set false → one NAT per AZ for AZ-failure isolation. Doc it.)
#  - enable_dns_hostnames = true # EKS + private DNS need this.
#
# ── THE TAGS THAT MATTER (the bit interviewers love) ─────────────────────────
# The AWS Load Balancer Controller auto-discovers subnets by tag. Without these
# your Task 5 ingress will sit in "pending" forever with no ALB created:
#   public_subnet_tags  = { "kubernetes.io/role/elb"          = "1" }
#   private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
#
# Docs: https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
#
# Write the module block below; ask Claude to review before applying.
```

- [ ] **Step 1: [HUMAN] Write `vpc.tf`.**
- [ ] **Step 2: [HUMAN] Ask Claude to review.**
- [ ] **Step 3: Validate, then apply ONLY the VPC** (incremental — cluster comes next):

```bash
AWS_PROFILE=microecom terraform -chdir=aws/main fmt
AWS_PROFILE=microecom terraform -chdir=aws/main validate
AWS_PROFILE=microecom terraform -chdir=aws/main apply -target=module.vpc
```
Read the plan: ~20-ish resources to add (VPC, 4 subnets, 1 NAT, 1 IGW, route
tables, EIP). **0 to destroy.** Type `yes` only if it matches.

- [ ] **Step 4: Verify**

```bash
AWS_PROFILE=microecom aws ec2 describe-vpcs \
  --filters Name=tag:Project,Values=microecom \
  --query 'Vpcs[].{id:VpcId,cidr:CidrBlock}' --output table
```
Expected: one VPC with cidr `10.0.0.0/16`.

> 🎓 **Interview notes to bank:** (1) public vs private subnet split and *why
> nodes go private*; (2) what a NAT gateway is for and the single-NAT cost/risk
> tradeoff; (3) what `kubernetes.io/role/elb` actually does (subnet
> auto-discovery by the ALB controller).

---

## Task 3: The EKS cluster + node group  [CHECKPOINT — HUMAN ✍️]

**The centerpiece.** You'll invoke the EKS module to create the managed control
plane and a Graviton spot node group in your private subnets. Two non-obvious
details below are the ones that bite beginners — read them.

**File:** Create `aws/main/eks.tf` (skeleton below).

```hcl
# aws/main/eks.tf
#
# Use module "eks", source "terraform-aws-modules/eks/aws", version "~> 20.0".
#
# ── REQUIREMENTS ─────────────────────────────────────────────────────────────
#  - cluster_name    = var.cluster_name
#  - cluster_version = var.cluster_version
#  - vpc_id     = module.vpc.vpc_id
#  - subnet_ids = module.vpc.private_subnets    # nodes live in private subnets
#  - cluster_endpoint_public_access = true       # so your laptop kubectl reaches it
#  - enable_irsa = true                           # OIDC provider for IRSA (Task 4)
#
#  - eks_managed_node_groups = {
#      default = {
#        instance_types = var.node_instance_types     # ["t4g.large"] = Graviton
#        capacity_type  = "SPOT"                       # ~70% cheaper, fine for sandbox
#        ami_type       = "AL2023_ARM_64_STANDARD"     # ARM64 AMI — MUST match t4g!
#        min_size       = var.node_min_size
#        max_size       = var.node_max_size
#        desired_size   = var.node_desired_size
#      }
#    }
#
# ── GOTCHA 1: arm64 AMI ↔ arm64 instance ─────────────────────────────────────
# t4g.* are Graviton (arm64). The AMI MUST be an *_ARM_64_* type or every pod
# CrashLoops with "exec format error". (This is also why your local arm64 image
# builds will run here with no cross-compile — spec §6.)
#
# ── GOTCHA 2: grant yourself cluster admin ───────────────────────────────────
# EKS module v20 uses Access Entries. Add this or your own kubectl gets
# "Unauthorized" even though you created the cluster:
#   enable_cluster_creator_admin_permissions = true
#
# Docs: https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
#
# Write the module block below; ask Claude to review before applying.
```

- [ ] **Step 1: [HUMAN] Write `eks.tf`.**
- [ ] **Step 2: [HUMAN] Ask Claude to review.**
- [ ] **Step 3: Apply the cluster** (this is the slow one — ~12–18 min):

```bash
AWS_PROFILE=microecom terraform -chdir=aws/main validate
AWS_PROFILE=microecom terraform -chdir=aws/main apply -target=module.eks
```
Plan: control plane, OIDC provider, node group, IAM roles, security groups.
0 to destroy. Go make coffee — EKS control-plane creation is genuinely ~10 min.

- [ ] **Step 4: Wire kubectl + verify nodes**

```bash
AWS_PROFILE=microecom aws eks update-kubeconfig \
  --name microecom-eks --region ap-southeast-1
kubectl get nodes -o wide
```
Expected: 2 nodes, STATUS `Ready`, ARCH `arm64`. **If nodes never go Ready**,
it's almost always the NAT route (nodes can't reach the EKS API / pull images) —
check Task 2's NAT gateway actually came up.

> 🎓 **Interview notes to bank:** (1) managed node group vs self-managed vs
> Fargate; (2) spot capacity tradeoff (interruptible — fine for stateless apps,
> you'd taint/PDB around it in prod); (3) what IRSA/OIDC is and why `enable_irsa`
> matters (next task uses it); (4) Access Entries replacing the old aws-auth
> ConfigMap.

---

## Task 4: ALB Controller — IRSA role (you) + Helm install (Claude)

The AWS Load Balancer Controller is the in-cluster operator that turns a
Kubernetes `Ingress` into a real AWS ALB. It needs AWS permissions — granted via
**IRSA** (IAM Role for Service Accounts), the keystone Phase 1 concept. **You
write the IRSA role; Claude scaffolds the Helm release** that consumes it.

**File:** Create `aws/main/alb-controller.tf`.

### 4a — [CHECKPOINT — HUMAN ✍️] the IRSA role

```hcl
# aws/main/alb-controller.tf  (top half — YOURS)
#
# Use the IRSA submodule, which ships the exact IAM policy the ALB controller
# needs so you don't hand-craft 200 lines of JSON:
#
#   module "alb_irsa" {
#     source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#     version = "~> 5.0"
#
#     role_name = "${var.project}-alb-controller"
#     attach_load_balancer_controller_policy = true   # the magic flag
#
#     oidc_providers = {
#       main = {
#         provider_arn = module.eks.oidc_provider_arn
#         namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
#       }
#     }
#   }
#
# The binding you're declaring in English: "the k8s ServiceAccount named
# aws-load-balancer-controller in namespace kube-system is allowed to assume this
# IAM role." That trust is what IRSA *is* — no static AWS keys in the cluster.
#
# Docs: https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest/submodules/iam-role-for-service-accounts-eks
#
# Write the module block; ask Claude to review.
```

- [ ] **Step 1: [HUMAN] Write the `module "alb_irsa"` block.**
- [ ] **Step 2: [HUMAN] Ask Claude to review.**

### 4b — [CLAUDE] the Helm release (appended to the same file)

- [ ] **Step 3: Claude appends the `helm_release` to `alb-controller.tf`**

```hcl
# aws/main/alb-controller.tf  (bottom half — CLAUDE)
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  # The IRSA binding: annotate the SA with the role ARN you built in 4a.
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_irsa.iam_role_arn
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [module.eks]
}
```

- [ ] **Step 4: Apply (cluster now exists, so providers resolve)**

```bash
AWS_PROFILE=microecom terraform -chdir=aws/main apply
```
This time **no `-target`** — apply the whole stack. Plan adds the IRSA role +
the helm release. ~2–3 min.

- [ ] **Step 5: Verify the controller is running**

```bash
kubectl -n kube-system get deploy aws-load-balancer-controller
kubectl -n kube-system get sa aws-load-balancer-controller -o yaml | grep role-arn
```
Expected: deployment `2/2` (or `1/1`), and the SA annotated with your
`microecom-alb-controller` role ARN.

> 🎓 **Interview note to bank — IRSA in one breath:** "The pod's ServiceAccount
> is annotated with an IAM role ARN; EKS's OIDC provider lets the pod exchange
> its projected SA token for temporary AWS credentials via STS. No long-lived
> keys ever live in the cluster." That sentence is worth memorizing verbatim.

---

## Task 5: hello-nginx → public ALB  [CLAUDE scaffolds, HUMAN verifies]

The proof. A plain nginx Deployment + an `Ingress` annotated for the ALB
controller. We apply this with **`kubectl`, not Terraform** — on purpose: a
`kubernetes_manifest` resource calls the cluster API at *plan* time, which is
brittle right after cluster creation. Keeping ephemeral app manifests out of TF
state also makes teardown (Task 6) clean. This mirrors spec §4's teardown gotcha
#1: the ALB is created by the in-cluster controller, invisible to TF state.

**File:** Create `aws/manifests/hello-nginx.yaml`.

- [ ] **Step 1: Claude creates `aws/manifests/hello-nginx.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-nginx
  labels: { app: hello-nginx }
spec:
  replicas: 2
  selector:
    matchLabels: { app: hello-nginx }
  template:
    metadata:
      labels: { app: hello-nginx }
    spec:
      containers:
        - name: nginx
          image: public.ecr.aws/nginx/nginx:stable   # multi-arch, runs on arm64
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: hello-nginx
spec:
  selector: { app: hello-nginx }
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP          # ALB targets pods directly (target-type: ip)
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-nginx
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-nginx
                port: { number: 80 }
```

- [ ] **Step 2: Apply it**

```bash
kubectl apply -f aws/manifests/hello-nginx.yaml
```

- [ ] **Step 3: Wait for the ALB, then grab its URL** (controller takes ~2–3 min
  to provision the ALB and register targets):

```bash
kubectl get ingress hello-nginx -w     # wait until ADDRESS shows a *.elb.amazonaws.com name
ALB=$(kubectl get ingress hello-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"
curl -s "http://$ALB" | head -5
```
Expected: the nginx welcome HTML. **🎉 That's Phase 1 done** — a pod in a private
subnet, reachable from the public internet through an AWS-managed load balancer
you provisioned with one annotation.

- [ ] **Step 4: Commit the IaC** (NOT state/tfvars — those are gitignored)

```bash
git add aws/main/vpc.tf aws/main/eks.tf aws/main/alb-controller.tf \
        aws/main/outputs.tf aws/manifests/hello-nginx.yaml
git commit -m "feat(aws): Phase 1 — VPC + EKS + ALB controller, hello-nginx public"
```
(`outputs.tf` is created in Task 6 below — commit them together.)

> 🎓 **Interview note to bank — the request path:** browser → ALB (public subnet)
> → target-type:ip → nginx pod (private subnet). No node port, no NAT on the
> inbound path (NAT is egress-only). Be able to draw this.

---

## Task 6: Outputs + lifecycle scripts + teardown drill  [CLAUDE scaffolds, HUMAN runs down]

**Tearing down correctly is itself an interview story** ("how do you guarantee a
sandbox leaves nothing billing?"). The order matters: in-cluster-created AWS
resources (the ALB) must be deleted by Kubernetes *before* `terraform destroy`,
or VPC deletion hangs forever on orphaned ENIs (spec §4 gotcha #1).

**Files:**
- Create: `aws/main/outputs.tf`, `scripts/aws/up.sh`, `scripts/aws/down.sh`, `scripts/aws/leak-check.sh`
- Modify: `Makefile`

- [ ] **Step 1: Claude creates `aws/main/outputs.tf`**

```hcl
output "cluster_name" { value = module.eks.cluster_name }
output "region"       { value = var.region }

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile microecom"
}
```

- [ ] **Step 2: Claude creates `scripts/aws/up.sh`**

```bash
#!/usr/bin/env bash
# Bring up the Phase 1 environment: terraform apply + wire kubectl.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../aws/main" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"

terraform -chdir="$DIR" init -input=false
terraform -chdir="$DIR" apply -auto-approve

aws eks update-kubeconfig \
  --name "$(terraform -chdir="$DIR" output -raw cluster_name)" \
  --region "$(terraform -chdir="$DIR" output -raw region)"
echo "✅ up. kubectl is pointed at the cluster."
```

- [ ] **Step 3: Claude creates `scripts/aws/down.sh`** (the careful one)

```bash
#!/usr/bin/env bash
# Tear down WITHOUT leaking. Delete in-cluster-created AWS resources (ALB) first.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../aws/main" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"

# 1. Delete Ingresses so the ALB controller removes the ALB + target groups.
#    Ignore errors if the cluster/ingress is already gone.
kubectl delete -f aws/manifests/hello-nginx.yaml --ignore-not-found=true || true

# 2. Wait for the ALB to actually disappear (orphaned ENIs block VPC destroy).
echo "Waiting 60s for the ALB controller to deprovision the load balancer..."
sleep 60

# 3. Now Terraform can destroy the VPC/EKS cleanly.
terraform -chdir="$DIR" destroy -auto-approve
echo "✅ destroyed. Run 'make aws-leak-check' to confirm nothing is still billing."
```

- [ ] **Step 4: Claude creates `scripts/aws/leak-check.sh`**

```bash
#!/usr/bin/env bash
# List resources that commonly survive a botched teardown and keep billing.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
R="${AWS_REGION:-ap-southeast-1}"

echo "── Load balancers ──"
aws elbv2 describe-load-balancers --region "$R" \
  --query 'LoadBalancers[].LoadBalancerName' --output table 2>/dev/null || echo "(none)"
echo "── NAT gateways (available) ──"
aws ec2 describe-nat-gateways --region "$R" \
  --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayId' --output table
echo "── Elastic IPs ──"
aws ec2 describe-addresses --region "$R" \
  --query 'Addresses[].PublicIp' --output table
echo "── Unattached EBS volumes ──"
aws ec2 describe-volumes --region "$R" \
  --filters Name=status,Values=available \
  --query 'Volumes[].VolumeId' --output table
echo "── EKS clusters ──"
aws eks list-clusters --region "$R" --output table
echo ""
echo "Anything listed above (except the persistent Phase 0 bucket/lock) is still billing."
```

- [ ] **Step 5: Make them executable + add Makefile targets**

```bash
chmod +x scripts/aws/up.sh scripts/aws/down.sh scripts/aws/leak-check.sh
```

Claude adds under the "AWS (ephemeral EKS):" help heading:

```makefile
.PHONY: aws-up aws-down aws-leak-check
aws-up:
	@scripts/aws/up.sh
aws-down:
	@scripts/aws/down.sh
aws-leak-check:
	@scripts/aws/leak-check.sh
```

- [ ] **Step 6: Commit the tooling**

```bash
git add scripts/aws/up.sh scripts/aws/down.sh scripts/aws/leak-check.sh Makefile
git commit -m "feat(aws): aws-up/down/leak-check lifecycle scripts for the main stack"
```

- [ ] **Step 7: [HUMAN] Run the teardown drill** (do this before you stop for the day):

```bash
make aws-down          # deletes ingress → waits → terraform destroy
make aws-leak-check    # confirm: no ALB, no available NAT, no EIP, no EKS cluster
```
Expected: leak-check shows empty tables (the only survivors are the Phase 0 state
bucket + lock table, which are in a different stack and cost ≪ $1/mo). **If a NAT
gateway or ALB is still listed, it's still billing** — investigate before walking
away.

> 🎓 **Interview note to bank — the teardown story:** "ALBs and EBS volumes are
> created by in-cluster controllers, so Terraform doesn't know about them. My
> down script deletes the Kubernetes objects first, waits for the controller to
> release the AWS resources, *then* destroys the VPC — otherwise VPC deletion
> hangs on orphaned ENIs." This is the rebuild-from-zero discipline the whole
> ephemeral design is built around.

---

## Self-Review (Claude ran this against the spec)

- **§8 Phase 1 deliverable** (VPC + EKS + ALB controller; hello-nginx reachable
  from internet) → Tasks 2, 3, 4, 5. ✅
- **§8 Phase 1 learning focus** (VPC/subnets/NAT → Task 2; IRSA → Task 4;
  ingress → Task 5). ✅
- **§3 topology** (one VPC 10.0.0.0/16, 2 AZs, single NAT, private node group,
  Graviton spot) → Tasks 2–3. Node count starts small (2× t4g.large) vs spec's
  eventual 3× t4g.xlarge — documented as a Phase-1 cost choice, scaled up when
  real workloads land in Phase 2/3. ✅
- **§4 community modules for vpc/eks, hand-written IAM** → VPC/EKS modules (Tasks
  2–3), hand-written-via-submodule IRSA (Task 4). ✅
- **§4 remote backend / single root module** → Task 1 (`aws/main` on Phase 0's
  S3 backend). ✅
- **§4 teardown gotcha #1** (delete in-cluster ALB before terraform destroy) →
  Task 6 `down.sh`. ✅
- **§6 arm64 images ↔ Graviton** (no cross-compile) → Task 3 AMI gotcha. ✅
- **§7 cost guardrails** (leak-check after teardown; spot+Graviton+single NAT) →
  cost table up top + Task 6. ✅
- **Deferred to later phases (correctly out of scope here):** ECR + self-hosted
  infra + first real service (Phase 2); Secrets Manager + ESO (Phase 3); RDS /
  ElastiCache / S3 swaps (Phase 4). hello-nginx uses a public image, so no ECR
  yet.

---

## Next phase

Phase 2 (ECR + self-hosted infra — Kafka, Mongo, observability — + your first
real JVM service on the cluster) gets its own plan once Phase 1 applies clean and
you've banked the IRSA + teardown interview notes. One phase at a time — the
learning loop.
