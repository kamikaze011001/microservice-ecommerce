#!/bin/bash
# DEPRECATED: use 'make vault-import'.
echo "⚠ vault-import-secrets.sh is deprecated — use: make vault-import" >&2
exec make vault-import
