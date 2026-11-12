"""Native integration checks: install with bootstrap.ps1 before running on Windows.

uv run --offline --no-project --python 3.13 -m unittest discover -s tests/zellij -p test_native_windows.py -v
All programs and sessions created here are disposable; real agents are never started.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
WINDOWS = sys.platform == 'win32'


@unittest.skipUnless(WINDOWS, 'native Windows only')
class NativeWorkspace(unittest.TestCase):
    def setUp(self):
        previous_bytecode = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        self.addCleanup(setattr, sys, 'dont_write_bytecode', previous_bytecode)
        from windows_console import Console
        self.Console = Console
        self.temp = tempfile.TemporaryDirectory(prefix='dotfiles-zellij-test-')
        self.root = Path(self.temp.name)
        self.session = 'dotfiles-test-' + uuid.uuid4().hex[:12]
        self.binary = shutil.which('zellij')
        self.assertTrue(self.binary, 'Install windows/zellij.ps1 -Apply first')
        self.pwsh = subprocess.check_output(['pwsh', '-NoProfile', '-Command', "Join-Path $PSHOME 'pwsh.exe'"], text=True).strip()
        self.config = self.root / 'config'
        (self.config / 'layouts').mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'calls'
        self.calls.mkdir()
        fake = self.bin / 'fake.py'
        fake.write_text('''import json, os, pathlib, sys, time, uuid
kind = sys.argv[1]
root = pathlib.Path(os.environ['DOTFILES_TEST_CALLS'])
(root / (uuid.uuid4().hex + '.json')).write_text(json.dumps(dict(kind=kind, args=sys.argv[2:], cwd=os.getcwd())), encoding='utf-8')
print('FAKE-' + kind, flush=True)
print('ARGS-' + repr(sys.argv[2:]), flush=True)
try:
    while True:
        gate = root / (kind + '.control')
        if gate.exists():
            sys.exit(int(gate.read_text()))
        time.sleep(.1)
except KeyboardInterrupt:
    print('INTERRUPTED-' + kind, flush=True)
''', encoding='utf-8')
        for kind in ('nvim', 'codex', 'ralphex'):
            (self.bin / (kind + '.cmd')).write_text(f'@"{sys.executable}" "{fake}" {kind} %*\n')
            if kind != 'ralphex':
                (self.bin / (kind + '.ps1')).write_text(f"& '{sys.executable}' '{fake}' {kind} @args\n")
        self.repos = self.root / 'repos'
        self.checkout = self.repos / "sp ace-é's"
        self.checkout.mkdir(parents=True)
        self.git(self.checkout, 'init', '-q')
        self.git(self.checkout, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-qm', 'test')
        self.external = self.root / 'external worktree'
        self.git(self.checkout, 'worktree', 'add', '-qb', 'other', str(self.external))
        (self.checkout / 'subdirectory').mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + str(Path(self.binary).parent) + os.pathsep + os.environ['PATH'],
                        ZELLIJ_CONFIG_DIR=str(self.config), ZELLIJ_SOCKET_DIR=str(self.root / 'sockets'),
                        XDG_STATE_HOME=str(self.root / 'state'), DOTFILES_REPO_ROOT=str(self.repos),
                        DOTFILES_SHARED_WORKSPACE=str(ROOT / '.tmux/layouts/workspace.py'),
                        DOTFILES_ZELLIJ_SHELL=self.pwsh, DOTFILES_ZELLIJ_POLL_SECONDS='.3',
                        DOTFILES_TEST_CALLS=str(self.calls), TERM='xterm-256color', WT_SESSION=str(uuid.uuid4()),
                        PYTHONDONTWRITEBYTECODE='1', PYTHONUTF8='1')
        for key in ('ZELLIJ', 'ZELLIJ_SESSION_NAME', 'ZELLIJ_PANE_ID'):
            self.env.pop(key, None)
        self.environment_patch = patch.dict(os.environ, self.env)
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)
        generate = ". '" + str(ROOT / 'windows/zellij/config.ps1') + "'; $files=Get-ZellijWindowsFiles -Repository '" + str(ROOT) + "' -Wrapper '" + str(ROOT / 'windows/zellij/workspace.ps1') + "' -Shell 'pwsh.exe'; foreach($key in $files.Keys){[IO.File]::WriteAllText((Join-Path '" + str(self.config) + "' $key),$files[$key])}"
        self.run_ps(generate)
        with (self.config / 'config.kdl').open('a') as stream:
            stream.write('\nshow_release_notes false\nshow_startup_tips false\n')
        self.clients = []
        self.watchers = []
        spec = importlib.util.spec_from_file_location('native_workspace', ROOT / 'windows/zellij/workspace.py')
        with patch.dict(os.environ, self.env):
            self.helper = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.helper)

    def tearDown(self):
        if hasattr(self, 'env'):
            try:
                subprocess.run([self.binary, 'kill-session', self.session], env=self.env, capture_output=True, timeout=8)
            except subprocess.TimeoutExpired:
                pass  # the test's ConPTY job still owns and closes its server
            for watcher in self.watchers:
                try:
                    watcher.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    watcher.terminate()
                    watcher.wait(timeout=5)
            for client in self.clients:
                client.close()
            try:
                subprocess.run([self.binary, 'delete-session', self.session, '--force'], env=self.env, capture_output=True, timeout=8)
            except subprocess.TimeoutExpired:
                pass
        # Windows closes ConPTY handles asynchronously.
        self.assertEqual(self.root.parent.resolve(), Path(tempfile.gettempdir()).resolve(), 'Unsafe test cleanup path')
        for attempt in range(20):
            try:
                self.temp.cleanup()
                break
            except PermissionError:
                time.sleep(.2)

    def git(self, cwd, *args):
        return subprocess.run(['git', '-C', str(cwd), *args], capture_output=True, text=True, check=True)

    def run_ps(self, code):
        return subprocess.run([self.pwsh, '-NoLogo', '-NoProfile', '-Command', code], env=self.env, capture_output=True, text=True, check=True)

    def start(self, restore=False):
        args = [self.binary, 'attach', '--create', '--force-run-commands', self.session]
        client = self.Console(args, self.checkout, self.env)
        self.clients.append(client)
        self.wait(lambda: len(self.tiled()) == 3)
        self.wait(lambda: len(self.call_rows()) >= (4 if restore else 2))
        self.wait(lambda: all(p.get('pane_cwd') for p in self.panes() if not p['is_plugin']))
        return client

    def action(self, *args):
        result = subprocess.run([self.binary, '--session', self.session, 'action', *map(str, args)], env=self.env, capture_output=True, text=True, encoding='utf-8', timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def panes(self):
        return json.loads(self.action('list-panes', '--json'))

    def tiled(self, tab=None):
        return [p for p in self.panes() if not p['is_plugin'] and not p['is_floating'] and (tab is None or p['tab_id'] == tab)]

    def call_rows(self):
        return [json.loads(p.read_text(encoding='utf-8')) for p in self.calls.glob('*.json')]

    def wait(self, predicate, seconds=25):
        deadline = time.monotonic() + seconds
        last = None
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except (AssertionError, ValueError, OSError, RuntimeError) as error:
                last = error
            time.sleep(.15)
        output = self.clients[-1].data.decode('utf-8', errors='replace')[-3500:] if self.clients else ''
        if self.clients:
            try:
                output += '\nPANES: ' + repr(self.panes())
                for pane in [p for p in self.panes() if not p['is_plugin']]:
                    output += '\nSCREEN ' + str(pane['id']) + ': ' + self.screen(pane)
            except (AssertionError, ValueError, OSError):
                pass
        self.fail(f'Timed out: {last}\n{output}')

    def focus(self, pane):
        result = subprocess.run([self.binary, '--session', self.session, 'action', 'focus-pane-id', str(pane['id'])], env=self.env, capture_output=True, text=True)
        self.assertTrue(result.returncode == 0 or 'already focused' in result.stderr, result.stderr)

    def command(self, pane, text):
        self.focus(pane)
        self.action('write-chars', '--pane-id', pane['id'], text)
        self.action('write', '--pane-id', pane['id'], 13)

    def screen(self, pane):
        return self.action('dump-screen', '--pane-id', pane['id'], '--full')

    def helper_action(self, action, *args, env=None):
        result = subprocess.run([sys.executable, str(ROOT / 'windows/zellij/workspace.py'), action, self.session, *map(str, args)],
                                env=env or self.env, capture_output=True, text=True, encoding='utf-8', timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_layout_lifecycle_cwd_keys_and_monitor(self):
        client = self.start()
        panes = sorted(self.tiled(), key=lambda p: p['pane_x'])
        self.assertLessEqual(max(p['pane_columns'] for p in panes) - min(p['pane_columns'] for p in panes), 1)
        self.assertTrue(panes[1]['is_focused'])
        self.assertEqual(sorted((r['kind'], r['args']) for r in self.call_rows()), [('codex', ['resume', '--last']), ('nvim', [])])
        self.assertTrue(all(Path(r['cwd']) == self.checkout for r in self.call_rows()))
        (self.calls / 'nvim.control').write_text('0')
        (self.calls / 'codex.control').write_text('7')
        time.sleep(2)
        for pane in (panes[0], panes[2]):
            self.wait(lambda: 'FAKE-' in self.screen(pane))
            self.command(pane, "Write-Output ('USABLE-' + 'SHELL')")
            self.wait(lambda: 'USABLE-SHELL' in self.screen(pane))
        self.assertEqual(len(self.call_rows()), 2)
        self.command(panes[1], "Set-Location -LiteralPath '" + str(self.checkout / 'subdirectory').replace("'", "''") + "'")
        self.wait(lambda: any(Path(p['pane_cwd']) == self.checkout / 'subdirectory' for p in self.tiled() if p.get('pane_cwd')))
        client.write(b'\x10d')
        new = self.wait(lambda: next((p for p in self.tiled() if p['id'] not in {q['id'] for q in panes}), None))
        self.wait(lambda: Path(next(p for p in self.tiled() if p['id'] == new['id'])['pane_cwd']) == self.checkout / 'subdirectory')
        self.action('switch-mode', 'normal')
        time.sleep(.2)
        client.write(b'\x14')
        time.sleep(.3)
        client.write(b'n')
        self.wait(lambda: len(self.tiled()) == 5)
        self.assertEqual(len(self.call_rows()), 2)
        # The real prefix binding opens a searchable floating helper; Escape cancels.
        client.write(b'\x02?')
        floating = self.wait(lambda: [p for p in self.panes() if p['is_floating']])
        self.assertIn('Shortcuts', floating[0]['title'])
        time.sleep(1)
        client.write(b'\x1b')
        self.wait(lambda: not any(p['is_floating'] for p in self.panes()))
        client.write(b'\x02M')
        monitor = self.wait(lambda: [p for p in self.tiled() if p['title'] == 'processes'])
        tab = monitor[0]['tab_id']
        rows = sorted(self.tiled(tab), key=lambda p: (p['pane_x'], p['pane_y']))
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[1]['pane_x'], rows[2]['pane_x'])
        self.assertLessEqual(abs(rows[0]['pane_columns'] - rows[1]['pane_columns']), 1)
        self.assertGreater(rows[0]['pane_rows'], rows[1]['pane_rows'])
        self.wait(lambda: 'ProcessName' in self.screen(rows[0]))
        provider = self.run_ps('(Get-WinEvent -LogName System -MaxEvents 1 -ErrorAction Stop).ProviderName').stdout.strip()
        self.assertTrue(provider)
        self.wait(lambda: provider in self.screen(rows[1]))
        self.helper_action('monitor')
        self.assertEqual(len({p['tab_id'] for p in self.tiled()}), 3)
        self.assertEqual(len(self.call_rows()), 2)
        for pane in rows[:2]:
            self.focus(pane)
            self.action('write', '--pane-id', pane['id'], 3)
            time.sleep(.5)
            self.command(pane, "Write-Output ('STOPPED-' + 'SHELL')")
            self.wait(lambda: 'STOPPED-SHELL' in self.screen(pane))

    def test_picker_reuses_canonical_checkouts_and_cancels(self):
        client = self.start()
        original_tab = self.tiled()[0]['tab_id']
        self.action('rename-tab', 'renamed by user')
        self.helper.open_checkout(self.session, str(self.checkout).upper(), 'same checkout')
        self.assertEqual(len(self.tiled()), 3)
        self.helper.open_checkout(self.session, str(self.external), 'external')
        self.wait(lambda: len(self.tiled()) == 6)
        self.helper.open_checkout(self.session, str(self.external), 'external again')
        self.assertEqual(len(self.tiled()), 6)
        self.helper.open_checkout(self.session, str(self.checkout), 'original')
        self.wait(lambda: any(p['tab_id'] == original_tab and p['is_focused'] for p in self.panes()))
        # Real fzf filter selects a registered worktree outside the repository root.
        env = dict(self.env, FZF_DEFAULT_OPTS='--filter=external')
        self.helper_action('pick', env=env)
        self.assertEqual(len(self.tiled()), 6)
        self.helper_action('pick', env=dict(self.env, FZF_DEFAULT_OPTS='--filter=does-not-exist'))
        self.assertEqual(len(self.tiled()), 6)
        client.write(b'\x02R')
        self.wait(lambda: any(p['is_floating'] for p in self.panes()))
        time.sleep(1)
        client.write(b'\x1b')
        self.wait(lambda: not any(p['is_floating'] for p in self.panes()))
        self.assertEqual(len(self.tiled()), 6)
        with patch.object(self.helper.shared, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'inspection failed')):
            with self.assertRaises(RuntimeError):
                self.helper.open_checkout(self.session, str(self.checkout), 'must not create')
        same_name = self.root / 'another parent' / self.checkout.name
        same_name.mkdir(parents=True)
        self.git(same_name, 'init', '-q')
        self.helper.open_checkout(self.session, str(same_name), self.checkout.name)
        self.wait(lambda: len(self.tiled()) == 9)
        self.wait(lambda: all(p.get('pane_cwd') for p in self.tiled()))
        self.helper.open_checkout(self.session, str(self.checkout), 'renamed again')
        self.helper.open_checkout(self.session, str(same_name), 'same basename again')
        self.assertEqual(len(self.tiled()), 9)

    def test_ctrl_c_and_save_kill_restore(self):
        self.start()
        self.action('save-session')
        cache = Path(os.environ['LOCALAPPDATA']) / 'Zellij/cache/contract_version_1/session_info' / self.session / 'session-layout.kdl'
        self.wait(cache.is_file)
        subprocess.run([self.binary, 'kill-session', self.session], env=self.env, capture_output=True, check=True)
        time.sleep(.5)
        self.helper.prepare_resurrection(self.session)
        self.assertIn('-NoExit', cache.read_text(encoding='utf-8'))
        self.start(restore=True)
        self.assertEqual(len(self.tiled()), 3)
        self.assertEqual(len(self.call_rows()), 4)
        self.assertEqual(sorted((r['kind'], r['args']) for r in self.call_rows()),
                         [('codex', ['resume', '--last'])] * 2 + [('nvim', [])] * 2)
        for kind in ('codex', 'nvim'):
            pane = next(p for p in self.tiled() if p['title'] == kind)
            self.focus(pane)
            self.action('write', '--pane-id', pane['id'], 3)
            time.sleep(.5)
            self.command(pane, "Write-Output ('CANCELLED-' + 'SHELL')")
            self.wait(lambda: 'CANCELLED-SHELL' in self.screen(pane))
        self.assertEqual(len(self.call_rows()), 4)

    def test_automatic_logs_rotation_dismissal_and_next_run(self):
        client = self.start()
        self.helper.open_checkout(self.session, str(self.external), 'exact worktree')
        self.wait(lambda: len(self.tiled()) == 6)
        target_tab = next(p['tab_id'] for p in self.tiled() if Path(p['pane_cwd']) == self.external)
        # Let both tabs' profiles finish before registering a quick completed run.
        time.sleep(2)
        before = [(p['id'], p['pane_x'], p['pane_y'], p['pane_columns'], p['pane_rows']) for p in self.tiled()]
        (self.calls / 'ralphex.control').write_text('0')
        launch = ". '" + str(ROOT / 'windows/interactive.ps1') + "'; Set-Location -LiteralPath '" + str(self.external) + "'; ralphex --fixture"
        self.run_ps(launch)
        viewer = self.wait(lambda: next((p for p in self.panes() if p['is_floating'] and not p['is_plugin']), None), seconds=45)
        self.assertEqual(viewer['tab_id'], target_tab)
        self.assertFalse(viewer['is_focused'])
        tabs = json.loads(self.action('list-tabs', '--json'))
        self.assertFalse(next(t for t in tabs if t['tab_id'] == target_tab)['are_floating_panes_visible'])
        self.assertEqual(before, [(p['id'], p['pane_x'], p['pane_y'], p['pane_columns'], p['pane_rows']) for p in self.tiled()])
        self.wait(lambda: 'FAKE-ralphex' in self.screen(viewer), seconds=40)
        client.write(b'\x14')
        time.sleep(.3)
        client.write(b'2')
        time.sleep(.3)
        client.write(b'\x1bf')  # Alt+F reveals the hidden viewer.
        self.wait(lambda: next(t for t in json.loads(self.action('list-tabs', '--json')) if t['tab_id'] == target_tab)['are_floating_panes_visible'])
        client.write(b'\x10w')  # Ctrl+P, w hides it again.
        self.wait(lambda: not next(t for t in json.loads(self.action('list-tabs', '--json')) if t['tab_id'] == target_tab)['are_floating_panes_visible'])
        runs = self.root / 'state/dotfiles-zellij/runs'
        record = next(runs.glob('*.json'))
        job = json.loads(record.read_text(encoding='utf-8'))
        log = Path(job['log'])
        with log.open('a') as stream:
            stream.write('\nAPPENDED-LINE\n')
        self.wait(lambda: 'APPENDED-LINE' in self.screen(viewer))
        # Replace after the producer closed its file; the follower must reopen it.
        log.rename(log.with_suffix('.old'))
        log.write_text('ROTATED-LINE\n')
        self.wait(lambda: 'ROTATED-LINE' in self.screen(viewer))
        self.run_ps(launch + ' --next-run')
        self.wait(lambda: len(list(runs.glob('*.json'))) == 2)
        self.wait(lambda: self.helper.discover()[str(self.external)]['identity'] != job['identity'])
        self.wait(lambda: '--next-run' in self.screen(viewer))
        self.assertEqual(len([p for p in self.panes() if p['is_floating'] and not p['is_plugin']]), 1)
        self.focus(viewer)
        self.action('close-pane', '--pane-id', viewer['id'])
        self.wait(lambda: not any(p['is_floating'] and not p['is_plugin'] for p in self.panes()))
        duplicate = subprocess.run([sys.executable, str(ROOT / 'windows/zellij/workspace.py'), 'watch', self.session], env=self.env, capture_output=True, timeout=5)
        self.assertEqual(duplicate.returncode, 0)
        # Stop only this test session's watcher and restart it against saved state.
        for pid, process in self.helper.shared.processes().items():
            if self.session in process['command'] and 'workspace.py' in process['command'] and ' watch ' in process['command']:
                subprocess.run(['taskkill', '/PID', str(pid), '/F'], capture_output=True, check=True)
        restarted = subprocess.Popen([sys.executable, str(ROOT / 'windows/zellij/workspace.py'), 'watch', self.session], env=self.env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
        self.watchers.append(restarted)
        time.sleep(2)
        self.assertFalse(any(p['is_floating'] and not p['is_plugin'] for p in self.panes()))
        self.run_ps(launch)
        later = self.wait(lambda: next((p for p in self.panes() if p['is_floating'] and not p['is_plugin']), None), seconds=45)
        self.wait(lambda: 'FAKE-ralphex' in self.screen(later), seconds=40)
        self.action('write', '--pane-id', later['id'], 3)
        time.sleep(1)
        self.command(later, "Write-Output ('LOG-' + 'SHELL')")
        self.wait(lambda: 'LOG-SHELL' in self.screen(later))

    def test_failed_inspection_and_floating_helpers_cannot_match(self):
        row = dict(is_plugin=False, is_floating=False, is_focused=True, tab_id=7,
                   pane_cwd=str(self.checkout / 'subdirectory'))
        with patch.object(self.helper, 'panes', return_value=[row]), patch.object(self.helper, 'action') as action:
            self.helper.open_checkout(self.session, str(self.checkout).upper(), 'checkout')
            self.assertEqual(action.call_args.args[1:], ('go-to-tab-by-id', '7'))
        # A floating helper's cwd must never make an unrelated tab look open.
        row = dict(is_plugin=False, is_floating=True, is_focused=True, tab_id=7, pane_cwd=str(self.checkout))
        with patch.object(self.helper, 'panes', return_value=[row]), patch.object(self.helper, 'action') as action:
            self.helper.open_checkout(self.session, str(self.checkout), 'checkout')
            self.assertEqual(action.call_args.args[1], 'new-tab')
        for output in ('invalid JSON', '{}', '[{"is_plugin":false}]',
                       '[{"is_plugin":false,"is_floating":false,"is_focused":true,"tab_id":7,"pane_cwd":null}]'):
            with patch.object(self.helper.shared, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                with self.assertRaises((ValueError, RuntimeError)):
                    self.helper.open_checkout(self.session, str(self.checkout), 'must not create')


if __name__ == '__main__':
    unittest.main()
