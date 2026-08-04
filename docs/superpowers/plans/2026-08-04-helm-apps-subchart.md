# Helm apps subchart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the 10 application Deployments, Services, HPAs, Ingresses, gateway RBAC and AWS ExternalSecrets/IRSA from a new Helm `apps` subchart at `deploy/charts/microecom/charts/apps/`, side by side with the untouched `k8s/apps/` Kustomize tree.

**Architecture:** One shared container template driven entirely by values. Each service block in `values.yaml` is merged over a chart-level `defaults` block with `mergeOverwrite (deepCopy $.Values.defaults) …`; `env` is merged separately, key by key, because mergo skips nil values. Environment divergence is two enums — `global.secret.backend` ∈ {`vault`, `externalSecrets`} and `global.ingress.className` ∈ {`nginx`, `alb`} — plus pure data in `envs/aws.yaml`.

**Tech Stack:** Helm 3 (umbrella chart + local subchart), Sprig template functions, bash assertion harness over `helm template`, minikube for the live checks.

## Global Constraints

Copy these into every task. They bind all tasks.

- **`k8s/` is not modified.** `git diff main HEAD -- 'k8s/**'` MUST be empty at the end of this phase. Read from it freely; never write to it.
- **Values are transcribed, not tuned.** Every port, resource, probe timing and HPA number comes from the existing base manifest. No retuning, no "improvements", no new observability.
- **`managementPort` is never derived from `port`.** Seven of nine JVM services follow `port + 10000`; authorization-server (6666 → **19091**) and gateway (6868 → **19093**) do not. Deriving it renders correctly for seven and silently points two services' probes at dead ports.
- **`deepCopy` before every merge.** Sprig's `merge`/`mergeOverwrite` mutate the destination in place. Without `deepCopy`, the first service's overrides permanently contaminate `.Values.defaults`.
- **`enabled` is read from the raw `$svc`, never from the merged result.** Mergo treats falsy values as absent, so `enabled: false` cannot survive a merge against a default of `true`.
- **Subchart `.Values` asymmetry.** Inside `charts/apps/templates/*` write `.Values.defaults` / `.Values.apps` (unprefixed). In the umbrella `Chart.yaml` `condition:`, in `--set`, and in the umbrella `values.yaml` / `envs/*.yaml`, keys stay fully qualified: `apps.apps.gateway.…` is correct and is NOT a typo to "fix".
- **Every object sets `metadata.namespace` explicitly** to `{{ .Values.global.namespaces.apps }}`. The Helm release namespace (`--namespace infra`) never determines object placement.
- **Labels are `app.kubernetes.io/*` only.** No bare `app:` key anywhere. (Plan 2 lesson: kafka-connect used a bare `app:` and a cross-cutting selector silently skipped it.)
- **Every new render assertion must be scoped and RED-proven.** `helm template` emits one flat text stream, so an unscoped assertion only asks "does this string appear anywhere in the release?" Standard: *would this fail if the object it names were deleted?* Prove it by breaking the thing it claims to prove (via `--set` or a scratch chart copy under `/private/tmp/`), confirming FAIL, restoring, confirming PASS.
- **Never `git push`.** A pre-push hook owns pushing and it is the human's job in this repo. Never bypass that hook.
- **Sandbox restrictions:** bare `rm` is blocked (use `python3 -c "import os; os.remove(...)"`), `git checkout --` is blocked (use `git restore`), foreground `sleep` is blocked (use `/bin/sleep`).

### Enum spelling — reconciled with the tree

The design spec writes the ESO enum value as `eso`. The checked-in files already
use **`externalSecrets`** (`deploy/charts/microecom/values.yaml` → `global.secret.backend: vault  # vault | externalSecrets`; `envs/aws.yaml` → `backend: externalSecrets`). **Use `externalSecrets`.** No template reads `global.secret.backend` today — this phase is its first consumer, so the checked-in spelling governs.

### Deviations from the spec, and why

Three deviations from §3 rule 3 of the spec ("deletion needs an explicit `null` sentinel"). The rule holds where the key is absent from `defaults`; it breaks where the key is present, because **mergo skips nil source values**, so `null` cannot overwrite a set default.

| Spec says | Plan does | Why |
|---|---|---|
| `env: null` on frontend unsets inherited env | `env` is merged by an explicit key-by-key loop, outside mergo | `mergeOverwrite` would leave `defaults.env` intact — the frontend would get `VAULT_TOKEN`, `JAVA_OPTS`, etc. Same failure for mock-paypal's per-key `VAULT_TOKEN: null`. |
| `appConfig: null` on frontend | frontend sets `static: true`; templates test `not $s.static` | Same mergo problem, inverted so the sentinel is truthy. |
| `managementPort: null` on frontend | frontend simply omits the key | `managementPort` is not in `defaults`, so omission already yields nil. The `null` is harmless but the omission is honest. |

One addition not in the spec, found while reading `k8s/apps/overlays/local/kustomization.yaml`: the **local overlay injects two env vars into payment-service** (`SPRING_APPLICATION_JSON` pointing at mock-paypal, and `PAYPAL_TUNNEL_URL`). The spec's survey missed it. It is reproduced in `envs/local-k8s.yaml` in Task 6.

One observation, deliberately **not** fixed: mock-paypal-service's `MOCK_PUBLIC_BASE_URL` is `http://api.microecom.local/mock-paypal-service` in the base manifest, and the AWS overlay does not patch it — so AWS inherits the local hostname today. The chart reproduces that faithfully. Fixing it is out of scope ("transcribe, don't tune").

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `deploy/charts/microecom/charts/apps/Chart.yaml` | subchart metadata |
| `deploy/charts/microecom/charts/apps/values.yaml` | `defaults{}` + 10 per-service `apps{}` blocks + `irsa{}` |
| `deploy/charts/microecom/charts/apps/templates/_helpers.tpl` | `apps.labels`, `apps.selectorLabels`, `apps.merged`, `apps.container` |
| `…/templates/deployments.yaml` | 10 Deployments |
| `…/templates/services.yaml` | 10 Services |
| `…/templates/hpas.yaml` | 5 HPAs, gated per-service on `.hpa` |
| `…/templates/gateway-rbac.yaml` | ServiceAccount + Role + RoleBinding, gated on `apps.gateway.rbac` |
| `…/templates/ingress.yaml` | nginx block \| alb block, selected by `global.ingress.className` |
| `…/templates/externalsecrets.yaml` | 9 ExternalSecrets, gated on `global.secret.backend` |
| `…/templates/irsa-serviceaccounts.yaml` | S3 IRSA ServiceAccounts, gated on the same enum + per-service `irsa` |

**Modified:**

| Path | Change |
|---|---|
| `deploy/charts/microecom/Chart.yaml` | add the `apps` dependency with `condition: apps.enabled` |
| `deploy/charts/microecom/values.yaml` | add `apps.enabled: false` |
| `deploy/charts/microecom/envs/local-k8s.yaml` | payment-service local env |
| `deploy/charts/microecom/envs/aws.yaml` | ESO defaults, IRSA, ALB service annotations, storefront host |
| `deploy/charts/microecom/tests/render-test.sh` | rescope the local-registry assertion; add the Phase-3 sections |
| `Makefile` | new `k8s-apps-helm` target |
| `deploy/README.md` | apps section + the "one path per cluster" extension |

---

## Task 1: Subchart scaffold, values, and Deployments

**Files:**
- Create: `deploy/charts/microecom/charts/apps/Chart.yaml`
- Create: `deploy/charts/microecom/charts/apps/values.yaml`
- Create: `deploy/charts/microecom/charts/apps/templates/_helpers.tpl`
- Create: `deploy/charts/microecom/charts/apps/templates/deployments.yaml`
- Modify: `deploy/charts/microecom/Chart.yaml`
- Modify: `deploy/charts/microecom/values.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh`

**Interfaces:**
- Produces, for every later task:
  - `apps.labels` — `dict "name" <string> "root" $` → the four `app.kubernetes.io/*` label lines (no leading indent; caller uses `nindent`).
  - `apps.selectorLabels` — same dict → the two immutable selector label lines.
  - `apps.container` — `dict "name" <string> "svc" $s "root" $` → the container list item. `$s` must be the **merged** service.
  - There is deliberately **no** merge helper: a Helm `define` returns a string, not a dict, so the merge cannot be factored out. `deployments.yaml` is the only template that needs it — see Task 2 for why `services.yaml` does not.
- Values keys later tasks read: `$svc.enabled`, `$svc.hpa`, `$svc.rbac`, `$svc.ingress`, `$svc.static`, `$svc.s3`, `$svc.irsa`, `$svc.serviceAnnotations`, `$svc.servicePort`, `$svc.extraPorts`, `.Values.irsa.s3RoleArn`.

- [ ] **Step 1: Create the subchart `Chart.yaml`**

```yaml
# deploy/charts/microecom/charts/apps/Chart.yaml
apiVersion: v2
name: apps
description: The ten microecom application workloads (9 JVM services + the storefront SPA)
type: application
version: 0.1.0
appVersion: "0.1.0"
```

- [ ] **Step 2: Create the subchart `values.yaml`**

Every number below is transcribed from `k8s/apps/base/<service>/deployment.yaml`. Do not adjust any of them.

