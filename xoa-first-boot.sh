#!/bin/bash
# /opt/xoa-read-xenstore.sh
# Reads XO-Lite xenstore provisioning data with verbose diagnostic logging.

LOG="/var/log/xoa-first-boot.log"
exec >> "$LOG" 2>&1

# --- Separator for multi-boot log readability ---
echo ""
echo "============================================================"
echo " xoa-read-xenstore  started at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " kernel : $(uname -r)"
echo " uptime : $(uptime)"
echo "============================================================"

# --- xenbus / xenstore availability check ---
echo ""
echo "[$(date '+%H:%M:%S')] [1/6] Checking xenstore prerequisites..."

if ! command -v xenstore-read &>/dev/null; then
    echo "[$(date '+%H:%M:%S')] FATAL: xenstore-read not found in PATH=$(echo $PATH)"
    echo "[$(date '+%H:%M:%S')] Is xe-guest-utilities installed and running?"
    systemctl status xe-linux-distribution 2>&1 || echo "(systemctl failed)"
    exit 1
fi
echo "[$(date '+%H:%M:%S')] xenstore-read binary : $(command -v xenstore-read)"
echo "[$(date '+%H:%M:%S')] xe-guest-utilities   : $(dpkg -l xe-guest-utilities 2>/dev/null | awk '/^ii/{print $3}' || echo 'not found via dpkg')"

# Check xenbus device node
if [ -e /dev/xen/xenbus ]; then
    echo "[$(date '+%H:%M:%S')] /dev/xen/xenbus      : present"
elif [ -e /proc/xen/xenbus ]; then
    echo "[$(date '+%H:%M:%S')] /proc/xen/xenbus     : present (legacy path)"
else
    echo "[$(date '+%H:%M:%S')] WARNING: neither /dev/xen/xenbus nor /proc/xen/xenbus found"
    echo "[$(date '+%H:%M:%S')] xen kernel modules:"
    lsmod | grep xen || echo "  (none loaded)"
fi

# --- domid resolution ---
echo ""
echo "[$(date '+%H:%M:%S')] [2/6] Resolving domid..."

DOMID=$(xenstore-read domid 2>&1)
XS_DOMID_EXIT=$?
echo "[$(date '+%H:%M:%S')] xenstore-read domid exit_code=$XS_DOMID_EXIT value='$DOMID'"

if [ $XS_DOMID_EXIT -ne 0 ] || [ -z "$DOMID" ]; then
    echo "[$(date '+%H:%M:%S')] FATAL: Could not read domid from xenstore."
    echo "[$(date '+%H:%M:%S')] xe-linux-distribution service status:"
    systemctl status xe-linux-distribution --no-pager 2>&1 || true
    exit 1
fi
echo "[$(date '+%H:%M:%S')] domid resolved : $DOMID"

XS_BASE="/local/domain/$DOMID/vm-data"
echo "[$(date '+%H:%M:%S')] xenstore base path : $XS_BASE"

# --- Raw xenstore dump ---
echo ""
echo "[$(date '+%H:%M:%S')] [3/6] Raw xenstore dump of entire /local/domain/$DOMID/ ..."

# xenstore-ls the parent to see what nodes exist at all
echo "[$(date '+%H:%M:%S')] --- xenstore-ls /local/domain/$DOMID ---"
xenstore-ls /local/domain/$DOMID 2>&1 || \
    echo "[$(date '+%H:%M:%S')] WARNING: xenstore-ls on domain root failed (EINVAL is normal if no explicit dir node)"

echo "[$(date '+%H:%M:%S')] --- xenstore-ls $XS_BASE ---"
xenstore-ls "$XS_BASE" 2>&1 || \
    echo "[$(date '+%H:%M:%S')] WARNING: xenstore-ls on vm-data failed — reading leaf keys directly instead"

# --- Key reading ---
echo ""
echo "[$(date '+%H:%M:%S')] [4/6] Reading individual keys..."

# xs_read: reads a key, logs raw exit code and raw value length for diagnostics
xs_read() {
    local KEY="$1"
    local FULL_PATH="${XS_BASE}/${KEY}"
    local RAW_VALUE
    local EXIT_CODE

    RAW_VALUE=$(xenstore-read "$FULL_PATH" 2>&1)
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        echo "[$(date '+%H:%M:%S')]   READ OK  : $KEY (${#RAW_VALUE} bytes)" >&2
        echo "$RAW_VALUE"
    else
        echo "[$(date '+%H:%M:%S')]   READ FAIL: $KEY → exit=$EXIT_CODE msg='$RAW_VALUE'" >&2
        echo ""
    fi
}

