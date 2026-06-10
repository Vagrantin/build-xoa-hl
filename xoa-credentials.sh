#!/bin/bash
# /opt/xoa-credentials.sh
# Phase 2: Updates XO admin credentials using NODE_TLS_REJECT_UNAUTHORIZED=0 xo-cli once xo-server is reachable.
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
    echo "[$(date '+%H:%M:%S')] Writing done flag and disabling service..."
    touch "$DONE_FLAG"
    systemctl disable xoa-credentials.service 2>/dev/null || true
    echo "[$(date '+%H:%M:%S')] xoa-credentials.service disabled. Will not run again."
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

# Register NODE_TLS_REJECT_UNAUTHORIZED=0 xo-cli with bootstrap credentials
NODE_TLS_REJECT_UNAUTHORIZED=0 xo-cli register "$XO_URL" "$BOOTSTRAP_EMAIL" "$BOOTSTRAP_PASSWORD" \
    --accept-unauthorized >> "$LOG" 2>&1 || {
    echo "[$(date)] ERROR: xo-cli registration failed with bootstrap credentials."
    exit 1
}

# Change the password
if [ -n "$NEW_PASSWORD" ]; then
    echo "[$(date)] Updating admin password..."
    NODE_TLS_REJECT_UNAUTHORIZED=0 xo-cli user.changePassword \
        oldPassword="$BOOTSTRAP_PASSWORD" \
        newPassword="$NEW_PASSWORD" >> "$LOG" 2>&1 || \
    echo "[$(date)] WARN: Password change failed (may already be changed)"
fi

# Change the email/login if different from default
if [ -n "$NEW_LOGIN" ] && [ "$NEW_LOGIN" != "$BOOTSTRAP_EMAIL" ]; then
    echo "[$(date)] Updating admin email to $NEW_LOGIN ..."
    # Get the admin user UUID
    USER_UUID=$(NODE_TLS_REJECT_UNAUTHORIZED=0 xo-cli user.getAll 2>/dev/null | \
        python3 -c "import sys,json; users=json.load(sys.stdin); \
        print([u['id'] for u in users.values() if u.get('email')=='${BOOTSTRAP_EMAIL}'][0])" \
        2>/dev/null || echo "")

    if [ -n "$USER_UUID" ]; then
        NODE_TLS_REJECT_UNAUTHORIZED=0 xo-cli user.set id="$USER_UUID" email="$NEW_LOGIN" >> "$LOG" 2>&1 || \
        echo "[$(date)] WARN: Email change failed. Using password-only change."
    fi
fi

# Cleanup secrets from tmpfs
rm -f /run/xoa-provision/admin-login /run/xoa-provision/admin-password

touch "$DONE_FLAG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === xoa-credentials complete ==="
