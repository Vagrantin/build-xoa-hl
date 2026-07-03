#!/bin/bash
# Setup script for AlmaLinux-based XOA builder
# Similar to setup-xoa-builder.sh but for AlmaLinux
# Runs on Linux Mint build machine
# Generates inst.ks and almalinux-build.json dynamically

set -e

CONFIG_FILE="build.config"

echo "=========================================================="
echo "  XOA-Lite Packer Build Environment Setup for AlmaLinux  "
echo "  Running on Linux Mint build machine                  "
echo "=========================================================="

# 1. Load external config
if [ -f "$CONFIG_FILE" ]; then
    echo "---> Found external configuration: loading $CONFIG_FILE..."
    source "./$CONFIG_FILE"
else
    echo "---> No external '$CONFIG_FILE' found. Proceeding with fallback defaults."
fi

# 2. Establish fallback values
BUILD_DIR="${BUILD_DIR:-$HOME/xoa-almalinux-build}"
XCPNG_IP="${XCPNG_IP:-192.168.1.10}"
XCPNG_USER="${XCPNG_USER:-root}"
XCPNG_PASSWORD="${XCPNG_PASSWORD:-YOUR_XCPNG_PASSWORD}"
VM_NETWORK_NAME="${VM_NETWORK_NAME:-Pool-wide network associated with eth0}"
VM_NAME="${VM_NAME:-xoa-almalinux}"
ALMALINUX_ROOT_PASSWORD="${ALMALINUX_ROOT_PASSWORD:-YOUR_SECURE_VM_PASSWORD}"

# AlmaLinux version - Latest LTS (AlmaLinux 9)
ALMALINUX_VERSION="${ALMALINUX_VERSION:-9}"
ALMALINUX_ISO_URL="${ALMALINUX_ISO_URL:-https://repo.almalinux.org/almalinux/${ALMALINUX_VERSION}/isos/x86_64/AlmaLinux-${ALMALINUX_VERSION}-latest-x86_64-minimal.iso}"
ALMALINUX_ISO_CHECKSUM="${ALMALINUX_ISO_CHECKSUM:-}"

echo "---> Using AlmaLinux version: $ALMALINUX_VERSION (Latest LTS)"
echo "---> ISO URL: $ALMALINUX_ISO_URL"

# 3. Install prerequisites
echo -e "\n---> Installing prerequisites..."
sudo apt-get update || true
sudo apt-get install -y wget gpg coreutils curl ufw jq

# 4. Install Packer
echo -e "\n---> Installing HashiCorp Packer..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    REPO_CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
else
    REPO_CODENAME=$(lsb_release -cs)
fi

if [ "$REPO_CODENAME" = "zara" ]; then
    REPO_CODENAME="noble"
fi

wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${REPO_CODENAME} main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update
sudo apt-get install -y packer

# 5. Install XCP-ng Packer Plugin
echo -e "\n---> Installing XCP-ng Packer Plugin..."
packer plugins install github.com/ddelnano/xenserver

# 6. Configure Firewall
echo -e "\n---> Configuring UFW Firewall (Ports 8000-9000)..."
sudo ufw allow 8000:9000/tcp

