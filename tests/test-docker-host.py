import importlib.util
import json
import os
from pathlib import Path
import io
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
def load(path):
    spec = importlib.util.spec_from_file_location('module', ROOT / path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
m = load('docker-host/command.py')
g = load('docker-host/generate-packer.py')

class Protocol(unittest.TestCase):
    def call(self, operation, **params):
        return m.handle(dict(version=1, operation=operation, **params))
    def config(self, **changes):
        return dict(name='nginx', image='nginx:alpine', cpus=.1, memoryMiB=16, **changes)
    def test_limits_and_no_shell(self):
        with patch.object(m, 'docker', return_value='abc\n') as docker, patch.object(m, 'present', side_effect=[False, True]):
            self.call('create', config=self.config(ports=[dict(host=8080, container=80, protocol='tcp')], volumes=[dict(name='web', path='/data')]))
        args = docker.call_args.args
        self.assertIn('--cpus', args); self.assertIn('--memory', args); self.assertIn('--memory-swap', args)
        self.assertIn('type=volume,source=xoa-hl-web,target=/data', args)
        self.assertNotIn('--privileged', args)
    def test_reject_unsafe_options_and_injection(self):
        cases = [self.config(privileged=True), self.config(volumes=[dict(name='/var/run/docker.sock', path='/data')])]
        for key, value in [('name','--help'), ('image','-v /:/host'), ('cpus',0), ('cpus',float('nan')), ('memoryMiB',0), ('restart','bogus')]:
            c=self.config(); c[key]=value; cases.append(c)
        for config in cases:
            with self.subTest(config=config), patch.object(m,'docker') as docker, self.assertRaises(ValueError):
                self.call('create', config=config)
            docker.assert_not_called()
    def test_unmanaged_container_rejected(self):
        with patch.object(m,'docker',return_value='[{"Config":{"Labels":{}}}]'), self.assertRaises(ValueError):
            self.call('remove',id='a'*64)
    def test_remove_preserves_volumes_and_does_not_force(self):
        with patch.object(m,'docker',side_effect=['[{"Config":{"Labels":{"net.xcp-hl.managed":"1"}}}]','']) as docker:
            self.call('remove',id='a'*64)
        self.assertEqual(docker.call_args.args,('rm','a'*64))
    def test_error_and_protocol_validation(self):
        for request in [dict(version=2,operation='overview'), dict(version=1,operation='exec')]:
            with self.assertRaises(ValueError): m.handle(request)
        with patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],1,b'',b'secret')), self.assertRaisesRegex(ValueError,'Docker operation failed'):
            m.docker('info')
    def test_missing_image_downloads_in_background_then_creates(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(m, 'TASKS', Path(directory)):
            worker = MagicMock(pid=os.getpid())
            with patch.object(m, 'present', return_value=False), patch.object(m, 'docker') as docker, \
                    patch.object(m.subprocess, 'Popen', return_value=worker) as popen:
                tid = self.call('create', config=self.config(environment=dict(TOKEN='hunter2')))['task']
                docker.assert_not_called()
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            request = json.loads(worker.stdin.write.call_args.args[0])
            self.assertIn('TOKEN=hunter2', request['args'])
            stored = (Path(directory) / (tid + '.json')).read_text()
            self.assertNotIn('hunter2', stored)
            task = m.read_tasks()[0]
            self.assertEqual((task['kind'], task['name'], task['state']), ('create', 'nginx', 'running'))
            self.assertNotIn('pid', task)
            # The worker pulls, creates, then clears its record.
            with patch.object(m.sys, 'stdin', MagicMock(buffer=io.BytesIO(json.dumps(request).encode()))), \
                    patch.object(m, 'docker', return_value='') as docker:
                m.run_task(tid)
            self.assertEqual([call.args[0] for call in docker.call_args_list], ['pull', 'run'])
            self.assertEqual(m.read_tasks(), [])
    def test_failed_and_interrupted_downloads_are_reported_and_dismissable(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(m, 'TASKS', Path(directory)):
            worker = MagicMock(pid=os.getpid())
            with patch.object(m.subprocess, 'Popen', return_value=worker):
                tid = self.call('pull', image='nginx:alpine')['task']
                with self.assertRaisesRegex(ValueError, 'already in progress'):
                    self.call('pull', image='nginx:alpine')
            with self.assertRaisesRegex(ValueError, 'Only a failed'):
                self.call('dismiss', id=tid)
            request = json.dumps(dict(image='nginx:alpine', args=None)).encode()
            with patch.object(m.sys, 'stdin', MagicMock(buffer=io.BytesIO(request))), \
                    patch.object(m, 'docker', side_effect=ValueError('secret daemon text')):
                m.run_task(tid)
            task = m.read_tasks()[0]
            self.assertEqual(task['state'], 'failed')
            self.assertNotIn('secret', task['error'])
            self.call('dismiss', id=tid)
            self.assertEqual(m.read_tasks(), [])
            # A worker that died is not shown as running for ever.
            m.write_task('a' * 16, dict(id='a' * 16, kind='pull', image='x', name='', state='running', error='', started=1, pid=2 ** 22 + 7))
            self.assertEqual(m.read_tasks(), [])
            for bad in ['../x', 'a' * 15, 5]:
                with self.assertRaises(ValueError): self.call('dismiss', id=bad)
    def test_summary_reports_limits_without_sampling(self):
        cid = 'a' * 64
        replies = {'info': json.dumps(dict(NCPU=4, ServerVersion='27')), 'ps': json.dumps(dict(ID=cid, State='running')),
                   'inspect': f'{cid} 1500000000 268435456\n'}
        with tempfile.TemporaryDirectory() as directory, patch.object(m, 'TASKS', Path(directory)), \
                patch.object(m.shutil, 'disk_usage', return_value=MagicMock(total=10, used=4)), \
                patch.object(m, 'docker', side_effect=lambda *args, **kw: replies[args[0]]) as docker:
            state = self.call('summary')
        self.assertEqual(state['limits'][cid], dict(cpus=1.5, memoryMiB=256))
        self.assertEqual((state['host']['cpusAllocated'], state['host']['memoryAllocatedMiB']), (1.5, 256))
        self.assertNotIn('stats', state)
        self.assertNotIn('stats', [call.args[0] for call in docker.call_args_list])
    def test_builder_is_distinct_and_wired(self):
        env={key:'test' for key in ('XCPNG_IP','XCPNG_USER','XCPNG_PASSWORD','VM_NETWORK_NAME','SR_NAME','ALMALINUX_ISO_URL','ALMALINUX_ISO_CHECKSUM')}
        env['DOCKER_BUILD_PASSWORD']='a'*24
        env['ALMALINUX_ISO_CHECKSUM']='sha256:'+'a'*64
        config,ks=g.generate(env)
        self.assertIs(config['builders'][0]['skip_set_template'],False)
        self.assertTrue(any(p.get('script')=='scripts/install-docker.sh' for p in config['provisioners']))
        self.assertNotIn('xoa-hl.rpm',json.dumps(config)); self.assertIn('selinux --enforcing',ks)
        with self.assertRaises(ValueError): g.generate({})
    def test_installer_keeps_vendor_service_and_stable_repo(self):
        s=(ROOT/'scripts/install-docker.sh').read_text()
        self.assertNotIn('enable docker-ce-nightly',s)
        self.assertNotIn('overlay2.size',s)
        self.assertNotIn('releases/latest',s)
        self.assertNotIn('docker-compose',s)

if __name__=='__main__': unittest.main()
