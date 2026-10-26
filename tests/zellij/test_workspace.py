"""Exercise the actual keys/layout with disposable sessions and fake commands."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
PICKER = ROOT / ".config/zellij/pick-repo.sh"
MONITOR = ROOT / ".config/zellij/open-monitor.sh"
RALPHEX = ROOT / ".config/zellij/ralphex.py"


def wait_for(predicate):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if value := predicate():
            return value
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for Zellij")


class LauncherTests(unittest.TestCase):
    def test_monitor_requires_a_session(self):
        result = subprocess.run(["bash", str(MONITOR)],
                                env=dict(os.environ, ZELLIJ_SESSION_NAME=""),
                                text=True, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inside Zellij", result.stderr)

    def test_machine_default_and_explicit_sessions(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-zj-") as directory:
            binary = Path(directory)
            for name, contents in {
                "hostname": '#!/bin/sh\n[ "$1" = -s ] || exit 64\n'
                            '[ "${DOTFILES_TEST_HOSTNAME_STATUS:-0}" = 0 ] || exit "$DOTFILES_TEST_HOSTNAME_STATUS"\n'
                            'printf "machine-a\\n"\n',
                "zellij": '#!/bin/sh\nprintf "%s\\0" "$@"\n',
            }.items():
                path = binary / name
                path.write_text(contents)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                       DOTFILES_COLOUR="purple", DOTFILES_TEST_HOSTNAME_STATUS="0")
            command = ["bash", "--noprofile", "--norc", "-c", 'source "$1"; shift; zj "$@"',
                       "fixture", str(ROOT / "shell/functions.bash")]
            for args, expected in [([], ["attach", "--create", "--force-run-commands", "machine-a"]),
                                   (["--session", "custom session"], ["--session", "custom session"]),
                                   (["attach", "custom session"], ["attach", "custom session"])]:
                with self.subTest(args=args):
                    env["DOTFILES_TEST_HOSTNAME_STATUS"] = "7" if args else "0"
                    result = subprocess.run(command + args, env=env, capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.decode().split("\0")[:-1],
                                     expected + ["options", "--theme", "dotfiles-purple"])
            env["DOTFILES_TEST_HOSTNAME_STATUS"] = "7"
            result = subprocess.run(command, env=env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 7)
            self.assertEqual(result.stdout, b"")


class PickerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dotfiles-picker-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repos = self.root / "repos"
        self.checkout = self.repos / "project's café $(touch PWNED)"
        self.checkout.mkdir(parents=True)
        binary = self.root / "bin"
        binary.mkdir()
        self.candidates = self.root / "candidates"
        self.calls = self.root / "zellij-args"
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                        ZELLIJ_SESSION_NAME="fixture", DOTFILES_REPO_ROOT=str(self.repos),
                        DOTFILES_TEST_CANDIDATES=str(self.candidates), DOTFILES_TEST_ZELLIJ_ARGS=str(self.calls))
        commands = {
            "fzf": '''#!/bin/bash
rows=$(cat)
printf '%s\\n' "$rows" > "$DOTFILES_TEST_CANDIDATES"
[[ ${DOTFILES_TEST_FZF_STATUS:-0} == 0 ]] || exit "$DOTFILES_TEST_FZF_STATUS"
printf '%s\\n' "${DOTFILES_TEST_SELECTION-${rows%%$'\\n'*}}"
''',
            "zellij": '''#!/bin/bash
if [[ $4 == list-panes ]]; then
    printf '%s\\n' "${DOTFILES_TEST_PANES:-[]}"
    exit "${DOTFILES_TEST_QUERY_STATUS:-0}"
fi
printf '%s\\0' "$@" > "$DOTFILES_TEST_ZELLIJ_ARGS"
exit "${DOTFILES_TEST_ZELLIJ_STATUS:-0}"
''',
            "python3": "#!/bin/sh\nexit 99\n",
        }
        for name, contents in commands.items():
            path = binary / name
            path.write_text(contents)
            path.chmod(0o755)

    def run_picker(self, **environment):
        return subprocess.run(["bash", str(PICKER)], env=dict(self.env, **environment), cwd=self.root,
                              stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=10)

    def test_cancel_errors_and_unknown_selection_cannot_open_a_tab(self):
        for status in (1, 130, 2):
            with self.subTest(status=status):
                result = self.run_picker(DOTFILES_TEST_FZF_STATUS=str(status))
                self.assertEqual(result.returncode, 1 if status == 2 else 0, result.stderr)
                self.assertFalse(self.calls.exists())
        result = self.run_picker(DOTFILES_TEST_SELECTION=str(self.root) + "\toutside checkout")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no longer available", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_paths_are_literal_deduplicated_and_safe_for_fzf(self):
        (self.repos / "alias").symlink_to(self.checkout, target_is_directory=True)
        (self.repos / ".hidden").mkdir()
        (self.repos / "with\ttab").mkdir()
        unusual = self.repos / "with-newline\n"
        unusual.mkdir()
        (self.repos / "newline-alias").symlink_to(unusual, target_is_directory=True)
        escaped = self.repos / "escape\x1b[31m"
        escaped.mkdir()
        result = self.run_picker()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("\t") for line in self.candidates.read_text().splitlines()]
        self.assertEqual(rows, [[str(self.checkout), self.checkout.name], [str(escaped), "escape[31m"]])
        args = self.calls.read_bytes().decode().split("\0")[:-1]
        self.assertEqual(args, ["--session", "fixture", "action", "new-tab", "--layout",
                                str(PICKER.parent / "layouts/repo.kdl"), "--cwd", str(self.checkout),
                                "--name", self.checkout.name])
        self.assertFalse((self.root / "PWNED").exists())

    def test_missing_session_root_and_zellij_failure_are_reported(self):
        for environment, message in [({"ZELLIJ_SESSION_NAME": ""}, "inside Zellij"),
                                     ({"DOTFILES_REPO_ROOT": str(self.root / "missing")}, "repository parent")]:
            with self.subTest(environment=environment):
                result = self.run_picker(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.calls.exists())
        result = self.run_picker(DOTFILES_TEST_ZELLIJ_STATUS="7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not open", result.stderr)

    def test_existing_checkout_matches_subdirectories_and_symlinks_after_renaming(self):
        subprocess.run(["git", "-C", str(self.checkout), "init", "-q"], check=True)
        nested = self.checkout / "nested \\ directory"
        nested.mkdir()
        alias = self.root / "checkout alias"
        alias.symlink_to(self.checkout, target_is_directory=True)
        for cwd in (self.checkout, nested, alias):
            with self.subTest(cwd=cwd):
                panes = [{"tab_id": 17, "tab_name": "renamed", "pane_cwd": str(cwd),
                          "is_plugin": False, "is_floating": False}]
                result = self.run_picker(DOTFILES_TEST_PANES=json.dumps(panes))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls.read_bytes().decode().split("\0")[:-1],
                                 ["--session", "fixture", "action", "go-to-tab-by-id", "17"])
        result = self.run_picker(DOTFILES_TEST_PANES=json.dumps(panes), DOTFILES_TEST_ZELLIJ_STATUS="7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not switch", result.stderr)
        self.assertFalse((self.root / "PWNED").exists())

    def test_same_name_worktrees_and_floating_panes_do_not_reuse_the_wrong_tab(self):
        subprocess.run(["git", "-C", str(self.checkout), "init", "-q"], check=True)
        subprocess.run(["git", "-C", str(self.checkout), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-qm", "fixture"], check=True)
        worktree = self.root / "outside/topic"
        subprocess.run(["git", "-C", str(self.checkout), "worktree", "add", "-qb", "topic", str(worktree)], check=True)
        other = self.root / "elsewhere" / self.checkout.name
        other.mkdir(parents=True)
        panes = [{"tab_id": i, "tab_name": self.checkout.name, "pane_cwd": str(cwd),
                  "is_plugin": False, "is_floating": floating}
                 for i, (cwd, floating) in enumerate([(other, False), (worktree, False), (self.checkout, True)])]
        result = self.run_picker(DOTFILES_TEST_PANES=json.dumps(panes))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_bytes().decode().split("\0")[3], "new-tab")

    def test_failed_or_invalid_pane_query_does_not_create_a_duplicate(self):
        for environment in ({"DOTFILES_TEST_QUERY_STATUS": "7"}, {"DOTFILES_TEST_PANES": "invalid JSON"}):
            with self.subTest(environment=environment):
                result = self.run_picker(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Could not inspect", result.stderr)
                self.assertFalse(self.calls.exists())


@unittest.skipUnless(shutil.which("zellij") and shutil.which("fzf"), "Zellij/fzf not installed")
class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dotfiles-zellij-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.session = "dotfiles-check-" + uuid.uuid4().hex[:10]
        self.env = dict(os.environ, SHELL="/bin/sh", TERM="xterm-256color", COLORTERM="truecolor",
                        DOTFILES_COLOUR="blue", FZF_DEFAULT_OPTS="--filter=topic",
                        PYTHONDONTWRITEBYTECODE="1")
        for name in ("ZELLIJ", "ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID", "ZELLIJ_CONFIG_FILE", "TMUX", "TMUX_PANE"):
            self.env.pop(name, None)
        for name in ("XDG_RUNTIME_DIR", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "ZELLIJ_CONFIG_DIR"):
            path = self.root / name
            path.mkdir(mode=0o700)
            self.env[name] = str(path)
        config = Path(self.env["ZELLIJ_CONFIG_DIR"])
        shutil.copytree(ROOT / ".config/zellij/layouts", config / "layouts")
        text = (ROOT / ".config/zellij/config.kdl").read_text().replace("$HOME/.config/zellij/pick-repo.sh", str(PICKER))
        text = text.replace("$HOME/.config/zellij/open-monitor.sh", str(MONITOR))
        (config / "config.kdl").write_text(text + "\nshow_release_notes false\n")
        binary = self.root / "bin"
        binary.mkdir()
        self.env["PATH"] = str(binary) + os.pathsep + self.env["PATH"]
        hostname = binary / "hostname"
        hostname.write_text(f'#!/bin/sh\nprintf "%s\\n" "{self.session}"\n')
        hostname.chmod(0o755)
        for command in ("nvim", "codex", "htop", "sudo"):
            self.env[f"DOTFILES_TEST_{command.upper()}_LOG"] = str(self.root / (command + "-calls.jsonl"))
            fake = binary / command
            fake.write_text('''#!/usr/bin/env python3
import json, os, sys
command = os.path.basename(sys.argv[0]).upper()
with open(os.environ[f'DOTFILES_TEST_{command}_LOG'], 'a') as stream:
    stream.write(json.dumps({'args':sys.argv[1:], 'cwd':os.getcwd()}) + '\\n')
print(f'FIXTURE_{command}_READY', flush=True)
for line in sys.stdin:
    if line.strip() == 'exit':
        break
''')
            fake.chmod(0o755)
        self.repos = self.root / "repos"
        self.main = self.repos / "project's café with spaces"
        self.main.mkdir(parents=True)
        self.git(self.main, "init", "-q", "-b", "main")
        self.git(self.main, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-qm", "fixture")
        self.worktree = self.root / "outside/topic with spaces"
        self.git(self.main, "worktree", "add", "-qb", "topic", str(self.worktree))
        self.env["DOTFILES_REPO_ROOT"] = str(self.repos)
        self.addCleanup(lambda: subprocess.run(["zellij", "kill-session", self.session], env=self.env,
                                               capture_output=True, timeout=10))
        self.start_client()
        wait_for(lambda: b"FIXTURE_CODEX_READY" in self.output)
        wait_for(lambda: b"FIXTURE_NVIM_READY" in self.output)
        wait_for(lambda: len(self.terminals()) == 3)
        wait_for(lambda: len(self.calls()) == 1)

    def start_client(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 160, 0, 0))
        output = bytearray()
        self.master, self.output = master, output
        self.client = client = subprocess.Popen([
            "bash", "--noprofile", "--norc", "-c", 'source "$1"; zj',
            "fixture", str(ROOT / "shell/functions.bash"),
        ], env=self.env, cwd=self.main, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        def drain():
            try:
                while data := os.read(master, 65536):
                    output.extend(data)
            except OSError:
                pass
        threading.Thread(target=drain, daemon=True).start()
        def close_client():
            if client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            os.close(master)
        self.addCleanup(close_client)

    @staticmethod
    def git(directory, *args):
        subprocess.run(["git", "-C", str(directory), *args], check=True, capture_output=True)

    def action(self, *args):
        result = subprocess.run(["zellij", "--session", self.session, "action", *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        if result.returncode:
            raise RuntimeError(result.stderr or result.stdout)
        return result.stdout.strip()

    def panes(self):
        try:
            return json.loads(self.action("list-panes", "--json") or "[]")
        except RuntimeError:
            return []

    def terminals(self):
        return [p for p in self.panes() if not p["is_plugin"]]

    def calls(self, command="codex"):
        path = Path(self.env[f"DOTFILES_TEST_{command.upper()}_LOG"])
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def keys(self, keys):
        os.write(self.master, keys)

    def test_plain_zj_reattaches_to_machine_session_without_restarting_commands(self):
        initial_panes = {p["id"] for p in self.terminals()}
        self.keys(b'\x0fd')  # Ctrl+O, d: detach without closing the session.
        self.assertEqual(self.client.wait(timeout=5), 0)
        self.start_client()
        wait_for(lambda: b"FIXTURE_CODEX_READY" in self.output)
        wait_for(lambda: b"FIXTURE_NVIM_READY" in self.output)
        self.assertIn(self.session.encode(), self.output)
        self.assertEqual({p["id"] for p in self.terminals()}, initial_panes)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.calls("nvim")), 1)

    def test_plain_zj_resurrects_saved_commands_without_enter(self):
        self.action("rename-tab", "Saved workspace")
        self.action("save-session")
        self.keys(b'\x11')  # Ctrl+Q: stop this disposable session.
        self.assertEqual(self.client.wait(timeout=5), 0)
        self.start_client()
        wait_for(lambda: len(self.calls()) == 2)
        wait_for(lambda: len(self.calls("nvim")) == 2)
        wait_for(lambda: len(self.terminals()) == 3)
        panes = self.terminals()
        self.assertTrue(all(p["tab_name"] == "Saved workspace" for p in panes))
        self.assertTrue(all(not p["is_held"] for p in panes))
        self.assertEqual(self.calls()[-1], {"args": ["resume", "--last"], "cwd": str(self.main)})
        self.assertEqual(self.calls("nvim")[-1], {"args": [], "cwd": str(self.main)})

    def test_one_codex_device_colour_and_new_panes_follow_current_directory(self):
        self.assertEqual(self.calls(), [{"args": ["resume", "--last"], "cwd": str(self.main)}])
        self.assertEqual(self.calls("nvim"), [{"args": [], "cwd": str(self.main)}])
        panes = sorted(self.terminals(), key=lambda p: p["pane_x"])
        self.assertEqual([p["title"] for p in panes], ["nvim", "shell", "codex"])
        self.assertEqual(len({p["pane_y"] for p in panes}), 1)
        widths = [p["pane_columns"] for p in panes]
        self.assertLessEqual(max(widths) - min(widths), 1)
        wait_for(lambda: b"95;175;255" in self.output)
        nested = self.main / "nested directory"
        nested.mkdir()
        self.keys(("cd " + shlex.quote(str(nested)) + "\r").encode())
        wait_for(lambda: any(p.get("pane_cwd") == str(nested) for p in self.terminals()))
        initial = {p["id"] for p in self.terminals()}
        self.keys(b'\x10r')  # Ctrl+P, r: split right.
        new = wait_for(lambda: next((p for p in self.terminals() if p["id"] not in initial and p.get("pane_cwd")), None))
        self.assertEqual(new["pane_cwd"], str(nested))
        self.assertIsNone(new.get("terminal_command"))
        self.keys(b'\x14n')  # Ctrl+T, n: new tab.
        wait_for(lambda: len(self.terminals()) == 5)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.calls("nvim")), 1)

    def test_picker_opens_outside_worktree_with_one_codex(self):
        self.keys(b'\x02R')  # Ctrl+B, Shift+R: repository picker.
        wait_for(lambda: len(self.calls()) == 2)
        wait_for(lambda: len(self.terminals()) == 6)
        self.assertEqual(self.calls()[-1], {"args": ["resume", "--last"], "cwd": str(self.worktree)})
        self.assertEqual(self.calls("nvim")[-1], {"args": [], "cwd": str(self.worktree)})
        selected = [p for p in self.terminals() if p.get("pane_cwd") == str(self.worktree)]
        self.assertEqual(len(selected), 3)
        self.assertTrue(all("[topic]" in p["tab_name"] for p in selected))
        self.action("rename-tab", "Working topic")
        existing = {p["id"] for p in self.terminals()}
        target = selected[0]["tab_id"]
        original = next(p["tab_id"] for p in self.terminals() if p["tab_id"] != target)
        self.action("go-to-tab-by-id", str(original))
        self.keys(b'\x02R')
        wait_for(lambda: json.loads(self.action("current-tab-info", "--json"))["tab_id"] == target)
        wait_for(lambda: {p["id"] for p in self.terminals()} == existing)
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(len(self.calls("nvim")), 2)
        self.assertTrue(all(p["tab_name"] == "Working topic" for p in self.terminals() if p["tab_id"] == target))

    def test_monitor_shortcut_opens_reuses_and_recreates_three_panes(self):
        uname = self.root / "bin/uname"
        uname.write_text('#!/bin/sh\nprintf "Linux\\n"\n')
        uname.chmod(0o755)
        self.keys(b'\x02M')
        wait_for(lambda: len(self.terminals()) == 6 and len(self.calls("sudo")) == 1)
        monitor = sorted((p for p in self.terminals() if p["tab_name"] == "monitor"),
                         key=lambda p: (p["pane_x"], p["pane_y"]))
        self.assertEqual([p["title"] for p in monitor], ["htop", "dmesg", "shell"])
        htop, logs, shell = monitor
        self.assertEqual(htop["pane_x"] + htop["pane_columns"], logs["pane_x"])
        self.assertEqual(logs["pane_x"], shell["pane_x"])
        self.assertEqual(htop["pane_y"], logs["pane_y"])
        self.assertEqual(logs["pane_y"] + logs["pane_rows"], shell["pane_y"])
        self.assertEqual(htop["pane_rows"], logs["pane_rows"] + shell["pane_rows"])
        self.assertLessEqual(abs(logs["pane_rows"] - shell["pane_rows"]), 1)
        widths = [p["pane_columns"] for p in monitor]
        self.assertLessEqual(max(widths) - min(widths), 1)
        self.assertEqual(self.calls("htop"), [{"args": [], "cwd": self.env["HOME"]}])
        self.assertEqual(self.calls("sudo"), [{"args": ["dmesg", "-wH"], "cwd": self.env["HOME"]}])
        self.assertIsNone(monitor[2].get("terminal_command"))
        self.assertTrue(monitor[1]["is_focused"])
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.calls("nvim")), 1)

        initial = {p["id"] for p in self.terminals()}
        self.action("go-to-tab", "1")
        self.keys(b'\x02M')
        wait_for(lambda: json.loads(self.action("current-tab-info", "--json"))["name"] == "monitor")
        wait_for(lambda: {p["id"] for p in self.terminals()} == initial)
        self.assertEqual(len(self.calls("htop")), 1)
        self.assertEqual(len(self.calls("sudo")), 1)

        self.keys(b'\x03')
        wait_for(lambda: any(p["id"] == monitor[1]["id"] and p.get("pane_command") == "/bin/sh"
                            for p in self.terminals()))
        self.action("focus-pane-id", str(monitor[0]["id"]))
        self.keys(b'exit\r')
        wait_for(lambda: any(p["id"] == monitor[0]["id"] and p.get("pane_command") == "/bin/sh"
                            for p in self.terminals()))
        self.assertTrue(all(not p["exited"] and not p["is_held"] for p in self.terminals()))
        self.assertEqual(len(self.calls("htop")), 1)
        self.assertEqual(len(self.calls("sudo")), 1)

        self.action("close-tab")
        wait_for(lambda: len(self.terminals()) == 3)
        self.keys(b'\x02M')
        wait_for(lambda: len(self.terminals()) == 6 and len(self.calls("sudo")) == 2)
        self.assertEqual(len(self.calls("htop")), 2)
        self.assertEqual(len(self.calls()), 1)

    def test_monitor_uses_macos_kernel_log_stream(self):
        uname = self.root / "bin/uname"
        uname.write_text('#!/bin/sh\nprintf "Darwin\\n"\n')
        uname.chmod(0o755)
        self.keys(b'\x02M')
        wait_for(lambda: len(self.calls("sudo")) == 1)
        self.assertEqual(self.calls("sudo")[0]["args"],
                         ["log", "stream", "--style", "compact", "--predicate", 'process == "kernel"'])

    @unittest.skipUnless(shutil.which("lsof"), "lsof not installed")
    def test_ralphex_auto_logs_follow_runs_without_focus_or_agent_changes(self):
        def stop(process):
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)

        watcher = subprocess.Popen([sys.executable, str(RALPHEX), "watch", self.session],
                                   env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(watcher.stderr.close)
        self.addCleanup(stop, watcher)
        runner = self.root / "bin/ralphex"
        shutil.copyfile(shutil.which("sleep"), runner)
        runner.chmod(0o755)
        if shutil.which("codesign"):
            subprocess.run(["codesign", "--force", "--sign", "-", str(runner)],
                           check=True, capture_output=True)
        command = [str(runner), "90"]
        if sys.platform.startswith("linux"):
            command = [sys.executable, "-c", 'import ctypes, time; '
                       'assert ctypes.CDLL(None).prctl(15, b"ralphex", 0, 0, 0) == 0; '
                       'time.sleep(90)']
        unrelated = self.root / "unrelated"
        unrelated.mkdir()
        self.git(unrelated, "init", "-q")
        with (unrelated / "other.log").open("w") as other_log:
            other = subprocess.Popen(command, cwd=unrelated, stdout=other_log, stderr=other_log)
        self.addCleanup(stop, other)
        log = self.worktree / "runner's output.log"
        stream = log.open("w")
        self.addCleanup(stream.close)

        def start_runner():
            process = subprocess.Popen(command, cwd=self.worktree, stdout=stream, stderr=stream)
            self.addCleanup(stop, process)
            return process

        original = self.terminals()
        shell = next(p for p in original if p["title"] == "shell")
        geometry = {p["id"]: tuple(p[k] for k in ("pane_x", "pane_y", "pane_columns", "pane_rows"))
                    for p in original}
        first = start_runner()
        viewer = wait_for(lambda: next((p for p in self.terminals()
                                      if p["title"].endswith(":logs")), None))
        self.assertEqual(len(self.terminals()), 4)
        self.assertEqual({p["tab_id"] for p in self.terminals()}, {shell["tab_id"]})
        self.assertTrue(viewer["is_floating"])
        self.assertFalse(json.loads(self.action("list-tabs", "--json"))[0]["are_floating_panes_visible"])
        self.assertEqual({p["id"]: tuple(p[k] for k in ("pane_x", "pane_y", "pane_columns", "pane_rows"))
                          for p in self.terminals() if p["id"] in geometry}, geometry)
        self.assertEqual(viewer["pane_cwd"], str(self.worktree))
        self.assertIn("[topic]", viewer["title"])
        self.keys(b"printf 'FOCUS_STAYED_IN_SHELL\\n'\r")
        wait_for(lambda: "FOCUS_STAYED_IN_SHELL" in self.action("dump-screen", "--pane-id", str(shell["id"])))
        stream.write("RALPHEX_FIRST_RUN\n")
        stream.flush()
        wait_for(lambda: "RALPHEX_FIRST_RUN" in self.action("dump-screen", "--pane-id", str(viewer["id"])))
        self.keys(b'\x1bf')  # Alt+F: show the log without creating another pane.
        wait_for(lambda: json.loads(self.action("list-tabs", "--json"))[0]["are_floating_panes_visible"])
        self.keys(b'\x10w')  # Ctrl+P, w: hide it again.
        wait_for(lambda: not json.loads(self.action("list-tabs", "--json"))[0]["are_floating_panes_visible"])
        duplicate = subprocess.run([sys.executable, str(RALPHEX), "watch", self.session],
                                   env=self.env, capture_output=True, timeout=5)
        self.assertEqual(duplicate.returncode, 0, duplicate.stderr)

        stop(first)
        stream.close()
        stream = (self.worktree / "next-run.txt").open("w")
        self.addCleanup(stream.close)
        second = start_runner()
        stream.write("RALPHEX_SECOND_RUN\n")
        stream.flush()
        wait_for(lambda: "RALPHEX_SECOND_RUN" in self.action("dump-screen", "--pane-id", str(viewer["id"])))
        time.sleep(5.5)
        self.assertEqual(len(self.terminals()), 4)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.calls("nvim")), 1)

        self.action("close-pane", "--pane-id", str(viewer["id"]))
        time.sleep(5.5)
        self.assertEqual(len(self.terminals()), 3)
        self.assertEqual({p["id"] for p in self.terminals()}, set(geometry))
        stop(watcher)
        watcher = subprocess.Popen([sys.executable, str(RALPHEX), "watch", self.session],
                                   env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(watcher.stderr.close)
        self.addCleanup(stop, watcher)
        time.sleep(5.5)
        self.assertEqual(len(self.terminals()), 3)

        self.action("new-tab", "--name", "worktree", "--cwd", str(self.worktree),
                    "--no-focus", "--", "/bin/sh")
        worktree_pane = wait_for(lambda: next((p for p in self.terminals() if p["tab_name"] == "worktree"), None))
        stop(second)
        start_runner()
        viewer = wait_for(lambda: next((p for p in self.terminals()
                                      if p["title"].endswith(":logs")), None))
        self.assertEqual(viewer["tab_id"], worktree_pane["tab_id"])
        self.assertTrue(viewer["is_floating"])
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.calls("nvim")), 1)
        self.action("focus-pane-id", str(viewer["id"]))
        self.keys(b'\x03')
        wait_for(lambda: any(p["id"] == viewer["id"] and p.get("pane_command") == "/bin/sh"
                            for p in self.terminals()))
        time.sleep(5.5)
        self.assertEqual(len(self.terminals()), 5)
        self.assertTrue(any(p["id"] == viewer["id"] and p.get("pane_command") == "/bin/sh"
                            for p in self.terminals()))
        subprocess.run(["zellij", "kill-session", self.session], env=self.env,
                       check=True, capture_output=True, timeout=10)
        self.assertEqual(watcher.wait(timeout=20), 0)

    def test_selected_tab_has_distinct_background_after_switching(self):
        self.action("rename-tab", "First")
        self.keys(b'\x14n')
        wait_for(lambda: len(self.terminals()) == 4)
        self.action("rename-tab", "Second")

        def background_before(label):
            output = bytes(self.output)
            if label not in output:
                return None
            prefix = output.rsplit(label, 1)[0]
            colours = re.findall(rb"\x1b\[48;2;(\d+;\d+;\d+)m", prefix)
            return colours[-1] if colours else None

        active, inactive = b"95;175;255", b"95;148;200"
        wait_for(lambda: background_before(b" Second ") == active)
        self.assertEqual(background_before(b" First "), inactive)
        self.keys(b'\x141')  # Ctrl+T, 1: select the first tab.
        wait_for(lambda: background_before(b" First ") == active)
        self.assertEqual(background_before(b" Second "), inactive)

    def test_help_opens_floating_and_q_closes_without_restarting_commands(self):
        initial = {p["id"] for p in self.terminals()}
        self.keys(b'\x02?')
        help_pane = wait_for(lambda: next((p for p in self.terminals() if p["id"] not in initial), None))
        self.assertTrue(help_pane["is_floating"])
        wait_for(lambda: "Custom shortcuts: Ctrl+B R = repo picker; Ctrl+B M = monitor; Ctrl+B ? = help" in
                 self.action("dump-screen", "--pane-id", str(help_pane["id"])))
        self.assertIn("keybinds {", self.action("dump-screen", "--pane-id", str(help_pane["id"])))
        self.keys(b'q')
        wait_for(lambda: {p["id"] for p in self.terminals()} == initial)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.calls("nvim")), 1)

    def test_codex_exit_and_interrupt_return_to_shell_without_relaunch(self):
        pane = next(p for p in self.terminals() if p["title"] == "codex")
        self.keys(b'\x10l\x10exit\r')  # Focus right, leave Pane mode, then exit Codex.
        wait_for(lambda: any(p["id"] == pane["id"] and p.get("pane_command") == "/bin/sh" for p in self.terminals()))
        self.keys(b"printf 'SHELL_AFTER_CODEX\\n'\r")
        wait_for(lambda: "SHELL_AFTER_CODEX" in [line.strip() for line in self.action("dump-screen", "--pane-id", str(pane["id"])).splitlines()])
        self.assertEqual(len(self.calls()), 1)
        self.keys(b'\x02R')
        wait_for(lambda: len(self.calls()) == 2)
        wait_for(lambda: len(self.terminals()) == 6)
        pane = next(p for p in self.terminals() if p["title"] == "codex" and p["id"] != pane["id"])
        self.keys(b'\x10l\x10\x03')
        wait_for(lambda: any(p["id"] == pane["id"] and p.get("pane_command") == "/bin/sh" for p in self.terminals()))
        self.keys(b'\r')
        time.sleep(0.2)
        self.assertEqual(len(self.calls()), 2)
        self.assertTrue(all(not p["exited"] for p in self.terminals()))


if __name__ == "__main__":
    unittest.main()
