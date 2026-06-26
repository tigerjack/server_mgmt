#!/usr/bin/env bash
# Convenience wrapper around ansible-playbook.
# Run from the repo root.  All extra arguments are forwarded to ansible-playbook.
#
# Automatic behaviour (no flags needed in the common case):
#   - If .vault_pass exists next to this script, it is passed via
#     --vault-password-file (no interactive vault prompt).
#   - If ansible_become_pass is wired up — either as a plaintext assignment in
#     group_vars/host_vars, or inside an encrypted vault.yml (per-host become
#     passwords belong here) — become auth is automatic, no sudo prompt.
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

# Decide whether to prompt for the become (sudo) password.
#
# ansible_become_pass is a secret, so it lives inside the ENCRYPTED vault
# files - a plaintext grep can never see it (the file is an opaque
# $ANSIBLE_VAULT blob). So we check two places:
#   1. plaintext vars files  - an uncommented assignment (comments don't count)
#   2. encrypted vault files  - decrypt with .vault_pass and grep the result
# If found in either, become auth comes from the vault and no prompt is needed.
#
# Note: become passwords are per-host (set in each host_vars/<host>/vault.yml),
# so --ask-become-pass is NOT a valid fallback for a multi-host run - it only
# accepts a single password. It remains useful only for the single-password or
# single-host (--limit) case.
become_args=(--ask-become-pass)
search_paths=("$ANSIBLE_DIR/group_vars" "$ANSIBLE_DIR/host_vars")

# 1. Uncommented plaintext assignment anywhere under group_vars/host_vars.
if grep -rEq '^[[:space:]]*ansible_become_pass[[:space:]]*:' \
       "${search_paths[@]}" 2>/dev/null; then
    become_args=()
# 2. Otherwise look inside encrypted vaults (needs the vault password file).
elif [[ -f "$REPO_ROOT/.vault_pass" ]]; then
    while IFS= read -r -d '' f; do
        head -n1 "$f" 2>/dev/null | grep -q '^\$ANSIBLE_VAULT' || continue
        if ansible-vault view --vault-password-file "$REPO_ROOT/.vault_pass" "$f" 2>/dev/null \
             | grep -Eq '^[[:space:]]*ansible_become_pass[[:space:]]*:'; then
            become_args=()
            break
        fi
    done < <(find "${search_paths[@]}" -type f -name '*.yml' -print0 2>/dev/null)
fi

# ansible.cfg must be in the working directory for Ansible to pick it up.
cd "$ANSIBLE_DIR"

exec ansible-playbook \
    -i "$ANSIBLE_DIR/inventory.yml" \
    "$ANSIBLE_DIR/site.yml" \
    "${vault_args[@]}" \
    "${become_args[@]}" \
    "$@"
