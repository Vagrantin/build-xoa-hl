#!/usr/bin/env python3
"""Generate a separate Docker-only image build for CI's XCP-ng-connected runner."""
import json
import os
import re
from pathlib import Path


def generate(env):
    required = ('XCPNG_IP', 'XCPNG_USER', 'XCPNG_PASSWORD', 'VM_NETWORK_NAME', 'SR_NAME', 'ALMALINUX_ISO_URL', 'ALMALINUX_ISO_CHECKSUM', 'DOCKER_BUILD_PASSWORD')
    for key in required:
        if not env.get(key):
            raise ValueError('Missing CI setting: ' + key)
    if not re.fullmatch(r'sha256:[a-fA-F0-9]{64}', env['ALMALINUX_ISO_CHECKSUM']):
        raise ValueError('Pin the AlmaLinux ISO with a sha256 checksum')
    password = env['DOCKER_BUILD_PASSWORD']
    # A cryptographically random CI password can be expressed safely in Kickstart.
    if not password.isalnum() or len(password) < 24:
        raise ValueError('Use an alphanumeric temporary password of at least 24 characters')
    kickstart = f'''lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate
rootpw --plaintext {password}
firewall --enabled --service=ssh
selinux --enforcing
bootloader --location=mbr
zerombr
clearpart --all --initlabel
autopart --type=plain --fstype=ext4
reboot
%packages
@^minimal-environment
openssh-server
python3
%end
%post
printf "PermitRootLogin yes\nPasswordAuthentication yes\n" > /etc/ssh/sshd_config.d/01-packer.conf
systemctl enable sshd
%end
'''
    builder = {
        'type': 'xenserver-iso', 'remote_host': env['XCPNG_IP'], 'remote_username': env['XCPNG_USER'],
        'remote_password': env['XCPNG_PASSWORD'], 'iso_url': env['ALMALINUX_ISO_URL'],
        'iso_checksum': env['ALMALINUX_ISO_CHECKSUM'], 'sr_name': env['SR_NAME'],
        'vm_name': 'XOA-HL Docker host v1', 'vm_description': 'Dedicated Docker workload template; protocol v1',
        'disk_size': 32768, 'vm_memory': 2048, 'network_names': [env['VM_NETWORK_NAME']],
        'http_directory': 'docker-host/http', 'boot_wait': '10s',
        'boot_command': ['<wait10>', '<esc><wait2>', '<esc><wait2>', 'linux inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/inst.ks inst.text<enter>'],
        'shutdown_command': 'passwd -l root; shutdown -P now', 'shutdown_timeout': '5m',
        'ssh_username': 'root', 'ssh_password': password, 'ssh_timeout': '30m',
        'format': 'xva_compressed', 'keep_vm': 'never', 'skip_set_template': False,
        'output_directory': 'docker-host/output',
    }
    provisioners = [
        {'type': 'shell', 'inline': ['dnf -y update',
         'dnf -y install epel-release', 'dnf -y install xe-guest-utilities-latest',
         'systemctl enable xe-linux-distribution']},
        {'type': 'file', 'source': 'docker-host/command.py', 'destination': '/tmp/docker-command.py'},
        {'type': 'shell', 'script': 'scripts/install-docker.sh'},
        {'type': 'shell', 'inline': ['dnf clean all', 'rm -f /tmp/docker-command.py', 'rm -f /root/.ssh/authorized_keys /etc/ssh/sshd_config.d/01-packer.conf',
          'rm -f /var/lib/dhclient/* /var/lib/NetworkManager/*lease*', 'sync']},
    ]
    return {'builders': [builder], 'provisioners': provisioners}, kickstart


if __name__ == '__main__':
    config, kickstart = generate(os.environ)
    Path('docker-host/http').mkdir(exist_ok=True)
    Path('docker-host/http/inst.ks').write_text(kickstart)
    Path('docker-host/packer.json').write_text(json.dumps(config, indent=2))
    for path in ('docker-host/packer.json', 'docker-host/http/inst.ks'):
        os.chmod(path, 0o600)
