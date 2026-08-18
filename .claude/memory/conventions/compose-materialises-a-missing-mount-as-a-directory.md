---
name: compose-materialises-a-missing-mount-as-a-directory
description: docker/mongodb.yml bind-mounted three deleted files, so every `make up` silently recreated docker/product.json and friends as EMPTY DIRECTORIES that looked like restored seed data
metadata: { type: convention, date: 2026-08-16 }
---

Phase 8 deleted `docker/api_role.json`, `docker/product.json` and
`docker/product-quantity-history.json`. `docker/mongodb.yml` still bind-mounted all three:

```yaml
- ./api_role.json:/seed/api_role.json:ro
```

**Docker Compose creates a missing bind-mount source as an empty directory.** So every
`make up` afterwards re-created paths named exactly like the deleted seed files. A subagent
found them, correctly identified them as wrong, and deleting them tripped a security warning —
they look precisely like destroying seed data.

The mounts were entirely dead: `mongodb.yml`'s entrypoint contains no `/seed` reference, and
none of the three were git-tracked. Removing them changed no behaviour except to stop Docker
fabricating directories named after deleted files.

**Why the deletion sweep missed it — the durable half.** Phase 8 learned *"grep
path-qualified, never by basename"*, because the canonical replacements share filenames
(`deploy/seed/product.json` vs `docker/product.json`) and a basename grep matches the new
path. But `mongodb.yml` lives **in** `docker/` and refers to `./product.json` — a RELATIVE
path that `git grep 'docker/product\.json'` can never match. **The fix for the basename blind
spot created a relative-path blind spot, and this reference lived in the gap between them.**

**How to apply:** a deletion sweep needs BOTH shapes — the repo-qualified path and the
basename as referenced from inside its own directory. Compose files, Dockerfiles and kustomize
bases all use the relative form. And when a deleted file mysteriously reappears as an empty
directory, look for a bind mount before assuming something restored it. Related:
[[make-n-shows-commands-not-the-files-they-read]].
