#!/bin/sh
set -eu
dockerd-entrypoint.sh >/tmp/docker.log 2>&1 &
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
docker info >/dev/null
# The helper uses an absolute vendor Docker path.
ln -s /usr/local/bin/docker /usr/bin/docker
docker pull busybox:1.37
python3 - <<'PY'
import importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader('command', '/usr/local/libexec/xoa-hl-docker-command')
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
def call(operation, **params): return m.handle(dict(version=1, operation=operation, **params))
cid = call('create', config={'name':'smoke', 'image':'busybox:1.37', 'cpus':.1, 'memoryMiB':16, 'restart':'no'})['id']
call('overview')
call('logs', id=cid)
call('start', id=cid)
call('stop', id=cid)
call('restart', id=cid)
call('stop', id=cid)
call('remove', id=cid)
assert call('overview')['containers'] == []
print('Real Docker protocol lifecycle passed')
PY
