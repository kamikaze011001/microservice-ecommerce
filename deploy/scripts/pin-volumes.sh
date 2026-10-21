#!/usr/bin/env bash
# Pin every minikube-hostpath volume to the node that holds its data.
#
#   CONTEXT=microecom deploy/scripts/pin-volumes.sh [--dry-run]   (make k8s-pin-volumes)
#   ONLY=infra/statefulset/minio …                              (one workload)
#
# minikube's `standard` class (k8s.io/minikube-hostpath) makes hostPath PVs
# with no nodeAffinity: the data sits on whichever node the pod first ran on,
# and a pod scheduled anywhere else silently starts on an empty or stale copy
# of the directory (data-mysql-0 existed on three nodes). cluster.sh now makes
# local-path (pinned) the default class, which fixes NEW volumes; this script
# moves the existing ones in place, keeping their data:
#
#   per workload: scale to 0 → for each of its volumes: PV reclaim → Retain,
#   delete the PVC, delete the PV (the directory stays), recreate the PV on
#   the same path with nodeAffinity = the node the pod was running on, and
#   recreate the PVC bound to it → scale back
#
# PV nodeAffinity is immutable, hence delete + recreate. Each workload restarts
# once. Already-pinned volumes are skipped, so a re-run is a no-op.
set -euo pipefail

: "${CONTEXT:?set CONTEXT (e.g. microecom)}"
case "$CONTEXT" in *eks*) echo "refusing an EKS context" >&2; exit 1 ;; esac
DRY=${1:-}
k() { kubectl --context "$CONTEXT" "$@"; }
run() { if [[ "$DRY" == --dry-run ]]; then echo "    would: $*"; else "$@"; fi; }
apply() { if [[ "$DRY" == --dry-run ]]; then echo "    would: apply $(jq -r '.kind+" "+.metadata.name')"; else k apply -f - >/dev/null; fi; }

