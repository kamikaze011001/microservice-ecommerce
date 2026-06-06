#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Repos
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
# NOTE: no bitnami repo — the 5 stateful services migrated to Docker Official
# images as plain manifests (Bitnami images deleted 2025-09-29). See k8s/CLAUDE.md.
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add vm https://victoriametrics.github.io/helm-charts/ 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
# metrics-server: upstream kubernetes-sigs chart (NOT bitnami/metrics-server).
# Bitnami deleted docker.io/bitnami/* versioned images on 2025-09-29; the
# upstream chart is the maintained, free replacement.
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update

# Namespaces
for ns in infra apps monitoring bootstrap; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
done

# Ingress
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace infra \
  --version 4.10.0 \
  -f k8s/infra/values/ingress-nginx.yaml \
  --wait --timeout 5m

# Metrics-server (separate chart) — required for HPA.
# Upstream kubernetes-sigs chart. --kubelet-insecure-tls is required on kind
# (kubelet serving certs are self-signed); InternalIP avoids inter-node
# hostname resolution issues. Upstream uses an `args` list, NOT bitnami's
# `extraArgs`/`apiService.create` keys.
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace infra \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' \
  --wait --timeout 3m

# Observability: VictoriaMetrics single-node + Grafana + kube-state-metrics.
# See docs/superpowers/specs/2026-06-02-victoriametrics-observability-design.md
helm upgrade --install vmsingle vm/victoria-metrics-single \
  --namespace monitoring \
  --version 0.39.0 \
  -f k8s/infra/values/victoria-metrics.yaml \
  --wait --timeout 5m

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --version 10.5.15 \
  -f k8s/infra/values/grafana.yaml \
  --wait --timeout 5m

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace monitoring \
  --wait --timeout 3m

# ── Stateful services — Docker Official images as plain manifests ────────────
# Migrated off Bitnami (docker.io/bitnami/* deleted 2025-09-29). Each manifest
# keeps its Service DNS name unchanged so the Vault seed + app config + seed
# Jobs need no edits. See k8s/CLAUDE.md and the design spec.
MANIFESTS=k8s/infra/manifests

# MongoDB needs an internal keyFile (auth + replica set together). Create it
# only if missing — re-runs must NOT rotate it, since rotating the keyfile
# would break the already-initialized replica set.
if ! kubectl -n infra get secret mongodb-keyfile >/dev/null 2>&1; then
  echo "creating mongodb-keyfile secret"
  kubectl -n infra create secret generic mongodb-keyfile \
    --from-literal=keyfile="$(openssl rand -base64 756 | tr -d '\n')"
fi

kubectl apply \
  -f "$MANIFESTS/mysql.yaml" \
  -f "$MANIFESTS/mysql-replica-service.yaml" \
  -f "$MANIFESTS/mysql-replica.yaml" \
  -f "$MANIFESTS/mongodb.yaml" \
  -f "$MANIFESTS/redis.yaml" \
  -f "$MANIFESTS/minio.yaml" \
  -f "$MANIFESTS/minio-ingress.yaml" \
  -f "$MANIFESTS/kafka.yaml"

# Wait for each to be Ready. The mongodb `bootstrap` and minio `setup` sidecars
# gate pod-readiness on a completion sentinel, so a Ready pod guarantees the
# replica-set users / bucket already exist — the seed Jobs that run later won't
# race ahead and fail to authenticate or write.
kubectl -n infra rollout status statefulset/mysql         --timeout=5m
kubectl -n infra rollout status statefulset/mysql-replica --timeout=5m
kubectl -n infra rollout status statefulset/mongodb       --timeout=5m
kubectl -n infra rollout status deployment/redis    --timeout=3m
kubectl -n infra rollout status statefulset/minio   --timeout=5m
kubectl -n infra rollout status statefulset/kafka   --timeout=5m

# ── MySQL replication: 1 primary + 2 replicas (GTID auto-position) ────────────
# Mirrors docker/scripts/init-mysql.sh, idempotent. The repl user is created on
# the primary AFTER init (so it replicates); replicas use SOURCE_AUTO_POSITION=1
# to pull the full binlog from empty (no clone needed). This runs before the JVM
# services (k8s-apps) and the seed Jobs, so all table DDL + seed rows replicate.
REPL_USER=repl_user
REPL_PASS=replica_ecommerce
PRIMARY_HOST=mysql.infra.svc.cluster.local

