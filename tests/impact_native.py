#!/usr/bin/env python3
"""Isolated tests of impact_native.c, without MoonBit or Node package installs.

The driver includes the production C bridge with only MoonBit allocation
accessors disabled. Git repositories, fake pnpm executables and all report
writes live in independently-owned TemporaryDirectory fixtures.

Run: python3 tests/impact_native.py
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
DRIVER = r'''
#define MOONIMPACT_STANDALONE 1
#include "impact_native.c"

int main(int argc, char **argv) {
  struct impact_result *r;
  struct impact_buffer payload = {0};
  int operation, flag = 0, code, i;
  const unsigned char *data;
  size_t length;
  if (argc < 3) return 97;
  if (!strcmp(argv[1], "git")) {
    operation = 0;
    data = (const unsigned char *)(argc > 3 ? argv[3] : "HEAD");
    length = strlen((const char *)data) + 1;
  } else if (!strcmp(argv[1], "run") && argc >= 5) {
    operation = atoi(argv[3]) ? 2 : 1;
    flag = atoi(argv[4]);
    for (i = 5; i < argc; ++i)
      if (!impact_append(&payload, argv[i], strlen(argv[i]) + 1)) return 96;
    data = payload.data; length = payload.len;
  } else if (!strcmp(argv[1], "report") && argc == 4) {
    operation = 3; data = (const unsigned char *)argv[3]; length = strlen(argv[3]);
  } else return 97;
  r = moonimpact_native_request(operation, (const unsigned char *)argv[2], data, (int32_t)length, flag);
  free(payload.data);
  if (!r) return 95;
  if (r->status) {
    fprintf(stderr, "ERROR: %s\n", r->error ? r->error : "native allocation failed");
    code = 2;
  } else {
    if (r->out.len) fwrite(r->out.data, 1, r->out.len, stdout);
    code = r->value;
  }
  moonimpact_native_result_free(r);
  return code;
}
'''
PNPM = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time
Path(os.environ['IMPACT_SHIM_LOG']).write_text(json.dumps({
    'argv': sys.argv[1:], 'cwd': os.getcwd(), 'pid': os.getpid(),
}), encoding='utf-8')
print('runner-stdout', flush=True)
print('runner-stderr', file=sys.stderr, flush=True)
if os.environ.get('IMPACT_SHIM_MODE') == 'timeout':
    time.sleep(20)
sys.exit(int(os.environ.get('IMPACT_SHIM_EXIT', '0')))
'''


def checked_cleanup(temp, owned):
    current = Path(temp.name).resolve()
    assert current == owned
    assert current.parent == Path(tempfile.gettempdir()).resolve()
    assert current.name.startswith('moonimpact-native-')
    temp.cleanup()


@unittest.skipUnless(sys.platform in ('darwin', 'linux'), 'POSIX native bridge')
class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc = shutil.which('cc')
        if not cc:
            raise unittest.SkipTest('C compiler unavailable')
        cls.build_temp = tempfile.TemporaryDirectory(prefix='moonimpact-native-build-')
        cls.build_root = Path(cls.build_temp.name).resolve()
        cls.addClassCleanup(checked_cleanup, cls.build_temp, cls.build_root)
        source = cls.build_root / 'driver.c'
        source.write_text(DRIVER, encoding='utf-8')
        cls.binary = cls.build_root / 'driver'
        subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-O0',
                        '-I', str(ROOT), str(source), '-o', str(cls.binary)],
                       check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='moonimpact-native-case-')
        self.base = Path(self.temp.name).resolve()
        self.addCleanup(checked_cleanup, self.temp, self.base)
        self.root = self.base / 'project space 中文'
        self.root.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env.update({
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_CONFIG_SYSTEM': os.devnull, 'GIT_TERMINAL_PROMPT': '0',
            'GIT_AUTHOR_NAME': 'MoonImpact fixture',
            'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
            'GIT_COMMITTER_NAME': 'MoonImpact fixture',
            'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
        })

    def owned(self, path):
        value = Path(path).resolve()
        self.assertTrue(value.is_relative_to(self.base))
        self.assertNotEqual(value, self.base)
        return value

    def write(self, relative, contents):
        path = self.root / relative
        self.owned(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding='utf-8')
        return path

    def invoke(self, *arguments, env=None):
        return subprocess.run([str(self.binary), *map(str, arguments)],
                              cwd=self.base, env=env or self.env,
                              capture_output=True, timeout=8)

    def expect_exit(self, result, expected):
        self.assertEqual(result.returncode, expected,
                         f'stdout={result.stdout!r}\nstderr={result.stderr!r}')

    def git(self, *arguments, expected=0):
        git = shutil.which('git')
        if not git:
            self.skipTest('Git unavailable')
        self.owned(self.root)
        result = subprocess.run([git, '-C', str(self.root),
                                 '-c', 'core.hooksPath=/dev/null',
                                 '-c', 'commit.gpgsign=false', *arguments],
                                env=self.env, capture_output=True, timeout=8)
        self.expect_exit(result, expected)
        return result.stdout.decode('utf-8').strip()

    def init_repo(self):
        self.git('init', '--initial-branch=main')
        self.write('.gitignore', '*.ignored\n')
        for name in ('tracked.ts', 'staged.ts', 'deleted.ts', 'old name.ts'):
            self.write(name, 'initial\n')
        self.git('add', '--all')
        self.git('commit', '-m', 'fixture initial')

    def changes(self, result):
        self.expect_exit(result, 0)
        data = result.stdout
        self.assertTrue(not data or data.endswith(b'\0'))
        return set(x.decode('utf-8') for x in data.split(b'\0') if x)

    def fake_pnpm(self):
        directory = self.base / 'shim bin'
        directory.mkdir()
        pnpm = directory / 'pnpm'
        pnpm.write_text(PNPM, encoding='utf-8')
        pnpm.chmod(0o755)
        log = self.base / 'invocation.json'
        env = dict(self.env, PATH=str(directory) + os.pathsep + self.env.get('PATH', '/usr/bin:/bin'),
                   IMPACT_SHIM_LOG=str(log))
        return env, log, pnpm

    def test_git_retains_staged_unstaged_untracked_deleted_and_rename_paths(self):
        self.init_repo()
        self.write('tracked.ts', 'unstaged\n')
        self.write('staged.ts', 'staged\n')
        self.git('add', '--', 'staged.ts')
        self.owned(self.root / 'deleted.ts').unlink()
        old = self.owned(self.root / 'old name.ts')
        renamed = self.owned(self.root / '新 name\nrenamed.ts')
        old.rename(renamed)
        self.write('space ;$(touch should-not-exist).ts', 'new\n')
        self.write('skip.ignored', 'ignored\n')
        self.assertEqual(self.changes(self.invoke('git', self.root)), {
            'tracked.ts', 'staged.ts', 'deleted.ts', 'old name.ts',
            '新 name\nrenamed.ts', 'space ;$(touch should-not-exist).ts',
        })
        self.assertFalse((self.root / 'should-not-exist').exists())

    def test_explicit_base_compares_to_worktree_not_only_head(self):
        self.init_repo()
        baseline = self.git('rev-parse', 'HEAD')
        self.write('committed.ts', 'committed\n')
        self.git('add', '--all')
        self.git('commit', '-m', 'fixture second')
        self.write('tracked.ts', 'working-tree\n')
        self.write('untracked.ts', 'untracked\n')
        self.assertEqual(self.changes(self.invoke('git', self.root, baseline)),
                         {'committed.ts', 'tracked.ts', 'untracked.ts'})

    def test_git_rejects_nonroot_unknown_ref_and_option_reference(self):
        self.init_repo()
        (self.root / 'child').mkdir()
        for root, reference in ((self.root / 'child', 'HEAD'), (self.root, 'unknown-ref'),
                                (self.root, '--help'), (self.root, '')):
            with self.subTest(root=root, reference=reference):
                result = self.invoke('git', root, reference)
                self.expect_exit(result, 2)
                self.assertEqual(result.stdout, b'')

    def test_git_ignores_inherited_repository_and_index_overrides(self):
        self.init_repo()
        self.write('tracked.ts', 'changed\n')
        env = dict(self.env, GIT_DIR=str(self.base / 'missing'),
                   GIT_WORK_TREE=str(self.base), GIT_INDEX_FILE=str(self.base / 'missing-index'))
        self.assertEqual(self.changes(self.invoke('git', self.root, env=env)), {'tracked.ts'})

    def test_git_disables_external_diff_textconv_and_fsmonitor(self):
        self.init_repo()
        marker = self.base / 'executed-unsafe-helper'
        hook = self.base / 'unsafe-helper'
        hook.write_text('#!/bin/sh\n' + 'touch ' + repr(str(marker)) + '\n', encoding='utf-8')
        hook.chmod(0o755)
        self.git('config', 'diff.external', str(hook))
        self.git('config', 'diff.fixture.textconv', str(hook))
        self.git('config', 'core.fsmonitor', str(hook))
        self.write('.gitattributes', '*.ts diff=fixture\n')
        self.write('tracked.ts', 'changed\n')
        changes = self.changes(self.invoke('git', self.root))
        self.assertIn('tracked.ts', changes)
        self.assertFalse(marker.exists())

    def test_git_clean_filter_is_rejected_before_it_can_execute(self):
        self.init_repo()
        marker = self.base / 'executed-clean-filter'
        hook = self.base / 'clean-helper'
        hook.write_text('#!/bin/sh\ntouch ' + repr(str(marker)) + '\ncat\n', encoding='utf-8')
        hook.chmod(0o755)
        self.git('config', 'filter.fixture.clean', str(hook))
        self.write('.gitattributes', '*.ts filter=fixture\n')
        self.write('tracked.ts', 'changed\n')
        result = self.invoke('git', self.root)
        self.expect_exit(result, 2)
        self.assertIn(b'clean/process filters', result.stderr)
        self.assertFalse(marker.exists())

    def test_git_replace_does_not_change_comparison_base(self):
        self.init_repo()
        before = self.git('rev-parse', 'HEAD')
        self.write('tracked.ts', 'second\n')
        self.git('add', '--all')
        self.git('commit', '-m', 'fixture second')
        head = self.git('rev-parse', 'HEAD')
        self.git('replace', head, before)
        self.assertEqual(self.changes(self.invoke('git', self.root)), set())

    def test_related_run_uses_fixed_argv_and_stderr_only(self):
        env, log, _ = self.fake_pnpm()
        tests = ['test/space ;$(touch injected).spec.ts', 'test/中文.spec.ts', '-danger.spec.ts']
        result = self.invoke('run', self.root, '0', '2000', *tests, env=env)
        self.expect_exit(result, 0)
        self.assertEqual(result.stdout, b'')
        self.assertIn(b'runner-stdout', result.stderr)
        self.assertIn(b'runner-stderr', result.stderr)
        invocation = json.loads(log.read_text(encoding='utf-8'))
        self.assertEqual(invocation['argv'], ['exec', 'vitest', 'run', *['./' + t for t in tests]])
        self.assertEqual(invocation['cwd'], str(self.root.resolve()))
        self.assertFalse((self.root / 'injected').exists())

    def test_full_run_explicitly_omits_test_filters(self):
        env, log, _ = self.fake_pnpm()
        result = self.invoke('run', self.root, '1', '2000', env=env)
        self.expect_exit(result, 0)
        self.assertEqual(json.loads(log.read_text())['argv'], ['exec', 'vitest', 'run'])

    def test_empty_related_selection_and_unsafe_paths_never_run(self):
        env, log, _ = self.fake_pnpm()
        for paths in ([], ['../outside.ts'], ['/absolute.ts'], ['a/../b.ts'],
                      ['a\\..\\b.ts'], ['C:/file.ts'], ['']):
            with self.subTest(paths=paths):
                self.expect_exit(self.invoke('run', self.root, '0', '1000', *paths, env=env), 2)
                self.assertFalse(log.exists())

    def test_test_exit_status_is_not_mistaken_for_startup_failure(self):
        env, log, _ = self.fake_pnpm()
        env['IMPACT_SHIM_EXIT'] = '17'
        result = self.invoke('run', self.root, '0', '2000', 'test/a.ts', env=env)
        self.expect_exit(result, 17)
        self.assertTrue(log.exists())
        self.assertNotIn(b'cannot start', result.stderr)

    def test_timeout_terminates_and_reaps_the_runner(self):
        env, log, _ = self.fake_pnpm()
        env['IMPACT_SHIM_MODE'] = 'timeout'
        start = time.monotonic()
        result = self.invoke('run', self.root, '0', '350', 'test/a.ts', env=env)
        self.expect_exit(result, 2)
        self.assertIn(b'timed out', result.stderr)
        self.assertLess(time.monotonic() - start, 4)
        pid = json.loads(log.read_text())['pid']
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_startup_missing_binary_invalid_executable_and_bad_root_fail(self):
        env, log, pnpm = self.fake_pnpm()
        self.expect_exit(self.invoke('run', self.base / 'missing', '1', '1000', env=env), 2)
        self.assertFalse(log.exists())
        missing = dict(env, PATH=str(self.base / 'no-binaries'))
        self.expect_exit(self.invoke('run', self.root, '1', '1000', env=missing), 2)
        # ENOEXEC must not trigger execvp's implicit /bin/sh fallback.
        pnpm.write_text('touch should-not-execute\n', encoding='utf-8')
        result = self.invoke('run', self.root, '1', '1000', env=env)
        self.expect_exit(result, 2)
        self.assertFalse((self.root / 'should-not-execute').exists())

    def test_report_is_create_only_and_preserves_existing_paths(self):
        output = self.base / 'plan.json'
        self.expect_exit(self.invoke('report', output, '{"plan":"中文"}\n'), 0)
        self.assertEqual(output.read_text(), '{"plan":"中文"}\n')
        self.expect_exit(self.invoke('report', output, 'overwritten'), 2)
        self.assertEqual(output.read_text(), '{"plan":"中文"}\n')
        empty = self.base / 'empty-config.json'
        empty.write_bytes(b'')
        self.expect_exit(self.invoke('report', empty, 'overwritten'), 2)
        self.assertEqual(empty.read_bytes(), b'')
        link = self.base / 'link.json'
        link.symlink_to(output)
        self.expect_exit(self.invoke('report', link, 'overwritten'), 2)
        self.assertEqual(output.read_text(), '{"plan":"中文"}\n')
        self.expect_exit(self.invoke('report', self.base / 'missing' / 'plan.json', '{}'), 2)
        self.assertFalse(list(self.base.glob('.moonimpact-report-*')))

    def test_concurrent_report_publications_never_clobber(self):
        output = self.base / 'race.json'
        texts = ['{"first":true}', '{"second":true}']
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda value: self.invoke('report', output, value), texts))
        self.assertEqual(sorted(r.returncode for r in results), [0, 2])
        self.assertIn(output.read_text(), texts)
        self.assertFalse(list(self.base.glob('.moonimpact-report-*')))


if __name__ == '__main__':
    unittest.main(verbosity=2)
