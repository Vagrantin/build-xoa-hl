#!/bin/bash
# Setup script for AlmaLinux-based XOA builder
# Similar to setup-xoa-builder.sh but for AlmaLinux
# Runs on Linux Mint build machine
# Generates ks.cfg and almalinux-build.json dynamically

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
echo -e "\n---> Resolving AlmaLinux ISO Checksum..."
if [ -z "$ALMALINUX_ISO_CHECKSUM" ]; then
    echo "---> Attempting to fetch checksum from AlmaLinux mirrors..."
    ISO_FILENAME=$(basename "$ALMALINUX_ISO_URL")
    ISO_BASE_URL=$(dirname "$ALMALINUX_ISO_URL")
    
    # Try CHECKSUM file
    CHECKSUM_CONTENT=$(curl -sSL "${ISO_BASE_URL}/CHECKSUM" 2>/dev/null || echo "")
    if [ -n "$CHECKSUM_CONTENT" ]; then
        RAW_HASH=$(echo "$CHECKSUM_CONTENT" | grep "$ISO_FILENAME" | head -n 1 | awk '{print $1}')
        if [ -n "$RAW_HASH" ]; then
            ALMALINUX_ISO_CHECKSUM="sha256:${RAW_HASH}"
            echo "Successfully parsed checksum: $ALMALINUX_ISO_CHECKSUM"
        fi
    fi
    
    # Try SHA256SUMS file
    if [ -z "$ALMALINUX_ISO_CHECKSUM" ]; then
        CHECKSUM_CONTENT=$(curl -sSL "${ISO_BASE_URL}/SHA256SUMS" 2>/dev/null || echo "")
        if [ -n "$CHECKSUM_CONTENT" ]; then
            RAW_HASH=$(echo "$CHECKSUM_CONTENT" | grep "$ISO_FILENAME" | head -n 1 | awk '{print $1}')
            if [ -n "$RAW_HASH" ]; then
                ALMALINUX_ISO_CHECKSUM="sha256:${RAW_HASH}"
                echo "Successfully parsed checksum from SHA256SUMS: $ALMALINUX_ISO_CHECKSUM"
            fi
        fi
    fi
    
    if [ -z "$ALMALINUX_ISO_CHECKSUM" ]; then
        echo "WARNING: Could not resolve checksum automatically."
        echo "Please provide ALMALINUX_ISO_CHECKSUM in build.config"
        echo "Get it from: https://repo.almalinux.org/almalinux/${ALMALINUX_VERSION}/isos/x86_64/"
        exit 1
    fi
fi

# 8. Create build directory and generate files
echo -e "\n---> Creating Project Directory & Files..."
mkdir -p "$BUILD_DIR/patches"
mkdir -p "$BUILD_DIR/scripts"
cd "$BUILD_DIR"

# Generate ks.cfg with EXT partitioning (not LVM) and all packages
cat > ks.cfg << 'KSEOF'
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
rootpw --plaintext placeholder_password

# System timezone
timezone Asia/Tokyo --isUtc

# System authorization information
auth --enableshadow --passalgo=sha512

# SELinux configuration - DISABLED (as requested)
selinux --disabled

# Firewall configuration
firewall --disabled

# System bootloader configuration
bootloader --location=mbr --boot-drive=sda

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
kexec-tools
chrony
openssh-server
openssh-clients
wget
curl
jq
tar
gzip
xfsprogs
net-tools
iproute
vim-enhanced
procps-ng
lsof
strace
psmisc
# Node.js 22.x dependencies
yum-utils
# For building from source (if needed)
git
make
gcc
gcc-c++
# XOA runtime dependencies
nfs-utils
cifs-utils
lvm2
ntfs-3g
fuse
# Valkey (Redis replacement)
valkey
# Development tools for Node.js native modules
python3
python3-devel
%end

%post --log=/root/ks-post.log

# Ensure SELinux is disabled
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

# Enable and start chrony
systemctl enable chronyd --now

# Enable and start SSH
systemctl enable sshd --now

# Configure SSH for root login (temporary for build)
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Create xo user for XOA
groupadd -f xo
useradd -m -g xo -s /bin/bash xo
echo "xo:placeholder_password" | chpasswd

# Install Node.js 22.x from NodeSource
curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
dnf install -y nodejs

%end
KSEOF

# Copy shared scripts if they exist
for script in xoa-first-boot.sh xoa-credentials.sh xoa-first-boot.service xoa-credentials.service; do
    if [ -f ../$script ]; then
        cp ../$script .
    fi
done

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
        "linux ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg<enter>"
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
        "echo '==> Installing xe-guest-utilities from xenserver.com...'",
        "wget -q https://releases.xenserver.com/packages/main/xe-guest-utilities/xe-guest-utilities-10.0.0-1.el9.x86_64.rpm -O /tmp/xe-guest-utilities.rpm",
        "dnf install -y /tmp/xe-guest-utilities.rpm",
        "rm -f /tmp/xe-guest-utilities.rpm"
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
        "git clone https://github.com/vatesfr/xen-orchestra.git /tmp/xen-orchestra-patched",
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
        "openssl req -x509 -newkey rsa:4096 -keyout /opt/xo/xo.key -out /opt/xo/xo.crt -days 3650 -nodes -subj '/CN=xoa.local'"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Writing xo-install.cfg...'",
        "cat > /tmp/xoa-installer/xo-install.cfg << 'XOEOF'
REPOSITORY="/tmp/xen-orchestra-patched"
BRANCH="master"
SELFUPGRADE="false"
PORT="443"
AUTOCERT="true"
PATH_TO_HTTPS_CERT="/opt/xo/xo.crt"
PATH_TO_HTTPS_KEY="/opt/xo/xo.key"
XOEOF"
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
      "type": "file",
      "source": "xoa-first-boot.sh",
      "destination": "/opt/xoa-first-boot.sh"
    },
    {
      "type": "file",
      "source": "xoa-credentials.sh",
      "destination": "/opt/xoa-credentials.sh"
    },
    {
      "type": "file",
      "source": "xoa-first-boot.service",
      "destination": "/etc/systemd/system/xoa-first-boot.service"
    },
    {
      "type": "file",
      "source": "xoa-credentials.service",
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
        "dnf clean all",
        "rm -rf /tmp/xoa-installer",
        "rm -rf /tmp/xen-orchestra-patched"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Stripping unique system identity...'",
        "echo -n > /etc/machine-id",
        "rm -f /var/lib/dbus/machine-id",
        "ln -s /etc/machine-id /var/lib/dbus/machine-id"
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
echo "  - $BUILD_DIR/ks.cfg (Kickstart with all packages)"
echo "  - $BUILD_DIR/almalinux-build.json (Packer template)"
echo ""
echo "Next steps:"
echo "1. cd $BUILD_DIR"
echo "2. packer validate almalinux-build.json"
echo "3. packer build almalinux-build.json"
echo "4. Check output-xva/ for the XVA image"
echo ""
echo "xe-guest-utilities source: https://releases.xenserver.com/packages/main/xe-guest-utilities/"
echo "Node.js 22.x setup: curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -"
