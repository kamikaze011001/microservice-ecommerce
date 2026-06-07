# k9s Infra-Monitor Plugin — Design Spec

**Date:** 2026-06-07
**Status:** Approved (design)
**Builds on:** the k9s setup in `k8s/k9s/` (branch `feat/k9s-monitoring`, PR #14). Implemented on that same branch.
**Goal:** Add one read-only k9s plugin so a single keypress on an infra pod shows that service's health (MySQL replication, MongoDB replica-set, Kafka consumer-group lag, Redis INFO) — closing k9s's gap between pod-level and app-level monitoring.

## Background

k9s shows Kubernetes objects (pods, logs, exec, resource usage) but not application internals. The `infra` namespace holds MySQL (`mysql-8.0.40`, root/root), MongoDB (`mongo:7.0`, root/root, 2-container pod), Kafka (`apache/kafka:3.9.1`, PLAINTEXT `localhost:9092`, no auth), and Redis (`redis:7.4-alpine`). Each ships a CLI capable of a quick read-only health report.

## Decisions

- **One smart key**, not per-service keys: a single plugin detects the service from the selected pod's name and runs the right command. One keystroke to learn.
- **Read-only only**: monitoring, no admin/write actions.
- **Four services**: MySQL, MongoDB, Kafka, Redis. (MinIO/Vault/kafka-connect REST are out of scope.)
- **Key = `Ctrl-Y`** (not `Ctrl-J` — terminals send Ctrl-J as Enter). Final collision check is part of live verification.

## Architecture

A committed `k8s/k9s/plugins.yaml` defines one plugin `inspect-infra`, scoped to the `pods` view. Its `command: bash -c <script>` uses k9s's env vars (`$NAME`, `$NAMESPACE`, `$CONTEXT`) to `kubectl exec` the right read-only command into the selected pod, with all output piped through `less` (scrollable; `background: false` so k9s suspends and the pager has a TTY; k9s resumes on `q`). It loads from the existing `K9S_CONFIG_DIR` — no Makefile change.

### Dispatch (case on pod name)

| Pod name | Command (via `kubectl exec`) |
|---|---|
| `mysql*` | `mysql -uroot -proot -e "SELECT @@hostname,@@server_id,@@read_only\G SHOW REPLICA STATUS\G"` (primary → state + empty replica status; replica → IO/SQL threads + lag) |
| `mongodb*` | `-c mongodb mongosh … --eval` printing `rs.status()` myState + members' stateStr/health |
| `kafka-connect*` | message: select the broker pod (matched BEFORE `kafka*`) |
| `kafka*` | `/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --all-groups --describe` |
| `redis*` | `redis-cli INFO` |
| anything else | `No infra monitor for pod: <name>` |

## Error handling

- Unrelated pod → friendly "no monitor" line.
- `kubectl exec` / auth / tool failures are not silenced — `2>&1` folds stderr into the paged output.
- All commands are strictly read-only.

## Testing / verification

- **Non-interactive:** `plugins.yaml` parses (`python3 yaml.safe_load`); `K9S_CONFIG_DIR=…/k8s/k9s k9s info` lists `Plugins:` under `k8s/k9s` with no config parse error.
- **Interactive (deferred to human — k9s is a TUI and the cluster is currently stopped):** start the cluster, select each of the four infra pods, press `Ctrl-Y`, confirm the correct read-only report; confirm via `?` that `Ctrl-Y` shows as a plugin and isn't shadowed (rebind if it is). The exact tool paths / container names / creds are confirmed in this step.

## Out of scope (YAGNI)

Write/admin actions; kafka-connect & schema-registry REST status; MinIO/Vault monitors; per-service key variants; a Prometheus/Grafana stack.