# PVC → "<ns> <pvc> <pv> <node> <workload kind/name>" for every unpinned
# minikube-hostpath volume a running pod uses.
unpinned() {
  k get pods -A -o json | jq -r '
    .items[] | select(.status.phase=="Running") | . as $p
    | .spec.volumes[]? | select(.persistentVolumeClaim)
    | [$p.metadata.namespace, .persistentVolumeClaim.claimName, $p.spec.nodeName,
       ($p.metadata.ownerReferences[0].kind + "/" + $p.metadata.ownerReferences[0].name)] | @tsv' \
  | while IFS=$'\t' read -r ns pvc node owner; do
      pv="$(k -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"
      [[ "$(k get pv "$pv" -o jsonpath='{.metadata.annotations.pv\.kubernetes\.io/provisioned-by}')" == k8s.io/minikube-hostpath ]] || continue
      [[ -z "$(k get pv "$pv" -o jsonpath='{.spec.nodeAffinity}')" ]] || continue
      # a ReplicaSet's owner is the Deployment we scale
      if [[ "$owner" == ReplicaSet/* ]]; then
        owner="deployment/$(k -n "$ns" get rs "${owner#*/}" -o jsonpath='{.metadata.ownerReferences[0].name}')"
      fi
      data="$(data_node "$(k get pv "$pv" -o jsonpath='{.spec.hostPath.path}')" "$node")"
      [[ "$data" == "$node" ]] || echo "  ! $ns/$pvc: pod runs on $node but its data is on $data, pinning to $data" >&2
      echo "$ns $pvc $pv $data ${owner,,}"
    done | sort -u
}

# Which node holds the volume's data: the running pod's node if its copy has
# any files, else the node with the largest copy. "Where the pod runs" alone is
# wrong right after a restart: the registry came back on a node with an empty
# directory while its 2.9 GB sat on another.
data_node() {  # <path> <running node>
  local n size best="" best_size=-1
  if docker exec "$2" sh -c "find '$1' -type f 2>/dev/null | head -1 | grep -q ."; then echo "$2"; return; fi
  for n in $(k get nodes -o jsonpath='{.items[*].metadata.name}'); do
    size="$(docker exec "$n" sh -c "du -sk '$1' 2>/dev/null | cut -f1")"
    [[ -n "$size" && "$size" -gt "$best_size" ]] && best=$n best_size=$size
  done
  echo "${best:-$2}"
}

pin_volume() {  # <ns> <pvc> <pv> <node>
  local ns=$1 pvc=$2 pv=$3 node=$4 old_pvc old_pv
  old_pvc="$(k -n "$ns" get pvc "$pvc" -o json)"
  old_pv="$(k get pv "$pv" -o json)"
  echo "  $ns/$pvc → $node ($(jq -r .spec.hostPath.path <<<"$old_pv"))"
  run k patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
  run k -n "$ns" delete pvc "$pvc" --wait=true >/dev/null
  run k delete pv "$pv" --wait=true >/dev/null
  # Same name, path, size and class; Retain + nodeAffinity; pre-bound to the PVC.
  jq --arg node "$node" --arg ns "$ns" --arg pvc "$pvc" '{
      apiVersion: "v1", kind: "PersistentVolume",
      metadata: { name: .metadata.name, labels: { "microecom/pinned": "true" } },
      spec: (.spec | del(.claimRef) + {
        persistentVolumeReclaimPolicy: "Retain",
        hostPath: { path: .hostPath.path, type: "Directory" },
        claimRef: { namespace: $ns, name: $pvc },
        nodeAffinity: { required: { nodeSelectorTerms: [ { matchExpressions: [
          { key: "kubernetes.io/hostname", operator: "In", values: [ $node ] } ] } ] } } })
    }' <<<"$old_pv" | apply
  # Keep labels and the Helm/apply annotations so the owning release still adopts it.
  jq --arg pv "$pv" '{
      apiVersion: "v1", kind: "PersistentVolumeClaim",
      metadata: { name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels,
        annotations: ((.metadata.annotations // {}) | with_entries(select(.key | test("^(pv|volume)\\.") | not))) },
      spec: (.spec | { accessModes, resources, storageClassName, volumeMode } + { volumeName: $pv })
    }' <<<"$old_pvc" | apply
}

mapfile -t VOLUMES < <(unpinned)
if [[ ${#VOLUMES[@]} -eq 0 ]]; then echo "every hostpath volume is already pinned"; exit 0; fi

# One scale-down per workload, however many volumes it has (mysql-replica: 2).
for workload in $(printf '%s\n' "${VOLUMES[@]}" | awk '{print $1"|"$5}' | sort -u); do
  ns=${workload%%|*} w=${workload#*|}
  [[ -z "${ONLY:-}" || "$ns/$w" == "$ONLY" ]] || continue
  replicas="$(k -n "$ns" get "$w" -o jsonpath='{.spec.replicas}')"
  echo "$ns/$w (replicas $replicas)"
  claims="$(printf '%s\n' "${VOLUMES[@]}" | awk -v ns="$ns" -v w="$w" '$1==ns && $5==w {print $2}' | jq -Rsc 'split("\n")[:-1]')"
  run k -n "$ns" scale "$w" --replicas=0 >/dev/null
  # Wait for the pods that MOUNT these claims, not for the selector: the
  # registry Deployment's selector also matches the registry-proxy DaemonSet.
  if [[ "$DRY" != --dry-run ]]; then
    for _ in $(seq 1 90); do
      k -n "$ns" get pods -o json | jq -e --argjson c "$claims" \
        '[.items[].spec.volumes[]?.persistentVolumeClaim.claimName] | any(. as $n | $c | index($n))' >/dev/null || break
      sleep 2
    done
  fi
  printf '%s\n' "${VOLUMES[@]}" | awk -v ns="$ns" -v w="$w" '$1==ns && $5==w' \
    | while read -r vns pvc pv node _; do pin_volume "$vns" "$pvc" "$pv" "$node"; done
  run k -n "$ns" scale "$w" --replicas="$replicas" >/dev/null
  if [[ "$DRY" != --dry-run ]]; then
    k -n "$ns" rollout status "$w" --timeout=5m
  fi
done
