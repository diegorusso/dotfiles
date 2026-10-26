#!/usr/bin/env python3
"""Follow Ralphex logs in floating panes in their Zellij repository tabs."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

SCRIPT = Path(__file__).resolve()
# Share detection and streaming with tmux without connecting to a tmux server.
sys.path.insert(0, str(SCRIPT.parents[2] / ".tmux/layouts"))
import workspace as shared


def session_state(session):
    namespace = os.environ.get("XDG_RUNTIME_DIR", "") + "\0" + session
    token = hashlib.sha256(namespace.encode()).hexdigest()[:24]
    root = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    directory = root / "dotfiles-zellij" / token
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    return directory


def action(session, *args):
    result = shared.run(["zellij", "--session", session, "action", *args])
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Zellij command failed")
    return result.stdout.strip()


def viewer_command(state):
    return ["bash", "-c", 'trap ":" INT; python3 "$1" follow "$2"; exec "${SHELL:-/bin/bash}"',
            "dotfiles-ralphex", str(SCRIPT), str(state)]


def sync_logs(session, directory, panes, jobs):
    if not jobs:
        return
    roots = [(p, shared.checkout(p["pane_cwd"]), shared.repo_key(p["pane_cwd"]))
             for p in panes if not p["is_plugin"] and p.get("pane_cwd")]
    for checkout, job in jobs.items():
        key = shared.repo_key(checkout)
        matches = [(p, root) for p, root, repo in roots if key and repo == key]
        if not matches:
            continue
        token = hashlib.sha256(checkout.encode()).hexdigest()[:24]
        state = directory / (token + ".json")
        try:
            previous = json.loads(state.read_text())
        except FileNotFoundError:
            previous = {}
        command = viewer_command(state)
        running = any(p.get("terminal_command") == " ".join(command)
                      and p.get("pane_command") == " ".join(command) for p in panes)
        opened = previous.get("opened_identity")
        if running or opened == job["identity"]:
            shared.atomic_json(state, {**job, "opened_identity": job["identity"]})
            continue
        shared.atomic_json(state, {**job, "opened_identity": opened})
        name = "".join(c for c in shared.label(checkout) if c.isprintable()) + ":logs"
        # Prefer the exact worktree; otherwise use a tab for the same repository.
        target, _ = max(matches, key=lambda pair: (pair[1] == checkout,
                                                  not pair[0]["is_floating"],
                                                  pair[0]["is_focused"]))
        action(session, "new-pane", "--tab-id", str(target["tab_id"]),
               "--floating", "--width", "80%", "--height", "60%",
               "--name", name, "--cwd", checkout,
               "--no-focus", "--close-on-exit", "--", *command)
        shared.atomic_json(state, {**job, "opened_identity": job["identity"]})


def watch(session):
    directory = session_state(session)
    with (directory / "watch.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        # A pane can close while its session continues; do not route through it.
        os.environ.pop("ZELLIJ_PANE_ID", None)
        failures = 0
        while True:
            try:
                panes = json.loads(action(session, "list-panes", "--json"))
            except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired):
                failures += 1
                if failures == 3:
                    return
            else:
                failures = 0
                try:
                    sync_logs(session, directory, panes, shared.discover())
                except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
                    print(f"Ralphex log watcher: {exc}", file=sys.stderr, flush=True)
            time.sleep(5)


def start(session):
    for command in ("zellij", "git", "lsof"):
        if not shutil.which(command):
            raise RuntimeError(f"Ralphex auto logs require {command}")
    directory = session_state(session)
    with (directory / "watch.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
    with (directory / "watcher.log").open("ab") as log:
        subprocess.Popen([sys.executable, str(SCRIPT), "watch", session],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=log, start_new_session=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "watch", "follow"))
    parser.add_argument("target", nargs="?")
    args = parser.parse_args()
    if args.action == "follow":
        if not args.target:
            parser.error("follow requires a log state file")
        shared.follow(args.target)
        return
    session = args.target or os.environ.get("ZELLIJ_SESSION_NAME")
    if not session:
        parser.error("start the watcher inside Zellij")
    try:
        (start if args.action == "start" else watch)(session)
    except (RuntimeError, OSError) as exc:
        parser.exit(1, f"Ralphex log watcher: {exc}\n")


if __name__ == "__main__":
    main()
