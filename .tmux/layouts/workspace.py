#!/usr/bin/env python3
"""Small tmux checkout helper. Native tmux owns all panes and their lifetime."""
import argparse
import base64
from collections import deque
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

WINDOWS = os.name == "nt"
if WINDOWS:
    import msvcrt
else:
    import fcntl

SCRIPT = Path(__file__).resolve()
STATE = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "dotfiles-tmux"
MUX = "psmux" if WINDOWS else "tmux"
MUX_ARGS = ["-L", os.environ["DOTFILES_MUX_NAMESPACE"]] if os.environ.get("DOTFILES_MUX_NAMESPACE") else []
NATIVE_POPUP_SESSION = None
SEP = "|||"
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")


def run(argv):
    return subprocess.run(list(map(str, argv)), text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, encoding="utf-8" if WINDOWS else None, timeout=10)


def tmux(*args):
    if WINDOWS and args and args[0] == "show-option":
        args = ("show-options", *args[1:])
    # Released PSMux 3.3.8 accepts user options, but does not isolate them by
    # window. Keep the helper's window metadata separately on this platform.
    if WINDOWS and args and args[0] in ("set-option", "show-options"):
        flags = "".join(arg[1:] for arg in args[1:] if isinstance(arg, str) and arg.startswith("-") and arg != "-t")
        if "w" in flags and "-t" in args:
            target_index = args.index("-t")
            target = args[target_index + 1]
            remaining = args[target_index + 2:]
            if remaining and remaining[0].startswith("@"):
                key = remaining[0]
                if args[0] == "show-options":
                    return native_metadata().get(target, {}).get(key, "")
                with locked("metadata"):
                    metadata = native_metadata()
                    values = metadata.setdefault(target, {})
                    if "u" in flags:
                        values.pop(key, None)
                    else:
                        values[key] = remaining[1]
                    atomic_json(native_metadata_path(), metadata)
                return ""
    # Without TMUX, PSMux routes bare pane/window IDs to the latest session.
    # Keep every command launched by a popup on its originating session.
    if WINDOWS and NATIVE_POPUP_SESSION:
        args = list(args)
        if "-t" in args:
            index = args.index("-t") + 1
            if str(args[index]).startswith("%"):
                args[index] = NATIVE_POPUP_SESSION + ":." + str(args[index])
            elif str(args[index]).startswith(("@", ":", ".")):
                args[index] = NATIVE_POPUP_SESSION + ":" + str(args[index]).lstrip(":")
        else:
            args += ["-t", NATIVE_POPUP_SESSION + ":"]
    result = run([MUX, *MUX_ARGS, *args])
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "tmux command failed")
    return result.stdout.strip()


def option(name, target=None):
    return tmux("show-options", "-wqv" if target else "-gqv",
                *(["-t", target] if target else []), name)


def git(directory, *args):
    result = run(["git", "-C", directory, *args])
    return result.stdout.rstrip("\n") if result.returncode == 0 else ""


def checkout(directory):
    return str(Path(git(directory, "rev-parse", "--show-toplevel") or directory).resolve())