echo "configuring replication user on primary (mysql-0)"
kubectl -n infra exec mysql-0 -- mysql -uroot -proot -e "
  CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${REPL_PASS}';
  GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
  FLUSH PRIVILEGES;"

for rep in mysql-replica-0 mysql-replica-1; do
  running=$(kubectl -n infra exec "$rep" -- mysql -uroot -proot -N -e \
    "SELECT COUNT(*) FROM performance_schema.replication_connection_status WHERE SERVICE_STATE='ON';" 2>/dev/null || echo 0)
  if [ "${running:-0}" -ge 1 ]; then
    echo "$rep already replicating; skipping"
    continue
  fi
  echo "starting replication on $rep"
  kubectl -n infra exec "$rep" -- mysql -uroot -proot -e "
    STOP REPLICA;
    CHANGE REPLICATION SOURCE TO
      SOURCE_HOST='${PRIMARY_HOST}',
      SOURCE_USER='${REPL_USER}',
      SOURCE_PASSWORD='${REPL_PASS}',
      SOURCE_AUTO_POSITION=1,
      GET_SOURCE_PUBLIC_KEY=1;
    START REPLICA;"
done

# Verify both replicas are actually replicating; fail the install if not (don't
# seed onto a broken topology).
sleep 5
for rep in mysql-replica-0 mysql-replica-1; do
  status=$(kubectl -n infra exec "$rep" -- mysql -uroot -proot -e "SHOW REPLICA STATUS\G")
  if echo "$status" | grep -q "Replica_IO_Running: Yes" && echo "$status" | grep -q "Replica_SQL_Running: Yes"; then
    echo "$rep replication OK"
  else
    echo "ERROR: $rep replication not running:"
    echo "$status" | grep -E "Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:"
    exit 1
  fi
done
echo "MySQL replication ready (1 primary + 2 replicas)"

helm upgrade --install vault hashicorp/vault \
  --namespace infra --version 0.27.0 \
  -f k8s/infra/values/vault.yaml --wait --timeout 5m

# Sensitive creds (PayPal, mail) come from k8s/.env (gitignored, not in
# any committed values.yaml or seed.sh). The vault-seed Job mounts this
# Secret via envFrom and references the keys from inside seed.sh.
# If k8s/.env is missing we still create an empty Secret so the Job's
# envFrom resolves — the put_if_missing blocks that reference these env
# vars will just write empty strings (acceptable for a smoke install
# without a working PayPal sandbox account).
if [ -f k8s/.env ]; then
  kubectl create secret generic vault-seed-env \
    --namespace bootstrap \
    --from-env-file=k8s/.env \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "warn: k8s/.env missing — creating empty vault-seed-env Secret. Copy k8s/.env.example to k8s/.env and re-run for working mail/PayPal."
  kubectl create secret generic vault-seed-env \
    --namespace bootstrap \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# Schema Registry — the JPA services use Confluent Avro (de)serializers and the
# Debezium Mongo connector publishes Avro, both of which require a reachable
# registry (services are Vault-pointed at schema-registry.infra.svc:8081).
# Depends on Kafka (KRaft) being Ready above — it stores subjects in a compacted
# _schemas topic. Must be up before the JVM services and the connector job.
kubectl apply -f "$MANIFESTS/schema-registry.yaml"
# 10m (not 5m): the confluentinc/cp-schema-registry image is ~1.8GB and on a
# cold cluster (e.g. after `make k8s-down` wipes each node's image cache) the
# pull alone can take ~5.5m, blowing past a 5m rollout wait even though the pod
# is healthy. Give the large Confluent image pull room.
kubectl -n infra rollout status deployment/schema-registry --timeout=10m

# Kafka Connect — long-running Deployment hosting source/sink connectors.
# Connector registration is a separate Job (k8s/infra/jobs/04-kafka-connect-register).
kubectl apply -f k8s/infra/manifests/kafka-connect.yaml
# 10m: same large-Confluent-image cold-pull reason as schema-registry above.
kubectl -n infra rollout status deployment/kafka-connect --timeout=10m

echo "infra install complete"
