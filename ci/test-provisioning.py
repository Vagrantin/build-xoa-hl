"""Exercise scripts in an isolated filesystem with injected command failures."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Provisioning(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ('etc', 'var/lib', 'var/log', 'run/xoa-provision', 'root', 'bin'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        self.events = self.root / 'events'
        self.env = dict(os.environ, PATH=f"{self.root}/bin:{os.environ['PATH']}", EVENTS=str(self.events))
        self.stub('systemctl', 'echo systemctl "$@" >> "$EVENTS"')
        self.stub('nc', 'exit 0')
        self.stub('id', 'exit 0')
        self.stub('chpasswd', 'cat >/dev/null; echo chpasswd >> "$EVENTS"; exit "${CHPASSWD_FAIL:-0}"')
        self.stub('node', 'echo api >> "$EVENTS"; exit "${API_FAIL:-0}"')
        self.stub('redis-cli', '''
echo "redis $*" >> "$EVENTS"
if [[ "$*" == *'CONFIG GET appendonly' ]]; then printf 'appendonly\\nyes\\n'
elif [[ "$*" == *SAVE && "${SAVE_FAIL:-0}" == 1 ]]; then echo 'ERR injected'; exit 0
else echo OK; fi''')
        self.envelope = self.root / 'etc/xoa-first-boot.env'
        self.done = self.root / 'var/lib/xoa-credentials.done'
        self.secret = 'synthetic$()`ssh-secret'
        self.write_env(self.secret)

    def stub(self, name, body):
        p = self.root / 'bin' / name
        p.write_text('#!/bin/bash\n' + body + '\n')
        p.chmod(0o755)

    def write_env(self, ssh):
        self.envelope.write_text(''.join(f'{k}={base64.b64encode(v.encode()).decode()}\n' for k, v in
                                        [('XOA_EMAIL', 'lab@example.test'), ('XOA_PASSWORD', 'false'), ('SSH_PASSWORD', ssh)]))
        self.envelope.chmod(0o600)

    def run_script(self, name, **env):
        # Rewrite fixed production paths in a copy; production has no test root knob.
        script = (ROOT / 'scripts' / name).read_text()
        for prefix in ('/etc', '/var', '/run', '/root'):
            script = script.replace(prefix + '/', str(self.root) + prefix + '/')
            script = script.replace(' ' + prefix + '\n', ' ' + str(self.root) + prefix + '\n')
        path = self.root / name
        path.write_text(script)
        return subprocess.run(['bash', str(path)], env=dict(self.env, **env), capture_output=True)

    def test_success_has_durable_order_and_removes_envelope(self):
        result = self.run_script('xoa-credentials.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.done.exists())
        self.assertFalse(self.envelope.exists())
        events = self.events.read_text()
        self.assertLess(events.index('appendfsync always'), events.index('api'))
        self.assertLess(events.index('api'), events.index('SAVE'))
        self.assertLess(events.index('SAVE'), events.index('appendfsync everysec'))
        self.assertLess(events.index('SAVE'), events.index('systemctl disable'))
        self.assertNotIn(self.secret, (self.root / 'var/log/xoa-first-boot.log').read_text())

    def test_each_failure_retains_retry_and_never_completes(self):
        for failure in ['API_FAIL', 'SAVE_FAIL', 'CHPASSWD_FAIL']:
            with self.subTest(failure=failure):
                result = self.run_script('xoa-credentials.sh', **{failure: '1'})
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.envelope.exists())
                self.assertFalse(self.done.exists())
                self.assertNotIn('systemctl disable', self.events.read_text())
        self.assertEqual(self.run_script('xoa-credentials.sh').returncode, 0)

    def test_disabled_ssh_and_newline_rejection(self):
        self.write_env('bad\nroot:injected')
        self.assertNotEqual(self.run_script('xoa-credentials.sh').returncode, 0)
        self.assertFalse(self.events.exists())
        self.write_env('')
        self.assertEqual(self.run_script('xoa-credentials.sh').returncode, 0)
        self.assertNotIn('chpasswd', self.events.read_text())

    def test_done_reentry_cleans_secrets_without_reapplying(self):
        self.done.touch()
        self.assertEqual(self.run_script('xoa-credentials.sh').returncode, 0)
        self.assertFalse(self.envelope.exists())
        self.assertNotIn('api', self.events.read_text())

    def test_reader_redacts_secrets_captures_before_guest_cleanup_and_reuses(self):
        self.envelope.unlink()
        self.stub('rpm', 'echo guest-utilities-test')
        self.stub('lsmod', 'exit 0')
        values = {'admin-account': json.dumps({'email': 'lab@example.test', 'password': 'true'}),
                  'system-account-xoa-password': self.secret, 'domid': '8'}
        self.stub('xenstore-read', """key=${1##*/}
case "$key" in
""" + '\n'.join(f"{key}) printf '%s\\n' '{value}';;" for key, value in values.items()) + '\n*) exit 1;;\nesac')
        self.stub('xenstore-rm', f'''[ -s '{self.envelope}' ] || exit 99
echo "remove $*" >> "$EVENTS"''')
        result = self.run_script('xoa-first-boot.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.envelope.stat().st_mode & 0o777, 0o600)
        log = (self.root / 'var/log/xoa-first-boot.log').read_text()
        self.assertNotIn(self.secret, log)
        self.assertNotIn(values['admin-account'], log)
        self.assertIn('system-account-xoa-password', self.events.read_text())
        original = self.envelope.read_bytes()
        self.stub('xenstore-read', 'exit 1')
        self.assertEqual(self.run_script('xoa-first-boot.sh').returncode, 0)
        self.assertEqual(self.envelope.read_bytes(), original)

    def test_reader_rejects_absent_partial_and_malformed_admin_before_network(self):
        self.envelope.unlink()
        self.stub('rpm', 'echo guest-utilities-test')
        self.stub('lsmod', 'exit 0')
        self.stub('xenstore-rm', 'echo unexpected-cleanup >> "$EVENTS"')
        for admin in ['', '{', '{}', '{"email":"lab@example.test"}', '{"password":"false"}']:
            with self.subTest(admin=admin):
                self.stub('xenstore-read', f"case \"$1\" in domid) echo 8;; */admin-account) printf '%s\\n' '{admin}';; *) exit 1;; esac")
                result = self.run_script('xoa-first-boot.sh')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.envelope.exists())
                self.assertFalse((self.root / 'etc/NetworkManager/system-connections/xoa-provisioned.nmconnection').exists())
                self.assertFalse(self.events.exists())

    def test_finalizer_stops_services_and_removes_database(self):
        redis = self.root / 'var/lib/redis'
        redis.mkdir()
        (redis / 'dump.rdb').write_text('build default admin')
        (redis / 'appendonlydir').mkdir()
        (redis / 'appendonlydir/old.aof').touch()
        # Runtime paths are rewritten; preserve the data-dir contract in the fixture.
        (self.root / 'etc/redis.conf').write_text(f'dir {redis}\nappendonly no\nappendfsync always\n')
        result = self.run_script('xoa-finalize-state.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(redis.iterdir()), [])
        self.assertIn('appendonly yes\nappendfsync everysec', (self.root / 'etc/redis.conf').read_text())
        self.assertFalse(self.envelope.exists())
        self.assertEqual(self.events.read_text().splitlines(), ['systemctl stop xo-server.service', 'systemctl stop redis.service'])
        network = (self.root / 'etc/systemd/system/NetworkManager.service.d/xoa-provisioning.conf').read_text()
        self.assertIn('Requires=xoa-first-boot.service', network)
        self.assertIn('After=xoa-first-boot.service', network)


if __name__ == '__main__':
    unittest.main()