def repo_key(directory):
    value = git(directory, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return str(Path(value).resolve()) if value else None


def label(directory):
    directory = Path(directory)
    worktrees = git(directory, "worktree", "list", "--porcelain", "-z").split("\0")
    primary = next((Path(s[9:]) for s in worktrees if s.startswith("worktree ")), directory)
    name = primary.name + "/" + directory.name if primary != directory else directory.name
    branch = git(directory, "symbolic-ref", "--quiet", "--short", "HEAD")
    branch = branch or git(directory, "rev-parse", "--short", "HEAD")
    return name + (f" [{branch}]" if branch else "")


def list_checkouts(base):
    seen = set()
    for directory in sorted(Path(base).iterdir()):
        if directory.name.startswith(".") or not directory.is_dir():
            continue
        paths = [directory]
        paths += [Path(s[9:]) for s in git(directory, "worktree", "list", "--porcelain", "-z").split("\0")
                  if s.startswith("worktree ")]
        for path in paths:
            path = path.resolve()
            if path in seen or not path.is_dir():
                continue
            seen.add(path)
            # fzf rows are line/tab delimited; don't offer an ambiguous path.
            if "\n" not in str(path) and "\t" not in str(path):
                yield str(path), label(path)


def panes():
    keys = ["session_id", "session_name", "window_id", "window_index", "window_name",
            "pane_id", "pane_index", "pane_current_path", "pane_current_command", "pane_pid", "pane_title",
            "@repo-view", "@repo-path", "@checkout-label"]
    output = tmux("list-panes", "-a", "-F", SEP.join("#{" + k + "}" for k in keys))
    rows = [dict(zip(keys, line.split(SEP))) for line in output.splitlines() if line]
    if WINDOWS:
        metadata = native_metadata()
        for row in rows:
            for key in ("@repo-view", "@repo-path", "@checkout-label"):
                row[key] = metadata.get(row["window_id"], {}).get(key, "")
    return rows


def caller(pane=None):
    global NATIVE_POPUP_SESSION
    target = pane or os.environ.get("TMUX_PANE")
    # PSMux popups are outside the window's pane tree. They provide the
    # originating session, but neither TMUX nor TMUX_PANE (unlike tmux popups).
    popup_session = os.environ.get("PSMUX_SESSION") if WINDOWS else None
    if not os.environ.get("TMUX") and not target and not popup_session:
        raise RuntimeError("Run this helper inside tmux")
    if popup_session and not target and not os.environ.get("TMUX"):
        NATIVE_POPUP_SESSION = popup_session
    target = target or (popup_session + ":" if popup_session else None)
    value = tmux("display-message", "-p", *(["-t", target] if target else []), "#{session_id}" + SEP + "#{pane_id}")
    session_id, pane_id = value.split(SEP, 1)
    pane = next((p for p in panes() if p["session_id"] == session_id and p["pane_id"] == pane_id), None)
    if pane is None:
        raise RuntimeError("The calling tmux pane is no longer open")
    return pane


@contextmanager
def locked(name, blocking=True):
    STATE.mkdir(parents=True, mode=0o700, exist_ok=True)
    server = server_identity()
    token = hashlib.sha256((server + name).encode()).hexdigest()[:24]
    with (STATE / (token + ".lock")).open("a+b") as stream:
        try:
            if WINDOWS:
                stream.seek(0, os.SEEK_END)
                if not stream.tell():
                    stream.write(b"\0")
                    stream.flush()
                while True:
                    stream.seek(0)
                    try:
                        msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                        break
                    except OSError:
                        if not blocking:
                            yield False
                            return
                        time.sleep(0.1)
            else:
                fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            if WINDOWS:
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


def server_identity():
    # PSMux has a server per session; its namespace identity is shared and stable.
    return tmux("display-message", "-p", "#{server_instance}" if WINDOWS else "#{socket_path}:#{pid}")


def native_metadata_path():
    token = hashlib.sha256(server_identity().encode()).hexdigest()[:24]
    return STATE / ("windows-" + token + ".json")


def native_metadata():
    try:
        return json.loads(native_metadata_path().read_text())
    except FileNotFoundError:
        return {}


def view_kind(pane):
    return pane.get("@repo-view", "") or next(
        (v for v in ("dev", "logs", "tests", "monitor")
         if pane["window_name"].endswith(":" + v) or pane["window_name"].endswith("-" + v)
         or pane["window_name"] == v), "")


def sidebar_windows():
    keys = ("window_id", "window_layout", "pane_id", "pane_title", "pane_start_command")
    rows = tmux("list-panes", "-a", "-F", SEP.join("#{" + key + "}" for key in keys))
    windows = {}
    for row in rows.splitlines():
        window, layout, pane, title, command = row.split(SEP, 4)
        state = windows.setdefault(window, {"layout": layout, "panes": [], "sidebar": False})
        state["panes"].append(pane)
        # ccmux delays startup in background windows, so the title alone is
        # insufficient immediately after its split-window command returns.
        if title in ("ccmux-sidebar", "dotfiles-agent-sidebar") or re.search(r'''(?:^|[/\s"'])ccmux\s+sidebar(?:[\s"']|$)''', command) or "native-agents.py" in command:
            state["sidebar"] = True
    return windows


def save_sidebar_layouts(target=None):
    for window, state in sidebar_windows().items():
        if (target is None or window == target) and not state["sidebar"]:
            tmux("set-option", "-w", "-t", window, "@dotfiles-sidebar-layout", json.dumps(state))


def restore_sidebar_layouts(target=None):
    for window, state in sidebar_windows().items():
        if (target is not None and window != target) or state["sidebar"]:
            continue
        saved = option("@dotfiles-sidebar-layout", window)
        if not saved:
            continue
        original = json.loads(saved)
        # select-layout can move pane contents when IDs no longer match. Keep
        # the current layout if working panes were added or removed meanwhile.
        if set(original["panes"]) == set(state["panes"]):
            layout = native_layout(original["layout"]) if WINDOWS else original["layout"]
            tmux("select-layout", "-t", window, layout)
        tmux("set-option", "-wu", "-t", window, "@dotfiles-sidebar-layout")


def native_layout(layout):
    """Encode PSMux's integer split percentages, avoiding its cell-to-percent floor."""
    body, position = layout.split(",", 1)[1], 0

    def parse():
        nonlocal position
        match = re.match(r"(\d+)x(\d+),(\d+),(\d+)", body[position:])
        if not match:
            raise RuntimeError("Invalid saved PSMux layout")
        dimensions = list(map(int, match.groups()))
        position += match.end()
        node = {"dimensions": dimensions}
        if position < len(body) and body[position] in "{[":
            opening = body[position]
            closing = "}" if opening == "{" else "]"
            position += 1
            children = [parse()]
            while body[position] == ",":
                position += 1
                children.append(parse())
            if body[position] != closing:
                raise RuntimeError("Invalid saved PSMux split")
            position += 1
            node.update(opening=opening, children=children)
        else:
            match = re.match(r",(\d+)", body[position:])
            if not match:
                raise RuntimeError("Invalid saved PSMux pane")
            node["pane"] = match.group(1)
            position += match.end()
        return node

    root = parse()
    if position != len(body):
        raise RuntimeError("Trailing data in saved PSMux layout")

    def encode(node, override=None):
        dimensions = node["dimensions"].copy()
        if override:
            dimensions[override[0]] = override[1]
        prefix = f"{dimensions[0]}x{dimensions[1]},{dimensions[2]},{dimensions[3]}"
        if "pane" in node:
            return prefix + "," + node["pane"]
        axis = 0 if node["opening"] == "{" else 1
        children = node["children"]
        total = sum(child["dimensions"][axis] for child in children)
        weights = [(child["dimensions"][axis] * 100 + total - 1) // total for child in children[:-1]]
        weights.append(max(0, 100 - sum(weights)))
        return prefix + node["opening"] + ",".join(encode(child, (axis, weight)) for child, weight in zip(children, weights)) + ("}" if axis == 0 else "]")

    encoded = encode(root)
    checksum = 0
    for byte in encoded.encode():
        checksum = (((checksum >> 1) | ((checksum & 1) << 15)) + byte) & 0xffff
    return f"{checksum:04x}," + encoded


def toggle_sidebar():
    if not shutil.which("ccmux"):
        raise RuntimeError("The agent sidebar requires ccmux")
    with locked("sidebar"):
        # A close hook may still be queued when the next toggle arrives.
        restore_sidebar_layouts()
        save_sidebar_layouts()
        try:
            result = run(["ccmux", "sidebar", "--toggle"])
        finally:
            restore_sidebar_layouts()
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or "ccmux sidebar toggle failed")


def view_path(pane):
    return pane.get("@repo-path") or checkout(pane["pane_current_path"])


def stamp(window, directory, kind, previous=None):
    previous = previous or {}
    text = label(directory) if kind != "monitor" else "system"
    for key, value in (("@repo-path", directory), ("@repo-view", kind), ("@checkout-label", text)):
        if previous.get(key) != value:
            tmux("set-option", "-wq", "-t", window, key, value)
    name = "monitor" if kind == "monitor" else text + ":" + kind
    if previous.get("window_name") != name:
        tmux("set-option", "-wq", "-t", window, "automatic-rename", "off")
        tmux("rename-window", "-t", window, name)


def send(pane, command):
    tmux("send-keys", "-t", pane, "-l", command)
    tmux("send-keys", "-t", pane, "Enter")


def helper_command(*args):
    return shell_command([sys.executable if WINDOWS else "python3", str(SCRIPT), *map(str, args)])


def shell_command(argv):
    if WINDOWS:
        return "& " + " ".join("'" + str(arg).replace("'", "''") + "'" for arg in argv)
    return shlex.join(list(map(str, argv)))


def available(command):
    words = shlex.split(command, posix=not WINDOWS)
    if WINDOWS and words and words[0] == "&":
        words = words[1:]
    return words and shutil.which(words[0].strip("'\"") if WINDOWS else words[0])


def native_start_command(command, directory):
    if not WINDOWS or command == "none":
        return []
    # Run after PowerShell's profiles initialize, rather than injecting keys
    # into a shell that may still be starting or moving a warm pane's cwd.
    # Resolve tools inside that shell: profiles can add paths/functions that
    # the popup's Python process cannot see.
    shell = shutil.which("pwsh") or "pwsh.exe"
    if "\\windowsapps\\" in shell.lower() and "\\microsoft\\windowsapps\\" not in shell.lower():
        alias = Path(os.environ["LOCALAPPDATA"]) / "Microsoft/WindowsApps/pwsh.exe"
        if os.path.lexists(alias):
            shell = str(alias)
    directory = str(directory).replace("'", "''")
    script = f"Set-Location -LiteralPath '{directory}'; {command}"
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    return [subprocess.list2cmdline([shell, "-NoLogo", "-NoExit", "-EncodedCommand", encoded])]


def ensure_view(session, directory, kind, focus=True):
    directory = str(Path(directory).resolve())
    if not Path(directory).is_dir():
        raise RuntimeError("Not a directory: " + directory)
    for pane in panes():
        if pane["session_id"] == session and view_kind(pane) == kind and (
                kind == "monitor" or view_path(pane) == directory):
            stamp(pane["window_id"], directory, kind, pane)
            if focus:
                tmux("select-window", "-t", pane["window_id"])
            return pane["window_id"], pane["pane_id"], False
    editor = assistant = monitor = "none"
    if kind == "dev":
        editor = option("@dev-editor-command") or "nvim"
        assistant = option("@dev-assistant-command") or "codex resume --last || codex"
    elif kind == "monitor":
        monitor = option("@monitor-command") or (helper_command("monitor-loop") if WINDOWS else "htop" if shutil.which("htop") else "top")
    root_command = editor if kind == "dev" else monitor
    root = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", session_target(session) + ":",
                "-n", Path(directory).name + ":" + kind, "-c", directory,
                *native_start_command(root_command, directory))
    window = tmux("display-message", "-p", "-t", root, "#{window_id}")
    try:
        stamp(window, directory, kind)
        if kind == "dev":
            middle = tmux("split-window", "-d", "-h", "-P", "-F", "#{pane_id}", "-t", root, "-c", directory)
            right = tmux("split-window", "-d", "-h", "-P", "-F", "#{pane_id}", "-t", middle, "-c", directory,
                         *native_start_command(assistant, directory))
            tmux("select-layout", "-t", window, "even-horizontal")
            commands = [] if WINDOWS else [(root, editor), (right, assistant)]
            for pane, command in commands:
                if command != "none" and available(command):
                    send(pane, command)
                elif command != "none":
                    tmux("display-message", "Optional command not found: " + shlex.split(command)[0])
            for pane, role in ((root, "editor"), (middle, "shell"), (right, "agent")):
                set_pane_role(pane, role)
            tmux("select-pane", "-t", root)
        elif kind == "monitor":
            if not WINDOWS and monitor != "none" and available(monitor):
                send(root, monitor)
        elif kind == "logs":
            set_pane_role(root, "ralphex log")
        elif kind == "tests":
            set_pane_role(root, "tests")
        if focus:
            tmux("select-window", "-t", window)
        return window, root, True
    except Exception:
        tmux("kill-window", "-t", window)
        raise


