#!/usr/bin/env bash
# Convenience wrapper around ansible-playbook.
# Run from the repo root.  All extra arguments are forwarded to ansible-playbook.
#
# Automatic behaviour (no flags needed in the common case):
#   - If .vault_pass exists next to this script, it is passed via
#     --vault-password-file (no interactive vault prompt).
#   - If vault_become_pass is set in any vault (i.e. ansible_become_pass is
#     wired up in group_vars), become auth is automatic too (no sudo prompt).
#   - Otherwise the script falls back to interactive prompts.
#
# Examples:
#   ./deploy.sh                        # full run, auto-detects credentials
#   ./deploy.sh --limit spqr-project   # single host
#   ./deploy.sh --tags forgejo         # single role
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

vault_args=()
if [[ -f "$REPO_ROOT/.vault_pass" ]]; then
    vault_args=(--vault-password-file "$REPO_ROOT/.vault_pass")
else
    vault_args=(--ask-vault-pass)
fi

# If vault_become_pass is in the vault (and wired to ansible_become_pass),
# ansible handles sudo automatically — no --ask-become-pass needed.
# If it is NOT set, we need the interactive prompt.
# Detect by checking whether ansible_become_pass is defined anywhere in vars.
become_args=()
if ! grep -r 'ansible_become_pass' "$REPO_ROOT/ansible/group_vars" \
       "$REPO_ROOT/ansible/host_vars" &>/dev/null 2>&1; then
    become_args=(--ask-become-pass)
fi

exec ansible-playbook \
    -i "$REPO_ROOT/ansible/inventory.yml" \
    "$REPO_ROOT/ansible/site.yml" \
    "${vault_args[@]}" \
    "${become_args[@]}" \
    "$@"
