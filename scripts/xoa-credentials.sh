#!/bin/bash
# /opt/xoa-credentials.sh
# Phase 2: Updates XO admin credentials using xo-cli once xo-server is reachable.
# Runs once after first boot, then disables itself.

LOG="/var/log/xoa-first-boot.log"
DONE_FLAG="/var/lib/xoa-credentials.done"
exec >> "$LOG" 2>&1

# --- Always run on exit: write done flag and disable this service ---
cleanup() {
    local EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        echo "[$(date '+%H:%M:%S')] Script exited with code $EXIT_CODE — credentials may not have been updated."
        echo "[$(date '+%H:%M:%S')] XOA will retain Ronivay default credentials (admin@admin.net / admin)."
        echo "[$(date '+%H:%M:%S')] Change them manually via the XO web UI."
    fi

    echo "[$(date '+%H:%M:%S')] Writing done flag..."
    touch "$DONE_FLAG"

    echo "[$(date '+%H:%M:%S')] Disabling and removing services..."
    systemctl disable xoa-first-boot.service 2>/dev/null || true
    systemctl disable xoa-credentials.service 2>/dev/null || true
    rm -f /etc/systemd/system/xoa-first-boot.service
    rm -f /etc/systemd/system/xoa-credentials.service
    systemctl daemon-reload 2>/dev/null || true

    echo "[$(date '+%H:%M:%S')] Removing env file with secrets..."
    rm -f /etc/xoa-first-boot.env
    rm -f /opt/xoa-first-boot.sh
    rm -f /opt/xoa-credentials.sh

    # Log removal must be last — nothing can be written after this
    echo "[$(date '+%H:%M:%S')] First-boot complete. Removing log."
    # Small delay to flush the echo above before the fd is unlinked
    sync
    #rm -f "$LOG"
    # No echo here — fd is gone
}
trap cleanup EXIT

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === xoa-credentials starting ==="

if [ -f "$DONE_FLAG" ]; then
    echo "[$(date)] Credentials already set. Exiting."
    exit 0
fi

# Read values saved by phase 1
ENV_FILE="/etc/xoa-first-boot.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[$(date)] ERROR: $ENV_FILE not found — xoa-read-xenstore.sh did not run or failed."
    exit 1
fi

echo "[$(date)] Sourcing credentials from $ENV_FILE"
source "$ENV_FILE"

NEW_LOGIN="$XOA_EMAIL"
NEW_PASSWORD="$XOA_PASSWORD"

# Ronivay defaults — used to bootstrap the API connection
BOOTSTRAP_EMAIL="admin@admin.net"
BOOTSTRAP_PASSWORD="admin"
XO_URL="wss://127.0.0.1"

if [ -z "$NEW_LOGIN" ] && [ -z "$NEW_PASSWORD" ]; then
    echo "[$(date)] No admin credentials in xenstore. Skipping."
    touch "$DONE_FLAG"
    exit 0
fi

# Wait for xo-server to be reachable (up to 3 minutes)
echo "[$(date)] Waiting for xo-server on port 443..."
RETRIES=0
until nc -z 127.0.0.1 443 2>/dev/null; do
    sleep 5
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge 36 ]; then
        echo "[$(date)] ERROR: xo-server did not start within 3 minutes."
        exit 1
    fi
done
echo "[$(date)] xo-server is up."
sleep 3  # let it fully initialise

# --- 7. Set SSH password ---
echo ""
echo "[$(date '+%H:%M:%S')] [7/8] Setting SSH system account password..."

if [ -z "$SSH_PASSWORD" ]; then
    echo "[$(date '+%H:%M:%S')] WARN: SSH_PASSWORD is empty — skipping password change."
else
    # Ronivay creates the 'xo' user by default
    SSH_LOGIN="xo"

    if ! id "$SSH_LOGIN" &>/dev/null; then
        echo "[$(date '+%H:%M:%S')] WARN: User '$SSH_LOGIN' does not exist — skipping."
    else
        echo "${SSH_LOGIN}:${SSH_PASSWORD}" | chpasswd
        CHPASSWD_EXIT=$?
        if [ $CHPASSWD_EXIT -eq 0 ]; then
            echo "[$(date '+%H:%M:%S')] SSH password set OK for user: $SSH_LOGIN"
        else
            echo "[$(date '+%H:%M:%S')] ERROR: chpasswd failed with exit code $CHPASSWD_EXIT"
        fi
    fi
fi

# Register xo-cli with bootstrap credentials
xo-cli register --allowUnauthorized "$XO_URL" "$BOOTSTRAP_EMAIL" "$BOOTSTRAP_PASSWORD" \
    >> "$LOG" 2>&1 || {
    echo "[$(date)] ERROR: xo-cli registration failed with bootstrap credentials."
    exit 1
}

# Change the password
if [ -n "$NEW_PASSWORD" ]; then
    echo "[$(date)] Updating admin password..."
    xo-cli user.changePassword \
        oldPassword="$BOOTSTRAP_PASSWORD" \
        newPassword="$NEW_PASSWORD" >> "$LOG" 2>&1 || \
    echo "[$(date)] WARN: Password change failed (may already be changed)"
fi

# Change the email/login if different from default
if [ -n "$NEW_LOGIN" ] && [ "$NEW_LOGIN" != "$BOOTSTRAP_EMAIL" ]; then
    echo "[$(date '+%H:%M:%S')] Updating admin email to: $NEW_LOGIN"

    echo "[$(date '+%H:%M:%S')] Fetching user list..."
    RAW_USERS=$(xo-cli user.getAll 2>&1)
    echo "[$(date '+%H:%M:%S')] user.getAll output:"

    # xo-cli outputs JS object notation (not JSON) — parse with grep/sed
    # Format is:  id: 'b6d07d80-c404-4ac8-96a6-38a2d74551f3',
    USER_UUID=$(echo "$RAW_USERS" \
        | grep -E "^\s+id:" \
        | head -1 \
        | sed "s/.*id: '//;s/'.*//")

    echo "[$(date '+%H:%M:%S')] USER_UUID resolved: '${USER_UUID}'"

    if [ -z "$USER_UUID" ]; then
        echo "[$(date '+%H:%M:%S')] WARN: Could not resolve USER_UUID — email not changed."
    else
        echo "[$(date '+%H:%M:%S')] Calling user.set..."
        xo-cli user.set \
            id="$USER_UUID" \
            email="$NEW_LOGIN" && \
            echo "[$(date '+%H:%M:%S')] Email updated to: $NEW_LOGIN" || \
            echo "[$(date '+%H:%M:%S')] WARN: user.set failed."
    fi
fi
# Cleanup secrets from tmpfs
rm -f /run/xoa-provision/admin-login /run/xoa-provision/admin-password

touch "$DONE_FLAG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === xoa-credentials complete ==="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Cleaning behind me ==="
