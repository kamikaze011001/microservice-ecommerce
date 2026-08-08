---
name: vault-config-comment-keys-are-really-seeded
description: The `_comment*` keys in docker/vault-configs/*.json are not comments — import-secrets.sh POSTs the file verbatim, so they have always been live Vault properties
metadata: { type: convention, date: 2026-08-07 }
---

JSON has no comment syntax, so documentation inside `docker/vault-configs/*.json` was written as
keys prefixed with `_comment`: `_comment`, `_comment_mail_creds`, `_comment_mock_paypal`,
`_comment_paypal_creds`.

`scripts/vault/import-secrets.sh` wraps the file with `jq '{data: .}'` and POSTs it **verbatim**
to the Vault KV v2 API. There is no filtering step. Those four keys have therefore always been
seeded into Vault as real properties — inert, because no Spring binding reads them, but present.

**Why it matters:** this is the difference between "94 keys in the file" and "90 keys of actual
config", and it was the *only* behavioural change in the canonical-secrets migration (the
canonical YAML carries that documentation as real YAML comments, so the four keys disappear).
When comparing an old seed path against a new one, an unexplained key-count mismatch is likely
this, not a lost property.

**How to apply:** do not treat `_comment*` keys as inert file-local documentation — anything that
counts, diffs, or copies `docker/vault-configs/*.json` must decide explicitly whether to carry
them. If you add documentation to one of those files while `docker/` is still the live compose
path, you are adding a Vault property. Related:
[[0004-canonical-secrets-resolve-transport-split]].
