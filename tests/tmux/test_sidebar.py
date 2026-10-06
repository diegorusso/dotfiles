"""Exercise layout preservation against real tmux split/close operations."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sidebar_workspace", ROOT / ".tmux/layouts/workspace.py")
workspace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspace)

# Mirror ccmux 1.4.3's native tmux operations without starting an agent daemon.
CCMUX = '''#!/usr/bin/env python3
import os
import subprocess
import sys
import time

def tmux(*args):
    return subprocess.check_output(["tmux", *args], text=True).strip()

if "--toggle" not in sys.argv:
    time.sleep(0.2)  # Real sidebars set their title only after booting.
    tmux("select-pane", "-t", os.environ["TMUX_PANE"], "-T", "ccmux-sidebar")
    os.execlp("sleep", "sleep", "60")

rows = [row.split("|") for row in tmux("list-panes", "-a", "-F",
        "#{window_id}|#{pane_id}|#{pane_title}").splitlines()]
windows = {row[0] for row in rows}
sidebars = {row[0]: row[1] for row in rows if row[2] == "ccmux-sidebar"}
if windows == set(sidebars):
    tmux("set-hook", "-gu", "after-new-window[99]")
    for pane in sidebars.values():
        tmux("kill-pane", "-t", pane)
else:
    for window in windows - set(sidebars):
        tmux("split-window", "-fhbd", "-l", "30", "-t", window, "ccmux sidebar")
    tmux("set-hook", "-g", "after-new-window[99]",
         "split-window -fhbd -l 30 'ccmux sidebar'")
'''


class SidebarTests(unittest.TestCase):
    def setUp(self):
        self.real_tmux = shutil.which("tmux")
        if not self.real_tmux:
            self.skipTest("tmux is not installed")
        self.temporary = tempfile.TemporaryDirectory(prefix="tmux-sidebar-check-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.socket = self.root / "server.sock"
        binary = self.root / "bin"
        binary.mkdir()
        (binary / "tmux").write_text(f'#!/bin/sh\nexec "{self.real_tmux}" -S "{self.socket}" "$@"\n')
        (binary / "ccmux").write_text(CCMUX)
        for path in binary.iterdir():
            path.chmod(0o755)
        shutil.copytree(ROOT / ".tmux/layouts", self.root / ".tmux/layouts")
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.root), "XDG_STATE_HOME": str(self.root / "state"),
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "TMUX": "", "TMUX_PANE": "", "TERM": "xterm-256color",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        state = patch.object(workspace, "STATE", self.root / "state/dotfiles-tmux")
        state.start()
        self.addCleanup(state.stop)
        self.addCleanup(lambda: subprocess.run(
            [self.real_tmux, "-S", str(self.socket), "kill-server"], capture_output=True))
        workspace.tmux("-f", str(ROOT / ".tmux.conf"), "new-session", "-d", "-s", "trial",
                       "-x", "180", "-y", "50", "sleep 60")
        os.environ["TMUX"] = workspace.tmux("display-message", "-p", "#{socket_path},#{pid},0")
        self.window = workspace.tmux("display-message", "-p", "#{window_id}")
        workspace.tmux("split-window", "-dh", "-t", self.window, "sleep 60")
        workspace.tmux("split-window", "-dh", "-t", self.window, "sleep 60")
        workspace.tmux("select-layout", "-t", self.window, "even-horizontal")

    @staticmethod
    def wait_for(predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        raise AssertionError("Timed out waiting for sidebar layout restoration")

    def sidebar(self, window):
        return workspace.tmux("list-panes", "-t", window, "-F", "#{pane_id}",
                              "-f", "#{==:#{pane_title},ccmux-sidebar}")

    def layout(self, window):
        return workspace.tmux("display-message", "-p", "-t", window, "#{window_layout}")

    def open_sidebar(self):
        workspace.toggle_sidebar()
        self.wait_for(lambda: all(self.sidebar(window) for window in workspace.sidebar_windows()))

    def test_repeated_toggles_restore_custom_and_nested_layouts(self):
        nested = workspace.tmux("new-window", "-dP", "-F", "#{window_id}", "sleep 60")
        right = workspace.tmux("split-window", "-dhP", "-F", "#{pane_id}", "-t", nested, "sleep 60")
        workspace.tmux("split-window", "-dv", "-t", right, "sleep 60")
        workspace.tmux("resize-pane", "-t", self.window + ".0", "-x", "90")
        layouts = {window: self.layout(window) for window in (self.window, nested)}
        pids = workspace.tmux("list-panes", "-a", "-F", "#{pane_id} #{pane_pid}")
        for _ in range(5):
            self.open_sidebar()
            workspace.toggle_sidebar()
            for window, original in layouts.items():
                self.assertEqual(self.layout(window), original)
                self.assertEqual(workspace.option("@dotfiles-sidebar-layout", window), "")
        self.assertEqual(workspace.tmux("list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"), pids)

    def test_close_and_exit_hooks_restore_without_another_toggle(self):
        original = self.layout(self.window)
        for command in ("kill-pane", "send-keys"):
            self.open_sidebar()
            pane = self.sidebar(self.window)
            workspace.tmux(command, "-t", pane, *(["C-c"] if command == "send-keys" else []))
            self.wait_for(lambda: not workspace.option("@dotfiles-sidebar-layout", self.window))
            self.assertEqual(self.layout(self.window), original)

    def test_auto_open_in_new_window_saves_before_splitting(self):
        self.open_sidebar()
        window = workspace.tmux("new-window", "-dP", "-F", "#{window_id}", "sleep 60")
        self.wait_for(lambda: self.sidebar(window))
        saved = json.loads(workspace.option("@dotfiles-sidebar-layout", window))
        self.assertEqual(len(saved["panes"]), 1)
        workspace.tmux("kill-pane", "-t", self.sidebar(window))
        self.wait_for(lambda: not workspace.option("@dotfiles-sidebar-layout", window))
        self.assertEqual(self.layout(window), saved["layout"])

    def test_window_resize_scales_saved_layout(self):
        self.open_sidebar()
        workspace.tmux("resize-window", "-t", self.window, "-x", "240")
        workspace.toggle_sidebar()
        widths = [int(value) for value in workspace.tmux(
            "list-panes", "-t", self.window, "-F", "#{pane_width}").splitlines()]
        self.assertEqual(sum(widths) + 2, 240)
        self.assertLessEqual(max(widths) - min(widths), 2)

    def test_changed_working_panes_are_not_rearranged(self):
        self.open_sidebar()
        extra = workspace.tmux("split-window", "-dvP", "-F", "#{pane_id}",
                               "-t", self.window + ".1", "sleep 60")
        workspace.tmux("kill-pane", "-t", self.sidebar(self.window))
        closed_layout = self.layout(self.window)
        self.wait_for(lambda: not workspace.option("@dotfiles-sidebar-layout", self.window))
        self.assertEqual(self.layout(self.window), closed_layout)
        self.assertIn(extra, workspace.sidebar_windows()[self.window]["panes"])


if __name__ == "__main__":
    unittest.main()
