---
name: the-pidfile-holds-the-launcher-not-the-port-holder
description: logs/pids/<svc>.pid is the `mvn spring-boot:run` launcher, not the JVM it forks — killing it leaves the port bound, and wait_for_port then succeeds against the dying process
metadata: { type: convention, date: 2026-08-16 }
---

Verified live on this host:

```
logs/pids/gateway.pid          -> 78970   (the Maven launcher)
lsof -nP -iTCP:6868 -sTCP:LISTEN -> 79061 (the forked Spring Boot JVM — the port holder)
```

`spring-boot-maven-plugin` forks the application JVM as a **child** of the `mvn` process whose
PID the pidfile records. So `kill "$(cat "$PID_DIR/$name.pid")"` signals a wrapper. Port
release then depends on an unverified chain — Maven's shutdown hook → the plugin destroying
the child → the child's own SIGTERM handling → Tomcat unbind — with no escalation if any link
fails.

**The failure is silent in the worst way.** If a replacement is forked immediately, it can lose
the bind race with `EADDRINUSE` — and `wait_for_port` **succeeds anyway**, because the OLD
process is still listening. `make up` reports the service healthy while it serves the stale
registration the restart was meant to heal.

`scripts/lib/proc.sh`'s `kill_orphan_on_port` is what actually frees the port: it `lsof`s the
port and SIGKILLs whatever holds it, regardless of PIDs. **Do not remove it as redundant** —
it is doing 100% of the work.

**The process-group kill above it is inert here.** `kill -- -"$pid"` targets pgid == the
launcher's PID, but a background `mvn spring-boot:run &` never becomes its own group leader —
every launcher from one `make up` shares the shell's pgid. Verified: `gateway` pid 89834 and
`authorization-server` pid 89782 both had pgid 89330, and no process had pgid 89834. The group
kill always ESRCHs and falls through to the launcher-only kill.

**How to apply:** to stop one of these services, kill by **port**, not by pidfile PID. Treat
the pidfile as a liveness marker only — reading it to test "is it running" is fine; killing by
it is not. Proven real: during a forced-drift run `kill_orphan_on_port` reaped PIDs
79352/79895/79896 for inventory/product/order-service — neither the pidfile PID nor the new
launcher. Related: [[minikube-tunnel-external-ip-is-sticky]] (another "the obvious signal is
not the real one" case).
