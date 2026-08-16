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

# local_host_ipv4s — every non-loopback IPv4 this host owns, one per line.
# Prints them; exits 1 and prints NOTHING if none can be determined.
#
# WHY A SET, NOT ONE ADDRESS: Spring registers whatever InetUtils picks — the
# first non-loopback site-local address by interface enumeration order. Any
# single address we compute is a GUESS at that choice. This host has five
# non-loopback site-locals (en1 plus four docker/minikube bridges), and the
# old default-route guess agreed with Spring only by luck. A disagreement
# produced a non-empty WRONG answer, which no fail-safe here catches — every
# service stale on every `make up`, permanently, because the replacement
# re-registers the same address.
#
# Asking "is Eureka's address one this host owns?" needs no guess at all.
local_host_ipv4s() {
    [ -n "${FORCE_NO_HOST_IP:-}" ] && return 1          # test seam: cannot determine
    if [ -n "${HOST_IP_OVERRIDE:-}" ]; then
        # test seam: pretend the host owns exactly these addresses. Deliberately
        # UNQUOTED so a space- or newline-separated list splits into one per
        # line; existing single-value callers are unaffected. IPs contain no
        # glob characters, so word-splitting is safe here.
        # shellcheck disable=SC2086
        printf '%s\n' $HOST_IP_OVERRIDE
        return 0
    fi
    local ips
    ips=$(ifconfig -a 2>/dev/null | awk '/^[[:space:]]*inet /{print $2}' \
          | grep -v '^127\.' | sort -u)
    [ -n "$ips" ] || return 1
    printf '%s\n' "$ips"
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
        try:
            if str(i.get("port", {}).get("$")) == want and i.get("ipAddr"):
                print(i["ipAddr"])
                sys.exit(0)
        except Exception:
            continue
sys.exit(1)
'
}

# eureka_staleness <http_port>
#   exit 0 = STALE; stdout is "<reg_ip> <local_ip…>" so the caller can log the
#            exact values the decision used
#   exit 1 = not stale, OR unknown — prints NOTHING
#
# Missing information NEVER yields 0. An unreachable Eureka, an unregistered
# service and an undeterminable local address set all mean "not stale", so
# the failure mode is "do nothing", never "restart everything". The local
# address lookup runs FIRST and short-circuits before the Eureka round-trip:
# an undeterminable address set prevents the check from asking Eureka at all,
# rather than merely making the answer irrelevant once it does.
#
# STALE means membership, not equality: is the registered address one this
# host owns? Not "does it match the one address we guessed Spring would
# pick" — see local_host_ipv4s for why that guess can be wrong.
#
# ONE function, not two: start.sh used to re-implement this formula inline to
# get the values for its log without a second round-trip, which left the test
# suite exercising a function production never called. Returning the values
# WITH the verdict removes the reason to duplicate it.
eureka_staleness() {
    local port=$1 reg_ip locals
    locals=$(local_host_ipv4s) || return 1
    [ -n "$locals" ] || return 1
    reg_ip=$(eureka_registered_ip "$port") || return 1
    [ -n "$reg_ip" ] || return 1
    # Stale = Eureka's address is NOT one this host owns. `grep -qxF` is an
    # exact whole-line fixed-string match: -F so dots are literal, -x so
    # 192.168.0.10 never matches 192.168.0.103.
    printf '%s\n' "$locals" | grep -qxF "$reg_ip" && return 1
    printf '%s %s\n' "$reg_ip" "$(printf '%s' "$locals" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
}
