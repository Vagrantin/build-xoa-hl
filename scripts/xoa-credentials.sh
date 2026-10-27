#!/bin/bash
# Phase 2: retryable provisioning. Completion always follows durable credentials.
set -euo pipefail
umask 077
LOG="/var/log/xoa-first-boot.log"
DONE_FLAG="/var/lib/xoa-credentials.done"
ENV_FILE="/etc/xoa-first-boot.env"
exec >> "$LOG" 2>&1

cleanup() {
    local result=$?
    if [ "$result" -ne 0 ]; then
        echo 'Credential provisioning failed; retained root-only retry state. Inspect service status and retry.'
    fi
}
trap cleanup EXIT

finish() {
    rm -f "$ENV_FILE" /run/xoa-provision/admin-login /run/xoa-provision/admin-password
    sync -f /etc
    systemctl disable xoa-first-boot.service xoa-credentials.service
}

if [ -f "$DONE_FLAG" ]; then
    finish
    exit 0
fi
[ -f "$ENV_FILE" ] || { echo 'Missing provisioning envelope'; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"
XOA_EMAIL=$(printf '%s' "$XOA_EMAIL" | base64 -d)
XOA_PASSWORD=$(printf '%s' "$XOA_PASSWORD" | base64 -d)
SSH_PASSWORD=$(printf '%s' "$SSH_PASSWORD" | base64 -d)
[ -n "$XOA_EMAIL" ] && [ -n "$XOA_PASSWORD" ] || { echo 'Missing admin credentials'; exit 1; }
# chpasswd accepts records separated by newlines. Reject injected records.
[[ "$SSH_PASSWORD" != *$'\n'* && "$SSH_PASSWORD" != *$'\r'* ]] || exit 1

for ((attempt=0; attempt<36; attempt++)); do
    if nc -z 127.0.0.1 443 2>/dev/null; then break; fi
    sleep 5
done
[ "$attempt" -lt 36 ] || { echo 'XO did not become reachable'; exit 1; }

redis_ok() {
    local reply
    reply=$(redis-cli --raw "$@")
    [ "$reply" = OK ] || { echo 'Redis durability operation failed'; return 1; }
}
[ "$(redis-cli --raw CONFIG GET appendonly | tail -n1)" = yes ] || {
    echo 'Redis AOF must be enabled before provisioning'; exit 1;
}
# AOF is authoritative on restart. SAVE alone cannot protect pending AOF writes.
redis_ok CONFIG SET appendfsync always

if [ -n "$SSH_PASSWORD" ]; then
    id xo >/dev/null
    printf 'xo:%s\n' "$SSH_PASSWORD" | chpasswd
fi

# The helper recognizes intermediate password/email changes on retry. Never
# print API error payloads, which can echo supplied parameters.
XOA_EMAIL="$XOA_EMAIL" XOA_PASSWORD="$XOA_PASSWORD" \
    NODE_TLS_REJECT_UNAUTHORIZED=0 node /root/xoa-apply-credentials.mjs

redis_ok SAVE
redis_ok CONFIG SET appendfsync everysec
# Credentials (including /etc/shadow) must reach disk before the done flag.
sync
touch "$DONE_FLAG"
sync -f "$DONE_FLAG"
finish
echo 'Credential provisioning complete; Redis saved and secrets removed.'
