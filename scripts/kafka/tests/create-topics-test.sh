#!/usr/bin/env bash
# Offline decision-table test for deploy/k8s-jobs/04-kafka-connect-register/create-topics.sh.
# A fake kafka-topics stands in for the broker, so this runs with the stack down.
#
#   topic   exists with   listed   expected
#   a       1             12       grown (--alter --partitions 12)
#   b       12            12       untouched
#   c       20            12       untouched + WARN (Kafka can't shrink)
#   d       —             12       created with cleanup.policy=compact
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUT="${SUT:-$ROOT/deploy/k8s-jobs/04-kafka-connect-register/create-topics.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"$work/kafka-topics" <<'EOF'
#!/bin/sh
shift 2                                   # --bootstrap-server <x>
case "$1" in
  --list) exit 0 ;;
  --describe)
    case "$3" in
      a) n=1 ;; b) n=12 ;; c) n=20 ;;
      *) echo "Error: topic '$3' does not exist" >&2; exit 1 ;;
    esac
    printf 'Topic: %s\tTopicId: x\tPartitionCount: %s\tReplicationFactor: 1\n' "$3" "$n" ;;
  *) echo "$*" >>"$CALLS" ;;
esac
EOF
chmod +x "$work/kafka-topics"
printf '# comment\n\na 12 delete\nb 12 delete\nc 12 delete\nd 12 compact\n' >"$work/topics.txt"

pass=0; fail=0
check() { if grep -qE -- "$2" "$3"; then pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
check_not() { if grep -qE -- "$2" "$3"; then echo "FAIL: $1"; fail=$((fail+1)); else pass=$((pass+1)); fi; }

CALLS="$work/calls" KAFKA_TOPICS="$work/kafka-topics" BOOTSTRAP=x TOPICS_FILE="$work/topics.txt" \
  sh "$SUT" >"$work/out" 2>&1
touch "$work/calls"

check     "a is grown to 12"                '^--alter --topic a --partitions 12$'                  "$work/calls"
check_not "b is not touched"                ' --topic b '                                           "$work/calls"
check_not "c is not shrunk"                 ' --topic c '                                           "$work/calls"
check     "c warns"                         'WARN +c has 20 partitions'                             "$work/out"
check     "d is created with 12 + compact"  '^--create --if-not-exists --topic d --partitions 12 .*cleanup.policy=compact$' "$work/calls"
check_not "comment line is not a topic"     'comment'                                               "$work/calls"

echo "create-topics-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
