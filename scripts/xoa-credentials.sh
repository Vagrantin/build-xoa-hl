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
# shellcheck source=/dev/null # written at first boot by xoa-first-boot.sh
source "$ENV_FILE"

# Values were base64-encoded on write; decode before use.
XOA_EMAIL=$(printf '%s' "$XOA_EMAIL" | base64 -d)
XOA_PASSWORD=$(printf '%s' "$XOA_PASSWORD" | base64 -d)
SSH_PASSWORD=$(printf '%s' "$SSH_PASSWORD" | base64 -d)

NEW_LOGIN="$XOA_EMAIL"
NEW_PASSWORD="$XOA_PASSWORD"

DEFAULT_EMAIL="admin@admin.net"
DEFAULT_PASSWORD="admin"
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

# --- 8. Set admin email and password ---
# JSON-RPC, not xo-cli: xo-cli turns the passwords "true"/"false" into booleans (xcp-hl#12).
echo ""
echo "[$(date '+%H:%M:%S')] [8/8] Applying admin credentials..."

if ! XO_API_URL="${XO_URL}/api/" DEFAULT_EMAIL="$DEFAULT_EMAIL" DEFAULT_PASSWORD="$DEFAULT_PASSWORD" \
    NEW_LOGIN="$NEW_LOGIN" NEW_PASSWORD="$NEW_PASSWORD" NODE_TLS_REJECT_UNAUTHORIZED=0 \
    node --input-type=module - <<'EOF'
const env = process.env
const ws = new WebSocket(env.XO_API_URL)
const pending = new Map()
let nextId = 0

const call = (method, params) =>
  new Promise((resolve, reject) => {
    const id = ++nextId
    pending.set(id, { resolve, reject })
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }))
  })

// Notifications carry no id and are ignored.
ws.onmessage = event => {
  const msg = JSON.parse(event.data)
  const waiter = msg.id !== undefined && pending.get(msg.id)
  if (!waiter) return
  pending.delete(msg.id)
  if (msg.error) waiter.reject(new Error(JSON.stringify(msg.error)))
  else waiter.resolve(msg.result)
}

ws.onerror = () => {
  console.error(`cannot reach ${env.XO_API_URL}`)
  process.exit(1)
}

ws.onopen = async () => {
  try {
    const user = await call('session.signIn', { email: env.DEFAULT_EMAIL, password: env.DEFAULT_PASSWORD })
    console.log(`Signed in as ${env.DEFAULT_EMAIL}`)
    if (env.NEW_PASSWORD) {
      await call('user.changePassword', { oldPassword: env.DEFAULT_PASSWORD, newPassword: env.NEW_PASSWORD })
      console.log('Admin password updated')
    }
    if (env.NEW_LOGIN && env.NEW_LOGIN !== env.DEFAULT_EMAIL) {
      await call('user.set', { id: user.id, email: env.NEW_LOGIN })
      console.log(`Admin email updated to: ${env.NEW_LOGIN}`)
    }
    process.exit(0)
  } catch (err) {
    console.error(err.message)
    process.exit(1)
  }
}
EOF
then
    echo "[$(date '+%H:%M:%S')] ERROR: applying admin credentials failed."
    exit 1
fi
# Cleanup secrets from tmpfs
rm -f /run/xoa-provision/admin-login /run/xoa-provision/admin-password

touch "$DONE_FLAG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === xoa-credentials complete ==="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Cleaning behind me ==="
