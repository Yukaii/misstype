"""Behavior tests for the Zig `misstypectl` (port of MisstypeCtlTests).

Runs the real binary on isolated synthetic files, with `dbus-send` and the
editor replaced by recording stubs so nothing touches a desktop session.

    python3 tests/capi/ctl_test.py [path/to/misstypectl]
"""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

BINARY = None


class CtlTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory(prefix='misstype-ctl-')
        self.dir = Path(self._temp.name)
        self.bin = self.dir / 'bin'
        self.bin.mkdir()
        self.log = self.dir / 'ran.log'
        self.stub('dbus-send', 0)
        self.stub('nano', 0)
        self.dict = str(self.dir / 'user_dictionary.tsv')
        self.conf = str(self.dir / 'misstype.conf')

    def tearDown(self):
        self._temp.cleanup()

    def stub(self, name, status):
        """A program that logs `name arg...` (NUL-free, one line) and exits."""
        path = self.bin / name
        path.write_text(f'#!/bin/sh\nprintf "%s" "{name}" >> "{self.log}"\n'
                        f'for a in "$@"; do printf "\\t%s" "$a" >> "{self.log}"; done\n'
                        f'printf "\\n" >> "{self.log}"\nexit {status}\n')
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def ran(self):
        if not self.log.exists():
            return []
        return [line.split('\t') for line in self.log.read_text().splitlines()]

    def ctl(self, *args, vars=None):
        env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', EDITOR='', VISUAL='',
                   XDG_DATA_HOME=str(self.dir / 'data'), XDG_CONFIG_HOME=str(self.dir / 'config'))
        env.update(vars or {})
        result = subprocess.run([BINARY, *args], env=env, text=True, capture_output=True)
        self.out = result.stdout.splitlines()
        self.err = result.stderr.splitlines()
        return result.returncode

    def read(self, path):
        try:
            return Path(path).read_text(encoding='utf-8')
        except FileNotFoundError:
            return ''

    def test_dict_add_keeps_comments_and_lists_tsv(self):
        Path(self.dict).write_text('# mine\nㄋㄧˇ-ㄏㄠˇ\t你好\n')
        self.assertEqual(self.ctl('dict', 'add', 'ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ', '黃昱愷', '--file', self.dict), 0)
        self.assertEqual(self.read(self.dict), '# mine\nㄋㄧˇ-ㄏㄠˇ\t你好\nㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ\t黃昱愷\n')
        self.assertEqual(self.ctl('dict', 'list', '--tsv', '--file', self.dict), 0)
        self.assertEqual(self.out, ['ㄋㄧˇ-ㄏㄠˇ\t你好', 'ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ\t黃昱愷'])

    def test_dict_add_rejects_mismatched_length_without_writing(self):
        self.assertEqual(self.ctl('dict', 'add', 'ㄋㄧˇ-ㄏㄠˇ', '你', '--file', self.dict), 1)
        self.assertIn('1 character for 2 syllables', self.err[-1], self.err)
        self.assertFalse(Path(self.dict).exists())

    def test_add_reweights_and_lifts_exclusion(self):
        self.ctl('dict', 'exclude', 'ㄉㄚˇ-ㄉㄨㄟˋ', '打對', '--file', self.dict)
        self.assertIn('!ㄉㄚˇ-ㄉㄨㄟˋ\t打對', self.read(self.dict))
        self.ctl('dict', 'add', 'ㄉㄚˇ-ㄉㄨㄟˋ', '打對', '--weight', '-2', '--file', self.dict)
        self.assertEqual(self.read(self.dict), 'ㄉㄚˇ-ㄉㄨㄟˋ\t打對\t-2.0\n')

    def test_remove_and_unexclude(self):
        self.ctl('dict', 'add', 'ㄋㄧˇ-ㄏㄠˇ', '你好', '--file', self.dict)
        self.assertEqual(self.ctl('dict', 'remove', 'ㄋㄧˇ-ㄏㄠˇ', '你好', '--file', self.dict), 0)
        self.assertEqual(self.ctl('dict', 'remove', 'ㄋㄧˇ-ㄏㄠˇ', '你好', '--file', self.dict), 1,
                         'second remove: not there')
        self.assertEqual(self.ctl('dict', 'unexclude', 'ㄋㄧˇ-ㄏㄠˇ', '你好', '--file', self.dict), 1)
        self.assertEqual(self.ctl('dict', 'list', '--tsv', '--file', self.dict), 0)
        self.assertEqual(self.out, [])

    def test_check_reports_bad_lines(self):
        Path(self.dict).write_text('ㄋㄧˇ-ㄏㄠˇ\t你\n')
        self.assertEqual(self.ctl('dict', 'check', '--file', self.dict), 1)
        self.assertIn(':1:', self.err[0], self.err)

    def test_edit_runs_editor_then_checks(self):
        self.assertEqual(self.ctl('dict', 'edit', '--file', self.dict, vars={'EDITOR': 'nano'}), 0)
        self.assertEqual(self.ran()[0], ['nano', self.dict])
        self.assertEqual(self.ctl('dict', 'edit', '--file', self.dict, vars={'EDITOR': 'nope-not-installed'}), 1)

    def test_config_set_get_reset_keeps_other_lines_and_reloads(self):
        Path(self.conf).write_text('# keep\nOther=1\nAutoShowCandidates=True\n')
        self.assertEqual(self.ctl('config', 'set', 'autoshowcandidates', 'off', '--file', self.conf), 0)
        self.assertEqual(self.read(self.conf), '# keep\nOther=1\nAutoShowCandidates=False\n')
        self.assertEqual(self.ran()[-1][0], 'dbus-send')
        self.assertEqual(self.ran()[-1][-1], 'string:misstype',
                         'reloads the addon, not just the global config')
        self.assertEqual(self.ctl('config', 'set', 'AutoCommitSyllables', '12', '--file', self.conf,
                                  '--no-reload'), 0)
        self.assertEqual(len(self.ran()), 1, '--no-reload does not ask fcitx5 to reload')
        self.assertEqual(self.ctl('config', 'get', 'AutoCommitSyllables', '--file', self.conf), 0)
        self.assertEqual(self.out, ['12'])
        self.assertEqual(self.ctl('config', 'reset', 'AutoCommitSyllables', '--file', self.conf), 0)
        self.assertEqual(self.read(self.conf), '# keep\nOther=1\nAutoShowCandidates=False\n')

    def test_config_choices_store_the_canonical_name(self):
        self.assertEqual(self.ctl('config', 'set', 'repairstrength', 'light', '--file', self.conf,
                                  '--no-reload'), 0)
        self.assertEqual(self.ctl('config', 'set', 'CursorCandidates', 'endingat', '--file', self.conf,
                                  '--no-reload'), 0)
        self.assertEqual(self.read(self.conf), 'RepairStrength=Light\nCursorCandidates=EndingAt\n')
        self.assertEqual(self.ctl('config', 'list', '--file', self.conf), 0)
        self.assertIn('MixedEnglish=False  (default)', self.out, 'defaults follow macOS')
        self.assertIn('CandidatesPerPage=8  (default)', self.out)

    def test_config_accepts_ten_number_keys(self):
        self.assertEqual(self.ctl('config', 'set', 'CandidateKeys', '1234567890', '--file', self.conf,
                                  '--no-reload'), 0, 'a full ten-key page is valid')
        self.assertEqual(self.ctl('config', 'set', 'ShiftTogglesEnglish', 'on', '--file', self.conf,
                                  '--no-reload'), 0)
        text = self.read(self.conf)
        self.assertIn('CandidateKeys=1234567890', text)
        self.assertIn('ShiftTogglesEnglish=True', text)
        self.assertEqual(self.ctl('config', 'set', 'CandidateKeys', '1234567890-', '--file', self.conf),
                         1, 'eleven keys')

    def test_config_rejects_bad_values(self):
        for args, status in [
            (('ToneTolerance', 'maybe'), 1),
            (('RepairStrength', 'max'), 1),
            (('CandidatesPerPage', '3'), 1),
            (('FuzzyRepair', 'on'), 2),  # replaced by RepairStrength
            (('AutoCommitSyllables', '999'), 1),
            (('CandidateKeys', 'aab'), 1),
            (('Nope', '1'), 2),
        ]:
            self.assertEqual(self.ctl('config', 'set', *args, '--file', self.conf), status, args)
        self.assertFalse(Path(self.conf).exists())

    def test_config_path_follows_xdg(self):
        self.assertEqual(self.ctl('config', 'path', vars={'XDG_CONFIG_HOME': '/tmp/xc'}), 0)
        self.assertEqual(self.out, ['/tmp/xc/fcitx5/conf/misstype.conf'])


if __name__ == '__main__':
    BINARY = str(Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'core-zig/zig-out/bin/misstypectl').resolve())
    unittest.main()
