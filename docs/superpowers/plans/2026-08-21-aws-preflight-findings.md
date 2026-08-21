# AWS pre-flight audit — findings

**Date:** 2026-08-21 · **Scope:** steps 2–9 of `scripts/aws/up-all.sh`, read-only
**Already fixed, not re-reported:** `build.sh`'s registry probe (Task 1, `320fa58`);
`down.sh`'s missing context guard and its `|| true` on the Ingress deletes (Task 2,
`02c24a1`/`8ea93d0`).

**How this audit was run:** three delegated auditors were dispatched and all three died
to machine sleep or stall before writing anything. The sweep below was performed
directly. That has a coverage consequence, stated honestly in **Coverage** — this is a
partial audit, not the full one the plan specified.

## Must fix before the run

### F1 — `down.sh`'s recovery message names a cluster that does not exist

- **Where:** `scripts/aws/down.sh:33`
- **Text:** `echo "  To restore the context:  aws eks update-kubeconfig --name microecom \\" >&2`
- **What happens at runtime:** `aws/main/variables.tf:16` defaults `cluster_name` to
  **`microecom-eks`**, and `aws/main/terraform.tfvars` does not override it. An operator
  who hits the exit-1 branch and follows this instruction verbatim gets
  `ResourceNotFoundException: No cluster found for name: microecom`. They are already in
  a failure state, and the printed remedy sends them to a second, unrelated failure.
- **Why offline gates missed it:** it is a string inside an `echo` on a branch no suite
  executes. `bash -n` and the unit suite both pass.
- **Provenance:** introduced by **this branch**, in Task 2 — I wrote it into the plan
  text. The two pre-existing scripts get it right: `infra-up.sh:28` and
  `aws-deploy.sh:189` both say `--name microecom-eks`.
- **Fix:** change `--name microecom` to `--name microecom-eks`, matching the other two
  and the Terraform default. Better still, note that `scripts/aws/up.sh:13` resolves it
  dynamically via `terraform output -raw cluster_name` rather than hardcoding — the
  hardcoded form in all three messages is a latent drift if `cluster_name` is ever
  overridden.

## Note and proceed

### N1 — `up-all.sh`'s own `kubectl` calls name no context

- **Where:** `scripts/aws/up-all.sh:195, 197, 204, 241, 242, 256`
- **Symptom:** with `kubectl` pointed elsewhere, the step-6 readiness gate, the
  inventory-service restart, and the ALB address lookup all run against the wrong
  cluster. The gate would fail with "deployment not found" rather than anything
  informative.
- **Why survivable here:** two reasons, both worth knowing. First, `up-all.sh` runs
  `up.sh` as step 1, which calls `aws eks update-kubeconfig … --alias microecom-eks` and
  thereby *sets* the current context — so a full one-shot run is self-consistent.
  Second, **the checkpoint plan never invokes `up-all.sh`**; it calls the individual
  entry points, and every one of those is guarded (`infra-up.sh:24-26`,
  `aws-deploy.sh:186-191`, and `seed.sh` receives `--context microecom-eks` explicitly).
- Still a genuine asymmetry: `up-all.sh` passes `--context` to the scripts it calls but
  not to its own `kubectl` invocations. Worth fixing before anyone runs `make aws-all`.

### N2 — `down.sh`'s ALB wait is a fixed sleep, not a poll

- **Where:** `scripts/aws/down.sh:57` — `sleep 60`
- **Symptom:** if the Load Balancer Controller takes longer than 60 s to deprovision,
  `terraform destroy` starts early and hangs on orphaned ENIs, usually surfacing as a
  destroy stuck on subnet or VPC deletion.
- **Why survivable:** recognisable, and `make aws-leak-check` catches the consequence.
  Already recorded in the plan's teardown section as a known weakness.

### N3 — `up-all.sh`'s header describes a deployment mechanism it no longer uses

- **Where:** `scripts/aws/up-all.sh:23` (`6 apps  kubectl apply -k overlay`) and `:162`
- **Symptom:** the step-6 banner and header comment describe the kustomize overlay path
  that Phase 8 deleted; the body calls `deploy/scripts/aws-deploy.sh` (Helm). A reader
  debugging step 6 looks for an overlay that does not exist.
- **Why survivable:** comments only; the code is correct. Lines 159–181 already document
  the Helm migration in detail, so the truth is present a few lines below the stale claim.

## Open questions

- **Can pods reach the SMTP host?** Mail is configured (below), but application pods run
  in private subnets and egress through the single NAT gateway. Whether outbound SMTP is
  permitted cannot be determined from the repo. **Resolved by:** attempting a
  registration at acceptance tier 3 and watching `authorization-server` logs. If OTP
  never arrives while the pod stays Ready, this is the cause.
- **Does `cluster_name` drift matter?** Three scripts hardcode the cluster name in
  recovery messages while `up.sh` resolves it from Terraform. Harmless at the current
  default; wrong for anyone who overrides `cluster_name`.

## Mail / OTP verdict

**CONFIGURED.** All seven mail keys resolve to non-empty values for `ENV=aws` in
`deploy/secrets/tests/golden/aws.json`:

```
/ecommerce/spring.mail.host                                  set
/ecommerce/spring.mail.port                                  set
/ecommerce/spring.mail.protocol                              set
/ecommerce/spring.mail.username                              set
/ecommerce/spring.mail.password                              set
/ecommerce/spring.mail.properties.mail.smtp.auth             set
/ecommerce/spring.mail.properties.mail.smtp.starttls.enable  set
```

