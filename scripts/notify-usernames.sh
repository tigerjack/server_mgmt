#!/usr/bin/env bash
# Email every user in the Authelia user database their username.
#
# Reads username/email pairs from the authelia container's
# /config/users_database.yml and sends each user a short plain-text message
# via swaks through your SMTP relay (Brevo by default).
#
# SAFETY: defaults to a dry run (prints, sends nothing). You must pass --send
# to actually deliver mail, and it asks for confirmation before the blast.
#
# SMTP auth is read from the environment if set, otherwise you are prompted.
# Credentials are handed to swaks via SWAKS_OPT_* env vars so they never
# appear in the process list (ps) or the command line.
#
# Usage:
#   scripts/notify-usernames.sh                 # dry run: list who would be mailed
#   scripts/notify-usernames.sh --test ME       # send ONE test mail to ME (sample username)
#   scripts/notify-usernames.sh --send          # send to everyone (asks to confirm)
#
# Common options (all have sensible defaults):
#   --send                 actually send to all users (default is dry run)
#   --test ADDR            send a single test message to ADDR and exit
#   --yes                  skip the "send to N users?" confirmation prompt
#   --user-file PATH       parse this file instead of copying from the container
#   --from ADDR            envelope/from address      (default noreply@promethence.com)
#   --server HOST          SMTP relay host            (default smtp-relay.brevo.com)
#   --port N               SMTP port                  (default 587, STARTTLS)
#   --site-name NAME       used in the subject/body   (default: short hostname)
#   --site-url URL         login URL in the body      (default: https://<fqdn>/)
#   --subject TEXT         email subject              (default: "[<site-name>] Your account username")
#   --delay SECONDS        pause between messages     (default 1)
#   --container NAME       authelia container name    (default authelia)
#   --containers-user U    rootless podman owner      (default containers)
#   -h, --help             show this help
#
# Environment (optional; prompted if unset):
#   BREVO_LOGIN   SMTP username
#   BREVO_KEY     SMTP password / API key
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
MODE="dry"                       # dry | send | test
TEST_ADDR=""
ASSUME_YES=0
USER_FILE=""
MAIL_FROM="noreply@promethence.com"
SMTP_SERVER="smtp-relay.brevo.com"
SMTP_PORT="587"
SITE_NAME=""
SITE_URL=""
SUBJECT=""
SEND_DELAY="1"
CONTAINER="authelia"
CONTAINERS_USER="containers"

die() { echo "error: $*" >&2; exit 1; }

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- arg parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --send)            MODE="send" ;;
        --test)            MODE="test"; TEST_ADDR="${2:-}"; shift; [[ -n "$TEST_ADDR" ]] || die "--test needs an address" ;;
        --yes|-y)          ASSUME_YES=1 ;;
        --user-file)       USER_FILE="${2:-}"; shift ;;
        --from)            MAIL_FROM="${2:-}"; shift ;;
        --server)          SMTP_SERVER="${2:-}"; shift ;;
        --port)            SMTP_PORT="${2:-}"; shift ;;
        --site-name)       SITE_NAME="${2:-}"; shift ;;
        --site-url)        SITE_URL="${2:-}"; shift ;;
        --subject)         SUBJECT="${2:-}"; shift ;;
        --delay)           SEND_DELAY="${2:-}"; shift ;;
        --container)       CONTAINER="${2:-}"; shift ;;
        --containers-user) CONTAINERS_USER="${2:-}"; shift ;;
        -h|--help)         usage 0 ;;
        *)                 die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# swaks is only needed to actually send; a dry run must work without it.
[[ "$MODE" == "dry" ]] || command -v swaks >/dev/null \
    || die "swaks is not installed (apt-get install -y swaks)"

# Derive site name/url from the host if not given.
: "${SITE_NAME:=$(hostname -s 2>/dev/null || hostname)}"
: "${SITE_URL:=https://$(hostname -f 2>/dev/null || hostname)/}"
: "${SUBJECT:=[$SITE_NAME] Your account username}"

# ---- obtain the user file ---------------------------------------------------
# Either use a file the caller pointed at, or copy it out of the container.
CLEANUP_FILE=""
cleanup() { [[ -n "$CLEANUP_FILE" ]] && rm -f "$CLEANUP_FILE"; return 0; }
trap cleanup EXIT