def session_target(session):
    if WINDOWS:
        # PSMux 3.3.8 double-prefixes -L namespaces when resolving $N targets.
        # Session names resolve correctly in both default and named namespaces.
        for row in tmux("list-sessions", "-F", "#{session_id}" + SEP + "#{session_name}").splitlines():
            identity, name = row.split(SEP, 1)
            if identity == session:
                return name
    return session


def set_pane_role(pane, role):
    # PSMux 3.3.8 supports pane titles but only built-in pane-scoped options.
    if WINDOWS:
        tmux("select-pane", "-t", pane, "-T", role)
    else:
        tmux("set-option", "-pq", "-t", pane, "@pane-role", role)


def processes():
    if WINDOWS:
        command = "@(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CreationDate,CommandLine) | ConvertTo-Json -Compress"
        result = run(["pwsh", "-NoLogo", "-NoProfile", "-Command", command])
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or "Cannot query Windows processes")
        return {int(p["ProcessId"]): {"parent": int(p["ParentProcessId"]), "started": p["CreationDate"],
                                    "name": p["Name"].removesuffix(".exe"), "command": p.get("CommandLine") or ""}
                for p in json.loads(result.stdout or "[]")}
    rows = {}
    for line in run(["ps", "-axo", "pid=,ppid=,lstart=,comm="]).stdout.splitlines():
        fields = line.strip().split(None, 7)
        if len(fields) == 8:
            rows[int(fields[0])] = {"parent": int(fields[1]), "started": " ".join(fields[2:7]),
                                   "name": Path(fields[7]).name}
    return rows


