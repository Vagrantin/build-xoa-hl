"""Real Redis: synchronous first-boot writes survive SIGKILL and AOF replay."""
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


class RedisDurability(unittest.TestCase):
    def test_provisioned_user_survives_crash_with_a_stale_rdb(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sock = str(root / 'redis.sock')
            conf = root / 'redis.conf'
            conf.write_text(f'port 0\nunixsocket {sock}\ndir {tmp}\nappendonly yes\nappendfsync everysec\n')
            process = None

            def cli(*args):
                return subprocess.check_output(['redis-cli', '-s', sock, '--raw', *args], text=True).strip()

            def start():
                nonlocal process
                process = subprocess.Popen(['redis-server', str(conf)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for _ in range(100):
                    try:
                        if cli('PING') == 'PONG':
                            return
                    except subprocess.CalledProcessError:
                        pass
                    time.sleep(0.05)
                self.fail('Redis failed to start')

            try:
                start()
                self.assertEqual(cli('SET', 'synthetic-user', 'default-admin'), 'OK')
                self.assertEqual(cli('SAVE'), 'OK')
                self.assertEqual(cli('CONFIG', 'SET', 'appendfsync', 'always'), 'OK')
                self.assertEqual(cli('SET', 'synthetic-user', 'deployed-admin'), 'OK')
                # First-boot barrier plus a stale dump: AOF must still win.
                old_dump = (root / 'dump.rdb').read_bytes()
                self.assertEqual(cli('SAVE'), 'OK')
                self.assertEqual(cli('CONFIG', 'SET', 'appendfsync', 'everysec'), 'OK')
                process.kill()
                process.wait(timeout=5)
                (root / 'dump.rdb').write_bytes(old_dump)
                start()
                self.assertEqual(cli('GET', 'synthetic-user'), 'deployed-admin')
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
