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
