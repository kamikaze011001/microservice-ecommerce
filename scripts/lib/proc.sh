#!/bin/bash
# Process/port kill helpers shared by stop.sh and start.sh's stale-Eureka-
# registration healing path. Source, don't execute.

# kill_orphan_on_port <name> <port>
# Two-step: SIGTERM whatever is listening on <port>, bounded 1s wait, SIGKILL
# escalation if it survives.
#
# WHY THIS EXISTS, NOT JUST `kill "$pid"`: spring-boot-maven-plugin forks the
# actual JVM as a child of the `mvn spring-boot:run` launcher. The PID a
# caller has on hand — from a pidfile, or the launcher PID `kill -0`-checked
# moments ago — is that launcher, not the JVM that holds the port. A plain
# `kill <pid>` (or even a failed/partial process-group kill) can leave the
# JVM child bound to the port; without this backstop, orphans survive
# `make nuke`/`stop.sh` and silently break fresh bootstraps (the port stays
# bound, so the replacement crashes with EADDRINUSE), and this is also the
# only thing that reaps `pnpm dev`'s forked Vite child, whose PID is never
# the one written to the pidfile in the first place.
kill_orphan_on_port() {
    local name=$1 port=$2
    [ -n "$port" ] && [ "$port" != "-" ] || return 0
    local orphans
    orphans=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    [ -n "$orphans" ] || return 0
    log_warn "$name: orphan(s) on :$port — killing $orphans"
    # shellcheck disable=SC2086
    kill $orphans 2>/dev/null || true
    sleep 1
    orphans=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$orphans" ]; then
        log_warn "$name: orphan(s) survived SIGTERM, sending SIGKILL"
        # shellcheck disable=SC2086
        kill -9 $orphans 2>/dev/null || true
    fi
}