def relatives(pid, rows):
    family, current = {pid}, rows[pid]["parent"]
    for _ in range(6):
        row = rows.get(current)
        if not row or row["name"] in ("tmux", "codex", "launchd", "systemd"):
            break
        family.add(current)
        family.update(p for p, item in rows.items()
                      if item["parent"] == current and item["name"] == "tee")
        current = row["parent"]
    return family


def open_files(pids):
    result = run(["lsof", "-a", "-p", ",".join(map(str, sorted(pids))), "-Fpcfan"])
    items, current = [], {}
    for line in result.stdout.splitlines():
        field, value = line[:1], line[1:]
        if field == "p":
            current = {"pid": int(value)}
        elif field == "c":
            current["name"] = value
        elif field == "f":
            current = {k: v for k, v in current.items() if k in ("pid", "name")}
            current["fd"] = value
        elif field == "a":
            current["access"] = value.strip()
        elif field == "n":
            items.append({**current, "path": value})
    return items


def select_log(files, worktree):
    candidates = []
    for item in files:
        path = Path(item["path"])
        if (not path.is_absolute() or item.get("access") not in ("w", "u")
                or path.suffix not in (".log", ".txt") or not path.is_relative_to(worktree)):
            continue
        score = 100 if item.get("name") == "tee" else 80 if path.suffix == ".log" else 60
        score += 10 if item.get("fd") in ("1", "2") else 0
        if path.is_file():
            candidates.append((score, path.stat().st_mtime, str(path)))
    return max(candidates)[2] if candidates else None