```yaml
# deploy/charts/microecom/charts/apps/values.yaml
#
# One shared template renders all ten workloads. Per-service blocks under `apps:`
# are merged OVER `defaults:` at render time. Read templates/_helpers.tpl for the
# three load-bearing merge rules before changing anything here.
#
# NOTE ON PATHS: from the umbrella chart these keys are `apps.defaults.…` and
# `apps.apps.<service>.…`. The doubled `apps.apps` is correct — the first is the
# subchart name, the second is this file's `apps:` map. Do not "fix" it.

# Applied to every service, then overridden per service.
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
  # A MAP, not a list: YAML lists cannot merge element-wise. The
  # list-of-{name,value} shape appears only at render time, emitted by a sorted
  # `range`, so renders are deterministic and diffs are stable.
  env:
    MALLOC_ARENA_MAX: "2"
    JAVA_OPTS: "-XX:MaxRAMPercentage=75.0 -XX:+UseG1GC"
    VAULT_TOKEN: root
    SPRING_CLOUD_VAULT_URI: http://vault.infra.svc.cluster.local:8200

# S3 IRSA role for the two services that presign uploads. Stamped by the deploy
# script from `terraform output s3_irsa_role_arn`; only read when
# global.secret.backend == externalSecrets AND a service sets `irsa: true`.
irsa:
  s3RoleArn: ""

apps:
  authorization-server:
    enabled: true
    port: 6666
    # NOT 16666. Transcribed from application.yml — see the Global Constraints.
    managementPort: 19091
    resources:
      requests: { cpu: 250m, memory: 512Mi }
      limits:   { cpu: 2000m, memory: 768Mi }
    env:
      JAVA_OPTS: "-XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -XX:+UseStringDeduplication"
    envFrom:
      - secretRef: { name: app-secrets, optional: true }
    s3: true
    hpa: { maxReplicas: 3, scaleUpPods: 2 }

  bff-service:
    enabled: true
    port: 8087
    managementPort: 18087
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 1000m, memory: 384Mi }

  frontend:
    enabled: true
    # Caddy serving a static Vite build. `static: true` is the sentinel that
    # switches off everything JVM-shaped: no actuator port, no app-config volume,
    # no ExternalSecret. A truthy sentinel, not a `null` one, because mergo skips
    # nil source values and could not unset a default of `true`.
    static: true
    port: 8080
    servicePort: 80
    env: {}
    resources:
      requests: { cpu: 20m, memory: 32Mi }
      limits:   { cpu: 200m, memory: 64Mi }
    probes:
      # failureThreshold is inherited (4 liveness / 6 readiness). The base
      # manifest omits it on both probes and relies on the Kubernetes default of
      # 3 for liveness / 3 for readiness; an explicit inherited value is a
      # deliberate, stated change (design spec §5).
      liveness:  { path: /, port: http, initialDelaySeconds: 10, periodSeconds: 30 }
      readiness: { path: /, port: http, initialDelaySeconds: 2,  periodSeconds: 5 }
    ingress:
      host: microecom.local

  gateway:
    enabled: true
    port: 6868
    # NOT 16868. Transcribed from application.yml — see the Global Constraints.
    managementPort: 19093
    serviceAccountName: gateway
    rbac: true
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { cpu: 1500m, memory: 768Mi }
    probes:
      liveness:  { initialDelaySeconds: 45 }
      readiness: { initialDelaySeconds: 25 }
    env:
      SPRING_PROFILES_ACTIVE: k8s
    hpa: { maxReplicas: 2, scaleUpPods: 1 }
    ingress:
      host: api.microecom.local
      annotations:
        # 120s, not the nginx default 60s: k6 bursts push gateway p99 past 60s.
        nginx.ingress.kubernetes.io/proxy-read-timeout: "120"
        nginx.ingress.kubernetes.io/proxy-send-timeout: "120"
        nginx.ingress.kubernetes.io/use-regex: "false"

  inventory-service:
    enabled: true
    port: 6969
    managementPort: 16969
    extraPorts:
      - { name: grpc, containerPort: 9090 }
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { cpu: 1500m, memory: 768Mi }
    s3: true
    hpa: { maxReplicas: 2, scaleUpPods: 1 }

  mock-paypal-service:
    enabled: true
    port: 8585
    managementPort: 18585
    resources:
      requests: { cpu: 50m,  memory: 256Mi }
      limits:   { cpu: 500m, memory: 384Mi }
    probes:
      liveness:  { initialDelaySeconds: 30 }
      readiness: { initialDelaySeconds: 15 }
    env:
      MOCK_PUBLIC_BASE_URL: http://api.microecom.local/mock-paypal-service
      JAVA_OPTS: "-XX:MaxRAMPercentage=75.0"
      # Not a Spring Cloud Vault client — unset both inherited Vault vars.
      VAULT_TOKEN: null
      SPRING_CLOUD_VAULT_URI: null

  orchestrator-service:
    enabled: true
    port: 9999
    managementPort: 19999
    resources:
      requests: { cpu: 100m,  memory: 512Mi }
      limits:   { cpu: 1000m, memory: 768Mi }

  order-service:
    enabled: true
    port: 9696
    managementPort: 19696
    resources:
      requests: { cpu: 200m,  memory: 512Mi }
      limits:   { cpu: 1500m, memory: 768Mi }
    hpa: { maxReplicas: 3, scaleUpPods: 2 }

  payment-service:
    enabled: true
    port: 8484
    managementPort: 18484
    # 512Mi requests, not 256Mi: 512Mi OOMKilled at startup (JVM non-heap).
    resources:
      requests: { cpu: 100m,  memory: 512Mi }
      limits:   { cpu: 1000m, memory: 768Mi }
    envFrom:
      - secretRef: { name: app-secrets, optional: true }

  product-service:
    enabled: true
    port: 7777
    managementPort: 17777
    resources:
      requests: { cpu: 200m,  memory: 512Mi }
      limits:   { cpu: 1500m, memory: 768Mi }
    s3: true
    hpa: { maxReplicas: 2, scaleUpPods: 1 }
```

- [ ] **Step 3: Create `_helpers.tpl`**

```gotemplate
{{/*
Labels carried by every apps object.

`app.kubernetes.io/name` — NOT a bare `app:` key. Plan 2 found kafka-connect
using a bare `app:` where every sibling used the canonical key, and a
cross-cutting selector silently skipped it. Nothing was broken at runtime, which
is exactly why it survived.

  usage: {{- include "apps.labels" (dict "name" $name "root" $) | nindent 4 }}
*/}}
{{- define "apps.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: microecom
{{- end }}

{{/*
The subset that goes into an immutable selector. `spec.selector` cannot be
changed on an existing Deployment, so this must stay a strict, stable subset of
apps.labels — never add `managed-by` or `part-of` here.
*/}}
{{- define "apps.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/*
The container block: name, image, ports, env, envFrom, both probes, resources,
and the AWS app-config volume mount.

  usage: {{- include "apps.container" (dict "name" $name "svc" $s "root" $) | nindent 8 }}

`.svc` must be the MERGED service (see the four-line preamble each template
repeats), not the raw values block.
*/}}
{{- define "apps.container" -}}
{{- $name := .name -}}
{{- $s := .svc -}}
{{- $root := .root -}}
- name: {{ $name }}
  image: {{ $root.Values.global.appImage.registry }}/{{ $name }}:{{ $root.Values.global.appImage.tag }}
  imagePullPolicy: {{ $s.imagePullPolicy }}
  ports:
    - name: http
      containerPort: {{ $s.port }}
    {{- range $p := $s.extraPorts }}
    - name: {{ $p.name }}
      containerPort: {{ $p.containerPort }}
    {{- end }}
    {{- if $s.managementPort }}
    - name: management
      containerPort: {{ $s.managementPort }}
    {{- end }}
  {{- if $s.env }}
  env:
    {{- range $k, $v := $s.env }}
    {{- if $v }}
    - name: {{ $k }}
      value: {{ $v | quote }}
    {{- end }}
    {{- end }}
  {{- end }}
  {{- with $s.envFrom }}
  envFrom:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  livenessProbe:
    httpGet:
      path: {{ $s.probes.liveness.path }}
      port: {{ $s.probes.liveness.port }}
    initialDelaySeconds: {{ $s.probes.liveness.initialDelaySeconds }}
    periodSeconds: {{ $s.probes.liveness.periodSeconds }}
    failureThreshold: {{ $s.probes.liveness.failureThreshold }}
  readinessProbe:
    httpGet:
      path: {{ $s.probes.readiness.path }}
      port: {{ $s.probes.readiness.port }}
    initialDelaySeconds: {{ $s.probes.readiness.initialDelaySeconds }}
    periodSeconds: {{ $s.probes.readiness.periodSeconds }}
    failureThreshold: {{ $s.probes.readiness.failureThreshold }}
  resources:
    {{- toYaml $s.resources | nindent 4 }}
  {{- if and (eq $root.Values.global.secret.backend "externalSecrets") (not $s.static) }}
  volumeMounts:
    - name: app-config
      mountPath: /etc/app-config
      readOnly: true
  {{- end }}
{{- end }}
```

- [ ] **Step 4: Create `deployments.yaml`**

The four-line merge preamble at the top of the `range` is repeated verbatim in `services.yaml` (Task 2). A `define` cannot return a dict, so this duplication is forced by the template language — do not try to factor it out.

```gotemplate
{{- range $name, $svc := .Values.apps }}
{{/*
  MERGE PREAMBLE — three load-bearing rules. Repeated verbatim in services.yaml
  because a Helm `define` cannot return a value.

  1. `enabled` is read from the RAW $svc. Mergo treats falsy values as absent, so
     `enabled: false` cannot survive a merge against a default of `true`.
  2. `deepCopy` is mandatory. Sprig's mergeOverwrite wraps mergo's in-place API
     and MUTATES its destination. Without deepCopy the first service's overrides
     permanently contaminate $.Values.defaults, and because `range` over a map
     iterates in sorted key order, every service sorting after it inherits them.
     Contamination COMPOUNDS: each later service that overrides the same field
     overwrites the previous leak. gateway (4th) leaks 45, then mock-paypal (6th)
     overwrites it with 30, so order-service (8th) observes 30 — not 45.
     render-test.sh asserts order-service still gets 60.
  3. `env` is merged OUTSIDE mergo, key by key. Mergo skips nil source values, so
     a per-key `null` (mock-paypal's VAULT_TOKEN) could not unset an inherited
     value, and `env: {}` could not clear the map. The explicit loop can store a
     nil; apps.container's `{{ if $v }}` then drops it.
*/}}
{{- if $svc.enabled }}
{{- $s := mergeOverwrite (deepCopy $.Values.defaults) (omit $svc "env") }}
{{- $env := deepCopy (default (dict) $.Values.defaults.env) }}
{{- if hasKey $svc "env" }}{{- range $k, $v := $svc.env }}{{- $_ := set $env $k $v }}{{- end }}{{- end }}
{{- if and (hasKey $svc "env") (not $svc.env) }}{{- $env = dict }}{{- end }}
{{- $_ := set $s "env" $env }}
{{- $sa := $s.serviceAccountName }}
{{- if and (not $sa) $s.irsa }}{{- $sa = $name }}{{- end }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  namespace: {{ $.Values.global.namespaces.apps }}
  labels:
    {{- include "apps.labels" (dict "name" $name "root" $) | nindent 4 }}
spec:
  replicas: {{ $s.replicas }}
  selector:
    matchLabels:
      {{- include "apps.selectorLabels" (dict "name" $name "root" $) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "apps.labels" (dict "name" $name "root" $) | nindent 8 }}
    spec:
      {{- with $sa }}
      serviceAccountName: {{ . }}
      {{- end }}
      containers:
        {{- include "apps.container" (dict "name" $name "svc" $s "root" $) | nindent 8 }}
      {{- if and (eq $.Values.global.secret.backend "externalSecrets") (not $s.static) }}
      volumes:
        - name: app-config
          secret:
            secretName: {{ $name }}-config
      {{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 5: Wire the subchart into the umbrella**

Modify `deploy/charts/microecom/Chart.yaml` — append to `dependencies`:

```yaml
apiVersion: v2
name: microecom
version: 0.1.0
appVersion: "0.1.0"
dependencies:
  - name: infra
    version: 0.1.0
    repository: ""          # local subchart in charts/infra
    condition: infra.enabled
  - name: apps
    version: 0.1.0
    repository: ""          # local subchart in charts/apps
    condition: apps.enabled