# Known flat keys
IP=$(xs_read "ip")
NETMASK=$(xs_read "netmask")
GATEWAY=$(xs_read "gateway")
DNS=$(xs_read "dns")
NTP=$(xs_read "ntp-servers")
SSH_PASSWORD=$(xs_read "system-account-xoa-password")

# JSON blob key
ADMIN_ACCOUNT_JSON=$(xs_read "admin-account")

# Probe for any unexpected keys XO-Lite might add in future versions
echo "[$(date '+%H:%M:%S')]   Probing additional known candidate keys..."
for CANDIDATE in hostname domain nameservers mtu network-ref ssl-verify \
                 ssh-login ssh-password xoa-admin-login xoa-admin-password \
                 system-account-ssh-login; do
    VAL=$(xenstore-read "${XS_BASE}/${CANDIDATE}" 2>/dev/null || echo "")
    if [ -n "$VAL" ]; then
        echo "[$(date '+%H:%M:%S')]   UNEXPECTED KEY FOUND: $CANDIDATE = $VAL"
    fi
done

# --- JSON parsing ---
echo ""
echo "[$(date '+%H:%M:%S')] [5/6] Parsing admin-account JSON blob..."

if [ -z "$ADMIN_ACCOUNT_JSON" ]; then
    echo "[$(date '+%H:%M:%S')] WARNING: admin-account key is empty — JSON parse skipped"
    XOA_EMAIL=""
    XOA_PASSWORD=""