def discover():
    if WINDOWS:
        # Windows has no lsof. Explicitly registered logs are shared by the watcher.
        jobs = {}
        namespace = server_identity()
        for path in STATE.glob("log-*.json"):
            try:
                job = json.loads(path.read_text())
                if job.get("namespace") == namespace and Path(job["log"]).is_file():
                    jobs[job["worktree"]] = job
            except (OSError, ValueError, KeyError):
                continue
        return jobs
    jobs, rows = {}, processes()
    for pid, process in rows.items():
        if process["name"] != "ralphex":
            continue
        try:
            files = open_files(relatives(pid, rows))
            cwd = next(f["path"] for f in files if f["pid"] == pid and f.get("fd") == "cwd")
            directory = checkout(cwd)
            log = select_log(files, Path(directory))
            if log and repo_key(directory):
                jobs[directory] = {"worktree": directory, "log": log,
                                   "identity": str(pid) + ":" + process["started"]}
        except (OSError, StopIteration, subprocess.TimeoutExpired):
            continue
    return jobs


def log_state(directory):
    server = server_identity() if WINDOWS else tmux("display-message", "-p", "#{socket_path}")
    # Share the same checkout stream across sessions. Session IDs change after
    # Resurrect; a restored viewer must keep following the same state file.
    token = hashlib.sha256((server + directory).encode()).hexdigest()[:24]
    return STATE / ("log-" + token + ".json")