```

Modify `deploy/charts/microecom/values.yaml` — add an `apps:` block immediately after the `infra:` block's `enabled` line region (top level, sibling of `infra:`). Place it directly above the `infra:` block so the two gates read together:

```yaml
# Phase 3 is side by side, not a cut-over: `make k8s-apps` (kubectl) stays the
# default path. Off here so `make k8s-infra-helm` keeps rendering exactly what it
# rendered in Phase 2; `make k8s-apps-helm` passes --set apps.enabled=true.
apps:
  enabled: false
```

- [ ] **Step 6: Render and eyeball once**

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  --set apps.enabled=true --show-only charts/apps/templates/deployments.yaml
```

Expected: 10 Deployment documents. Spot-check that `gateway` has `containerPort: 19093`, `initialDelaySeconds: 45`, `SPRING_PROFILES_ACTIVE`; that `frontend` has no `management` port and no `env:` key at all; that `mock-paypal-service` has `MOCK_PUBLIC_BASE_URL` but no `VAULT_TOKEN`.

- [ ] **Step 7: Add the render-test helpers**

Append to `deploy/charts/microecom/tests/render-test.sh`, immediately after the `section()` definition (around line 67), before the `# ── Task 1` marker:

```bash
# ── Phase 3 helpers ─────────────────────────────────────────────────────────

# The apps subchart is gated off by default (side-by-side phase). Every apps
# assertion renders through this instead of render().
apps_render() { render --set apps.enabled=true "$@"; }

# doc_named <kind> <name> <text> — one object, by kind AND metadata.name.
# docs_of_kind alone is not enough here: ten Deployments in one stream means an
# unscoped probe assertion could be satisfied by any of the other nine.
doc_named() {
  docs_of_kind "$1" <<<"$3" | awk -v RS='\n---\n' -v n="$2" '$0 ~ ("(^|\n)  name: " n "([ \t]*$|\n)")'
}

# probe_block <deployment-doc> <liveness|readiness>
# Slices one probe out of a rendered container. The container block's key order
# is fixed by apps.container: ... livenessProbe / readinessProbe / resources.
probe_block() {
  case "$2" in
    liveness)  awk '/livenessProbe:/{f=1} /readinessProbe:/{f=0} f' <<<"$1" ;;
    readiness) awk '/readinessProbe:/{f=1} /resources:/{f=0} f' <<<"$1" ;;
  esac
}

# assert_probe <deployment-name> <liveness|readiness> <field> <expected> <text>
assert_probe() {
  local doc block actual
  doc="$(doc_named Deployment "$1" "$5")"
  block="$(probe_block "$doc" "$2")"
  actual="$(awk -v f="$3:" '$1 == f { print $2; exit }' <<<"$block")"
  if [ "$actual" = "$4" ]; then
    ok   "$1 $2 $3 = $4"
  else
    bad  "$1 $2 $3 is '${actual:-<none>}', expected '$4'"
  fi
}
```

- [ ] **Step 8: Rescope the local-registry assertion (the Plan 2 carry-over)**

The in-file comment at line 127 mandates this. Do **not** delete the assertion — it is the check that caught the `global.image.registry` collision.

In `deploy/charts/microecom/tests/render-test.sh`, replace:

```bash
# PHASE 3: the apps subchart's images legitimately ARE localhost:5000/... —
# scope this assertion to the infra documents then, do not delete it.
assert_lacks "no infra image is rewritten to the local registry"  'image: .*localhost:5000/' "$out"
```

with:

```bash
# PHASE 3 (done): the apps subchart's images legitimately ARE localhost:5000/...,
# so this assertion is now scoped to an apps-DISABLED render. `$out` above comes
# from render(), and the umbrella defaults apps.enabled=false — that IS the
# scoping, and it is enforced rather than incidental by the paired assertion in
# the apps section below, which requires apps images TO carry the registry. If
# apps.enabled ever flips to true by default, that pairing makes the conflict
# fail loudly instead of quietly weakening this check.
assert_lacks "no infra image is rewritten to the local registry (apps off)" \
                                                                  'image: .*localhost:5000/' "$out"
```

- [ ] **Step 9: Add the Phase-3 Deployment assertions**

Append at the end of `render-test.sh`, **before** the final `printf '\n%d passed, %d failed\n'` summary lines:

```bash
# ── Phase 3 / Task 1: apps subchart gating and Deployments ──────────────────
section "apps subchart — gating and Deployments"

infra_only="$(render)"
assert_lacks "apps subchart is OFF by default (side-by-side phase)" \
             '^  name: order-service$' "$(docs_of_kind Deployment <<<"$infra_only")"

apps_out="$(apps_render)"
assert_ok    "apps.enabled=true renders"                          "$apps_out"

apps_deploys="$(docs_of_kind Deployment <<<"$apps_out")"
# Asserted by NAME, not by count: the stream also carries infra Deployments, so a
# count would flip to a false red the day infra gains or loses one.
for s in authorization-server bff-service frontend gateway inventory-service \
         mock-paypal-service orchestrator-service order-service payment-service \
         product-service; do
  assert_has "Deployment rendered: $s" "^  name: ${s}\$" "$apps_deploys"
done

# Pairs with the infra-only assertion above: apps images MUST carry the local
# registry. Together the two pin the scoping in both directions.
gw="$(doc_named Deployment gateway "$apps_out")"
assert_has   "gateway image comes from the local registry" \
             'image: localhost:5000/gateway:dev' "$gw"

# ── deepCopy contamination guard (design spec §3 rule 1) ────────────────────
# `range` over a map iterates in sorted key order, so without deepCopy every
# service's overrides mutate .Values.defaults in place and leak into the ones
# sorting after it — and each later override compounds on the last. gateway
# (4th of 10) leaks 45, mock-paypal-service (6th) then overwrites that with 30,
# so order-service (8th) inherits 30. Asserting it still gets its own 60 fails
# the moment the deepCopy is dropped, whichever value happens to leak.
assert_probe order-service liveness initialDelaySeconds 60 "$apps_out"
assert_probe gateway       liveness initialDelaySeconds 45 "$apps_out"
assert_probe gateway       readiness initialDelaySeconds 25 "$apps_out"

# Per-service transcription checks (design spec §3 table).
assert_probe mock-paypal-service liveness  initialDelaySeconds 30 "$apps_out"
assert_probe mock-paypal-service readiness initialDelaySeconds 15 "$apps_out"
assert_probe frontend            liveness  initialDelaySeconds 10 "$apps_out"
assert_probe frontend            readiness initialDelaySeconds 2  "$apps_out"
# The base frontend readinessProbe omits failureThreshold; the merge supplies an
# explicit inherited 6 (design spec §5, a deliberate stated change).
assert_probe frontend            readiness failureThreshold    6  "$apps_out"

# managementPort is listed per service, never derived. authorization-server and
# gateway break the `port + 10000` pattern; deriving would point their probes at
# dead ports and both would fail readiness forever with a clean-looking values file.
auth="$(doc_named Deployment authorization-server "$apps_out")"
assert_has   "authorization-server management port is 19091, not 16991" \
             'containerPort: 19091' "$auth"
assert_lacks "authorization-server management port was not derived" \
             'containerPort: 16666' "$auth"
assert_has   "gateway management port is 19093, not 16868" 'containerPort: 19093' "$gw"
assert_lacks "gateway management port was not derived"     'containerPort: 16868' "$gw"

# env: null semantics — mergo would have silently kept these.
mock="$(doc_named Deployment mock-paypal-service "$apps_out")"
assert_lacks "mock-paypal-service does not inherit VAULT_TOKEN (null unset)" \
             'VAULT_TOKEN' "$mock"
assert_lacks "mock-paypal-service does not inherit SPRING_CLOUD_VAULT_URI" \
             'SPRING_CLOUD_VAULT_URI' "$mock"
assert_has   "mock-paypal-service keeps its own JAVA_OPTS (no G1GC)" \
             'value: "-XX:MaxRAMPercentage=75.0"' "$mock"
fe="$(doc_named Deployment frontend "$apps_out")"
assert_lacks "frontend has no env block at all"            '^          - name: JAVA_OPTS$' "$fe"
assert_lacks "frontend has no management port"             'name: management' "$fe"

# gateway is the only service with SPRING_PROFILES_ACTIVE.
assert_has   "gateway sets SPRING_PROFILES_ACTIVE=k8s"     'SPRING_PROFILES_ACTIVE' "$gw"
assert_lacks "order-service does not set SPRING_PROFILES_ACTIVE" \
             'SPRING_PROFILES_ACTIVE' "$(doc_named Deployment order-service "$apps_out")"

# extraPorts, envFrom, serviceAccountName hatches.
inv="$(doc_named Deployment inventory-service "$apps_out")"
assert_has   "inventory-service exposes grpc 9090"         'containerPort: 9090' "$inv"
assert_has   "authorization-server has envFrom app-secrets" 'name: app-secrets' "$auth"
assert_lacks "order-service has no envFrom"                'envFrom' "$(doc_named Deployment order-service "$apps_out")"
assert_has   "gateway uses the gateway ServiceAccount"     'serviceAccountName: gateway' "$gw"

# Resources, sampled across the spread of the §3 table.
assert_has   "authorization-server cpu limit is 2000m"     'cpu: 2000m' "$auth"
assert_has   "frontend memory request is 32Mi"             'memory: 32Mi' "$fe"

# Labels and namespace.
assert_has   "apps objects land in the apps namespace"     '^  namespace: apps$' "$gw"
# Any indent, not just 4: pod-template labels sit at 8 spaces, and a bare `app:`
# there would be just as wrong as one in metadata.
assert_lacks "no bare app: label anywhere in apps"         '^ +app: ' "$apps_deploys"

# Vault backend (default) renders no app-config volume.
assert_lacks "backend=vault renders no app-config volume"  'app-config' "$apps_deploys"
```

