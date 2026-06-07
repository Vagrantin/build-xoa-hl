#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -e 

# Define the name of the external configuration file
CONFIG_FILE="build.config"

echo "=========================================================="
echo "  XOA-Lite Packer Build Environment Setup for Linux Mint  "
echo "=========================================================="

# 1. Try to load the external config file
if [ -f "$CONFIG_FILE" ]; then
    echo "---> Found external configuration: loading $CONFIG_FILE..."
    # Source the file to import its variables
    source "./$CONFIG_FILE"
else
    echo "---> No external '$CONFIG_FILE' found. Proceeding with fallback defaults."
fi

# 2. Establish fallback values using ${VARIABLE:-DEFAULT} syntax
BUILD_DIR="${BUILD_DIR:-$HOME/xoa-build}"
XCPNG_IP="${XCPNG_IP:-192.168.1.10}"
XCPNG_USER="${XCPNG_USER:-root}"
XCPNG_PASSWORD="${XCPNG_PASSWORD:-YOUR_XCPNG_PASSWORD}"
VM_NETWORK_NAME="${VM_NETWORK_NAME:-Pool-wide network associated with eth0}"
VM_NAME="${VM_NAME:-xoa-community-edition}"
DEBIAN_XO_USER="${DEBIAN_XO_USER:-xo}"
DEBIAN_XO_PASSWORD="${DEBIAN_XO_PASSWORD:-YOUR_SECURE_XO_PASSWORD}"
DEBIAN_ROOT_PASSWORD="${DEBIAN_ROOT_PASSWORD:-YOUR_SECURE_VM_PASSWORD}"
DEBIAN_ISO_URL="${DEBIAN_ISO_URL:-https://cdimage.debian.org/mirror/cdimage/archive/12.5.0/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso}"
# DEBIAN_ISO_CHECKSUM is intentionally left blank here if not provided via config, to be fetched dynamically later.

# 3. Purge any broken legacy files from previous failed runs
sudo rm -f /etc/apt/sources.list.d/hashicorp.list

# 4. Safely extract the upstream Ubuntu base codename (e.g., noble)
echo "---> Detecting upstream OS codename..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    REPO_CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
else
    REPO_CODENAME=$(lsb_release -cs)
fi

if [ "$REPO_CODENAME" = "zara" ]; then
    REPO_CODENAME="noble"
fi

echo "Using upstream repository codename: $REPO_CODENAME"

# 5. Add GPG Key and Repo BEFORE running apt-get update
echo -e "\n---> Preparing Repositories..."
sudo apt-get update || true 
sudo apt-get install -y wget gpg coreutils curl ufw

wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${REPO_CODENAME} main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

# 6. Now run the clean system update and install Packer
echo -e "\n---> Installing HashiCorp Packer..."
sudo apt-get update
sudo apt-get install -y packer

# 7. Install XCP-ng/XenServer Packer Plugin
echo -e "\n---> Installing XCP-ng Packer Plugin..."
packer plugins install github.com/ddelnano/xenserver

# 8. Configure Firewall for Packer HTTP Server
echo -e "\n---> Configuring UFW Firewall (Ports 8000-9000)..."
sudo ufw allow 8000:9000/tcp

# 8.5 Dynamically resolve ISO Checksum if not explicitly predefined
if [ -z "$DEBIAN_ISO_CHECKSUM" ]; then
    echo -e "\n---> Resolving ISO Checksum dynamically..."
    ISO_FILENAME=$(basename "$DEBIAN_ISO_URL")
    ISO_BASE_URL=$(dirname "$DEBIAN_ISO_URL")
    
    # Safely pull the mirror's SHA256SUMS file without breaking on pipeline failures
    SHA256_CONTENT=$(curl -sSL "${ISO_BASE_URL}/SHA256SUMS" || echo "")
    
    if [ -n "$SHA256_CONTENT" ]; then
        RAW_HASH=$(echo "$SHA256_CONTENT" | grep "$ISO_FILENAME" | head -n 1 | awk '{print $1}')
        if [ -n "$RAW_HASH" ]; then
            DEBIAN_ISO_CHECKSUM="sha256:${RAW_HASH}"
            echo "Successfully parsed remote checksum: $DEBIAN_ISO_CHECKSUM"
        fi
    fi

    # Hard safety fallback in case the URL structure doesn't expose a standard SHA256SUMS file
    if [ -z "$DEBIAN_ISO_CHECKSUM" ]; then
        echo "WARNING: Dynamic lookup failed. Falling back to default 12.5.0 static checksum."
        DEBIAN_ISO_CHECKSUM="sha256:7398b688321cb170364d96a77d13ebbf0062b08fa1fb1fb98e21975b9f71c356"
    fi
else
    echo -e "\n---> Using user-defined configuration checksum: $DEBIAN_ISO_CHECKSUM"
fi

# 9. Scaffold the Project Structure
echo -e "\n---> Creating Project Directory & Files..."
mkdir -p "$BUILD_DIR/patches"
cd "$BUILD_DIR"

