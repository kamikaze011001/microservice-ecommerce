#!/bin/bash
# DEPRECATED: use 'make vault-init && make vault-unseal && make vault-import',
# or 'make vault-unseal' alone for the post-restart path.
echo "⚠ init-vault.sh is deprecated — use: make vault-init / make vault-unseal" >&2
case "${1:-init}" in
    unseal) exec make vault-unseal ;;
    *)      exec make vault-init vault-unseal vault-import ;;
esac
