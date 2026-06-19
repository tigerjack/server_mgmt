#!/usr/bin/env bash
# Sequential Nextcloud major-version upgrade.
# Nextcloud refuses to skip major versions, so 30 → 34 requires four separate
# upgrades with database migrations at each step.
#
# Prereq: create .vault_pass in the repo root so you aren't prompted four times:
#   echo 'your-vault-password' > .vault_pass && chmod 600 .vault_pass
#
# Usage (run from repo root):
#   ./upgrade-nextcloud.sh 30 34

set -euo pipefail

FROM=${1:?Usage: $0 <from_version> <to_version>  (e.g. $0 30 34)}
TO=${2:?Usage: $0 <from_version> <to_version>}
REPO="$(cd "$(dirname "$0")" && pwd)"
VARS="$REPO/ansible/group_vars/all/vars.yml"
SCONT="sudo -u containers XDG_RUNTIME_DIR=/run/user/$(id -u containers)"

if [[ ! -f "$REPO/.vault_pass" ]]; then
    echo "ERROR: $REPO/.vault_pass not found."
    echo "Create it first: echo 'your-vault-password' > .vault_pass && chmod 600 .vault_pass"
    exit 1
fi

echo "=== Nextcloud sequential upgrade: $FROM → $TO ==="

for (( v=FROM+1; v<=TO; v++ )); do
    prev=$((v-1))
    echo ""
    echo "━━━ Step $((v-FROM)) of $((TO-FROM)): Nextcloud $prev → $v ━━━"

    # Update the image tag in vars.yml
    sed -i "s|nextcloud:${prev}-apache|nextcloud:${v}-apache|" "$VARS"
    echo "  vars.yml → nextcloud:${v}-apache"

    # Run only the nextcloud role (stop → recreate container with new image → start)
    ansible-playbook \
        -i "$REPO/ansible/inventory.yml" \
        "$REPO/ansible/upgrade-nextcloud.yml" \
        --vault-password-file "$REPO/.vault_pass" \
        --ask-become-pass

    # Wait until occ reports installed (upgrade can take several minutes)
    echo -n "  Waiting for occ upgrade to finish"
    until $SCONT podman exec --user www-data nextcloud \
            php /var/www/html/occ status --output=json 2>/dev/null \
            | grep -q '"installed":true'; do
        sleep 10
        printf '.'
    done
    echo " done"
    echo "  ✓ Nextcloud $v is up"
done

echo ""
echo "=== All done: Nextcloud $TO ==="
echo "Run the full playbook to sync everything else (Traefik restart etc.):"
echo "  ./deploy.sh"