def atomic_json(path, data):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    encoded = json.dumps(data, indent=2) + "\n"
    if path.exists() and path.read_text() == encoded:
        return
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".update-")
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(encoded)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def sync_log(session, directory, job=None, focus=False):
    state = log_state(directory)
    if job:
        atomic_json(state, job)
    window, pane, fresh = ensure_view(session, directory, "logs", focus)
    identity = (job or {}).get("identity", "waiting")
    previous = tmux("show-option", "-wqv" if WINDOWS else "-pqv", "-t", window if WINDOWS else pane, "@log-job")
    command = tmux("display-message", "-p", "-t", pane, "#{pane_current_command}")
    # A stopped viewer stays stopped for this run; never interrupt another tool.
    if fresh or ((focus or (previous and previous != identity)) and command in ("bash", "zsh", "sh", "fish", "pwsh", "powershell", "pwsh.exe", "powershell.exe")):
        send(pane, helper_command("follow", state))
    tmux("set-option", "-wq" if WINDOWS else "-pq", "-t", window if WINDOWS else pane, "@log-job", identity)
    return window


def follow(state):
    current, stream, inode = None, None, None
    print("Ralphex logs: waiting for a runner in this checkout. Ctrl+C returns to the shell.", flush=True)
    try:
        while True:
            try:
                job = json.loads(Path(state).read_text())
                path = Path(job["log"])
                stat = path.stat()
                identity, replacement = (str(path), job["identity"]), (stat.st_dev, stat.st_ino)
                if identity != current or inode != replacement or (stream and stat.st_size < stream.tell()):
                    if stream:
                        stream.close()
                    print(f"\nRalphex · {job['worktree']}\nLog: {path}\n", flush=True)
                    stream = path.open("rb")
                    size = stream.seek(0, os.SEEK_END)
                    stream.seek(max(0, size - 131072))
                    sys.stdout.buffer.write(b"".join(deque(stream, maxlen=80)))
                    current, inode = identity, replacement
                output = stream.read()
                if output:
                    sys.stdout.buffer.write(output)
                sys.stdout.buffer.flush()
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        if stream:
            stream.close()


def refresh():
    seen = set()
    for pane in panes():
        window = pane["window_id"]
        if window in seen:
            continue
        seen.add(window)
        kind = view_kind(pane)
        if kind:
            directory = view_path(pane)
            if Path(directory).is_dir():
                stamp(window, directory, kind, pane)


def watch(on_refresh=None):
    with locked("watch", blocking=False) as acquired:
        if not acquired:
            return
        server = server_identity()
        seen = {}
        while True:
            try:
                if WINDOWS:
                    sessions = run([MUX, *MUX_ARGS, "list-sessions"])
                    if sessions.returncode or not sessions.stdout.strip():
                        return
                if server_identity() != server:
                    return
                with locked("layout"):
                    refresh()
                    open_repos = {(p["session_id"], repo_key(view_path(p))) for p in panes()
                                  if view_kind(p) in ("dev", "tests", "logs")}
                    jobs = discover() if WINDOWS or shutil.which("lsof") else {}
                    for directory, job in jobs.items():
                        for session, key in open_repos:
                            if key and key == repo_key(directory):
                                view = (session, directory)
                                existing = any(p["session_id"] == session and view_kind(p) == "logs"
                                               and view_path(p) == directory for p in panes())
                                if existing or seen.get(view) != job["identity"]:
                                    sync_log(session, directory, job)
                                seen[view] = job["identity"]
                if on_refresh:
                    on_refresh()
                time.sleep(5)
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
                # An empty server during startup is normal; a dead server exits.
                if run([MUX, *MUX_ARGS, "list-sessions"]).returncode:
                    return
                print(str(exc), file=sys.stderr)
                time.sleep(5)


