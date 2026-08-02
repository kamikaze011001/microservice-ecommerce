{{/*
Fully-qualified in-cluster Service DNS name.

  {{ include "microecom.fqdn" (dict "name" "kafka" "namespace" $ns) }}
  → kafka.infra.svc.cluster.local

Every cross-service address goes through here so renaming a namespace is a
values change, not a search-and-replace across 14 files.
*/}}
{{- define "microecom.fqdn" -}}
{{- printf "%s.%s.svc.cluster.local" .name .namespace -}}
{{- end -}}
