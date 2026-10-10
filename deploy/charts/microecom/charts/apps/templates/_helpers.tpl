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
Is this service rendered? "true" or "" (a define cannot return a bool).

`onlyService` narrows the release to ONE service. The devbox (deploy/devbox/)
renders this subchart once per service, as one Argo CD Application each, so
every service gets its own sync status, history and rollback. Unset — the
umbrella `helm upgrade` path and AWS — it changes nothing.

`enabled` is read from the RAW values block, same as the merge preamble's
rule 1 in deployments.yaml.

  usage: {{- if include "apps.selected" (dict "name" $name "svc" $svc "root" $) }}
*/}}
{{- define "apps.selected" -}}
{{- if and .svc.enabled (or (not .root.Values.onlyService) (eq .root.Values.onlyService .name)) -}}
true
{{- end -}}
{{- end }}

{{/*
The container block: name, image, ports, env, envFrom, both probes, resources,
and the AWS app-config volume mount.

  usage: {{- include "apps.container" (dict "name" $name "svc" $s "root" $) | nindent 8 }}

`.svc` must be the MERGED service (see the four-line preamble each template
repeats), not the raw values block.
*/}}
{{/*
The image tag: the service's own `image.tag` wins over `global.appImage.tag`.
A per-service tag is what lets the devbox run order-service at one version and
inventory-service at another, and roll back one without the other.
*/}}
{{- define "apps.imageTag" -}}
{{- $own := "" -}}
{{- with .svc.image }}{{ $own = .tag }}{{ end -}}
{{- $own | default (required "global.appImage.tag must be set (the image tag) -- stamped by the deploy script (deploy/scripts/aws-deploy.sh, or --set-string global.appImage.tag=... by hand, or TAG=<tag>); see envs/aws.yaml" .root.Values.global.appImage.tag) -}}
{{- end }}

{{- define "apps.container" -}}
{{- $name := .name -}}
{{- $s := .svc -}}
{{- $root := .root -}}
- name: {{ $name }}
  image: {{ required "global.appImage.registry must be set (the ECR registry) -- stamped by the deploy script (deploy/scripts/aws-deploy.sh, or --set-string global.appImage.registry=... by hand) from `terraform output ecr_registry` (aws/bootstrap); see envs/aws.yaml" $root.Values.global.appImage.registry }}/{{ $name }}:{{ include "apps.imageTag" (dict "svc" $s "root" $root) }}
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
  {{- /*
    springConfig: Spring properties as a nested map, deep-merged from
    defaults.springConfig (env-wide) and the service's own block — because it
    goes through the preamble's mergeOverwrite like every other non-env key.
    Rendered as SPRING_APPLICATION_JSON, which outranks every config import
    (Vault included) and, unlike plain env vars, keeps map keys with dots AND
    dashes exact (`application.kafka.topics.order-service.order.failed-status`).
    orchestrator-service's EnvOverridePrecedenceTest pins that behaviour.
    One container has one SPRING_APPLICATION_JSON, so setting it in `env` as
    well is refused rather than letting one silently win.
  */ -}}
  {{- $env := deepCopy (default (dict) $s.env) }}
  {{- /* Not for static services: defaults.springConfig (env-wide Spring
       properties) would otherwise land in the Caddy container too. */}}
  {{- if and $s.springConfig (not $s.static) }}
  {{- if get $env "SPRING_APPLICATION_JSON" }}
  {{- fail (printf "%s: set either springConfig or env.SPRING_APPLICATION_JSON, not both" $name) }}
  {{- end }}
  {{- $_ := set $env "SPRING_APPLICATION_JSON" (toJson $s.springConfig) }}
  {{- end }}
  {{- if $env }}
  env:
    {{- range $k, $v := $env }}
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
  {{- /* Not for static services: the SPA's probes use the `http` port, and an
       inherited startup probe on `management` would name a port it doesn't
       have. Caddy starts in milliseconds anyway. */}}
  {{- if and $s.probes.startup (not $s.static) }}
  startupProbe:
    httpGet:
      path: {{ $s.probes.startup.path }}
      port: {{ $s.probes.startup.port }}
    periodSeconds: {{ $s.probes.startup.periodSeconds }}
    failureThreshold: {{ $s.probes.startup.failureThreshold }}
  {{- end }}
  resources:
    {{- toYaml $s.resources | nindent 4 }}
  {{- if and (eq $root.Values.global.secret.backend "externalSecrets") (not $s.static) }}
  volumeMounts:
    - name: app-config
      mountPath: /etc/app-config
      readOnly: true
  {{- end }}
{{- end }}
