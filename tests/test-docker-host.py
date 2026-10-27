import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

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
        with patch.object(m, 'docker', return_value='abc\n') as docker:
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
