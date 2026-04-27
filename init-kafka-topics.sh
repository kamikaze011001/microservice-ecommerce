#!/bin/bash
# DEPRECATED: use 'make kafka-topics'.
echo "⚠ init-kafka-topics.sh is deprecated — use: make kafka-topics" >&2
exec make kafka-topics
