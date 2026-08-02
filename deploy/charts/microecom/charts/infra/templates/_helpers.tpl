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

{{/*
Block until a Kafka broker answers. Used by every workload that hard-exits when
Kafka is absent: kafka-exporter, schema-registry, kafka-connect.

  {{- include "microecom.waitForKafka" (dict "kafka" $kafka) | nindent 8 }}

Reuses apache/kafka:3.9.1 — already pulled on any node running Kafka, already
carries the CLI. No new image, no new pull.
*/}}
{{- define "microecom.waitForKafka" -}}
- name: wait-for-kafka
  image: apache/kafka:3.9.1
  command:
    - sh
    - -c
    - |
      until /opt/kafka/bin/kafka-broker-api-versions.sh \
            --bootstrap-server {{ .kafka }} >/dev/null 2>&1; do
        echo "waiting for kafka at {{ .kafka }}"
        sleep 3
      done
      echo "kafka is up"
  resources:
    requests: { cpu: 10m, memory: 64Mi }
    limits:   { cpu: 200m, memory: 256Mi }
{{- end -}}

{{/*
An initContainer that creates each named topic if missing and forces
cleanup.policy=compact on it. Takes `kafka` (bootstrap host:port) and `topics`
(space-separated list, consumed by the shell loop).

Kafka auto-creates internal topics with cleanup.policy=delete, and both Schema
Registry and Connect refuse to start on a non-compacted topic. install.sh fixed
all four topics from one loop before either service started; here each service
repairs exactly the topics it owns, from inside its own pod, so it also
self-heals after a Kafka rebuild.
*/}}
{{- define "microecom.ensureCompacted" -}}
- name: ensure-compacted
  image: apache/kafka:3.9.1
  env:
    - name: TOPICS
      value: "{{ .topics }}"
  command:
    - sh
    - -c
    - |
      set -e
      for t in $TOPICS; do
        /opt/kafka/bin/kafka-topics.sh --bootstrap-server {{ .kafka }} \
          --create --if-not-exists --topic "$t" \
          --partitions 1 --replication-factor 1
        /opt/kafka/bin/kafka-configs.sh --bootstrap-server {{ .kafka }} \
          --alter --entity-type topics --entity-name "$t" \
          --add-config cleanup.policy=compact
      done
  resources:
    requests: { cpu: 10m, memory: 64Mi }
    limits:   { cpu: 200m, memory: 256Mi }
{{- end -}}
