#!/bin/bash
# Install Docker on AlmaLinux 9
# This script is run during the Packer build to install Docker on the XOA-HL appliance

set -euo pipefail

echo "==> Installing Docker CE on AlmaLinux 9"

# Install required dependencies
if ! rpm -q docker-ce docker-ce-cli containerd.io >/dev/null 2>&1; then
    echo "---> Docker not installed, proceeding with installation..."
else
    echo "---> Docker is already installed"
    exit 0
fi

# Add Docker CE repository
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Enable the repository
yum-config-manager --enable docker-ce-nightly

# Install Docker CE
yum install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "==> Docker installed successfully"

# Start and enable Docker service
systemctl enable docker
systemctl start docker

# Verify Docker is running
docker --version

# Add current user to docker group (if not root)
if [ "$(whoami)" != "root" ]; then
    usermod -aG docker $(whoami)
fi

# Configure Docker to use the XCP-ng storage driver
echo "==> Configuring Docker for XCP-ng"

# Create Docker daemon configuration
mkdir -p /etc/docker

# Configure Docker to use overlay2 with XFS support
# This is important for XCP-ng which uses XFS for storage
cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true",
    "overlay2.size=20G"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  },
  "live-restore": true,
  "userland-proxy": false
}
EOF

# Restart Docker to apply configuration
systemctl restart docker

echo "==> Docker configuration complete"

# Verify Docker is working
docker info | grep -E "Storage Driver|Cgroup Driver|Kernel Version"

# Install docker-compose for easier container management
if ! command -v docker-compose >/dev/null 2>&1; then
    echo "---> Installing docker-compose..."
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-Linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
fi

echo "==> Docker setup complete"