if [[ -z "$USER_FILE" ]]; then
    run_podman() {
        sudo -u "$CONTAINERS_USER" \
            XDG_RUNTIME_DIR="/run/user/$(id -u "$CONTAINERS_USER")" \
            podman "$@"
    }
    USER_FILE="$(mktemp)"
    CLEANUP_FILE="$USER_FILE"
    run_podman cp "$CONTAINER:/config/users_database.yml" "$USER_FILE" \
        || die "could not copy users_database.yml from container '$CONTAINER'"
fi
[[ -r "$USER_FILE" ]] || die "user file not readable: $USER_FILE"

# ---- extract username<TAB>email pairs --------------------------------------
# Pattern-based (no YAML parser), so it tolerates values that trip yq. Tracks
# the current username (2-space-indented key) and emits it with the user's
# email line (4-space-indented). Skips users with no email.
extract_pairs() {
    awk '
        /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { u=$1; sub(/:$/,"",u); next }
        /^    email:/ {
            e=$2; gsub(/"/,"",e); gsub(/'\''/,"",e)
            if (u != "" && e != "") { print u "\t" e; u="" }
        }
    ' "$USER_FILE"
}

mapfile -t PAIRS < <(extract_pairs)
[[ ${#PAIRS[@]} -gt 0 ]] || die "no username/email pairs found in $USER_FILE"

# ---- build the message body -------------------------------------------------
# $1 = username. Real newlines (printf), plain text.
build_body() {
    printf 'Hello,\n\nYour username for %s is: %s\n\nTo sign in, follow the instructions at %s\n\nBest,\nSimone\n' \
        "$SITE_NAME" "$1" "$SITE_URL"
}

# ---- dry run: just show the plan -------------------------------------------
if [[ "$MODE" == "dry" ]]; then
    echo "DRY RUN — nothing will be sent. ${#PAIRS[@]} recipient(s):"
    for p in "${PAIRS[@]}"; do
        printf '  %s\t->  %s\n' "${p%%$'\t'*}" "${p#*$'\t'}"
    done
    echo
    echo "From:    $MAIL_FROM"
    echo "Relay:   $SMTP_SERVER:$SMTP_PORT (STARTTLS)"
    echo "Subject: $SUBJECT"
    echo
    echo "Re-run with --test you@example.com to send one, or --send to mail everyone."
    exit 0
fi

# ---- credentials (env or prompt) -------------------------------------------
if [[ -z "${BREVO_LOGIN:-}" ]]; then
    read -rp "SMTP username: " BREVO_LOGIN
    [[ -n "$BREVO_LOGIN" ]] || die "no SMTP username given"
fi
if [[ -z "${BREVO_KEY:-}" ]]; then
    read -rsp "SMTP password / API key: " BREVO_KEY; echo
    [[ -n "$BREVO_KEY" ]] || die "no SMTP password given"
fi
# Pass auth to swaks via the environment so it never lands on the command line.
export SWAKS_OPT_auth_user="$BREVO_LOGIN"
export SWAKS_OPT_auth_password="$BREVO_KEY"

# send_one <to> <username>
send_one() {
    local to="$1" username="$2" body
    body="$(build_body "$username")"
    swaks --to "$to" --from "$MAIL_FROM" \
        --server "$SMTP_SERVER" --port "$SMTP_PORT" --tls --auth LOGIN \
        --header "Subject: $SUBJECT" \
        --body "$body" >/dev/null
}

# ---- test mode: one message, then stop -------------------------------------
if [[ "$MODE" == "test" ]]; then
    echo "Sending one test message to $TEST_ADDR ..."
    if send_one "$TEST_ADDR" "testuser"; then
        echo "OK — check $TEST_ADDR (and its spam folder)."
    else
        die "test send failed — check credentials/relay before using --send"
    fi
    exit 0
fi

# ---- send mode: confirm, then blast ----------------------------------------
if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -rp "About to email ${#PAIRS[@]} user(s) via $SMTP_SERVER. Proceed? [y/N] " ans
    [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]] || { echo "aborted."; exit 1; }
fi

sent=0; failed=0
for p in "${PAIRS[@]}"; do
    username="${p%%$'\t'*}"
    email="${p#*$'\t'}"
    if send_one "$email" "$username"; then
        echo "sent:   $email ($username)"; ((sent++))
    else
        echo "FAILED: $email ($username)" >&2; ((failed++))
    fi
    sleep "$SEND_DELAY"
done

echo
echo "done: $sent sent, $failed failed, ${#PAIRS[@]} total."
[[ "$failed" -eq 0 ]]
