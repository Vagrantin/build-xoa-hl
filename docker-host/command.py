#!/usr/bin/python3
"""Version 1 of the forced-command protocol. Never executes SSH_ORIGINAL_COMMAND."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

LABEL = 'net.xcp-hl.managed=1'
NAME = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$')
IMAGE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_./:@-]{0,254}$')
ID = re.compile(r'^[a-f0-9]{12,64}$')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def docker(*args, timeout=30):
    # No shell; no caller-selected subcommand. Keep daemon errors and env values out of replies.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        result = subprocess.run(['/usr/bin/docker', *args], stdout=output, stderr=errors, timeout=timeout,
                                preexec_fn=limit_output)
        require(result.returncode == 0, 'Docker operation failed; check image, ports, name and Docker service on the VM')
        output.seek(0)
        data = output.read(4 * 1024 * 1024 + 1)
        require(len(data) <= 4 * 1024 * 1024, 'Docker response too large')
        return data.decode('utf-8', errors='replace')


def limit_output():
    import resource
    resource.setrlimit(resource.RLIMIT_FSIZE, (4 * 1024 * 1024, 4 * 1024 * 1024))


def lines(value):
    return [json.loads(line) for line in value.splitlines() if line]


def managed(cid):
    require(isinstance(cid, str) and ID.fullmatch(cid), 'Invalid container ID')
    value = json.loads(docker('inspect', cid))[0]
    require(value.get('Config', {}).get('Labels', {}).get('net.xcp-hl.managed') == '1', 'Container is not managed by XOA-HL')
    return value


def number(value, low, high, title):
    require(type(value) in (int, float) and low <= value <= high, 'Invalid ' + title)
    return value


def create(config):
    require(isinstance(config, dict), 'Invalid configuration')
    require(not set(config) - {'name', 'image', 'cpus', 'memoryMiB', 'ports', 'volumes', 'environment', 'restart'}, 'Unknown configuration option')
    require(isinstance(config.get('name'), str) and NAME.fullmatch(config['name']), 'Invalid name')
    require(isinstance(config.get('image'), str) and IMAGE.fullmatch(config['image']), 'Invalid image')
    cpus = number(config.get('cpus'), .1, os.cpu_count(), 'CPU limit')
    total = int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemTotal:'))) * 1024
    memory = number(config.get('memoryMiB'), 16, max(16, total // 1048576 - 256), 'memory limit')
    require(int(memory) == memory, 'Memory must be whole MiB')
    restart = config.get('restart', 'unless-stopped')
    require(restart in ('no', 'on-failure', 'always', 'unless-stopped'), 'Invalid restart policy')
    args = ['run', '--detach', '--label', LABEL, '--name', config['name'], '--cpus', str(cpus),
            '--memory', str(memory) + 'm', '--memory-swap', str(memory) + 'm', '--pids-limit', '256',
            '--security-opt', 'no-new-privileges:true', '--restart', restart]
    ports = config.get('ports', [])
    require(isinstance(ports, list) and len(ports) <= 16, 'Invalid ports')
    for p in ports:
        require(isinstance(p, dict) and set(p) == {'host', 'container', 'protocol'}, 'Invalid port mapping')
        for key in ('host', 'container'):
            require(type(p[key]) is int and 1 <= p[key] <= 65535, 'Invalid port')
        require(p['host'] != 22, 'Port 22 is reserved for management')
        require(p['protocol'] in ('tcp', 'udp'), 'Invalid protocol')
        args += ['--publish', f"{p['host']}:{p['container']}/{p['protocol']}"]
    volumes = config.get('volumes', [])
    require(isinstance(volumes, list) and len(volumes) <= 16, 'Invalid volumes')
    for v in volumes:
        require(isinstance(v, dict) and set(v) == {'name', 'path'}, 'Invalid volume')
        require(isinstance(v['name'], str) and NAME.fullmatch(v['name']), 'Invalid volume name')
        require(isinstance(v['path'], str) and re.fullmatch(r'/[a-zA-Z0-9_./-]+', v['path']) and '..' not in v['path'].split('/'), 'Invalid mount path')
        args += ['--mount', f"type=volume,source=xoa-hl-{v['name']},target={v['path']}"]
    environment = config.get('environment', {})
    require(isinstance(environment, dict) and len(environment) <= 64, 'Invalid environment')
    for key, value in environment.items():
        require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,127}', key) and isinstance(value, str) and len(value) <= 4096 and '\0' not in value, 'Invalid environment variable')
        args += ['--env', key + '=' + value]
    # Pull explicitly through the UI first. Failed pulls never leave half-created containers.
    docker('image', 'inspect', config['image'])
    return {'id': docker(*args, config['image'], timeout=60).strip()}


def handle(request):
    require(isinstance(request, dict) and request.get('version') == 1, 'Unsupported protocol')
    op = request.get('operation')
    if op == 'overview':
        info = json.loads(docker('info', '--format', '{{json .}}'))
        containers = lines(docker('ps', '--all', '--no-trunc', '--filter', 'label=' + LABEL, '--format', '{{json .}}'))
        stats = lines(docker('stats', '--no-stream', '--no-trunc', '--format', '{{json .}}',
                             *[c['ID'] for c in containers if c['State'] == 'running'])) if any(c['State'] == 'running' for c in containers) else []
        mem = {line.split(':')[0]: int(line.split()[1]) * 1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith(('MemTotal:', 'MemAvailable:'))}
        disk = shutil.disk_usage('/var/lib/docker')
        return {'version': 1, 'containers': containers, 'stats': stats,
                'images': lines(docker('images', '--no-trunc', '--format', '{{json .}}')),
                'host': {'cpus': info['NCPU'], 'memoryTotal': mem['MemTotal'], 'memoryUsed': mem['MemTotal'] - mem['MemAvailable'],
                         'load': os.getloadavg()[0], 'cpuTicks': [int(v) for v in Path('/proc/stat').read_text().splitlines()[0].split()[1:9]],
                         'diskTotal': disk.total, 'diskUsed': disk.used, 'dockerVersion': info['ServerVersion']}}
    if op == 'create':
        return create(request.get('config'))
    if op in ('start', 'stop', 'restart', 'remove', 'logs'):
        cid = request.get('id')
        managed(cid)
        if op == 'logs':
            # Non-following, bounded log snapshot, including stderr. Docker mux is handled by CLI.
            with tempfile.TemporaryFile() as output:
                result = subprocess.run(['/usr/bin/docker', 'logs', '--tail', '200', '--since', '24h', '--timestamps', cid],
                                        stdout=output, stderr=subprocess.STDOUT, timeout=15, preexec_fn=limit_output)
                require(result.returncode == 0, 'Cannot read logs (output may exceed 4 MiB)')
                size = output.tell()
                output.seek(max(0, size - 65536))
                return {'logs': output.read(65536).decode('utf-8', errors='replace')}
        if op == 'remove':
            docker('rm', cid)  # Running containers must be stopped first. Never -v.
        else:
            docker(op, cid)
        return {'success': True}
    if op == 'pull':
        image = request.get('image')
        require(isinstance(image, str) and IMAGE.fullmatch(image), 'Invalid image')
        docker('pull', '--quiet', image, timeout=240)
        return {'success': True}
    if op == 'removeImage':
        image = request.get('image')
        require(isinstance(image, str) and re.fullmatch(r'sha256:[a-f0-9]{64}', image), 'Invalid image ID')
        docker('rmi', image)  # No force: images used by containers cannot be removed.
        return {'success': True}
    raise ValueError('Unsupported operation')


def main():
    try:
        data = sys.stdin.buffer.read(65537)
        require(len(data) <= 65536, 'Request too large')
        result = handle(json.loads(data))
        print(json.dumps({'result': result}))
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        # Validation messages contain no command output, credentials or environment values.
        error = sys.exc_info()[1]
        print(json.dumps({'error': str(error) if isinstance(error, ValueError) else 'Docker host operation failed'}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