# 7. Resolve ISO Checksum
# 7. Resolve ISO Checksum
echo -e "\n---> Resolving AlmaLinux ISO Checksum..."
if [ -z "$ALMALINUX_ISO_CHECKSUM" ]; then
    echo "---> Attempting to fetch checksum from AlmaLinux mirrors..."
    ISO_FILENAME=$(basename "$ALMALINUX_ISO_URL")
    ISO_BASE_URL=$(dirname "$ALMALINUX_ISO_URL")

    _validate_hash() {
        # Accept only 64-char lowercase hex (SHA256)
        echo "$1" | grep -qE '^[a-f0-9]{64}$'
    }

    # Try BSD-style CHECKSUM file:
    #   # SHA256 (AlmaLinux-9-...-minimal.iso) = <hash>
    CHECKSUM_CONTENT=$(curl -sSL "${ISO_BASE_URL}/CHECKSUM" 2>/dev/null || true)
    if [ -n "$CHECKSUM_CONTENT" ]; then
        RAW_HASH=$(echo "$CHECKSUM_CONTENT" \
            | grep "($ISO_FILENAME)" \
            | head -n 1 \
            | awk '{print $NF}')          # hash is the LAST field in BSD format
        if _validate_hash "$RAW_HASH"; then
            ALMALINUX_ISO_CHECKSUM="sha256:${RAW_HASH}"
            echo "Successfully parsed checksum (CHECKSUM): $ALMALINUX_ISO_CHECKSUM"
        fi
    fi

    # Fallback: GNU-style SHA256SUMS file:
    #   <hash>  AlmaLinux-9-...-minimal.iso
    if [ -z "$ALMALINUX_ISO_CHECKSUM" ]; then
        CHECKSUM_CONTENT=$(curl -sSL "${ISO_BASE_URL}/SHA256SUMS" 2>/dev/null || true)
        if [ -n "$CHECKSUM_CONTENT" ]; then
            RAW_HASH=$(echo "$CHECKSUM_CONTENT" \
                | grep -E "^[a-f0-9]" \
                | grep "$ISO_FILENAME" \
                | head -n 1 \
                | awk '{print $1}')       # hash is the FIRST field in GNU format
            if _validate_hash "$RAW_HASH"; then
                ALMALINUX_ISO_CHECKSUM="sha256:${RAW_HASH}"
                echo "Successfully parsed checksum (SHA256SUMS): $ALMALINUX_ISO_CHECKSUM"
            fi
        fi
    fi

    if [ -z "$ALMALINUX_ISO_CHECKSUM" ]; then
        echo "ERROR: Could not resolve checksum automatically."
        echo "Get it from: https://repo.almalinux.org/almalinux/${ALMALINUX_VERSION}/isos/x86_64/"
        exit 1
    fi
fi
# 8. Create build directory and generate files
echo -e "\n---> Creating Project Directory & Files..."
mkdir -p "$BUILD_DIR/patches"
mkdir -p "$BUILD_DIR/scripts"
cd "$BUILD_DIR"

# Generate inst.ks with EXT partitioning (not LVM) and all packages
cat << KSEOF > inst.ks
# AlmaLinux 9 Minimal Kickstart Configuration
# Target: Minimal install for XOA
# POC: SELinux disabled, DHCP network, EXT filesystem

# System language
lang en_US.UTF-8

# Keyboard layout
keyboard us

# Network configuration - DHCP only (as requested)
network --onboot yes --device eth0 --bootproto dhcp

# Root password (will be replaced by Packer)
rootpw --plaintext ${ALMALINUX_ROOT_PASSWORD}

# System timezone
timezone Asia/Tokyo --utc

# SELinux configuration - DISABLED (as requested)
selinux --disabled

# Firewall configuration
firewall --disabled

# System bootloader configuration
bootloader --location=mbr --boot-drive=xvda

# Clear the Master Boot Record
zerombr

# Partition clearing information
clearpart --all --initlabel

# Disk partitioning - EXT (not LVM, as requested)
part /boot --fstype="ext4" --size=1024
part / --fstype="ext4" --size=1 --grow

# Reboot after installation
reboot

%packages
@^minimal-environment
@core
chrony
openssh-server
openssh-clients
curl
tar
net-tools
iproute
%end

%post --log=/root/ks-post.log

# Ensure SELinux is disabled
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

systemctl disable network 2>/dev/null || true
systemctl enable NetworkManager --now

# Configure SSH for root login (temporary for build)
systemctl enable sshd --now
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

systemctl enable chronyd --now

# Install extra package not in base repo
dnf install -y epel-release
dnf install -y wget git
systemctl enable chronyd

# Create xo user for XOA
groupadd -f xo
useradd -m -g xo -s /bin/bash xo
usermod -aG wheel xo

%end
KSEOF