else
    echo "[$(date '+%H:%M:%S')] admin-account raw length : ${#ADMIN_ACCOUNT_JSON} bytes"
    # Print with password masked
    MASKED=$(echo "$ADMIN_ACCOUNT_JSON" | \
        python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    d['password'] = '***masked***'
    print(json.dumps(d))
except Exception as e:
    print('JSON parse error: ' + str(e))
" 2>/dev/null)
    echo "[$(date '+%H:%M:%S')] admin-account masked     : $MASKED"

    # Check python3 availability
    if ! command -v python3 &>/dev/null; then
        echo "[$(date '+%H:%M:%S')] FATAL: python3 not found — cannot parse JSON"
        exit 1
    fi
    echo "[$(date '+%H:%M:%S')] python3 version : $(python3 --version 2>&1)"

    XOA_EMAIL=$(echo "$ADMIN_ACCOUNT_JSON" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('email',''))" \
        2>/dev/null || echo "")
    XOA_PASSWORD=$(echo "$ADMIN_ACCOUNT_JSON" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('password',''))" \
        2>/dev/null || echo "")

    [ -n "$XOA_EMAIL" ]    && echo "[$(date '+%H:%M:%S')] email parsed OK : $XOA_EMAIL" \
                           || echo "[$(date '+%H:%M:%S')] WARNING: email field empty after parse"
    [ -n "$XOA_PASSWORD" ] && echo "[$(date '+%H:%M:%S')] password parsed OK : (set, ${#XOA_PASSWORD} chars)" \
                           || echo "[$(date '+%H:%M:%S')] WARNING: password field empty after parse"
fi

# --- Summary and env file ---
echo ""
echo "[$(date '+%H:%M:%S')] [6/6] Summary and persisting env file..."
echo "[$(date '+%H:%M:%S')] ip           : ${IP:-(empty → DHCP)}"
echo "[$(date '+%H:%M:%S')] netmask      : ${NETMASK:-(empty)}"
echo "[$(date '+%H:%M:%S')] gateway      : ${GATEWAY:-(empty)}"
echo "[$(date '+%H:%M:%S')] dns          : ${DNS:-(empty)}"
echo "[$(date '+%H:%M:%S')] ntp          : ${NTP:-(empty)}"
echo "[$(date '+%H:%M:%S')] xoa_email    : ${XOA_EMAIL:-(not set)}"
echo "[$(date '+%H:%M:%S')] xoa_password : ${XOA_PASSWORD:+(set, ${#XOA_PASSWORD} chars)}"
[ -z "$XOA_PASSWORD" ]  && echo "[$(date '+%H:%M:%S')] xoa_password : (not set)"
echo "[$(date '+%H:%M:%S')] ssh_password : ${SSH_PASSWORD:+(set, ${#SSH_PASSWORD} chars)}"
[ -z "$SSH_PASSWORD" ]  && echo "[$(date '+%H:%M:%S')] ssh_password : (not set)"

# Validation pass/fail before writing env file
ERRORS=0
[ -z "$ADMIN_ACCOUNT_JSON" ] && echo "[$(date '+%H:%M:%S')] FAIL: admin-account missing"       && ERRORS=$((ERRORS+1))
[ -z "$XOA_EMAIL" ]          && echo "[$(date '+%H:%M:%S')] FAIL: xoa email empty"             && ERRORS=$((ERRORS+1))
[ -z "$XOA_PASSWORD" ]       && echo "[$(date '+%H:%M:%S')] FAIL: xoa password empty"          && ERRORS=$((ERRORS+1))
[ -z "$SSH_PASSWORD" ]       && echo "[$(date '+%H:%M:%S')] FAIL: system-account-xoa-password missing" && ERRORS=$((ERRORS+1))
[ "$ERRORS" -eq 0 ]          && echo "[$(date '+%H:%M:%S')] PASS: all expected keys present ($ERRORS errors)"

cat > /etc/xoa-first-boot.env << ENVEOF
IP="${IP}"
NETMASK="${NETMASK}"
GATEWAY="${GATEWAY}"
DNS="${DNS}"
NTP="${NTP}"
XOA_EMAIL="${XOA_EMAIL}"
XOA_PASSWORD="${XOA_PASSWORD}"
SSH_PASSWORD="${SSH_PASSWORD}"
ENVEOF
chmod 600 /etc/xoa-first-boot.env

echo "[$(date '+%H:%M:%S')] env file written : /etc/xoa-first-boot.env ($(wc -l < /etc/xoa-first-boot.env) lines)"

# --- 7. Write NetworkManager keyfile ---
echo ""
echo "[$(date '+%H:%M:%S')] [7/7] Writing NetworkManager keyfile..."

NM_CONN_DIR="/etc/NetworkManager/system-connections"
NM_CONN_FILE="${NM_CONN_DIR}/xoa-provisioned.nmconnection"
mkdir -p "$NM_CONN_DIR"

CONN_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
echo "[$(date '+%H:%M:%S')] Connection UUID : $CONN_UUID"

if [ -z "$IP" ]; then
    echo "[$(date '+%H:%M:%S')] No IP set → writing DHCP keyfile"
    cat > "$NM_CONN_FILE" << NMEOF
[connection]
id=xoa-provisioned
uuid=${CONN_UUID}
type=ethernet
autoconnect=true
autoconnect-priority=100

[ethernet]

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
NMEOF

else
    # Convert dotted netmask to CIDR prefix length
    CIDR=$(python3 -c "
import ipaddress
print(ipaddress.IPv4Network('0.0.0.0/${NETMASK}', strict=False).prefixlen)
" 2>/dev/null || echo "24")

    # NM dns format: semicolon-separated with trailing semicolon
    DNS_NM="${DNS};"

    echo "[$(date '+%H:%M:%S')] Static IP  : ${IP}/${CIDR}"
    echo "[$(date '+%H:%M:%S')] Gateway    : ${GATEWAY}"
    echo "[$(date '+%H:%M:%S')] DNS        : ${DNS_NM}"

    cat > "$NM_CONN_FILE" << NMEOF
[connection]
id=xoa-provisioned
uuid=${CONN_UUID}
type=ethernet
autoconnect=true
autoconnect-priority=100

[ethernet]

[ipv4]
method=manual
address1=${IP}/${CIDR},${GATEWAY}
dns=${DNS_NM}

[ipv6]
method=ignore
NMEOF
fi

# NM refuses to load keyfiles that are not chmod 600
chmod 600 "$NM_CONN_FILE"
echo "[$(date '+%H:%M:%S')] NM keyfile written : $NM_CONN_FILE"
echo "[$(date '+%H:%M:%S')] NM keyfile content :"
cat "$NM_CONN_FILE"
echo "============================================================"
echo " xoa-read-xenstore  finished at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "============================================================"