- [ ] **Step 10: Run the suite**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: all previous assertions still pass, plus the new section, and `0 failed`. If the infra assertions fail with "chart not vendored" errors, run `helm dependency build deploy/charts/microecom/charts/infra` first.

- [ ] **Step 11: RED-prove the deepCopy guard**

This is the load-bearing assertion of the whole phase. Prove it fails when the thing it names is broken.

```bash
cp -r deploy/charts/microecom /private/tmp/red-microecom
# Drop the deepCopy from the scratch copy only.
python3 - <<'PY'
import pathlib
p = pathlib.Path('/private/tmp/red-microecom/charts/apps/templates/deployments.yaml')
t = p.read_text()
assert 'mergeOverwrite (deepCopy $.Values.defaults)' in t
p.write_text(t.replace('mergeOverwrite (deepCopy $.Values.defaults)',
                       'mergeOverwrite $.Values.defaults'))
PY
helm template microecom /private/tmp/red-microecom --namespace infra \
  --set apps.enabled=true --show-only charts/apps/templates/deployments.yaml \
  | awk -v RS='\n---\n' '/(^|\n)  name: order-service([ \t]*$|\n)/' \
  | awk '/livenessProbe:/{f=1} /readinessProbe:/{f=0} f' \
  | grep initialDelaySeconds
```

Expected: `initialDelaySeconds: 45` — order-service inheriting gateway's value, which is exactly the corruption. Then clean up:

```bash
python3 -c "import shutil; shutil.rmtree('/private/tmp/red-microecom')"
```

Re-run `bash deploy/charts/microecom/tests/render-test.sh` and confirm it is green again (the real chart was never touched).

- [ ] **Step 12: Commit**

```bash
git add deploy/charts/microecom/charts/apps deploy/charts/microecom/Chart.yaml \
        deploy/charts/microecom/values.yaml deploy/charts/microecom/tests/render-test.sh
git commit -m "feat(helm): apps subchart with value-driven Deployments"
```

---

## Task 2: Services and HPAs

**Files:**
- Create: `deploy/charts/microecom/charts/apps/templates/services.yaml`
- Create: `deploy/charts/microecom/charts/apps/templates/hpas.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh`

