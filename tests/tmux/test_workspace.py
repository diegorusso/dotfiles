"""Real isolated-server tests; no user panes, agents or configuration are changed."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("workspace", ROOT / ".tmux/layouts/workspace.py")
workspace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspace)


class WorkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="tmux-check-")
        cls.root = Path(cls.temporary.name).resolve()
        cls.home = cls.root / "home"
        cls.home.mkdir()
        cls.real_tmux = shutil.which("tmux")
        if not cls.real_tmux:
            raise unittest.SkipTest("tmux is not installed")
        cls.socket = cls.root / "server.sock"
        cls.bin = cls.root / "bin"
        cls.bin.mkdir()
        shim = cls.bin / "tmux"
        shim.write_text(f'#!/bin/sh\nexec "{cls.real_tmux}" -S "{cls.socket}" "$@"\n')
        shim.chmod(0o755)
        shutil.copytree(ROOT / ".tmux/layouts", cls.home / ".tmux/layouts")
        cls.environment = patch.dict(os.environ, {
            "HOME": str(cls.home), "XDG_STATE_HOME": str(cls.root / "state"),
            "PATH": str(cls.bin) + os.pathsep + os.environ["PATH"],
            "TMUX": "", "TMUX_PANE": "", "TERM": "xterm-256color",
        })
        cls.environment.start()
        cls.state_patch = patch.object(workspace, "STATE", cls.root / "state/dotfiles-tmux")
        cls.state_patch.start()
        try:
            workspace.tmux("-f", str(ROOT / ".tmux.conf"), "new-session", "-d", "-s", "trial", "-x", "180", "-y", "50")
            workspace.tmux("set-option", "-g", "default-shell", "/bin/bash")
            workspace.tmux("set-option", "-g", "default-command", "exec /bin/bash --noprofile --norc")
            for option in ("@dev-editor-command", "@dev-assistant-command", "@monitor-command"):
                workspace.tmux("set-option", "-g", option, "none")
            cls.session = workspace.tmux("display-message", "-p", "#{session_id}")
            cls.pane = workspace.tmux("display-message", "-p", "#{pane_id}")
            os.environ["TMUX"] = workspace.tmux("display-message", "-p", "#{socket_path},#{pid},0")
            os.environ["TMUX_PANE"] = cls.pane
            cls.repos = cls.root / "repos"
            cls.main = cls.repos / "project with spaces"
            cls.main.mkdir(parents=True)
            cls.git(cls.main, "init", "-q", "-b", "main")
            cls.git(cls.main, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-qm", "fixture")
            cls.worktree = cls.root / "elsewhere/trial-worktree"
            cls.git(cls.main, "worktree", "add", "-qb", "topic", str(cls.worktree))
        except Exception:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        subprocess.run([cls.real_tmux, "-S", str(cls.socket), "kill-server"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.state_patch.stop()
        cls.environment.stop()
        cls.temporary.cleanup()

    @staticmethod
    def git(directory, *args):
        subprocess.run(["git", "-C", str(directory), *args], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    @staticmethod
    def wait_for(predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.1)
        raise AssertionError("Timed out waiting for tmux")

    def test_worktrees_outside_repo_root_and_symlink_deduplication(self):
        alias = self.repos / "alias"
        alias.symlink_to(self.main)
        try:
            rows = list(workspace.list_checkouts(self.repos))
            self.assertEqual(len(rows), 2)
            self.assertEqual({p for p, _ in rows}, {str(self.main), str(self.worktree)})
            self.assertIn("[topic]", dict(rows)[str(self.worktree)])
        finally:
            alias.unlink()

    def test_picker_opens_actual_selected_worktree(self):
        env = dict(os.environ, FZF_DEFAULT_OPTS="--filter=trial-worktree")
        result = subprocess.run(["bash", str(ROOT / ".tmux/layouts/pick-repo.sh"), str(self.repos)],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(p.get("@repo-path") == str(self.worktree) and p.get("@repo-view") == "dev"
                            for p in workspace.panes()))

    def test_concurrent_launch_and_reuse_after_metadata_loss(self):
        helper = ROOT / ".tmux/layouts/dev-3cols.sh"
        jobs = [subprocess.Popen(["bash", str(helper), str(self.main)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(3)]
        for job in jobs:
            _, stderr = job.communicate(timeout=15)
            self.assertEqual(job.returncode, 0, stderr.decode())
        before = [p for p in workspace.panes() if p.get("@repo-path") == str(self.main)
                  and p.get("@repo-view") == "dev"]
        self.assertEqual(len(before), 3)
        window = before[0]["window_id"]
        workspace.tmux("set-option", "-wu", "-t", window, "@repo-path")
        workspace.tmux("set-option", "-wu", "-t", window, "@repo-view")
        reused, _, fresh = workspace.ensure_view(self.session, self.main, "dev")
        self.assertEqual(reused, window)
        self.assertFalse(fresh)
        self.assertEqual({p["pane_id"] for p in before},
                         {p["pane_id"] for p in workspace.panes() if p["window_id"] == window})

    def test_same_basename_and_other_session_do_not_collide(self):
        other = self.root / "other" / self.main.name
        other.mkdir(parents=True)
        first, _, _ = workspace.ensure_view(self.session, self.main, "dev")
        second, _, _ = workspace.ensure_view(self.session, other, "dev")
        self.assertNotEqual(first, second)
        second_session = workspace.tmux("new-session", "-d", "-P", "-F", "#{session_id}", "-s", "other")
        try:
            third, _, _ = workspace.ensure_view(second_session, self.main, "dev")
            self.assertNotEqual(first, third)
        finally:
            workspace.tmux("kill-session", "-t", second_session)

    def test_tests_monitor_and_popup_bindings(self):
        first = workspace.ensure_view(self.session, self.worktree, "tests")
        second = workspace.ensure_view(self.session, self.worktree, "tests")
        self.assertEqual(first[0], second[0])
        self.assertEqual(workspace.tmux("display-message", "-p", "-t", first[1], "#{pane_current_path}"), str(self.worktree))
        first = workspace.ensure_view(self.session, self.home, "monitor")
        self.assertEqual(first[0], workspace.ensure_view(self.session, self.worktree, "monitor")[0])
        bindings = workspace.tmux("list-keys", "-T", "prefix")
        for key in ("R", "M", "L", "T", "A", "B"):
            self.assertRegex(bindings, r"(?m)^bind-key\s+-T prefix " + key + r"\s+")
        self.assertIn("ccmux picker --client-tty", bindings)

    def test_log_selection_ignores_readers_and_other_checkouts(self):
        log = self.worktree / "run.log"
        log.write_text("one\n")
        wrong = self.main / "wrong.log"
        wrong.write_text("wrong\n")
        files = [{"path": str(log), "name": "tee", "access": "w", "fd": "1"},
                 {"path": str(wrong), "name": "tee", "access": "w", "fd": "1"},
                 {"path": str(self.worktree / "task.log"), "name": "tail", "access": "r", "fd": "3"}]
        self.assertEqual(workspace.select_log(files, self.worktree), str(log))
        self.assertEqual(workspace.relatives(3, {1: {"name": "codex", "parent": 0},
                         2: {"name": "bash", "parent": 1}, 3: {"name": "ralphex", "parent": 2},
                         4: {"name": "tee", "parent": 2}}), {2, 3, 4})

    def test_real_runner_auto_log_window_without_focus_change(self):
        with workspace.locked("layout"):
            workspace.ensure_view(self.session, self.main, "dev", focus=False)
        runner = self.bin / "ralphex"
        shutil.copyfile(shutil.which("sleep"), runner)
        runner.chmod(0o755)
        if shutil.which("codesign"):
            subprocess.run(["codesign", "--force", "--sign", "-", str(runner)], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        log = self.worktree / "automatic.log"
        active = workspace.tmux("display-message", "-p", "#{window_id}")
        with log.open("w") as stream:
            job = subprocess.Popen([str(runner), "60"], cwd=self.worktree, stdout=stream, stderr=stream)
            try:
                self.wait_for(lambda: str(self.worktree) in workspace.discover())
                self.wait_for(lambda: any(p.get("@repo-path") == str(self.worktree) and
                                          p.get("@repo-view") == "logs" for p in workspace.panes()))
                self.assertEqual(workspace.tmux("display-message", "-p", "#{window_id}"), active)
                pane = next(p for p in workspace.panes() if p.get("@repo-path") == str(self.worktree)
                            and p.get("@repo-view") == "logs")
                stream.write("RUNNER_OUTPUT\n")
                stream.flush()
                self.wait_for(lambda: "RUNNER_OUTPUT" in workspace.tmux("capture-pane", "-p", "-t", pane["pane_id"]))
                workspace.tmux("send-keys", "-t", pane["pane_id"], "C-c")
                self.wait_for(lambda: workspace.tmux("display-message", "-p", "-t", pane["pane_id"], "#{pane_current_command}") == "bash")
                time.sleep(5.5)
                self.assertEqual(workspace.tmux("display-message", "-p", "-t", pane["pane_id"], "#{pane_current_command}"), "bash")
                workspace.sync_log(self.session, str(self.worktree), workspace.discover()[str(self.worktree)], focus=True)
                self.wait_for(lambda: workspace.tmux("display-message", "-p", "-t", pane["pane_id"], "#{pane_current_command}") != "bash")
            finally:
                job.terminate()
                job.wait(timeout=5)

    def test_saved_codex_command_uses_exact_identity_and_safe_fallback(self):
        pane = workspace.panes()[0]
        path = self.root / "snapshot.txt"
        fields = ["pane", pane["session_name"], pane["window_index"], "1", "*", pane["pane_index"],
                  "title", pane["pane_current_path"], "1", "codex", ":codex resume --last"]
        path.write_text("\t".join(fields) + "\n")
        native = "11111111-2222-3333-4444-555555555555"
        agent = {"agentType": "codex", "tmuxPane": pane["pane_id"], "nativeSessionId": native,
                 "cwd": pane["pane_current_path"], "pid": int(pane["pane_pid"])}
        workspace.save_layout(path, [agent])
        self.assertIn(native, path.read_text())
        self.assertNotIn("--last", path.read_text())
        # A daemon on another socket may reuse pane IDs: PID ancestry must match.
        workspace.save_layout(path, [{**agent, "pid": 99999999}])
        self.assertTrue(path.read_text().endswith(":codex resume\n"))
        workspace.save_layout(path, [])
        self.assertTrue(path.read_text().endswith(":codex resume\n"))

    def test_background_sync_preserves_an_unowned_shell(self):
        directory = self.root / "manual-log-window"
        directory.mkdir()
        log = directory / "run.log"
        log.write_text("LOG\n")
        _, pane, _ = workspace.ensure_view(self.session, directory, "logs", focus=False)
        workspace.sync_log(self.session, str(directory), {
            "worktree": str(directory), "log": str(log), "identity": "manual:start"})
        self.assertEqual(workspace.tmux("display-message", "-p", "-t", pane, "#{pane_current_command}"), "bash")

    def test_new_job_switches_log_without_restarting_viewer(self):
        directory = self.root / "log-checkout"
        directory.mkdir()
        first_log, second_log = directory / "first.log", directory / "second.log"
        first_log.write_text("FIRST\n")
        second_log.write_text("SECOND\n")
        first = {"worktree": str(directory), "log": str(first_log), "identity": "1:start"}
        workspace.sync_log(self.session, str(directory), first)
        pane = next(p for p in workspace.panes() if p.get("@repo-path") == str(directory))
        self.wait_for(lambda: "FIRST" in workspace.tmux("capture-pane", "-p", "-t", pane["pane_id"]))
        shell = int(pane["pane_pid"])
        pid = next(pid for pid, row in workspace.processes().items() if row["parent"] == shell)
        workspace.sync_log(self.session, str(directory), {**first, "log": str(second_log), "identity": "2:start"})
        self.wait_for(lambda: "SECOND" in workspace.tmux("capture-pane", "-p", "-t", pane["pane_id"]))
        self.assertEqual(workspace.processes()[pid]["parent"], shell)
        replacement = directory / "replacement.log"
        replacement.write_text("ROTATED\n")
        replacement.replace(second_log)
        self.wait_for(lambda: "ROTATED" in workspace.tmux("capture-pane", "-p", "-t", pane["pane_id"]))


if __name__ == "__main__":
    unittest.main()