Declared in `deploy/secrets/contexts/aws.yaml` and the canonical
`deploy/secrets/ecommerce.yaml`. **Acceptance tier 3 (registration and login) should
work**, subject to the SMTP egress question above.

The two failure modes look completely different and are worth distinguishing in advance:
a *missing* mail config makes `authorization-server` fail readiness and never come up —
loud, and it would block checkpoint 3. Config present but the SMTP host unreachable
leaves the pod happily Ready while the OTP silently never arrives — which looks like a
frontend bug and is not one.

## Verified clean

Checked and found correct — recorded so a later reader knows these were examined, not
skipped:

- **Every referenced path exists.** `deploy/aws-infra/storageclass-gp3.yaml`,
  `deploy/aws-infra/manifests/*` (all six `-f` targets), `deploy/k8s-jobs/04-kafka-connect-register/`,
  `aws/manifests/hello-nginx.yaml`, `deploy/platform-values/ingress-nginx.yaml`. No
  dangling references survived Phase 8 on these paths.
- **`aws-deploy.sh`'s `terraform output … || true` reads are guarded.** Lines 150–151 can
  yield empty strings, and lines 155–156 immediately fail with an actionable message.
  This is the correct shape, not the "unguarded read passes when its input vanishes"
  defect it superficially resembles.
- **Context guards exist on the paths the checkpoint plan actually uses:**
  `infra-up.sh:24-26` aborts unless the context is `microecom-eks`;
  `aws-deploy.sh:186-191` does the same.
- **Every `helm upgrade --install` carries `--wait --timeout 5m`** — `infra-up.sh:79`,
  `:130`, `:146`; `platform.sh:37`, `:51`.
- **All `helm repo add … || true` are benign** — "already added" is the expected
  condition being suppressed, not a transport failure.
- **No remaining `http://` against a remote host.** The only occurrences are
  `build.sh:37` (Task 1) and `build.sh:56` inside `image_in_registry` (fixed in
  the code-review pass after Task 1 — it was reachable only when
  `REUSE_EXISTING` is set, which is the `REUSE_EXISTING=1 REGISTRY=<ecr-host>`
  path, so it was a live-but-unexercised instance of the same defect). Both are
  now gated behind `registry_is_local_http` and both carry `--max-time 5`.
  Also two display strings in `up-all.sh:261-262`.

## Coverage

Read directly and swept for all ten patterns:

| File | Lines |
|---|---|
| `scripts/aws/up-all.sh` | 263 |
| `scripts/aws/infra-up.sh` | 174 |
| `scripts/aws/push-images.sh` | 50 |
| `scripts/aws/up.sh` | 18 |
| `scripts/aws/down.sh` | 73 |
| `scripts/aws/leak-check.sh` | 33 |
| `deploy/scripts/aws-deploy.sh` | 195 |
| `deploy/scripts/secrets-seed.sh` | 194 |
| `deploy/scripts/platform.sh` | 56 |
| `deploy/images/build.sh` | 167 |

Plus `aws/main/variables.tf`, `aws/main/eks.tf`, `deploy/secrets/contexts/aws.yaml`, and
`deploy/secrets/tests/golden/aws.json` for the cluster-name and mail questions.

**`deploy/scripts/seed.sh` (744 lines) — gap closed after the first draft.** It runs at
steps 4, 7, 8 and 9, directly under the two riskiest checkpoints, so it was swept for the
same patterns rather than left unexamined. Findings: **none.** It is the best-guarded
script in the path.

- It has its own context guard at lines 109–114 that **refuses to guess** — if
  `--context` disagrees with `kubectl`'s current context, it aborts rather than picking
  one. Line 723's reconcile names the context explicitly too.
- Every hardcoded `127.0.0.1` is correct: the Mongo URIs at 309 and 315 are evaluated
  *inside* `docker exec` (compose leg) or
  `kubectl --context "$KUBE_CONTEXT" -n "$NS" exec -i mongodb-0` (k8s/aws leg), so they
  address the container's own loopback. Line 244's `http://localhost:9000` is likewise
  inside a `docker exec`. Line 374's MinIO host is a variable.
- Its `|| true` uses are on `grep -c` (616–617), where exit 1 means "zero matches" — the
  expected-absent case, not a suppressed transport failure. Two comments (207, 703)
  exist specifically to explain why `|| true` is deliberately *absent* elsewhere.
- Worth reading for its own sake: the Mongo legs pipe credentials through **stdin** into
  a temp config file rather than passing `-u/-p`, because argv is readable via `ps aux`
  host-side and `/proc/<pid>/cmdline` container-side.

**Still NOT audited — the remaining gap:**

- **`deploy/aws-infra/` manifest contents** (mongodb, kafka, schema-registry,
  kafka-connect, external-secrets, plus values and dashboards). Confirmed to *exist* and
  to be referenced correctly, but not reviewed for image references, storage-class
  assumptions, or unenforced ordering requirements. These apply at checkpoint 2.
- `scripts/aws/RUNBOOK.md` was read for its step sequence and teardown guidance, but not
  swept for the ten patterns. It is documentation; a defect there misleads rather than
  breaks.

Confidence: **high** for the ten patterns across the eleven scripts swept; **none** for
the `aws-infra` manifest contents. Checkpoint 2 is where that gap would surface, and
checkpoint 2's verification step (`get pods -n infra`, `get pvc -A`, `get sc`) is
designed to catch exactly the class of problem those manifests could carry.
