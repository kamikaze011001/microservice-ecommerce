---
name: an-unguarded-read-passes-when-its-input-vanishes
description: deleting a file is the only way to learn who really read it — one suite kept reporting 33 passed after its input was deleted, while its neighbour reading the same file failed loudly
metadata: { type: convention, date: 2026-08-15 }
---

Deleting `docker/vault-configs/` exposed this in `deploy/secrets/tests/equivalence-test.sh`:

```bash
APPLICATION_JWK="$(jq -r '."application.jwk"' "$ROOT/docker/vault-configs/authorization-server.json")"
```

With the file gone, `jq` failed, the assignment produced an **empty string**, and the suite
still reported **33 passed / 0 failed**. A pass that proved nothing about a vanished input.
Only a path-qualified grep found it.

Its neighbour `capture-golden.sh` reads the *same file* and survives correctly, because it
guards the result:

```bash
[ -n "$APPLICATION_JWK" ] && [ "$APPLICATION_JWK" != "null" ] || { echo "FAIL: ..."; exit 1; }
```

Same read, same deleted file, opposite outcome. **That guard is the entire difference** — and
it explains why the pattern keeps recurring: the guard costs one line and pays off only in a
scenario that, by definition, has not happened yet. This was the ninth instance in the deploy
refactor of an empty result reading as a negative result, several of them *inside* guards
written to prevent it.

**How to apply:** every read of an external file or command output needs an explicit
non-empty assertion before its value is used, especially in tests. When auditing, ask what
the check does when its input is *absent* — not merely when it is wrong.

Corollary: **deletion is a diagnostic, not just cleanup.** Removing a file is the only way to
find out who was really reading it, and twice in this phase the reader turned out to be a
test that kept passing without it — meaning those assertions had been partly decorative for
some time. The risk of deleting is a dangling reference; the risk of *not* deleting is never
learning which of your assertions were load-bearing. Related:
[[cross-env-equality-checks-miss-shared-drift]],
[[make-n-shows-commands-not-the-files-they-read]].
