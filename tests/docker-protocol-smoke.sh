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
import time
cid = call('create', config={'name':'smoke', 'image':'busybox:1.37', 'cpus':.1, 'memoryMiB':16, 'restart':'no'})['id']
state = call('overview')
assert state['limits'][cid] == {'cpus': .1, 'memoryMiB': 16}, state['limits']
assert 'stats' not in call('summary')
# An image that is not local is downloaded by a detached worker, then created.
task = call('create', config={'name':'later', 'image':'busybox:1.36', 'cpus':.1, 'memoryMiB':16, 'restart':'no'})['task']
for _ in range(120):
    state = call('overview')
    if not state['tasks']: break
    time.sleep(1)
assert not state['tasks'], state['tasks']
later = [c['ID'] for c in state['containers'] if c['Names'] == 'later']
assert len(later) == 1, state['containers']
call('remove', id=later[0])
# A download that cannot succeed is reported, creates nothing, and can be dismissed.
task = call('pull', image='registry.invalid/none:1')['task']
for _ in range(120):
    failed = [t for t in call('overview')['tasks'] if t['state'] == 'failed']
    if failed: break
    time.sleep(1)
assert failed and failed[0]['id'] == task, call('overview')['tasks']
call('dismiss', id=task)
assert call('overview')['tasks'] == []
call('logs', id=cid)
call('start', id=cid)
call('stop', id=cid)
call('restart', id=cid)
call('stop', id=cid)
call('remove', id=cid)
assert call('overview')['containers'] == []
print('Real Docker protocol lifecycle passed')
PY
