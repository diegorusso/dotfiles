"""Native process-based agent navigation. No agent hooks or daemon are installed."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

AGENTS = ("codex", "claude", "opencode", "gemini", "copilot", "aider")


def agent_name(row):
    name = row["name"].lower()
    if name in AGENTS:
        return name
    if name in ("node", "bun", "python", "python3"):
        for agent in AGENTS:
            if re.search(r"(?:^|[\\/\s@])" + agent + r"(?:[\\/\s.\"-]|$)", row.get("command", ""), re.I):
                return agent
    return None


def agent_rows(workspace):
    processes = workspace.processes()
    rows = []
    for pane in workspace.panes():
        if pane["pane_title"] == "dotfiles-agent-sidebar":
            continue
        shell = int(pane["pane_pid"] or 0)
        found = set()
        for pid, process in processes.items():
            name = agent_name(process)
            if not name:
                continue
            current, visited = pid, set()
            while current and current not in visited:
                if current == shell:
                    found.add(name)
                    break
                visited.add(current)
                current = processes.get(current, {}).get("parent")
        if found:
            rows.append({**pane, "agent": "/".join(sorted(found)), "state": "running"})
    return rows


def clean(text):
    return re.sub(r"[\x00-\x1f\x7f]", "", text)


def jump(workspace, row):
    workspace.tmux("select-window", "-t", row["window_id"])
    workspace.tmux("select-pane", "-t", row["pane_id"])
    workspace.tmux("switch-client", "-t", workspace.session_target(row["session_id"]))


def picker(workspace):
    if not shutil.which("fzf"):
        raise RuntimeError("Agent picker requires fzf")
    rows = agent_rows(workspace)
    if not rows:
        print("No running agents found in native PSMux panes.")
        return
    text = "\n".join(row["pane_id"] + "\t" + clean(f"{row['agent']} · running · {row['session_name']} · {row['window_name']}") for row in rows)
    preview = subprocess.list2cmdline([workspace.MUX, *workspace.MUX_ARGS, "capture-pane", "-p", "-t", "{1}"])
    result = subprocess.run(["fzf", "--delimiter=\t", "--with-nth=2..", "--reverse",
                             "--prompt=Agent> ", "--preview", preview], input=text, text=True, stdout=subprocess.PIPE)
    if result.returncode in (1, 130):
        return
    if result.returncode:
        raise RuntimeError("Agent picker failed")
    selected = result.stdout.split("\t", 1)[0].strip()
    row = next((row for row in rows if row["pane_id"] == selected), None)
    if row:
        jump(workspace, row)


def sidebar_panes(workspace):
    keys = ("window_id", "pane_id", "pane_title", "pane_start_command")
    output = workspace.tmux("list-panes", "-a", "-F", workspace.SEP.join("#{" + k + "}" for k in keys))
    rows = [dict(zip(keys, line.split(workspace.SEP, 3))) for line in output.splitlines() if line]
    return rows, {row["window_id"]: row["pane_id"] for row in rows
                  if row["pane_title"] == "dotfiles-agent-sidebar" or "native-agents.py" in row["pane_start_command"]}


def add_sidebar(workspace, window):
    _, sidebars = sidebar_panes(workspace)
    if window in sidebars or workspace.option("@dotfiles-native-sidebar") != "on":
        return
    workspace.save_sidebar_layouts(window)
    command = workspace.shell_command([sys.executable, str(Path(__file__).resolve()), "render", "--workspace", str(workspace.SCRIPT)])
    pane = workspace.tmux("split-window", "-h", "-d", "-P", "-F", "#{pane_id}", "-l", "30", "-t", window, "--", command)
    # PSMux 3.3.8 reports default-shell for pane_start_command. Mark the pane
    # while holding the sidebar lock, before the renderer has finished loading.
    workspace.set_pane_role(pane, "dotfiles-agent-sidebar")
    workspace.tmux("set-option", "-w", "-t", window, "@native-sidebar-visited", "yes")


def sync_sidebars(workspace):
    with workspace.locked("sidebar"):
        workspace.restore_sidebar_layouts()
        if workspace.option("@dotfiles-native-sidebar") == "on":
            rows, _ = sidebar_panes(workspace)
            for window in {row["window_id"] for row in rows}:
                if not workspace.option("@native-sidebar-visited", window):
                    add_sidebar(workspace, window)


def toggle_sidebar(workspace):
    with workspace.locked("sidebar"):
        workspace.restore_sidebar_layouts()
        rows, sidebars = sidebar_panes(workspace)
        windows = {row["window_id"] for row in rows}
        if windows == set(sidebars):
            workspace.tmux("set-option", "-g", "@dotfiles-native-sidebar", "off")
            for pane in sidebars.values():
                try:
                    workspace.tmux("kill-pane", "-t", pane)
                except RuntimeError:
                    # A sidebar may finish between the snapshot and close.
                    if any(row["pane_id"] == pane for row in workspace.panes()):
                        raise
            workspace.restore_sidebar_layouts()
        else:
            workspace.tmux("set-option", "-g", "@dotfiles-native-sidebar", "on")
            for window in windows - set(sidebars):
                add_sidebar(workspace, window)


def render(workspace):
    import msvcrt
    workspace.tmux("select-pane", "-t", os.environ["TMUX_PANE"], "-T", "dotfiles-agent-sidebar")
    selection, refresh_at, rows = 0, 0, []
    try:
        print("\033[?25l", end="", flush=True)
        while True:
            if time.monotonic() >= refresh_at:
                try:
                    rows = agent_rows(workspace)
                except (RuntimeError, subprocess.TimeoutExpired):
                    if workspace.run([workspace.MUX, *workspace.MUX_ARGS, "list-sessions"]).returncode:
                        return
                    refresh_at = time.monotonic() + 3
                    continue
                selection = min(selection, max(0, len(rows) - 1))
                width = shutil.get_terminal_size((30, 40)).columns
                lines = ["Agents · running processes", "j/k: select  Enter: jump", "q: close sidebar", ""]
                for index, row in enumerate(rows):
                    lines += [("> " if index == selection else "  ") + row["agent"],
                              "  " + clean(row["window_name"])]
                if not rows:
                    lines.append("No running agents")
                print("\033[H\033[2J" + "\n".join(line[:max(1, width - 1)] for line in lines), flush=True)
                refresh_at = time.monotonic() + 3
            if msvcrt.kbhit():
                key = msvcrt.getwch()
                if key in ("q", "\x03"):
                    return
                if key == "j":
                    selection = min(selection + 1, max(0, len(rows) - 1))
                    refresh_at = 0
                elif key == "k":
                    selection = max(0, selection - 1)
                    refresh_at = 0
                elif key == "\r" and rows:
                    jump(workspace, rows[selection])
            time.sleep(0.05)
    except KeyboardInterrupt:
        pass
    finally:
        print("\033[?25h", end="", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("agents", "sidebar", "sidebar-add", "render", "watch"))
    parser.add_argument("argument", nargs="?")
    parser.add_argument("--workspace", required=True)
    args = parser.parse_intermixed_args()
    spec = importlib.util.spec_from_file_location("workspace", args.workspace)
    workspace = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(workspace)
    if args.action == "agents":
        picker(workspace)
    elif args.action == "sidebar":
        toggle_sidebar(workspace)
    elif args.action == "sidebar-add":
        if args.argument:
            with workspace.locked("sidebar"):
                add_sidebar(workspace, args.argument)
        else:
            sync_sidebars(workspace)
    elif args.action == "watch":
        workspace.watch(lambda: sync_sidebars(workspace))
    else:
        render(workspace)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