def save_layout(path, agents=None):
    """Resurrect's native hook: preserve commands by exact conversation, never --last."""
    if agents is None:
        try:
            agents = json.loads(run(["ccmux", "show", "--json"]).stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            agents = []
    identities, rows = {}, processes()
    for agent in agents:
        native = agent.get("nativeSessionId", "")
        if agent.get("agentType") == "codex" and UUID.fullmatch(native or ""):
            identities[agent.get("tmuxPane")] = (native, checkout(agent["cwd"]), agent.get("pid"))
    targets = {(p["session_name"], p["window_index"], p["pane_index"]): p for p in panes()}
    lines = []
    for line in Path(path).read_text().splitlines():
        fields = line.split("\t")
        if len(fields) >= 11 and fields[0] == "pane" and fields[9] == "codex":
            pane = targets.get((fields[1], fields[2], fields[5]))
            identity = identities.get((pane or {}).get("pane_id"))
            command = ["codex", "resume"]
            # ccmux can be serving another socket. A pane number alone is not
            # identity: verify that its agent actually descends from this pane.
            pid = identity[2] if identity else None
            for _ in range(30):
                if not pid or str(pid) == (pane or {}).get("pane_pid"):
                    break
                pid = rows.get(pid, {}).get("parent")
            if identity and str(pid) == pane["pane_pid"] and identity[1] == checkout(pane["pane_current_path"]):
                command += [identity[0], "-C", identity[1]]
            fields[10] = ":" + shlex.join(command)
            line = "\t".join(fields)
        lines.append(line)
    Path(path).write_text("\n".join(lines) + "\n")


def monitor_loop():
    try:
        while True:
            result = run(["pwsh", "-NoProfile", "-Command", "Get-Process | Sort-Object CPU -Descending | Select-Object -First 20 Id,ProcessName,CPU,WorkingSet | Format-Table -AutoSize | Out-String -Width 100"])
            print("\033[H\033[2J" + result.stdout, flush=True)
            time.sleep(2)
    except KeyboardInterrupt:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["list", "dev", "tests", "logs", "monitor", "watch", "follow", "save", "refresh",
                                          "sidebar", "sidebar-save", "sidebar-restore", "monitor-loop"])
    parser.add_argument("argument", nargs="?")
    parser.add_argument("--log", help="Register an explicit log for this checkout (native Windows)")
    args = parser.parse_args()
    if args.action == "list":
        for path, title in list_checkouts(args.argument or str(Path.home() / "repos")):
            print(path + "\t" + title)
    elif args.action == "monitor-loop":
        monitor_loop()
    elif args.action == "follow":
        follow(args.argument)
    elif args.action == "watch":
        watch()
    elif args.action == "save":
        save_layout(args.argument)
    elif args.action == "sidebar":
        toggle_sidebar()
    elif args.action in ("sidebar-save", "sidebar-restore"):
        with locked("sidebar"):
            if args.action == "sidebar-save":
                # Only ccmux's auto-open hook needs a pre-split snapshot.
                if WINDOWS or "ccmux sidebar" in tmux("show-hooks", "-g", "after-new-window"):
                    save_sidebar_layouts(args.argument)
            else:
                restore_sidebar_layouts(args.argument)
    else:
        pane = caller(args.argument if args.action != "dev" else None)
        with locked("layout"):
            if args.action == "refresh":
                refresh()
            else:
                directory = (args.argument or str(Path.home())) if args.action == "dev" else view_path(pane)
                if args.action == "monitor":
                    directory = str(Path.home())
                if args.action == "logs":
                    job = discover().get(directory)
                    if args.log:
                        log = Path(args.log).resolve()
                        if not log.is_file():
                            raise RuntimeError("Log file does not exist: " + str(log))
                        job = {"worktree": directory, "log": str(log), "identity": str(time.time_ns())}
                        if WINDOWS:
                            job["namespace"] = server_identity()
                    sync_log(pane["session_id"], directory, job, focus=True)
                else:
                    ensure_view(pane["session_id"], directory, args.action)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
