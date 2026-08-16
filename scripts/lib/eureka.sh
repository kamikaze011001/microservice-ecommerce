#!/usr/bin/env bash
# Eureka registration freshness. Pure query + comparison — never restarts
# anything; the caller decides what to do with the verdict.
#
# WHY THIS EXISTS: under compose the JVMs run on the HOST and register the
# host's IP with Eureka. After a network/IP change the processes are still
# alive, so scripts/services/start.sh skips them, and they keep serving stale
# registrations. Everything looks up and requests fail.
#
# JOIN KEY IS THE HTTP PORT, NOT THE NAME. `gateway` appears in Eureka as
# CLOUD-GATEWAY, so a name-based match would silently never heal the gateway.
# services.list already carries the port as the single source of truth.

EUREKA_URL="${EUREKA_URL:-http://localhost:8761}"

# current_host_ip — the IP a host-run JVM would register.
# Prints it; exits 1 and prints NOTHING if it cannot be determined.
current_host_ip() {
    [ -n "${FORCE_NO_HOST_IP:-}" ] && return 1          # test seam
    if [ -n "${HOST_IP_OVERRIDE:-}" ]; then
        printf '%s' "$HOST_IP_OVERRIDE"; return 0
    fi
    # Derive the interface from the DEFAULT ROUTE, never a hardcoded one:
    # on this project's own machine the IP is on en1 and `ipconfig getifaddr
    # en0` returns empty, which would make every service look drifted.
    local iface ip
    iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    [ -n "$iface" ] || return 1
    ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
    [ -n "$ip" ] || return 1
    printf '%s' "$ip"
}

# eureka_registered_ip <http_port> — the ipAddr Eureka holds for the instance
# serving that port. Prints it; exits 1 and prints NOTHING when Eureka is
# unreachable or no instance matches.
eureka_registered_ip() {
    local port=$1 json
    if [ -n "${EUREKA_APPS_FIXTURE:-}" ]; then
        json=$(cat "$EUREKA_APPS_FIXTURE" 2>/dev/null) || return 1
    else
        json=$(curl -sf --max-time 3 -H 'Accept: application/json' \
                    "$EUREKA_URL/eureka/apps" 2>/dev/null) || return 1
    fi
    [ -n "$json" ] || return 1
    printf '%s' "$json" | EUREKA_PORT="$port" python3 -c '
import sys, os, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
apps = d.get("applications", {}).get("application", [])
if isinstance(apps, dict):
    apps = [apps]
want = os.environ["EUREKA_PORT"]
for a in apps:
    insts = a.get("instance", [])
    if isinstance(insts, dict):
        insts = [insts]
    for i in insts:
        if str(i.get("port", {}).get("$")) == want and i.get("ipAddr"):
            print(i["ipAddr"])
            sys.exit(0)
sys.exit(1)
'
}

# registration_is_stale <http_port>
#   exit 0 = STALE, the caller should restart this service
#   exit 1 = not stale, OR unknown
# Missing information NEVER yields 0. An empty Eureka response and a genuinely
# fresh stack must not be confusable.
registration_is_stale() {
    local port=$1 host_ip reg_ip
    host_ip=$(current_host_ip) || return 1
    [ -n "$host_ip" ] || return 1
    reg_ip=$(eureka_registered_ip "$port") || return 1
    [ -n "$reg_ip" ] || return 1
    [ "$reg_ip" != "$host_ip" ]
}
