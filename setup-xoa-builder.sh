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
#DEBIAN_ISO_URL="${DEBIAN_ISO_URL:-https://ftp.jaist.ac.jp/pub/Linux/debian-cd/current/amd64/iso-cd/debian-12.12.0-amd64-netinst.iso}"
DEBIAN_ISO_URL="${DEBIAN_ISO_URL:-https://ftp.jaist.ac.jp/pub/Linux/debian-cd/current/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso}"

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
    
    SHA256_CONTENT=$(curl -sSL "${ISO_BASE_URL}/SHA256SUMS" || echo "")
    if [ -n "$SHA256_CONTENT" ]; then
        RAW_HASH=$(echo "$SHA256_CONTENT" | grep "$ISO_FILENAME" | head -n 1 | awk '{print $1}')
        if [ -n "$RAW_HASH" ]; then
            DEBIAN_ISO_CHECKSUM="sha256:${RAW_HASH}"
            echo "Successfully parsed remote checksum: $DEBIAN_ISO_CHECKSUM"
        fi
    fi

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
d-i debian-installer/add-kernel-opts string net.ifnames=0 biosdevname=0
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string xoa-base
d-i netcfg/get_domain string local
d-i mirror/country string manual
d-i mirror/http/hostname string ftp.jaist.ac.jp
d-i mirror/http/directory string /pub/Linux/debian
d-i passwd/root-login boolean true
d-i passwd/root-password password ${DEBIAN_ROOT_PASSWORD}
d-i passwd/root-password-again password ${DEBIAN_ROOT_PASSWORD}
d-i passwd/user-fullname string XenOrchestra User
d-i passwd/username string ${DEBIAN_XO_USER}
d-i passwd/user-password password ${DEBIAN_XO_PASSWORD}
d-i passwd/user-password-again password ${DEBIAN_XO_PASSWORD}
d-i clock-setup/utc boolean true
d-i time/zone string Asia/Tokyo
d-i partman-auto/method string regular
d-i partman-auto/filesystem string ext4
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
tasksel tasksel/first multiselect standard
d-i pkgsel/include string network-manager openssh-server sudo curl wget vim git jq
d-i pkgsel/exclude string firmware-b43-installer firmware-ralink firmware-realtek firmware-*wifi* firmware-ath9k firmware-brcm80211 wireless-tools wpagui bluetooth bluez lvm2 dmsetup
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
      "vm_memory": 4096,
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
      "format": "xva_compressed",
      "output_directory": "output-xva",
      "keep_vm": "always",
      "skip_set_template": "true"
    }
  ],
  "provisioners": [
    {
      "type": "shell",
      "inline": [
        "echo '==> Updating base system...'",
        "apt-get update && apt-get upgrade -y",
        "echo '==> Fetching stable Xen Guest Utilities...'",
        "wget -q \"https://github.com/xenserver/xe-guest-utilities/releases/download/v10.0.0/xe-guest-utilities_10.0.0-1_amd64.deb\" -O /tmp/xe-guest-utilities.deb",
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
        "ls -l /tmp/xoa-installer/"
      ]
    },
    {
      "type": "file",
      "source": "patches/menu-hide-items.patch",
      "destination": "/tmp/xoa-installer/"
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
          "echo '==> checking the content of the xoa-installer folder'",
          "cd /tmp/xoa-installer/ && pwd && ls -l"
        ]
    },
    {
      "type": "shell",
      "inline": [
        "echo '==> Implementing Local Git Repository for Xen-Orchestra source...'",
        "git clone https://github.com/vatesfr/xen-orchestra.git /tmp/xen-orchestra-patched",
        "cd /tmp/xen-orchestra-patched && git config user.name \"Packer Builder\" && git config user.email \"packer@internal\"",
        "echo '==> Applying custom design patch...'",
        "cd /tmp/xen-orchestra-patched && git apply /tmp/xoa-installer/menu-hide-items.patch",
        "cd /tmp/xen-orchestra-patched && git add -A && git commit -m \"Apply custom design patch\"",
    	"echo '==> Generating self-signed TLS certificate...'",
    	"mkdir -p /opt/xo",
    	"openssl req -x509 -newkey rsa:4096 -keyout /opt/xo/xo.key -out /opt/xo/xo.crt -days 3650 -nodes -subj \"/CN=xoa.local\"",
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
        "echo '==> Running XOA installation (this will take a while)...'",
        "cd /tmp/xoa-installer && ./xo-install.sh --install",
        "echo '==> Cleaning up install files...'",
        "apt-get clean",
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
EOF

echo -e "\n=========================================================="
echo "  Setup Complete! Your environment is ready.              "
echo "=========================================================="
echo "Next steps:"
echo "1. cd $BUILD_DIR"
echo "2. packer validate xoa-build.json"
echo "3. packer build xoa-build.json"

cd "$BUILD_DIR"
pwd
packer validate xoa-build.json
PACKER_LOG=1 packer build xoa-build.json
cd /root/xoa-build/output-xva/
echo -e "\n=========================================================="
echo "  Moving and compressing the XOA image.                   "
echo "=========================================================="
gzip --best xoa-hl.xva && mv xoa-hl.xva.gz /home/matth/
chown matth:matth /home/matth/xoa-hl.xva.gz
