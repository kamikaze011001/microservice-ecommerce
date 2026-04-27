#!/bin/bash
# Show running status of every service in the registry.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/colors.sh
source "$REPO_ROOT/scripts/lib/colors.sh"
# shellcheck source=../lib/registry.sh
source "$REPO_ROOT/scripts/lib/registry.sh"

load_registry

printf "%-22s %-6s %-6s %s\n" "SERVICE" "HTTP" "GRPC" "STATE"
while IFS= read -r line; do
    name=$(svc_field "$line" 1)
    http=$(svc_field "$line" 2)
    grpc=$(svc_field "$line" 3)
    if (echo > "/dev/tcp/localhost/$http") 2>/dev/null; then
        state="${GREEN}● running${NC}"
    else
        state="${RED}○ down${NC}"
    fi
    printf "%-22s %-6s %-6s " "$name" "$http" "$grpc"
    echo -e "$state"
done < <(svc_list)
