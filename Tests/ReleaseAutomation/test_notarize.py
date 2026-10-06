"""Notarization survives network blips and gives up on Apple's queue instead of waiting forever."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]

# Each notarytool call takes the next scripted answer for its subcommand: "offline" fails like a dropped
# connection, anything else is the submission status notarytool reports.
FAKE_XCRUN = '''#!/bin/zsh
set -eu
print "xcrun $*" >> "$TEST_LOG"
queue="$TEST_ROOT/$2"
answer="$(head -n 1 "$queue")"
remaining="$(tail -n +2 "$queue")"
[[ -z "$remaining" ]] || print -r -- "$remaining" > "$queue"
if [[ "$answer" == offline ]]; then
    print -u2 'Error: The Internet connection appears to be offline.'
    exit 1
fi
case "$2" in
    submit) print '{"id":"fixture-id","message":"Successfully uploaded file"}' ;;
    info) print "{\\"id\\":\\"fixture-id\\",\\"status\\":\\"$answer\\"}" ;;
    log) print '{"issues":[{"message":"The binary is not signed."}]}' ;;
esac
'''


class NotarizationTests(unittest.TestCase):
    def notarize(self, submit, info, timeout='60'):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'bin').mkdir()
            (root / 'bin/xcrun').write_text(FAKE_XCRUN)
            (root / 'bin/xcrun').chmod(0o700)
            (root / 'submit').write_text('\n'.join(submit) + '\n')
            (root / 'info').write_text('\n'.join(info) + '\n')
            (root / 'log').write_text('ok\n')
            (root / 'Noodle.zip').write_text('archive')
            environment = dict(os.environ, PATH=f'{root}/bin:' + os.environ['PATH'],
                               TEST_LOG=str(root / 'commands'), TEST_ROOT=str(root),
                               APPLE_API_KEY_PATH='/fixture/key', APPLE_API_KEY_ID='fixture',
                               APPLE_API_ISSUER_ID='fixture', NOODLE_NOTARY_TIMEOUT=timeout,
                               NOODLE_NOTARY_POLL='0')
            started = time.monotonic()
            result = subprocess.run(['zsh', str(ROOT / 'scripts/notarize.sh'), str(root / 'Noodle.zip')],
                                    env=environment, capture_output=True, text=True, timeout=30)
            commands = (root / 'commands').read_text() if (root / 'commands').exists() else ''
            return result, commands, time.monotonic() - started

    def test_a_dropped_connection_keeps_the_submission(self):
        result, commands, _ = self.notarize(['offline', 'ok'], ['offline', 'In Progress', 'offline', 'Accepted'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands.count('notarytool submit'), 2)
        self.assertEqual(commands.count('notarytool info fixture-id'), 4)

    def test_a_slow_queue_ends_at_the_deadline(self):
        result, commands, elapsed = self.notarize(['ok'], ['In Progress'], timeout='2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fixture-id', result.stderr)
        self.assertLess(elapsed, 20)
        self.assertEqual(commands.count('notarytool submit'), 1)

    def test_a_rejection_prints_apples_log(self):
        result, commands, _ = self.notarize(['ok'], ['Invalid'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('notarytool log fixture-id', commands)
        self.assertIn('The binary is not signed.', result.stderr)

    def test_an_upload_that_keeps_failing_gives_up(self):
        result, commands, _ = self.notarize(['offline'], [])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands.count('notarytool submit'), 3)
        self.assertNotIn('notarytool info', commands)


if __name__ == '__main__':
    unittest.main()