**Interfaces:**
- Consumes: `apps.labels`, `apps.selectorLabels` from Task 1. **Not** the merge preamble — see below.
- Produces: Services named `<service>` with a port named `http` on every one (the Ingress templates in Task 4 bind by `port: { name: http }` for both gateway and frontend, which is why the frontend's port 80 must also be named `http`).

**Why these two templates read raw values, not merged ones:** a Service needs
`port`, `servicePort`, `extraPorts`, `managementPort` and `serviceAnnotations`;
an HPA needs `hpa`. **None of those keys exist in `defaults`** — every one is
per-service by nature — so merging would copy five keys that can never differ
from their source. Reading `$svc` directly is both shorter and honest about
where the values come from. `deployments.yaml` is the one template that must
merge, because it reads `resources`, `probes`, `env`, `replicas` and
`imagePullPolicy`, all of which do have defaults.

- [ ] **Step 1: Write the failing assertions first**

Append to `render-test.sh` before the summary lines:

```bash
# ── Phase 3 / Task 2: Services and HPAs ─────────────────────────────────────
section "apps subchart — Services and HPAs"

apps_svcs="$(docs_of_kind Service <<<"$apps_out")"
for s in authorization-server bff-service frontend gateway inventory-service \
         mock-paypal-service orchestrator-service order-service payment-service \
         product-service; do
  assert_has "Service rendered: $s" "^  name: ${s}\$" "$apps_svcs"
done

gw_svc="$(doc_named Service gateway "$apps_out")"
assert_has   "gateway Service exposes 6868"                'port: 6868' "$gw_svc"
assert_has   "gateway Service exposes management 19093"    'port: 19093' "$gw_svc"
assert_has   "gateway Service selects by app.kubernetes.io/name" \
             'app\.kubernetes\.io/name: gateway' "$gw_svc"

fe_svc="$(doc_named Service frontend "$apps_out")"
# 80 → containerPort 8080, matching the base manifest. The port is NAMED http on
# purpose: ingress.yaml binds both gateway and frontend by port name.
assert_has   "frontend Service listens on 80"              'port: 80$' "$fe_svc"
assert_has   "frontend Service port is named http"         'name: http' "$fe_svc"
assert_lacks "frontend Service has no management port"     'name: management' "$fe_svc"

inv_svc="$(doc_named Service inventory-service "$apps_out")"
assert_has   "inventory-service Service exposes grpc"      'name: grpc' "$inv_svc"
assert_has   "inventory-service grpc port is 9090"         'port: 9090' "$inv_svc"

# HPAs: exactly the five that have one today. Assert both directions — the
# services that must have one, and a representative that must not.
apps_hpas="$(docs_of_kind HorizontalPodAutoscaler <<<"$apps_out")"
for s in authorization-server gateway inventory-service order-service product-service; do
  assert_has "HPA rendered: $s" "^  name: ${s}\$" "$apps_hpas"
done
for s in bff-service frontend mock-paypal-service orchestrator-service payment-service; do
  assert_lacks "no HPA for $s" "^  name: ${s}\$" "$apps_hpas"
done

auth_hpa="$(doc_named HorizontalPodAutoscaler authorization-server "$apps_out")"
assert_has   "authorization-server HPA maxReplicas 3"      'maxReplicas: 3' "$auth_hpa"
assert_has   "authorization-server HPA scales up 2 pods"   'value: 2' "$auth_hpa"
gw_hpa="$(doc_named HorizontalPodAutoscaler gateway "$apps_out")"
assert_has   "gateway HPA maxReplicas 2"                   'maxReplicas: 2' "$gw_hpa"
assert_has   "gateway HPA targets 60% CPU"                 'averageUtilization: 60' "$gw_hpa"
assert_has   "gateway HPA scaleDown window is 300s"        'stabilizationWindowSeconds: 300' "$gw_hpa"
```

- [ ] **Step 2: Run the suite to verify the new assertions fail**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: the Task 2 section fails (no Service or HPA documents exist yet). Everything above it still passes.

- [ ] **Step 3: Create `services.yaml`**

```gotemplate
{{- range $name, $svc := .Values.apps }}
{{/*
  Raw $svc, no merge. Every key a Service reads — port, servicePort, extraPorts,
  managementPort, serviceAnnotations — is per-service by nature and absent from
  `defaults`, so a merge would copy five keys that can never differ from their
  source. If you ever add one of these to `defaults`, add the merge preamble from
  deployments.yaml here at the same time, or the Service's targetPort and the
  container's containerPort will silently disagree.
*/}}
{{- if $svc.enabled }}
{{- $s := $svc }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  namespace: {{ $.Values.global.namespaces.apps }}
  labels:
    {{- include "apps.labels" (dict "name" $name "root" $) | nindent 4 }}
  {{- with $s.serviceAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: ClusterIP
  selector:
    {{- include "apps.selectorLabels" (dict "name" $name "root" $) | nindent 4 }}
  ports:
    # Named `http` on every service, including the frontend's 80 → 8080. Both
    # ingress blocks bind backends by port NAME, so renaming this breaks routing.
    - name: http
      port: {{ $s.servicePort | default $s.port }}
      targetPort: http
    {{- range $p := $s.extraPorts }}
    - name: {{ $p.name }}
      port: {{ $p.containerPort }}
      targetPort: {{ $p.name }}
    {{- end }}
    {{- if $s.managementPort }}
    - name: management
      port: {{ $s.managementPort }}
      targetPort: management
    {{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 4: Create `hpas.yaml`**

Reads the **raw** `$svc.hpa`, not a merged value: `hpa` is absent from `defaults`, so there is nothing to merge and the preamble would only add noise.

```gotemplate
{{- range $name, $svc := .Values.apps }}
{{- if and $svc.enabled $svc.hpa }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ $name }}
  namespace: {{ $.Values.global.namespaces.apps }}
  labels:
    {{- include "apps.labels" (dict "name" $name "root" $) | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ $name }}
  minReplicas: {{ $svc.hpa.minReplicas | default 1 }}
  # maxReplicas is 2 for most services, not 3: minikube has ~3 GiB of headroom
  # after baseline replicas, and four services × one extra replica × 512Mi = 2 GiB.
  # Going higher OOMKills the node under a k6 ramp. authorization-server and
  # order-service get 3 because login (bcrypt) and checkout are the hot paths.
  maxReplicas: {{ $svc.hpa.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          # A percentage of requests.cpu, not of the node.
          averageUtilization: {{ $svc.hpa.targetCPUUtilization | default 60 }}
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Pods
          value: {{ $svc.hpa.scaleUpPods }}
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
{{- end }}
{{- end }}
```

- [ ] **Step 5: Run the suite to verify the Task 2 assertions pass**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: `0 failed`.

- [ ] **Step 6: RED-prove the HPA gating assertion**

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  --set apps.enabled=true --set apps.apps.gateway.hpa=null \
  --show-only charts/apps/templates/hpas.yaml | grep -c 'name: gateway'
```

Expected: `0` (and helm may report the file rendered empty if all five are removed — that is fine; the point is gateway's HPA disappears when its `hpa` key does).

- [ ] **Step 7: Commit**

```bash
git add deploy/charts/microecom/charts/apps/templates/services.yaml \
        deploy/charts/microecom/charts/apps/templates/hpas.yaml \
        deploy/charts/microecom/tests/render-test.sh
git commit -m "feat(helm): apps Services and HPAs"
```

---

## Task 3: Gateway RBAC

**Files:**
- Create: `deploy/charts/microecom/charts/apps/templates/gateway-rbac.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh`

**Interfaces:**
- Consumes: `apps.labels`; `apps.gateway.rbac` and `apps.gateway.serviceAccountName` from Task 1's values.
- Produces: a ServiceAccount named `gateway` in the `apps` namespace, referenced by the gateway Deployment's `serviceAccountName` (already rendered in Task 1).

- [ ] **Step 1: Write the failing assertions**

Append to `render-test.sh` before the summary lines:

```bash
# ── Phase 3 / Task 3: gateway RBAC ──────────────────────────────────────────
section "apps subchart — gateway RBAC"

apps_sas="$(docs_of_kind ServiceAccount <<<"$apps_out")"
assert_has   "gateway ServiceAccount exists"               '^  name: gateway$' "$apps_sas"
assert_lacks "no ServiceAccount for order-service"         '^  name: order-service$' "$apps_sas"

gw_role="$(doc_named Role gateway-discovery "$apps_out")"
# Match the whole flow list, not the bare resource names. A bare 'endpoints'
# ALSO matches inside 'endpointslices', so dropping `endpoints` from the core
# rule would leave that assertion green while gateway discovery breaks. `pods`
# get is required even in SERVICE discovery mode: Spring Cloud Kubernetes reads
# its OWN pod at startup. Dropping it looks harmless and breaks boot.
assert_has   "gateway Role grants services+endpoints+pods" \
             'resources: \[services, endpoints, pods\]' "$gw_role"
assert_has   "gateway Role covers endpointslices"          'resources: \[endpointslices\]' "$gw_role"
gw_rb="$(doc_named RoleBinding gateway-discovery "$apps_out")"
# Anchored to the 4-space subjects indent. An unanchored 'name: gateway' also
# matches this doc's own `  name: gateway-discovery` (metadata AND roleRef, both
# 2-space), so it stays green even with the ServiceAccount subject wrong or
# missing — which is the one thing this assertion exists to prove.
assert_has   "RoleBinding targets the gateway SA"          '^    name: gateway$' "$gw_rb"

no_rbac="$(apps_render --set apps.apps.gateway.rbac=null)"
assert_lacks "gateway.rbac unset removes the Role" \
             'gateway-discovery' "$(docs_of_kind Role <<<"$no_rbac")"
```

- [ ] **Step 2: Run the suite to verify they fail**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: the Task 3 section fails — no ServiceAccount, Role or RoleBinding exists.

- [ ] **Step 3: Create `gateway-rbac.yaml`**

Transcribed from `k8s/apps/base/gateway/rbac.yaml`.

```gotemplate
{{- $gw := .Values.apps.gateway }}
{{- if and $gw.enabled $gw.rbac }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $gw.serviceAccountName }}
  namespace: {{ .Values.global.namespaces.apps }}
  labels:
    {{- include "apps.labels" (dict "name" "gateway" "root" $) | nindent 4 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gateway-discovery
  namespace: {{ .Values.global.namespaces.apps }}
  labels:
    {{- include "apps.labels" (dict "name" "gateway" "root" $) | nindent 4 }}
rules:
  - apiGroups: [""]
    # `pods` get is required even in SERVICE discovery mode — Spring Cloud
    # Kubernetes reads its own pod at startup. Removing it looks harmless and
    # breaks the gateway's boot.
    resources: [services, endpoints, pods]
    verbs: [get, list, watch]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gateway-discovery
  namespace: {{ .Values.global.namespaces.apps }}
  labels:
    {{- include "apps.labels" (dict "name" "gateway" "root" $) | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: gateway-discovery
subjects:
  - kind: ServiceAccount
    name: {{ $gw.serviceAccountName }}
    namespace: {{ .Values.global.namespaces.apps }}
{{- end }}
```

- [ ] **Step 4: Run the suite**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add deploy/charts/microecom/charts/apps/templates/gateway-rbac.yaml \
        deploy/charts/microecom/tests/render-test.sh
git commit -m "feat(helm): gateway discovery RBAC in the apps subchart"
```

---

## Task 4: Ingress — nginx and ALB

**Files:**
- Create: `deploy/charts/microecom/charts/apps/templates/ingress.yaml`
- Modify: `deploy/charts/microecom/envs/aws.yaml` (add `global.ingress.hosts.storefront`)
- Test: `deploy/charts/microecom/tests/render-test.sh`

**Interfaces:**
- Consumes: `apps.labels`; `$svc.ingress.host`, `$svc.ingress.annotations` from Task 1's values; `global.ingress.className`; `global.ingress.hosts.storefront`.
- Produces: on `nginx`, two Ingresses (`gateway`, `frontend`); on `alb`, one Ingress (`gateway-alb`).

- [ ] **Step 1: Write the failing assertions**

Append to `render-test.sh` before the summary lines:

```bash
# ── Phase 3 / Task 4: Ingress ───────────────────────────────────────────────
section "apps subchart — Ingress (nginx | alb)"

apps_ings="$(docs_of_kind Ingress <<<"$apps_out")"
assert_has   "nginx: gateway Ingress exists"               '^  name: gateway$' "$apps_ings"
assert_has   "nginx: frontend Ingress exists"              '^  name: frontend$' "$apps_ings"
assert_lacks "nginx: no ALB Ingress"                       'gateway-alb' "$apps_ings"
gw_ing="$(doc_named Ingress gateway "$apps_out")"
assert_has   "nginx: gateway host"                         'host: api\.microecom\.local' "$gw_ing"
# 120s, not nginx's default 60s: k6 bursts push gateway p99 past 60s and the
# proxy would return 504 before the service answered.
assert_has   "nginx: gateway keeps the 120s proxy-read-timeout" \
             'proxy-read-timeout: "120"' "$gw_ing"
assert_has   "nginx: gateway keeps the 120s proxy-send-timeout" \
             'proxy-send-timeout: "120"' "$gw_ing"
fe_ing="$(doc_named Ingress frontend "$apps_out")"
assert_has   "nginx: frontend host"                        'host: microecom\.local' "$fe_ing"
assert_lacks "nginx: frontend carries no proxy timeouts"   'proxy-read-timeout' "$fe_ing"

# ALB. `global.appImage.registry` is empty in envs/aws.yaml (the deploy script
# stamps it), so pass one here — otherwise every image renders as `/name:`.
ALB_ARGS=(-f "$CHART_DIR/envs/aws.yaml"
          --set global.appImage.registry=583178372344.dkr.ecr.ap-southeast-1.amazonaws.com
          --set global.appImage.tag=testsha
          --set apps.irsa.s3RoleArn=arn:aws:iam::583178372344:role/microecom-s3)
aws_out="$(apps_render "${ALB_ARGS[@]}")"
assert_ok    "aws values render"                           "$aws_out"
aws_ings="$(docs_of_kind Ingress <<<"$aws_out")"
assert_has   "alb: the ALB Ingress exists"                 '^  name: gateway-alb$' "$aws_ings"
assert_lacks "alb: no nginx gateway Ingress"               '^  name: gateway$' "$aws_ings"
assert_lacks "alb: no nginx frontend Ingress"              '^  name: frontend$' "$aws_ings"
alb="$(doc_named Ingress gateway-alb "$aws_out")"
assert_has   "alb: internet-facing"                        'scheme: internet-facing' "$alb"
assert_has   "alb: target-type ip"                         'target-type: ip' "$alb"
# Assert the VALUE, not just the annotation key — a bare 'listen-ports' passes
# on any listener config at all, including one that dropped 443.
assert_has   "alb: listens on 80 and 443" \
             'listen-ports: .\[\{"HTTP": 80\}, \{"HTTPS": 443\}\]' "$alb"
assert_has   "alb: host is the storefront domain"          'host: shop\.microecom\.click' "$alb"
# The 8 service prefixes are DERIVED from the service list (range, skipping
# gateway and frontend), so adding a service can no longer leave it invisible on
# AWS — the failure mode that motivated this phase.
paths="$(grep -c '^          - path: /' <<<"$alb")"
if [ "$paths" = "9" ]; then
  ok  "alb: 8 service prefixes + the / catch-all"
else
  bad "alb: expected 9 paths (8 services + catch-all), got $paths"
fi
assert_has   "alb: order-service prefix is derived"        '- path: /order-service$' "$alb"
assert_lacks "alb: gateway is not its own prefix"          '- path: /gateway$' "$alb"
assert_lacks "alb: frontend is not a prefix"               '- path: /frontend$' "$alb"

# alb_backend <alb-doc> <path> — the backend Service name serving ONE ALB path.
# Which path routes where is the whole point of this Ingress, and an unscoped
# `name: frontend` proves only that frontend is a backend SOMEWHERE in the doc:
# swap the / and /order-service backends and it stays green while the storefront
# serves API traffic. Read the first `name:` under the matching path instead.
alb_backend() {
  awk -v p="          - path: $2" '
    $0 == p             { f = 1; next }
    f && /^ +name: /    { print $2; exit }
  ' <<<"$1"
}
assert_backend() {
  local actual; actual="$(alb_backend "$3" "$2")"
  if [ "$actual" = "$1" ]; then ok "alb: $2 routes to $1"
  else bad "alb: $2 routes to '${actual:-<none>}', expected '$1'"; fi
}
assert_backend frontend /              "$alb"
assert_backend gateway  /order-service "$alb"
```

- [ ] **Step 2: Run the suite to verify they fail**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: the Task 4 section fails — no Ingress documents exist yet.

- [ ] **Step 3: Add the storefront host to `envs/aws.yaml`**

In `deploy/charts/microecom/envs/aws.yaml`, extend the existing `global:` block. The `ingress:` key already exists there with `className: alb` — add `hosts:` under it:

```yaml
global:
  appImage:
    registry: ""            # filled from terraform output (ECR registry) by the deploy script
    tag: ""                 # filled from the build's git sha
    pullPolicy: IfNotPresent
  secret:
    backend: externalSecrets
  ingress:
    className: alb
    hosts:
      # ONE host feeds two things: the AWS LB Controller auto-discovers the ACM
      # cert matching it for the :443 listener, and external-dns reads it to
      # create the Route 53 A-alias. Consequence: the raw *.elb.amazonaws.com
      # hostname 404s, because every rule requires this Host header.
      storefront: shop.microecom.click
```

- [ ] **Step 4: Create `ingress.yaml`**

Two whole blocks, not a shared loop — the nginx and ALB shapes differ in object count, host count and routing, so unifying them would be false economy.

```gotemplate
{{- $ns := .Values.global.namespaces.apps }}
{{- if eq .Values.global.ingress.className "nginx" }}
{{/* Local: one Ingress per service that declares a host. */}}
{{- range $name, $svc := .Values.apps }}
{{- if and $svc.enabled $svc.ingress }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
    {{- include "apps.labels" (dict "name" $name "root" $) | nindent 4 }}
  {{- with $svc.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: nginx
  rules:
    - host: {{ $svc.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $name }}
                port:
                  name: http
{{- end }}
{{- end }}

{{- else if eq .Values.global.ingress.className "alb" }}
{{/*
  AWS: ONE Ingress. Listener-rule precedence is by path specificity — the AWS
  Load Balancer Controller expands a Prefix path "/foo" into ALB conditions
  "/foo" + "/foo/*", and "/" into "/*" (the catch-all, lowest priority). So the
  service prefixes out-rank "/" regardless of the order they appear here: only
  genuine /<service>/** traffic reaches the gateway, everything else boots the SPA.

  Health checks are deliberately NOT set here. With two backends an
  Ingress-level check would apply to BOTH target groups, and the gateway's
  19093/actuator probe would fail the static SPA. Each Service carries its own
  alb.ingress.kubernetes.io/healthcheck-* annotations instead (envs/aws.yaml).
*/}}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gateway-alb
  namespace: {{ $ns }}
  labels:
    {{- include "apps.labels" (dict "name" "gateway" "root" $) | nindent 4 }}
  annotations:
    # Public ALB, in the public subnets tagged kubernetes.io/role/elb.
    alb.ingress.kubernetes.io/scheme: internet-facing
    # ip mode registers pod IPs directly as targets; instance mode would need a
    # NodePort Service.
    alb.ingress.kubernetes.io/target-type: ip
    # Opens BOTH :80 and :443; ssl-redirect 301-bounces :80 to :443. No
    # certificate-arn — the controller auto-discovers the ACM cert whose domain
    # matches the host rule below.
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  ingressClassName: alb
  rules:
    - host: {{ .Values.global.ingress.hosts.storefront }}
      http:
        paths:
          {{- range $name, $svc := .Values.apps }}
          {{- if and $svc.enabled (not (has $name (list "gateway" "frontend"))) }}
          {{/*
            DERIVED, not listed. Each service sets
            `server.servlet.context-path: /<service-name>` and the gateway routes
            `Path=/<service-name>/**` with no StripPrefix, so the prefix follows
            from the service name by an ENFORCED convention. Adding a service can
            no longer leave it working locally and invisible on AWS.
          */}}
          - path: /{{ $name }}
            pathType: Prefix
            backend:
              service:
                name: gateway
                port:
                  name: http
          {{- end }}
          {{- end }}
          # Catch-all: the SPA. Caddy serves index.html for any unmatched path
          # (try_files {path} /index.html), then Vue Router takes over for deep
          # links like /checkout, /products/123, /payment/success.
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  name: http
{{- end }}
```

- [ ] **Step 5: Run the suite**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: `0 failed`. If the ALB path count assertion reports a number other than 9, check the indentation of the `- path:` lines — the assertion greps for exactly ten leading spaces.

- [ ] **Step 6: RED-prove the derived-paths assertion**

Disabling one service must remove exactly one ALB path.

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  -f deploy/charts/microecom/envs/aws.yaml \
  --set apps.enabled=true \
  --set apps.apps.bff-service.enabled=false \
  --set apps.irsa.s3RoleArn=arn:aws:iam::583178372344:role/microecom-s3 \
  --show-only charts/apps/templates/ingress.yaml | grep -c '^          - path: /'
```

Expected: `8` (one fewer than the 9 the suite asserts). Confirms the paths track the service list rather than being a hardcoded block that happens to have the right length.

- [ ] **Step 7: Commit**

```bash
git add deploy/charts/microecom/charts/apps/templates/ingress.yaml \
        deploy/charts/microecom/envs/aws.yaml \
        deploy/charts/microecom/tests/render-test.sh
git commit -m "feat(helm): nginx and ALB ingress with derived service prefixes"
```

---

## Task 5: ExternalSecrets, app-config volumes and IRSA

**Files:**
- Create: `deploy/charts/microecom/charts/apps/templates/externalsecrets.yaml`
- Create: `deploy/charts/microecom/charts/apps/templates/irsa-serviceaccounts.yaml`
- Modify: `deploy/charts/microecom/envs/aws.yaml`
- Test: `deploy/charts/microecom/tests/render-test.sh`

**Interfaces:**
- Consumes: `apps.labels`; `global.secret.backend`; `$svc.static`, `$svc.s3`, `$svc.irsa`; `.Values.irsa.s3RoleArn`.
- Produces: Secrets named `<service>-config` (created at runtime by ESO), which Task 1's Deployment template already mounts as the `app-config` volume.

**Note on `irsa`:** Task 1's Deployment template already derives `serviceAccountName` from `irsa: true` when no explicit name is set. `envs/aws.yaml` therefore sets only `irsa: true` — setting the ServiceAccount name separately would be a second place to forget.

- [ ] **Step 1: Write the failing assertions**

Append to `render-test.sh` before the summary lines. `ALB_ARGS` and `aws_out` were defined in Task 4's section — reuse them.

```bash
# ── Phase 3 / Task 5: ExternalSecrets, app-config, IRSA ─────────────────────
section "apps subchart — secret backend"

# backend=vault (default) — none of this renders. Scoped to the apps documents:
# $apps_out also carries infra, and an unscoped match there would be noise.
assert_lacks "vault: no ExternalSecrets"        'kind: ExternalSecret' "$apps_out"
assert_lacks "vault: no app-config volume"      'app-config' "$apps_deploys"
assert_lacks "vault: no IRSA annotation"        'eks\.amazonaws\.com/role-arn' "$apps_deploys"
assert_has   "vault: services still get VAULT_TOKEN" 'VAULT_TOKEN' "$(doc_named Deployment order-service "$apps_out")"

# backend=externalSecrets.
aws_es="$(docs_of_kind ExternalSecret <<<"$aws_out")"
for s in authorization-server bff-service gateway inventory-service \
         mock-paypal-service orchestrator-service order-service payment-service \
         product-service; do
  assert_has "eso: ExternalSecret for $s" "^  name: ${s}\$" "$aws_es"
done
assert_lacks "eso: no ExternalSecret for the static frontend" '^  name: frontend$' "$aws_es"

ps_es="$(doc_named ExternalSecret product-service "$aws_out")"
assert_has   "eso: product-service pulls app/ecommerce"    'key: app/ecommerce' "$ps_es"
assert_has   "eso: product-service pulls app/core-s3"      'key: app/core-s3' "$ps_es"
assert_has   "eso: product-service pulls its own secret"   'key: app/product-service' "$ps_es"
assert_has   "eso: target Secret is <name>-config"         'name: product-service-config' "$ps_es"
os_es="$(doc_named ExternalSecret order-service "$aws_out")"
assert_lacks "eso: order-service does NOT pull core-s3"    'key: app/core-s3' "$os_es"

# The configtree mount and the Vault switch-off are pure data in envs/aws.yaml —
# applied once to `defaults`, not nine times via a JSON6902 component.
aws_os="$(doc_named Deployment order-service "$aws_out")"
assert_has   "eso: app-config volume is mounted"           'mountPath: /etc/app-config' "$aws_os"
assert_has   "eso: volume comes from <name>-config"        'secretName: order-service-config' "$aws_os"
assert_has   "eso: SPRING_CONFIG_IMPORT points at the configtree" \
             'optional:configtree:/etc/app-config/' "$aws_os"
assert_has   "eso: Spring Cloud Vault is switched off"     'SPRING_CLOUD_VAULT_ENABLED' "$aws_os"
# Helm deletes a key whose override value is null. If that ever stops holding,
# every pod would try to reach a Vault that does not exist on EKS.
assert_lacks "eso: VAULT_TOKEN is deleted, not just disabled" 'VAULT_TOKEN' "$aws_os"
assert_lacks "eso: SPRING_CLOUD_VAULT_URI is deleted"      'vault\.infra\.svc' "$aws_os"
aws_fe="$(doc_named Deployment frontend "$aws_out")"
assert_lacks "eso: the static frontend gets no app-config volume" \
             'app-config' "$aws_fe"

# IRSA. This file exists today at k8s/apps/overlays/aws/s3-irsa-serviceaccounts.yaml
# referenced by NO kustomization, applied imperatively by a script with a
# sed-stamped placeholder. As a chart object the "present but not wired in" state
# stops being representable.
aws_sas="$(docs_of_kind ServiceAccount <<<"$aws_out")"
assert_has   "irsa: product-service ServiceAccount"        '^  name: product-service$' "$aws_sas"
assert_has   "irsa: authorization-server ServiceAccount"   '^  name: authorization-server$' "$aws_sas"
assert_lacks "irsa: no ServiceAccount for order-service"   '^  name: order-service$' "$aws_sas"
# Scoped to ONE ServiceAccount. Against the whole ServiceAccount stream this
# proves only that SOME SA carries the ARN — three services set irsa: true, and
# the annotation going missing on two of them would stay green.
assert_has   "irsa: the role ARN is stamped, not a placeholder" \
             'role-arn: arn:aws:iam::583178372344:role/microecom-s3' \
             "$(doc_named ServiceAccount product-service "$aws_out")"
assert_has   "irsa: authorization-server carries the ARN too" \
             'role-arn: arn:aws:iam::583178372344:role/microecom-s3' \
             "$(doc_named ServiceAccount authorization-server "$aws_out")"
assert_lacks "irsa: no PLACEHOLDER survives"               'PLACEHOLDER' "$aws_sas"
assert_has   "irsa: product-service Deployment uses its SA" \
             'serviceAccountName: product-service' "$(doc_named Deployment product-service "$aws_out")"

# ALB per-target-group health checks live on the Services, not the Ingress.
aws_gw_svc="$(doc_named Service gateway "$aws_out")"
assert_has   "alb: gateway healthcheck targets the management port" \
             'healthcheck-port: "19093"' "$aws_gw_svc"
assert_has   "alb: gateway healthcheck path is readiness" \
             'healthcheck-path: /actuator/health/readiness' "$aws_gw_svc"
aws_fe_svc="$(doc_named Service frontend "$aws_out")"
assert_has   "alb: frontend healthcheck is / on the traffic port" \
             'healthcheck-port: traffic-port' "$aws_fe_svc"
```

- [ ] **Step 2: Run the suite to verify they fail**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: the Task 5 section fails on everything ESO-related. The `backend=vault` assertions at the top should already pass.

- [ ] **Step 3: Create `externalsecrets.yaml`**

```gotemplate
{{- if eq .Values.global.secret.backend "externalSecrets" }}
{{- range $name, $svc := .Values.apps }}
{{/* The static SPA has no runtime secrets — the API base is baked into the JS
     bundle at image-build time as an empty string, so calls are relative. */}}
{{- if and $svc.enabled (not $svc.static) }}
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ $name }}
  namespace: {{ $.Values.global.namespaces.apps }}
  labels:
    {{- include "apps.labels" (dict "name" $name "root" $) | nindent 4 }}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: {{ $name }}-config
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: app/ecommerce
    {{- if $svc.s3 }}
    - extract:
        key: app/core-s3
    {{- end }}
    - extract:
        key: app/{{ $name }}
{{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 4: Create `irsa-serviceaccounts.yaml`**

```gotemplate
{{- if eq .Values.global.secret.backend "externalSecrets" }}
{{- range $name, $svc := .Values.apps }}
{{- if and $svc.enabled $svc.irsa }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $name }}
  namespace: {{ $.Values.global.namespaces.apps }}
  labels:
    {{- include "apps.labels" (dict "name" $name "root" $) | nindent 4 }}
  annotations:
    {{/*
      `required` on purpose. The Kustomize original carried a literal
      PLACEHOLDER_S3_ROLE_ARN that a shell script sed-stamped at apply time; a
      missed stamp produced a ServiceAccount that looked fine and failed at
      runtime with an opaque S3 403. This turns that into a deploy-time error.
      The deploy script passes --set apps.irsa.s3RoleArn="$(terraform output
      -raw s3_irsa_role_arn)".
    */}}
    eks.amazonaws.com/role-arn: {{ required "apps.irsa.s3RoleArn must be set when secret.backend=externalSecrets and a service sets irsa: true" $.Values.irsa.s3RoleArn }}
{{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 5: Add the ESO data to `envs/aws.yaml`**

Append a top-level `apps:` block to `deploy/charts/microecom/envs/aws.yaml` (after the existing `infra:` block):

```yaml
apps:
  # Three of the AWS overlay's four jobs need NO template branch — they are pure
  # data, applied ONCE to defaults rather than nine times via a JSON6902 component.
  defaults:
    env:
      # An explicit null in an override values file makes Helm DELETE the key.
      # Not merely disabling Vault: on EKS there is no Vault to reach.
      VAULT_TOKEN: null
      SPRING_CLOUD_VAULT_URI: null
      SPRING_CLOUD_VAULT_ENABLED: "false"
      SPRING_CONFIG_IMPORT: optional:configtree:/etc/app-config/

  # Stamped by the deploy script:
  #   --set apps.irsa.s3RoleArn="$(terraform output -raw s3_irsa_role_arn)"
  # Left empty here so a forgotten stamp fails the render instead of the pod.
  irsa:
    s3RoleArn: ""

  apps:
    # The two services that presign direct-to-S3 uploads. `irsa: true` alone is
    # enough — the Deployment template derives serviceAccountName from it, so
    # there is no second place to forget.
    authorization-server:
      irsa: true
    product-service:
      irsa: true

    # Per-target-group ALB health checks. The AWS Load Balancer Controller reads
    # these from the BACKING SERVICE and applies them to that Service's target
    # group only — an Ingress-level check would apply the gateway's actuator
    # probe to the static SPA too, and fail it.
    gateway:
      serviceAnnotations:
        alb.ingress.kubernetes.io/healthcheck-port: "19093"
        alb.ingress.kubernetes.io/healthcheck-path: /actuator/health/readiness
    frontend:
      serviceAnnotations:
        # Caddy answers 200 on "/" the moment it starts.
        alb.ingress.kubernetes.io/healthcheck-port: traffic-port
        alb.ingress.kubernetes.io/healthcheck-path: /
```

- [ ] **Step 6: Run the suite**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: `0 failed`.

**If `assert_lacks "eso: VAULT_TOKEN is deleted, not just disabled"` fails:** Helm's null-deletion did not reach the subchart's nested `defaults.env`. Fallback — set the two keys to `null` per service is not viable (nine repetitions); instead change `_helpers.tpl`'s env loop guard from `{{- if $v }}` to `{{- if and $v (ne $v "__unset__") }}` and use the string `"__unset__"` in `envs/aws.yaml` instead of `null`. Only take this fallback if the assertion actually fails — `null` is the cleaner form and is expected to work.

- [ ] **Step 7: RED-prove the `required` guard**

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  -f deploy/charts/microecom/envs/aws.yaml --set apps.enabled=true 2>&1 | head -3
```

Expected: `Error: execution error at (microecom/charts/apps/templates/irsa-serviceaccounts.yaml:…): apps.irsa.s3RoleArn must be set …` — the missing ARN is a render-time failure, not a runtime 403.

- [ ] **Step 8: Commit**

```bash
git add deploy/charts/microecom/charts/apps/templates/externalsecrets.yaml \
        deploy/charts/microecom/charts/apps/templates/irsa-serviceaccounts.yaml \
        deploy/charts/microecom/envs/aws.yaml \
        deploy/charts/microecom/tests/render-test.sh
git commit -m "feat(helm): ExternalSecrets, app-config mounts and S3 IRSA on AWS"
```

---

## Task 6: Local env data, the Makefile target, and docs

**Files:**
- Modify: `deploy/charts/microecom/envs/local-k8s.yaml`
- Modify: `Makefile`
- Modify: `deploy/README.md`
- Test: `deploy/charts/microecom/tests/render-test.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: `make k8s-apps-helm`, used by Task 7's live checks.

- [ ] **Step 1: Write the failing assertions**

Append to `render-test.sh` before the summary lines:

```bash
# ── Phase 3 / Task 6: local env data ────────────────────────────────────────
section "apps subchart — local env"

local_out="$(apps_render -f "$CHART_DIR/envs/local-k8s.yaml")"
assert_ok    "local-k8s values render"                     "$local_out"
pay="$(doc_named Deployment payment-service "$local_out")"
# The local Kustomize overlay injects these two into payment-service so checkout
# talks to mock-paypal instead of real PayPal. Missing them, local checkout
# silently calls api-m.paypal.com and fails.
assert_has   "local: payment-service points at mock-paypal" \
             'mock-paypal-service\.apps\.svc\.cluster\.local:8585' "$pay"
assert_has   "local: payment-service has PAYPAL_TUNNEL_URL" \
             'PAYPAL_TUNNEL_URL' "$pay"
# Not on AWS, where real PayPal is used.
assert_lacks "aws: payment-service does NOT point at mock-paypal" \
             'mock-paypal-service\.apps\.svc\.cluster\.local:8585' \
             "$(doc_named Deployment payment-service "$aws_out")"
```

- [ ] **Step 2: Run the suite to verify they fail**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: the two `local:` assertions fail; the `aws:` one already passes.

- [ ] **Step 3: Add the payment-service local env to `envs/local-k8s.yaml`**

Transcribed from `k8s/apps/overlays/local/kustomization.yaml`, which patches these two vars onto payment-service. They exist only in the local overlay — the design spec's survey missed them.

```yaml
global:
  appImage:
    registry: localhost:5000
    tag: dev

apps:
  apps:
    payment-service:
      env:
        # Local checkout goes through mock-paypal-service, not api-m.paypal.com.
        # Without these, checkout silently calls the real PayPal sandbox and fails.
        SPRING_APPLICATION_JSON: '{"application":{"paypal":{"base-url":"http://mock-paypal-service.apps.svc.cluster.local:8585/mock-paypal-service"}}}'
        PAYPAL_TUNNEL_URL: "http://api.microecom.local"
```

- [ ] **Step 4: Run the suite**

```bash
bash deploy/charts/microecom/tests/render-test.sh
```

Expected: `0 failed`. Record the final assertion count — it goes in the PR body.

- [ ] **Step 5: Add the Makefile target**

Insert into `Makefile` immediately after the existing `k8s-apps-down` target (around line 398):

```make
# Helm path for the apps, alongside `make k8s-apps` (kubectl/kustomize).
# Both bring-up paths stay in the tree this phase; rolling back is reverting this
# target. They are NOT composable on one cluster — the Helm chart selects on
# app.kubernetes.io/name while the base manifests use a bare `app:` key, and
# spec.selector is immutable on a Deployment. Pick one path per cluster.
#
# --timeout stays 30m and remains governed by the Plan 2 drift guard in
# tests/render-test.sh, which asserts it stays >= activeDeadlineSeconds + 330s.
#
# ENV=aws additionally REQUIRES the S3 IRSA role ARN, or the render fails by
# design (see charts/apps/templates/irsa-serviceaccounts.yaml):
#   make k8s-apps-helm ENV=aws \
#     HELM_EXTRA='--set apps.irsa.s3RoleArn=$$(terraform output -raw s3_irsa_role_arn)'
# Phase 7 moves that into the AWS deploy script; this phase only ever runs local.
k8s-apps-helm:
	@helm upgrade --install microecom deploy/charts/microecom \
	  --namespace infra --create-namespace \
	  -f deploy/charts/microecom/envs/$(or $(ENV),local-k8s).yaml \
	  --set apps.enabled=true $(HELM_EXTRA) \
	  --wait --timeout 30m
	@kubectl -n apps rollout status deployment --timeout=10m
```

- [ ] **Step 6: Verify the target resolves without running it**

```bash
make -n k8s-apps-helm
```

Expected: the `helm upgrade --install` line with `envs/local-k8s.yaml` substituted, then the `kubectl rollout status` line. No errors.

- [ ] **Step 7: Update `deploy/README.md`**

Append after the "The two infra bring-up paths are alternatives, not composable, on one cluster" section:

```markdown
## Helm apps subchart (Phase 3 path)

`deploy/charts/microecom/charts/apps` renders the ten application workloads
previously brought up by `kubectl apply -k k8s/apps/overlays/local`: nine JVM
services plus the storefront SPA, with their Services, five HPAs, the gateway's
discovery RBAC, the nginx Ingresses, and — on AWS — the ExternalSecrets,
`app-config` configtree mounts and S3 IRSA ServiceAccounts.

```bash
make k8s-apps        # kubectl/kustomize path (still the default)
make k8s-apps-helm   # Helm path (ENV=aws selects envs/aws.yaml)
```

The subchart is gated `apps.enabled: false` in the umbrella `values.yaml`, so
`make k8s-infra-helm` renders exactly what it rendered in Phase 2.
`k8s-apps-helm` passes `--set apps.enabled=true`.

### The apps paths are alternatives too — same rule, different reason

The infra rule above is about Helm ownership metadata. For apps the reason is
sharper: the base manifests use a bare `app: <name>` as their
`spec.selector.matchLabels`, the chart uses `app.kubernetes.io/name`, and
**`spec.selector` is immutable on a Deployment**. Neither path can be installed
over the other. Tear the cluster down before switching.

### One shared template, variation in values

Per-service blocks under `apps:` are merged over a chart-level `defaults:` block.
Three rules are load-bearing, and breaking any of them fails quietly:

1. **`deepCopy` before every merge.** Sprig's `mergeOverwrite` wraps mergo's
   in-place API and mutates its destination. Without `deepCopy`, the first
   service's overrides contaminate `.Values.defaults` permanently, and because
   `range` over a map iterates in sorted key order, every service sorting after
   it inherits them — `gateway` sorts 4th of 10, so its `initialDelaySeconds: 45`
   leaks into the six after it. `render-test.sh` asserts order-service still gets
   60.
2. **`enabled` is read from the raw values block, before the merge.** Mergo
   treats falsy values as absent, so `enabled: false` cannot survive a merge
   against a default of `true`.
3. **`env` is merged outside mergo, key by key.** For the same reason: mergo
   skips nil source values, so a per-key `null` could not unset an inherited
   variable. `env` is a map rather than a list because YAML lists cannot merge
   element-wise; the list-of-`{name,value}` shape appears only at render time,
   emitted by a sorted `range`.

### `managementPort` is listed, never derived

Seven of the nine JVM services put Actuator on `port + 10000`. Two do not:
authorization-server is `6666 → 19091` and gateway is `6868 → 19093` (fossils of
an older shared-9091 scheme, later prefixed with `1`). Both probes target the
management port by name, so deriving it would render correctly for seven
services and point two at dead ports — permanent readiness failure with a
values file that looks clean.

General rule: derive a value only when the relationship is *enforced*, not
merely *observed*. The ALB service prefixes (§ below) are safe to derive because
the gateway's `Path=/<service-name>/**` routing convention enforces them.

### The ALB service prefixes are derived from the service list

The hand-written `k8s/apps/overlays/aws/ingress-gateway.yaml` lists eight
`/<service>` paths by hand. Adding a service and forgetting that list gave you a
service that worked locally and was invisible on AWS. The chart ranges the
service list, skips `gateway` and `frontend`, and emits the rest — the
divergence is no longer representable.
```

- [ ] **Step 8: Confirm `k8s/` is untouched**

```bash
git diff main HEAD -- 'k8s/**' | head
```

Expected: empty output. This is the rollback guarantee for the phase — if anything appears here, revert it before committing.

- [ ] **Step 9: Commit**

```bash
git add deploy/charts/microecom/envs/local-k8s.yaml Makefile deploy/README.md \
        deploy/charts/microecom/tests/render-test.sh
git commit -m "feat(helm): make k8s-apps-helm target, local env data, docs"
```

---

## Task 7: Live-cluster verification

**Files:** none created or modified unless a check fails. Fixes land in the files from Tasks 1–6.

**Interfaces:** Consumes `make k8s-apps-helm` from Task 6.

Render tests prove the YAML says the right thing. These prove it works. App images are locally built, so unlike Plan 2 there is no Docker Hub rate-limit exposure for the apps themselves — infra still pulls upstream images.

**Ordering scar to preserve:** `k8s-seed-mysql` runs **after** apps, because `docker/ecommerce.sql` is data-only and Hibernate `ddl-auto` creates the schema at service boot. Do not move it earlier.

- [ ] **Step 1: Bring up a clean cluster on the Helm path**

```bash
make k8s-nuke
make k8s-cluster-up
make k8s-platform
make k8s-infra-helm
make k8s-build-reuse
make k8s-apps-helm
```

Expected: `k8s-apps-helm` exits 0 and the rollout status line reports every Deployment rolled out.

If images fail to pull, confirm the registry: `curl -s localhost:5001/v2/_catalog`. Host pushes through `:5001`, pods pull through `:5000` — that split is correct, do not "fix" either side.

- [ ] **Step 2: Check 1 — all 10 pods Ready, 0 restarts**

```bash
kubectl -n apps get pods -o wide
kubectl -n apps get pods --no-headers | awk '{print $1, $2, $4}'
```

Expected: 10 pods (plus any HPA-added replicas), every one `1/1`, RESTARTS `0`.

- [ ] **Step 3: Check 2 — gateway RBAC actually functions**

Not "the Role object exists" — that is what the render test already proved. Prove discovery resolves:

```bash
kubectl -n apps logs deploy/gateway | grep -iE 'discovery|kubernetes' | head -20
kubectl -n apps exec deploy/gateway -- \
  curl -s localhost:19093/actuator/health/readiness
```

Expected: readiness `{"status":"UP"}` and no `Forbidden`/`cannot list resource` lines in the logs. A missing `pods` verb shows up here, not at render time.

- [ ] **Step 4: Check 3 — storefront browse through the ingress**

Needs `make k8s-tunnel` running in a separate terminal with a TTY-cached sudo credential. **This step requires the human** — an agent shell cannot satisfy the sudo prompt.

```bash
curl -s http://api.microecom.local/product-service/v1/products?page=1&size=30 | head -c 400
curl -s -o /dev/null -w '%{http_code}\n' http://microecom.local
```

Expected: the product JSON with the 30 seeded products (including MinIO image URLs), and `200` from the storefront.

Fallback without the tunnel, which proves the pods and Services but not the Ingress:

```bash
kubectl -n apps port-forward svc/gateway 6868:6868 &
curl -s 'http://localhost:6868/product-service/v1/products?page=1&size=30' | head -c 400
```

- [ ] **Step 5: Check 4 — inventory-service gRPC reachable on 9090**

```bash
kubectl -n apps exec deploy/order-service -- \
  sh -c 'timeout 3 sh -c "</dev/tcp/inventory-service.apps.svc.cluster.local/9090" && echo grpc-open'
```

Expected: `grpc-open`. This is what the `extraPorts` hatch exists for; a Service missing the grpc port fails here and nowhere else.

- [ ] **Step 6: Check 5 — idempotence**

```bash
make k8s-apps-helm
helm -n infra history microecom | tail -3
kubectl -n apps get pods --no-headers | awk '{print $4}' | sort -u
```

Expected: a new revision, status `deployed`, and restart counts still `0` — a re-install that churns objects would restart pods.

- [ ] **Step 7: Check 6 — AWS gating on a full render**

```bash
helm template microecom deploy/charts/microecom --namespace infra \
  -f deploy/charts/microecom/envs/aws.yaml --set apps.enabled=true \
  --set global.appImage.registry=583178372344.dkr.ecr.ap-southeast-1.amazonaws.com \
  --set global.appImage.tag=testsha \
  --set apps.irsa.s3RoleArn=arn:aws:iam::583178372344:role/microecom-s3 \
  > /private/tmp/aws-render.yaml
grep -c 'ingressClassName: nginx' /private/tmp/aws-render.yaml
grep -c 'VAULT_TOKEN' /private/tmp/aws-render.yaml
grep -c 'kind: ExternalSecret' /private/tmp/aws-render.yaml
```

Expected: `0`, `0`, `9`. Redirect to a file rather than piping into the shell tool — a full render is large enough to be truncated.

- [ ] **Step 8: Check 7 — kubectl-path rollback, on a cluster that never ran the Helm apps release**

A green run on a Helm-populated cluster proves nothing, because the objects already exist. This exact mistake was made and corrected in Plan 2.

```bash
make k8s-nuke
make k8s-cluster-up
make k8s-platform
make k8s-infra          # kubectl infra path, to match
make k8s-build-reuse
make k8s-apps           # the path this phase must not have broken
kubectl -n apps get pods --no-headers | awk '{print $2, $4}' | sort | uniq -c
```

Expected: every pod `1/1` with `0` restarts. Confirm again that `git diff main HEAD -- 'k8s/**'` is empty — that is why this check can pass at all.

- [ ] **Step 9: Record the results**

Write the seven checks and their outcomes into the PR body draft. If any check failed and was fixed, name the defect and the fix — those are the most valuable lines in the PR.

- [ ] **Step 10: Commit any fixes**

```bash
git add -A deploy/
git commit -m "fix(helm): <what the live check surfaced>"
```

If no check surfaced a defect, there is nothing to commit — say so rather than inventing a commit.

---

## Deferred, carried into this phase

- **The Grafana browser check from Plan 2** is still open: the dashboards were confirmed present as a ConfigMap with the right three keys, but rendering under the `Custom` folder needs `make k8s-tunnel` and a TTY-cached sudo credential. It belongs to the human, not to this plan.
