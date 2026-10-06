"""Native PSMux checks, in a unique namespace without agents or user configuration."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(os.name == "nt", "Native Windows only")
class NativeWorkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = load("native_workspace", ROOT / ".tmux/layouts/workspace.py")
        cls.agents = load("native_agents", ROOT / "windows/workspace/native-agents.py")
        cls.binary = os.environ.get("PSMUX_TEST_EXE") or shutil.which("psmux")
        if not cls.binary:
            raise unittest.SkipTest("PSMux is not installed")
        version = subprocess.check_output([cls.binary, "--version"], text=True)
        import re
        match = re.search(r"psmux (\d+)\.(\d+)\.(\d+)", version)
        if not match or tuple(map(int, match.groups())) < (3, 3, 8):
            raise unittest.SkipTest("PSMux 3.3.8 or newer is required")
        cls.temporary = tempfile.TemporaryDirectory(prefix="dotfiles-native-mux-")
        cls.root = Path(cls.temporary.name)
        cls.namespace = "dotfiles-test-" + uuid.uuid4().hex
        cls.environment = patch.dict(os.environ, {
            "DOTFILES_MUX_NAMESPACE": cls.namespace, "XDG_STATE_HOME": str(cls.root / "state"),
            "PATH": str(Path(cls.binary).parent) + os.pathsep + os.environ["PATH"],
            "TMUX": "", "TMUX_PANE": "", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUTF8": "1",
        })
        cls.environment.start()
        cls.workspace.MUX = cls.binary
        cls.workspace.MUX_ARGS = ["-L", cls.namespace]
        cls.workspace.STATE = cls.root / "state/dotfiles-tmux"
        try:
            cls.workspace.tmux("-f", "NUL", "new-session", "-d", "-s", "trial", "-x", "180", "-y", "50",
                               "--", "pwsh", "-NoLogo", "-NoProfile")
            cls.workspace.tmux("set-option", "-g", "default-shell", "pwsh.exe")
            cls.workspace.tmux("set-option", "-g", "default-command", "pwsh -NoLogo -NoProfile")
            for option in ("@dev-editor-command", "@dev-assistant-command", "@monitor-command"):
                cls.workspace.tmux("set-option", "-g", option, "none")
            cls.session = cls.workspace.tmux("display-message", "-p", "#{session_id}")
            cls.pane = cls.workspace.tmux("display-message", "-p", "#{pane_id}")
            os.environ["TMUX_PANE"] = cls.pane
            cls.repo = cls.root / "repos/project with spaces"
            cls.repo.mkdir(parents=True)
            cls.git("init", "-q", "-b", "main")
            cls.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-qm", "fixture")
            cls.worktree = cls.root / "elsewhere/topic checkout"
            cls.git("worktree", "add", "-qb", "topic", str(cls.worktree))
        except Exception:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        subprocess.run([cls.binary, "-L", cls.namespace, "kill-server"], capture_output=True)
        cls.environment.stop()
        assert cls.root.resolve().parent == Path(tempfile.gettempdir()).resolve()
        for attempt in range(100):
            try:
                cls.temporary.cleanup()
                break
            except PermissionError:
                if attempt == 99:
                    raise
                time.sleep(0.1)

    @classmethod
    def git(cls, *args):
        subprocess.run(["git", "-C", str(cls.repo), *args], check=True, capture_output=True)

    @staticmethod
    def wait_for(predicate):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.1)
        raise AssertionError("Native pane did not reach the expected state")

    def test_worktree_views_reuse_and_roles(self):
        workspace = self.workspace
        entries = dict(workspace.list_checkouts(self.repo.parent))
        self.assertIn(str(self.worktree.resolve()), entries)
        first, _, fresh = workspace.ensure_view(self.session, self.worktree, "dev")
        self.assertTrue(fresh)
        second, _, fresh = workspace.ensure_view(self.session, self.worktree, "dev")
        self.assertEqual(first, second)
        self.assertFalse(fresh)
        panes = [p for p in workspace.panes() if p["window_id"] == first]
        self.assertEqual(3, len(panes))
        self.assertTrue(all("[topic]:dev" in p["window_name"] for p in panes))
        roles = workspace.tmux("list-panes", "-t", first, "-F", "#{pane_title}").splitlines()
        self.assertEqual(["editor", "shell", "agent"], roles)
        self.assertEqual(workspace.ensure_view(self.session, self.worktree, "tests")[0],
                         workspace.ensure_view(self.session, self.worktree, "tests")[0])

    def test_lock_contention_and_release(self):
        with self.workspace.locked("test-lock") as first:
            self.assertTrue(first)
            with self.workspace.locked("test-lock", blocking=False) as second:
                self.assertFalse(second)
        with self.workspace.locked("test-lock", blocking=False) as third:
            self.assertTrue(third)

    def test_powershell_quotes_are_literal(self):
        literal = "C:\\a folder\\it's $literal; $(throw 'bad')"
        command = self.workspace.shell_command([sys.executable, "-c", "import sys; print(sys.argv[1])", literal])
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", command], check=True, capture_output=True, text=True)
        self.assertEqual(literal, result.stdout.strip())

    def test_agent_process_ancestry(self):
        panes = [{"pane_pid": "10", "pane_title": "shell", "pane_id": "%1"},
                 {"pane_pid": "20", "pane_title": "shell", "pane_id": "%2"}]
        processes = {10: {"parent": 1, "name": "pwsh"},
                     11: {"parent": 10, "name": "codex"},
                     21: {"parent": 20, "name": "node", "command": r'node C:\tools\@anthropic-ai\claude-code\cli.js'},
                     99: {"parent": 1, "name": "codex"}}
        with patch.object(self.workspace, "panes", return_value=panes), patch.object(self.workspace, "processes", return_value=processes):
            rows = self.agents.agent_rows(self.workspace)
        self.assertEqual([("%1", "codex"), ("%2", "claude")], [(row["pane_id"], row["agent"]) for row in rows])

    def test_agent_autostart_after_shell_initialization(self):
        workspace = self.workspace
        records = self.root / 'assistant starts.jsonl'
        startup = self.root / 'slow startup.ps1'
        executable = self.root / 'fake codex.cmd'
        stub = self.root / 'fake codex.py'
        stub.write_text(
            'import json, os, sys\n'
            f'with open({str(records)!r}, "a", encoding="utf-8") as stream:\n'
            '    stream.write(json.dumps({"arguments": sys.argv[1:], "directory": os.getcwd()}) + "\\n")\n'
            'sys.exit(1 if sys.argv[1:] else 0)\n',
            encoding='utf-8',
        )
        executable.write_text(
            '@echo off\n' + subprocess.list2cmdline([sys.executable, str(stub)])
            + ' %*\nexit /b %errorlevel%\n',
            encoding='utf-8',
        )
        startup.write_text(
            "Start-Sleep -Milliseconds 1500\n"
            "Set-Alias -Scope Global codex '" + str(executable).replace("'", "''") + "'\n",
            encoding='utf-8',
        )
        command = ". '" + str(startup).replace("'", "''") + "'; codex resume --last || codex"
        try:
            workspace.tmux('set-option', '-g', '@dev-assistant-command', command)
            directory = self.root / 'autostart checkout'
            directory.mkdir()
            self.assertFalse(workspace.available(command))
            window, _, _ = workspace.ensure_view(self.session, directory, 'dev')
            try:
                self.wait_for(lambda: records.exists() and len(records.read_text().splitlines()) == 2)
            except AssertionError:
                pane = workspace.tmux('list-panes', '-t', window, '-F', '#{pane_id}').splitlines()[-1]
                screen = workspace.tmux('capture-pane', '-p', '-t', pane)
                recorded = records.read_text() if records.exists() else '(no launches recorded)'
                self.fail(f'Agent did not start after shell initialization:\n{recorded}\n{screen}')
            launches = [json.loads(line) for line in records.read_text().splitlines()]
            self.assertEqual([['resume', '--last'], []], [row['arguments'] for row in launches])
            self.assertTrue(all(Path(row['directory']) == directory for row in launches))
            roles = workspace.tmux('list-panes', '-t', window, '-F', '#{pane_title}').splitlines()
            self.assertEqual(['editor', 'shell', 'agent'], roles)
            reused, _, fresh = workspace.ensure_view(self.session, directory, 'dev')
            self.assertEqual(window, reused)
            self.assertFalse(fresh)
            self.assertEqual(2, len(records.read_text().splitlines()))
        finally:
            workspace.tmux('set-option', '-g', '@dev-assistant-command', 'none')

    def test_process_snapshot(self):
        self.assertIn(os.getpid(), self.workspace.processes())

    def test_picker_selects_worktree_from_real_popup(self):
        if not shutil.which('uv') or not shutil.which('fzf'):
            self.skipTest('Repository picker requires uv and fzf')
        wrapper = ROOT / 'windows/workspace/workspace.ps1'
        selected_checkout = self.root / 'elsewhere/picker checkout'
        self.git('worktree', 'add', '-qb', 'picker-topic', str(selected_checkout))
        result_file = self.root / 'picker result.json'
        output_file = self.root / 'picker output.txt'
        launcher = self.root / 'picker popup.ps1'

        def quote(value):
            return "'" + str(value).replace("'", "''") + "'"

        launcher.write_text(
            "$env:FZF_DEFAULT_OPTS = '--filter=picker'\n"
            "$report = @{ exit = 0; tmux = $env:TMUX; pane = $env:TMUX_PANE; session = $env:PSMUX_SESSION }\n"
            "try { & " + quote(wrapper) + " pick " + quote(self.repo.parent)
            + " -WorkspaceScript " + quote(self.workspace.SCRIPT) + " *> " + quote(output_file)
            + " } catch { $report.exit = 1; $report.error = $_.Exception.Message }\n"
            "[IO.File]::WriteAllText(" + quote(result_file) + ", ($report | ConvertTo-Json))\n",
            encoding='utf-8',
        )
        command = self.workspace.shell_command(['pwsh', '-NoLogo', '-NoProfile', '-File', launcher])
        # A newer session must not receive the popup's selected checkout.
        self.workspace.tmux('-f', 'NUL', 'new-session', '-d', '-s', 'picker-other', '--', 'pwsh', '-NoProfile')
        try:
            for option in ('@dev-editor-command', '@dev-assistant-command'):
                self.workspace.tmux('set-option', '-g', '-t', 'picker-other:', option, 'none')
            self.workspace.tmux('display-popup', '-t', 'trial:', '-E', '-w', '85%', '-h', '75%', command)
            self.wait_for(result_file.exists)
            report = json.loads(result_file.read_text(encoding='utf-8-sig'))
            output = output_file.read_text(encoding='utf-8-sig') if output_file.exists() else ''
            self.assertEqual(0, report['exit'], f'{report}\n{output}')
            windows = [pane for pane in self.workspace.panes()
                       if pane['@repo-path'] == str(selected_checkout.resolve()) and pane['@repo-view'] == 'dev']
            self.assertEqual(3, len(windows))
            self.assertEqual(self.session, windows[0]['session_id'])
            active = self.workspace.tmux('display-message', '-t', 'trial:', '-p', '#{window_id}')
            self.assertEqual(windows[0]['window_id'], active)
        finally:
            # Stop only this disposable server; kill-server -L would also stop
            # trial, and this release's namespaced kill-session can time out.
            registry = Path(os.environ.get('PSMUX_DATA_DIR', str(Path.home() / '.psmux')))
            base = self.namespace + '__picker-other'
            port = int((registry / (base + '.port')).read_text())
            key = (registry / (base + '.key')).read_text().strip()
            with socket.create_connection(('127.0.0.1', port), timeout=5) as connection:
                connection.sendall(('AUTH ' + key + '\nkill-server\n').encode('utf-8'))
                connection.shutdown(socket.SHUT_WR)
                while connection.recv(1024):
                    pass
            self.wait_for(lambda: 'picker-other' not in self.workspace.tmux('list-sessions', '-F', '#{session_name}'))

    def test_sidebar_layout_roundtrip(self):
        workspace = self.workspace
        workspace.tmux("set-option", "-g", "remain-on-exit", "on")
        window, _, _ = workspace.ensure_view(self.session, self.repo, "dev")
        workspace.tmux("resize-pane", "-t", window + ".0", "-x", "75")
        before = workspace.tmux("display-message", "-p", "-t", window, "#{window_layout}")
        active = workspace.tmux("display-message", "-p", "#{pane_id}")
        self.agents.toggle_sidebar(workspace)
        self.wait_for(lambda: window in self.agents.sidebar_panes(workspace)[1])
        windows = {row['window_id'] for row in workspace.panes()}
        self.wait_for(lambda: windows == set(self.agents.sidebar_panes(workspace)[1]))
        for sidebar in self.agents.sidebar_panes(workspace)[1].values():
            width = int(workspace.tmux("display-message", "-p", "-t", sidebar, "#{pane_width}"))
            self.assertLessEqual(abs(width - 30), 1)
            try:
                self.wait_for(lambda: "Agents" in workspace.tmux("capture-pane", "-p", "-t", sidebar))
            except AssertionError:
                self.fail(workspace.tmux("capture-pane", "-p", "-t", sidebar))
        self.assertEqual(active, workspace.tmux("display-message", "-p", "#{pane_id}"))
        self.agents.toggle_sidebar(workspace)
        self.wait_for(lambda: not self.agents.sidebar_panes(workspace)[1])
        after = workspace.tmux("display-message", "-p", "-t", window, "#{window_layout}")
        self.assertEqual(before, after)
        self.assertEqual(active, workspace.tmux("display-message", "-p", "#{pane_id}"))

    def test_log_registration_is_namespace_scoped(self):
        workspace = self.workspace
        log = self.root / "runner.log"
        log.write_text("native log line\n")
        directory = str(self.repo.resolve())
        job = {"worktree": directory, "log": str(log), "identity": "test", "namespace": workspace.server_identity()}
        workspace.atomic_json(workspace.log_state(directory), job)
        self.assertEqual(job, workspace.discover()[directory])
        foreign = {**job, "namespace": "other-server", "worktree": "other checkout"}
        workspace.atomic_json(workspace.STATE / "log-foreign.json", foreign)
        self.assertNotIn("other checkout", workspace.discover())
        window = workspace.sync_log(self.session, directory, job)
        self.wait_for(lambda: "native log line" in workspace.tmux("capture-pane", "-p", "-t", window))

    def test_z_config_and_powershell_entrypoint(self):
        if not shutil.which("uv"):
            self.skipTest("uv is not installed")
        runtime = subprocess.run(["uv", "python", "find", "--offline", "3.13"], capture_output=True)
        if runtime.returncode:
            self.skipTest("Provision Python 3.13 with windows/packages.ps1 -Apply")
        wrapper = ROOT / "windows/workspace/workspace.ps1"
        shim = self.root / "workspace shim.ps1"
        shim.write_text(
            "param([string]$Action, [string]$Argument)\n"
            "$report = Join-Path '" + str(self.root).replace("'", "''") + "' (\"hook-$Action.txt\")\n"
            "try { & '" + str(wrapper).replace("'", "''") + "' $Action $Argument -WorkspaceScript '"
            + str(self.workspace.SCRIPT).replace("'", "''") + "' *> $report }\n"
            "catch { $_ | Out-String | Add-Content -LiteralPath $report; throw }\n",
            encoding="utf-8",
        )
        config = self.root / "native.conf"
        config.write_text((ROOT / "windows/psmux.conf").read_text(encoding="utf-8").replace(
            "$HOME/.config/dotfiles/windows/workspace/workspace.ps1", shim.as_posix()), encoding="utf-8")
        self.workspace.tmux("source-file", config)
        keys = self.workspace.tmux("list-keys", "-T", "prefix")
        for key in ("R", "M", "L", "T", "A", "B"):
            self.assertIn(" " + key + " ", keys)
        for key in ("M", "L", "T", "B", "P", "S"):
            binding = next(line.split(" " + key + " ", 1)[1] for line in keys.splitlines()
                           if " " + key + " " in line)
            self.assertTrue(binding.startswith("run-shell "), binding)
            self.assertFalse(binding.startswith("run-shell -b "), binding)
        sidebar_command = next(line.split(" B ", 1)[1] for line in keys.splitlines() if " B " in line)
        registry = Path(os.environ.get('PSMUX_DATA_DIR', str(Path.home() / '.psmux')))
        base = self.namespace + '__trial'
        port = int((registry / (base + '.port')).read_text())
        key = (registry / (base + '.key')).read_text().strip()

        def press_sidebar_binding():
            # Attached clients send this stored command to the server. A CLI
            # run-shell without formats runs locally and misses handle failures.
            with socket.create_connection(('127.0.0.1', port), timeout=30) as connection:
                connection.sendall(('AUTH ' + key + '\n' + sidebar_command + '\n').encode('utf-8'))
                connection.shutdown(socket.SHUT_WR)
                with connection.makefile('r', encoding='utf-8') as reader:
                    self.assertEqual('OK', reader.readline().strip())
                    output = reader.read()
            self.assertEqual('', output.strip())
            report = self.root / 'hook-sidebar.txt'
            self.assertTrue(report.exists())
            self.assertEqual('', report.read_text(encoding='utf-8-sig').strip())

        directory = self.root / "launcher checkout"
        directory.mkdir()
        command = ["pwsh", "-NoLogo", "-NoProfile", "-File", str(wrapper), "dev", str(directory), "-WorkspaceScript", str(self.workspace.SCRIPT)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(any(p["@repo-path"] == str(directory) and p["@repo-view"] == "dev" for p in self.workspace.panes()))
        press_sidebar_binding()
        self.assertEqual({p['window_id'] for p in self.workspace.panes()},
                         set(self.agents.sidebar_panes(self.workspace)[1]))
        created = self.workspace.tmux("new-window", "-d", "-P", "-F", "#{window_id}", "-n", "hook test")
        try:
            self.wait_for(lambda: created in self.agents.sidebar_panes(self.workspace)[1])
        except AssertionError:
            reports = '\n'.join(path.name + ': ' + path.read_text(encoding='utf-8-sig')
                                for path in self.root.glob('hook-*.txt'))
            self.fail('Sidebar hook did not add a pane:\n' + reports)
        press_sidebar_binding()
        self.wait_for(lambda: not self.agents.sidebar_panes(self.workspace)[1])


if __name__ == "__main__":
    unittest.main()
