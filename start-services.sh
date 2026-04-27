#!/bin/bash
# DEPRECATED: use 'make svc-start' / 'make svc-stop' / 'make status'.
echo "⚠ start-services.sh is deprecated — use: make svc-start | svc-stop | status" >&2
case "${1:-start}" in
    stop)   exec make svc-stop ;;
    status) exec make status ;;
    *)      exec make svc-start ;;
esac
