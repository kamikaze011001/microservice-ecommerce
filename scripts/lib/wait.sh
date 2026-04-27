#!/bin/bash
# Port and HTTP readiness checks. Source, don't execute.

# wait_for_port <label> <port> [max_attempts=36]
# Polls localhost:<port> at 5s intervals. 36*5s = 3min default.
wait_for_port() {
    local label=$1 port=$2 max=${3:-36} attempt=1
    log_info "Waiting for $label (port $port)..."
    while [ "$attempt" -le "$max" ]; do
        if (echo > /dev/tcp/localhost/"$port") 2>/dev/null; then
            log_ok "$label is up"
            return 0
        fi
        echo "  [$attempt/$max] Not ready yet..."
        sleep 5
        attempt=$((attempt + 1))
    done
    log_err "$label failed to start on port $port"
    return 1
}

# wait_for_http <label> <url> [max_attempts=36]
wait_for_http() {
    local label=$1 url=$2 max=${3:-36} attempt=1
    log_info "Waiting for $label ($url)..."
    while [ "$attempt" -le "$max" ]; do
        if curl -sf "$url" > /dev/null 2>&1; then
            log_ok "$label is up"
            return 0
        fi
        sleep 5
        attempt=$((attempt + 1))
    done
    log_err "$label failed: $url not responding"
    return 1
}
