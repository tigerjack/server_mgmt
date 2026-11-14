#!/usr/bin/env bash
# Prints the Ansible vault password from the desktop keyring (any Secret
# Service provider: GNOME Keyring, KWallet, KeePassXC). Ansible runs an
# executable --vault-password-file and reads the password from its stdout;
# deploy.sh uses this script when .vault_pass is absent.
#
# Store the password once (secret-tool prompts for it, so it stays out of
# shell history):
#   secret-tool store --label='server_mgmt ansible vault' \
#       service ansible-vault project server_mgmt
set -euo pipefail

if ! secret-tool lookup service ansible-vault project server_mgmt; then
    echo "vault-pass-keyring: no vault password in the keyring; store it with:" >&2
    echo "  secret-tool store --label='server_mgmt ansible vault' service ansible-vault project server_mgmt" >&2
    exit 1
fi
