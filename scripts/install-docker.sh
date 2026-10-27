#!/bin/bash
# Dedicated Docker guest only. Invoked by docker-host Packer CI; never on XOA or Dom0.
set -euo pipefail
. /etc/os-release
[[ "$ID" == almalinux && "$VERSION_ID" == 9* ]]
if rpm -q xoa-hl >/dev/null 2>&1 || test -f /etc/xensource-inventory; then
    echo "Refusing to install Docker on the management appliance or Dom0" >&2
    exit 1
fi
dnf -y install dnf-plugins-core cloud-init openssh-server python3 sudo
# Stable vendor repository; RPM signatures checked by dnf.
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf -y --disablerepo='docker-ce-test*' --disablerepo='docker-ce-nightly*' install docker-ce docker-ce-cli containerd.io
install -d -m 755 /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3"},"live-restore":true}
EOF
# Keep the vendor service/socket and kernel-selected storage driver.
install -D -m 755 /tmp/docker-command.py /usr/local/libexec/xoa-hl-docker-command
systemctl enable docker sshd cloud-init-local cloud-init cloud-config cloud-final
restorecon -v /usr/local/libexec/xoa-hl-docker-command
systemctl start docker
docker info >/dev/null
printf '1\n' > /etc/xoa-hl-docker-host-version
# A clone gets its identity and SSH host keys from XO's per-VM cloud-init seed.
cloud-init clean --logs --seed
rm -f /etc/ssh/ssh_host_* /etc/machine-id
truncate -s 0 /etc/machine-id
