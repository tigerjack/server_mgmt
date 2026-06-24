#!/usr/bin/env bash
# Convenience wrapper around ansible-playbook.
# Run from the repo root.  All extra arguments are forwarded to ansible-playbook.
#
# Automatic behaviour (no flags needed in the common case):
#   - If .vault_pass exists next to this script, it is passed via
#     --vault-password-file (no interactive vault prompt).
#   - If ansible_become_pass is wired up (a real uncommented assignment in
#     group_vars or host_vars), become auth is automatic — no sudo prompt.
#   - Otherwise the script falls back to interactive prompts.
#
# Examples:
#   ./deploy.sh                        # full run, auto-detects credentials
#   ./deploy.sh --limit spqr-project   # single host
#   ./deploy.sh --tags forgejo         # single role
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ANSIBLE_DIR="$REPO_ROOT/ansible"

vault_args=()
if [[ -f "$REPO_ROOT/.vault_pass" ]]; then
    vault_args=(--vault-password-file "$REPO_ROOT/.vault_pass")
else
    vault_args=(--ask-vault-pass)
fi

# Only skip --ask-become-pass when ansible_become_pass is actually wired up
# (an uncommented assignment). A comment line must not count as "wired up".
become_args=()
if ! grep -rEq '^[[:space:]]*ansible_become_pass[[:space:]]*:' \
       "$ANSIBLE_DIR/group_vars" \
       "$ANSIBLE_DIR/host_vars" 2>/dev/null; then
    become_args=(--ask-become-pass)
fi

# ansible.cfg must be in the working directory for Ansible to pick it up.
cd "$ANSIBLE_DIR"

exec ansible-playbook \
    -i "$ANSIBLE_DIR/inventory.yml" \
    "$ANSIBLE_DIR/site.yml" \
    "${vault_args[@]}" \
    "${become_args[@]}" \
    "$@"