# Generate preseed.cfg
echo "Generating preseed.cfg..."
cat << EOF > preseed.cfg
# preseed.cfg
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string xoa-base
d-i netcfg/get_domain string local
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-login boolean true
d-i passwd/root-password password ${DEBIAN_ROOT_PASSWORD}
d-i passwd/root-password-again password ${DEBIAN_ROOT_PASSWORD}
d-i passwd/user-fullname string XenOrchestra User
d-i passwd/username string ${DEBIAN_XO_USER}
d-i passwd/user-password password ${DEBIAN_XO_PASSWORD}
d-i passwd/user-password-again password ${DEBIAN_XO_PASSWORD}
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i partman-auto/method string lvm
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i tasksel/first multiselect standard
d-i pkgsel/include string openssh-server sudo
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev  string default
d-i preseed/late_command string in-target sed -i 's/.*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
d-i finish-install/reboot_in_progress note
EOF

# Generate xoa-build.json
echo "Generating xoa-build.json..."
cat << EOF > xoa-build.json
{
  "builders": [
    {
      "type": "xenserver-iso",
      "remote_host": "${XCPNG_IP}",
      "remote_username": "${XCPNG_USER}",
      "remote_password": "${XCPNG_PASSWORD}",
      "iso_url": "${DEBIAN_ISO_URL}",
      "iso_checksum": "${DEBIAN_ISO_CHECKSUM}",
      "sr_name": "Local storage",
      "vm_name": "${VM_NAME}",
      "vm_description": "XOA Community Edition - xo-lite compatible",
      "disk_size": 10000,
      "vm_memory": 2048,
      "http_directory": ".",
      "network_names": ["${VM_NETWORK_NAME}"],
      "boot_command": [
       "<wait5><esc><wait>",
       "install <wait>",
       " url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg <wait>",
       " debian-installer=en_US.UTF-8 <wait>",
       " auto=true <wait>",
       " priority=critical <wait>",
       " locale=en_US.UTF-8 <wait>",
       " keyboard-configuration/xkb-keymap=us <wait>",
       " interface=auto",
       " vga=788 noprompt quiet--- <enter>"
      ],
      "boot_wait": "5s",
      "ssh_username": "root",
      "ssh_password": "${DEBIAN_ROOT_PASSWORD}",
      "ssh_timeout": "30m",
      "format": "xva",
      "output_directory": "output-xva",
      "keep_vm": "never"
    }
  ],
  "provisioners": [
    {
      "type": "shell",
      "inline": [
        "echo '==> Updating base system...'",
        "apt-get update && apt-get upgrade -y",
        "echo '==> Installing dependencies...'",
        "apt-get install -y curl wget sudo vim git jq cloud-init",
        "echo '==> Fetching stable Xen Guest Utilities...'",
        "DOWNLOAD_URL=$(curl -s https://api.github.com/repos/xenserver/xe-guest-utilities/releases/latest | jq -r '.assets[] | select(.name | endswith(\"amd64.deb\")) | .browser_download_url')",
        "wget -q $DOWNLOAD_URL -O /tmp/xe-guest-utilities.deb",
        "dpkg -i /tmp/xe-guest-utilities.deb || apt-get install -f -y",
        "rm -f /tmp/xe-guest-utilities.deb"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Cloning XOA installer...'",
        "git clone https://github.com/ronivay/XenOrchestraInstallerUpdater.git /tmp/xoa-installer",
        "cd /tmp/xoa-installer && git checkout master",
        "chown -R xo:xo /tmp/xoa-installer"
      ]
    },
    {
      "type": "file",
      "source": "patches/",
      "destination": "/tmp/xoa-installer/"
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Running XOA installation (this will take a while)...'",
        "su - xo -c 'cd /tmp/xoa-installer && ./xo-install.sh --oss --non-interactive'",
        "echo '==> Cleaning up install files...'",
        "apt-get clean",
        "rm -rf /tmp/xoa-installer"
      ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Optimizing cloud-init for XCP-ng/xo-lite...'",
        "mkdir -p /etc/cloud/cloud.cfg.d",
        "echo 'datasource_list: [ XenServer, NoCloud, ConfigDrive ]' > /etc/cloud/cloud.cfg.d/90_xcp_datasources.cfg",

        "echo '==> Cleaning network persistent state...'",
        "echo '# Interfaced managed by cloud-init' > /etc/network/interfaces",
        "echo 'auto lo' >> /etc/network/interfaces",
        "echo 'iface lo inet loopback' >> /etc/network/interfaces",

        "echo '==> Stripping unique system identity...'",
        "echo -n > /etc/machine-id",
        "rm -f /var/lib/dbus/machine-id",
        "ln -s /etc/machine-id /var/lib/dbus/machine-id",

        "echo '==> Removing existing SSH host keys...'",
        "rm -f /etc/ssh/ssh_host_*_key*",

        "echo '==> Clearing cloud-init cache cache...'",
        "cloud-init clean --logs --seed"
      ]
    }
  ]
}
EOF

echo -e "\n=========================================================="
echo "  Setup Complete! Your environment is ready.              "
echo "=========================================================="
echo "Next steps:"
echo "1. cd $BUILD_DIR"
echo "2. packer validate xoa-build.json"
echo "3. packer build xoa-build.json"