# Generate almalinux-build.json
cat > almalinux-build.json << PACKEREOF
{
  "builders": [
    {
      "type": "xenserver-iso",
      "remote_host": "$XCPNG_IP",
      "remote_username": "$XCPNG_USER",
      "remote_password": "$XCPNG_PASSWORD",
      "iso_url": "$ALMALINUX_ISO_URL",
      "iso_checksum": "$ALMALINUX_ISO_CHECKSUM",
      "sr_name": "Local storage",
      "vm_name": "$VM_NAME",
      "vm_description": "XOA Community Edition - AlmaLinux $ALMALINUX_VERSION - xo-lite compatible",
      "disk_size": 10000,
      "vm_memory": 4096,
      "http_directory": ".",
      "network_names": ["$VM_NETWORK_NAME"],
      "boot_command": [
        "<wait5><esc><wait>",
        "linux inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/inst.ks inst.text<enter>"
      ],
      "boot_wait": "5s",
      "ssh_username": "root",
      "ssh_password": "$ALMALINUX_ROOT_PASSWORD",
      "ssh_timeout": "30m",
      "format": "xva_compressed",
      "keep_vm": "always",
      "skip_set_template": "true"
    }
  ],
  "provisioners": [
    {
      "type": "shell",
      "inline": [
        "echo '==> Updating base system...'",
        "dnf update -y"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Installing xe-guest-utilities from github xenserver...'",
        "wget -q ${XE_GUEST_UTILITIES_URL} -O /tmp/xe-guest-utilities.rpm",
        "wget -q ${XE_GUEST_UTILITIES_XENSTORE_URL} -O /tmp/xe-guest-utilities-xenstore.rpm",
        "dnf install -y /tmp/xe-guest-utilities.rpm",
        "dnf install -y /tmp/xe-guest-utilities-xenstore.rpm",
        "rm -f /tmp/xe-guest-utilities.rpm",
        "rm -f /tmp/xe-guest-utilities-xenstore.rpm"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Cloning XOA installer...'",
        "git clone https://github.com/ronivay/XenOrchestraInstallerUpdater.git /tmp/xoa-installer",
        "cd /tmp/xoa-installer && git checkout master"
      ]
    },
    {
      "type": "file",
      "source": "patches/menu-hide-items.patch",
      "destination": "/tmp/xoa-installer/"
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Cloning xen-orchestra source...'",
        "git clone --depth 1 https://github.com/vatesfr/xen-orchestra.git /tmp/xen-orchestra-patched",
        "cd /tmp/xen-orchestra-patched && git config user.name 'Packer Builder' && git config user.email 'packer@internal'",
        "echo '==> Applying custom design patch...'",
        "cd /tmp/xen-orchestra-patched && git apply /tmp/xoa-installer/menu-hide-items.patch",
        "cd /tmp/xen-orchestra-patched && git add -A && git commit -m 'Apply custom design patch'"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Generating self-signed TLS certificate...'",
        "mkdir -p /opt/xo",
        "openssl req -x509 -newkey rsa:4096 -keyout /opt/xo/xohl.key -out /opt/xo/xohl.crt -days 3650 -nodes -subj '/CN=xoa.local'"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Writing xo-install.cfg...'",
        "echo 'REPOSITORY=\"/tmp/xen-orchestra-patched\"' > /tmp/xoa-installer/xo-install.cfg",
        "echo 'BRANCH=\"master\"'                        >> /tmp/xoa-installer/xo-install.cfg",
        "echo 'SELFUPGRADE=\"false\"'                    >> /tmp/xoa-installer/xo-install.cfg",
        "echo 'PORT=\"443\"'                             >> /tmp/xoa-installer/xo-install.cfg",
        "echo 'AUTOCERT=\"true\"'                        >> /tmp/xoa-installer/xo-install.cfg",
        "echo 'PATH_TO_HTTPS_CERT=\"/opt/xo/xohl.crt\"'  >> /tmp/xoa-installer/xo-install.cfg",
        "echo 'PATH_TO_HTTPS_KEY=\"/opt/xo/xohl.key\"'   >> /tmp/xoa-installer/xo-install.cfg"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Running XOA installation...'",
        "cd /tmp/xoa-installer && ./xo-install.sh --install"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "cd /opt/xo/xo-builds/xen-orchestra-*/ && yarn install --production --ignore-scripts --prefer-offline || true"
      ]
    },
    {
      "type": "file",
      "source": "scripts/xoa-first-boot.sh",
      "destination": "/opt/xoa-first-boot.sh"
    },
    {
      "type": "file",
      "source": "scripts/xoa-credentials.sh",
      "destination": "/opt/xoa-credentials.sh"
    },
    {
      "type": "file",
      "source": "systemd/xoa-first-boot.service",
      "destination": "/etc/systemd/system/xoa-first-boot.service"
    },
    {
      "type": "file",
      "source": "systemd/xoa-credentials.service",
      "destination": "/etc/systemd/system/xoa-credentials.service"
    },
    {
      "type": "shell",
      "inline": [
        "chmod +x /opt/xoa-first-boot.sh /opt/xoa-credentials.sh",
        "systemctl daemon-reload",
        "systemctl enable xoa-first-boot.service xoa-credentials.service"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Cleaning up...'",
	"dnf remove -y iwl100-firmware iwl1000-firmware iwl105-firmware \
  iwl135-firmware iwl2000-firmware iwl2030-firmware iwl3160-firmware \
  iwl5000-firmware iwl5150-firmware iwl6000g2a-firmware \
  iwl6050-firmware iwl7260-firmware",
	"dnf remove -y gcc gcc-c++ cpp binutils binutils-gold make patch \
  git git-core git-core-doc \
  glibc-devel glibc-headers kernel-headers kernel-tools kernel-tools-libs \
  libxcrypt-devel openssl-devel libpng-devel zlib-devel libstdc++-devel \
  yarn",
	"dnf remove -y firewalld firewalld-filesystem python3-firewall python3-nftables \
  NetworkManager-team teamd libteam NetworkManager-tui \
  sssd-client sssd-common sssd-kcm sssd-nfs-idmap \
  quota quota-nls irqbalance microcode_ctl \
  rsyslog rsyslog-logrotate \
  man-db groff-base info \
  lshw lsscsi sg3_utils sg3_utils-libs pciutils-libs ethtool \
  dracut-config-rescue",
	"dnf remove -y selinux-policy selinux-policy-targeted policycoreutils",
	"dnf autoremove -y",
        "dnf clean all",
	"rm -rf /var/cache/dnf/ /var/log/*.log",
        "rm -rf /tmp/xoa-installer",
        "rm -rf /opt/xo/xo-src/",
        "rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*",
        "find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' -exec rm -rf {} +",
        "rm -rf /usr/share/i18n/locales",
        "rm -rf /tmp/xen-orchestra-patched"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "find /opt/xo/xo-builds/*/packages/xo-web/dist -name '*.map' -delete"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Stripping unique system identity...'",
        "echo /etc/machine-id",
        "echo -n > /etc/machine-id",
        "echo /etc/machine-id"
      ]
    }
  ]
}
PACKEREOF

echo -e "\n=========================================================="
echo "  Setup Complete! Your AlmaLinux environment is ready.   "
echo "=========================================================="
echo ""
echo "Build machine: Linux Mint (as requested)"
echo "Target OS: AlmaLinux $ALMALINUX_VERSION (Latest LTS)"
echo "Filesystem: EXT (not LVM, as requested)"
echo "Node.js: v22.x (minimum requirement)"
echo ""
echo "Generated files:"
echo "  - $BUILD_DIR/inst.ks (Kickstart with all packages)"
echo "  - $BUILD_DIR/almalinux-build.json (Packer template)"
echo ""
echo "Next steps:"
echo "1. cd $BUILD_DIR"
echo "2. packer validate almalinux-build.json"
echo "3. packer build almalinux-build.json"
echo "4. Check output-xva/ for the XVA image"
echo ""
cd "$BUILD_DIR"
pwd
packer validate almalinux-build.json
PACKER_LOG=1 packer build almalinux-build.json
echo "xe-guest-utilities source: https://releases.xenserver.com/packages/main/xe-guest-utilities/"
echo "Node.js 22.x setup: curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -"
