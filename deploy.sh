#!/usr/bin/env bash
# Convenience wrapper around ansible-playbook.
# Run from the repo root.  All extra arguments are forwarded to ansible-playbook.
#
# Examples:
#   ./deploy.sh                              # full run, prompts for vault + sudo passwords
#   ./deploy.sh --limit spqr-project        # single host
#   ./deploy.sh --vault-password-file .vault_pass --ask-become-pass
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

exec ansible-playbook \
    -i "$REPO_ROOT/ansible/inventory.yml" \
    "$REPO_ROOT/ansible/site.yml" \
    --ask-vault-pass \
    --ask-become-pass \
    "$@"
