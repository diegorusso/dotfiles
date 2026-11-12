"""Native Windows Zellij helpers. Pane/session ownership always comes from Zellij."""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import msvcrt
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

SCRIPT = Path(__file__).resolve()
SHARED = Path(os.environ.get('DOTFILES_SHARED_WORKSPACE', str(Path.home() / '.tmux/layouts/workspace.py')))
spec = importlib.util.spec_from_file_location('shared_workspace', SHARED)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
STATE = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'dotfiles-zellij'
CONFIG = Path(os.environ.get('ZELLIJ_CONFIG_DIR', str(Path(os.environ['APPDATA']) / 'Zellij/config')))
WRAPPER = SCRIPT.with_suffix('.ps1')
SHELL = os.environ.get('DOTFILES_ZELLIJ_SHELL') or shutil.which('pwsh')


def canonical(path):
    return os.path.normcase(str(Path(path).resolve()))


def session_state(session):
    token = hashlib.sha256((os.environ.get('ZELLIJ_SOCKET_DIR', '') + '\0' + session).encode()).hexdigest()[:24]
    return STATE / token


@contextmanager
def locked(path, blocking=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a+b') as stream:
        if not stream.tell():
            stream.write(b'\0')
            stream.flush()
        acquired = False
        while not acquired:
            stream.seek(0)
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                acquired = True
            except OSError:
                if not blocking:
                    yield False
                    return
                time.sleep(.05)
        try:
            yield True
        finally:
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


def action(session, *args):
    result = shared.run(['zellij', '--session', session, 'action', *args])
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Zellij action failed')
    return result.stdout.strip()


def panes(session):
    rows = json.loads(action(session, 'list-panes', '--json'))
    if not isinstance(rows, list) or any(not isinstance(p, dict) or
            any(type(p.get(key)) is not bool for key in ('is_plugin', 'is_floating', 'is_focused')) or
            type(p.get('tab_id')) is not int or
            (p.get('pane_cwd') is not None and not isinstance(p['pane_cwd'], str)) for p in rows):
        raise RuntimeError('Could not inspect open repository tabs')
    return rows


def open_checkout(session, directory, label):
    with locked(session_state(session) / 'tabs.lock'):
        rows = panes(session)
        for pane in rows:
            if pane['is_plugin'] or pane['is_floating'] or not pane.get('pane_cwd'):
                continue
            if canonical(shared.checkout(pane['pane_cwd'])) == canonical(directory):
                action(session, 'go-to-tab-by-id', str(pane['tab_id']))
                return
        # Reuse can succeed from a known pane while another pane is starting.
        # Creation needs a complete inspection, otherwise it might duplicate it.
        if any(not p['is_plugin'] and not p['is_floating'] and not p.get('pane_cwd') for p in rows):
            raise RuntimeError('Repository pane directories are not available yet; retry the picker')
        action(session, 'new-tab', '--layout', str(CONFIG / 'layouts/repo.kdl'), '--cwd', directory, '--name', label)


def picker(session):
    root = Path(os.path.expandvars(os.environ.get('DOTFILES_REPO_ROOT', str(Path.home() / 'repos')))).expanduser()
    if not root.is_dir():
        raise RuntimeError('Set DOTFILES_REPO_ROOT to your repository parent directory')
    rows = {path: ''.join(c for c in label if c.isprintable()) for path, label in shared.list_checkouts(root)}
    if not rows:
        return
    offered = [path + '\t' + label for path, label in rows.items()]
    selected = subprocess.run(['fzf', '--delimiter=\t', '--with-nth=2..', '--reverse', '--prompt=Repo / worktree> '],
                              input='\n'.join(offered), text=True, encoding='utf-8', stdout=subprocess.PIPE)
    if selected.returncode in (1, 130):
        return
    selection = selected.stdout.rstrip('\r\n')
    if selected.returncode or selection not in offered:
        raise RuntimeError('Repository picker failed or selected an unknown checkout')
    directory = selection.split('\t', 1)[0]
    if not Path(directory).is_dir():
        raise RuntimeError('The selected checkout is no longer available')
    open_checkout(session, directory, rows[directory])


def monitor(session):
    with locked(session_state(session) / 'tabs.lock'):
        names = action(session, 'query-tab-names').splitlines()
        if 'monitor' in names:
            action(session, 'go-to-tab-name', 'monitor')
        else:
            action(session, 'new-tab', '--layout', str(CONFIG / 'layouts/monitor.kdl'), '--cwd', str(Path.home()))


def prepare_resurrection(session):
    """Wrap saved foreground programs only in an explicitly EXITED 0.45.1 session.

    Keep the native snapshot, geometry and cwd. No live cache is edited. Upstream
    Windows discovers child processes instead of retaining the -NoExit wrapper.
    """
    if Path(session).name != session or session in ('.', '..'):
        raise RuntimeError('Invalid session name')
    listing = shared.run(['zellij', 'list-sessions', '--no-formatting'])
    if not any(re.match(re.escape(session) + r'\s+.*\bEXITED\b', line) for line in listing.stdout.splitlines()):
        return
    path = Path(os.environ['LOCALAPPDATA']) / 'Zellij/cache/contract_version_1/session_info' / session / 'session-layout.kdl'
    if not path.is_file():
        return
    with locked(session_state(session) / 'restore.lock'):
        original = path.read_text(encoding='utf-8')
        # The pinned release serializes one pane declaration and args per line.
        # Match JSON-compatible quoted KDL strings; never interpret shell text.
        string = r'"(?:[^"\\]|\\.)*"'
        pane = re.compile(r'(?m)^(?P<head>\s*pane\b[^\n]*?\bcommand=)(?P<command>' + string + r')(?P<tail>[^\n]*\{)\n(?P<body>(?:' + string + r'|[^{}"])*?)^(?P<end>\s*})')

        def wrap(match):
            command = json.loads(match['command'])
            body = match['body']
            arguments = re.search(r'(?m)^\s*args\b([^\n]*)\n', body)
            args = [json.loads(token) for token in re.findall(string, arguments[1])] if arguments else []
            if '-NoExit' in args:
                return match[0]  # already has a usable profiled shell; avoid nesting
            if Path(command).name.lower() in ('starship', 'starship.exe'):
                command, args = SHELL, ['-NoLogo']  # transient prompt, not an application
            encoded = base64.b64encode(json.dumps([command, *args], ensure_ascii=False).encode()).decode()
            saved_args = ['-NoLogo', '-NoExit', '-File', str(WRAPPER), 'run-saved', encoded]
            if arguments:
                body = body[:arguments.start()] + body[arguments.end():]
            body = '                args ' + ' '.join(json.dumps(a, ensure_ascii=False) for a in saved_args) + '\n' + body
            return match['head'] + json.dumps(SHELL) + match['tail'] + '\n' + body + match['end']

        updated = pane.sub(wrap, original)
        if updated != original:
            backup = path.with_name('dotfiles-before-restore.kdl')
            if not backup.exists():
                shutil.copyfile(path, backup)
            temporary = path.with_suffix('.dotfiles-tmp')
            temporary.write_text(updated, encoding='utf-8')
            os.replace(temporary, path)


def events():
    last = 0
    try:
        while True:
            query = "Get-WinEvent -LogName System -MaxEvents 40 -ErrorAction Stop | Sort-Object RecordId | Where-Object RecordId -gt " + str(last)
            result = shared.run(['pwsh', '-NoLogo', '-NoProfile', '-Command', query + ' | Select-Object RecordId,TimeCreated,LevelDisplayName,ProviderName,Message | ConvertTo-Json -Compress'])
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or 'Cannot read the Windows System event log')
            records = json.loads(result.stdout or '[]')
            for record in records if isinstance(records, list) else [records]:
                print(f"{record['TimeCreated']} {record['LevelDisplayName']} {record['ProviderName']}: {record['Message']}", flush=True)
                last = max(last, record['RecordId'])
            time.sleep(2)
    except KeyboardInterrupt:
        pass


def run_runner(arguments):
    binary = shutil.which('ralphex')
    if not binary:
        raise RuntimeError('Install the native ralphex executable before using its PowerShell launch integration')
    directory = shared.checkout(os.getcwd())
    if not shared.repo_key(directory):
        raise RuntimeError('Run ralphex from a Git checkout')
    identity = uuid.uuid4().hex
    runs = STATE / 'runs'
    runs.mkdir(parents=True, exist_ok=True)
    log_path = runs / (identity + '.log')
    with log_path.open('wb') as log:
        process = subprocess.Popen([binary, *arguments], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        shared.atomic_json(runs / (identity + '.json'), {'identity': identity, 'worktree': directory, 'log': str(log_path),
                                                       'pid': process.pid, 'time': time.time()})
        try:
            while data := process.stdout.read1(65536):
                log.write(data)
                log.flush()
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            return process.wait()
        except KeyboardInterrupt:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
            return 130


def discover():
    jobs = {}
    for path in (STATE / 'runs').glob('*.json'):
        try:
            job = json.loads(path.read_text(encoding='utf-8'))
            previous = jobs.get(job['worktree'])
            if Path(job['log']).is_file() and (not previous or job['time'] > previous['time']):
                jobs[job['worktree']] = job
        except (OSError, ValueError, KeyError):
            continue
    return jobs


def sync_logs(session, directory, rows, jobs):
    roots = [(pane, shared.checkout(pane['pane_cwd']), shared.repo_key(pane['pane_cwd'])) for pane in rows
             if not pane['is_plugin'] and not pane['is_floating'] and pane.get('pane_cwd')]
    processes = None
    for checkout, job in jobs.items():
        repository = shared.repo_key(checkout)
        matches = [(pane, root) for pane, root, key in roots if key and repository and canonical(key) == canonical(repository)]
        if not matches:
            continue
        state = directory / (hashlib.sha256(canonical(checkout).encode()).hexdigest()[:24] + '.json')
        previous = json.loads(state.read_text(encoding='utf-8')) if state.exists() else {}
        running = False
        marker = state.with_suffix('.viewer')
        if marker.exists():
            if processes is None:
                processes = shared.processes()
            try:
                viewer = json.loads(marker.read_text(encoding='utf-8'))
                running = (processes.get(viewer['pid'], {}).get('started') == viewer['started'] and
                           any(not p['is_plugin'] and p['is_floating'] and p['id'] == viewer.get('pane') for p in rows))
            except (ValueError, KeyError):
                pass
        opened = previous.get('opened_identity')
        shared.atomic_json(state, {**job, 'opened_identity': job['identity'] if running else opened})
        if running or opened == job['identity']:
            continue
        target, _ = max(matches, key=lambda pair: (canonical(pair[1]) == canonical(checkout), pair[0]['is_focused']))
        action(session, 'new-pane', '--tab-id', str(target['tab_id']), '--floating', '--width', '80%', '--height', '60%',
               '--name', shared.label(checkout) + ':logs', '--cwd', checkout, '--no-focus', '--close-on-exit', '--',
               SHELL, '-NoLogo', '-NoExit', '-File', str(WRAPPER), 'follow', str(state))
        shared.atomic_json(state, {**job, 'opened_identity': job['identity']})


def follow(state):
    path = Path(state)
    marker = path.with_suffix('.viewer')
    pane_id = int(os.environ['ZELLIJ_PANE_ID'])
    session = os.environ['ZELLIJ_SESSION_NAME']
    shared.atomic_json(marker, {'pid': os.getpid(), 'started': shared.processes()[os.getpid()]['started'], 'pane': pane_id})
    checked = 0
    failures = 0

    def closed():
        nonlocal checked, failures
        if time.monotonic() - checked < 5:
            return False
        checked = time.monotonic()
        try:
            rows = json.loads(action(session, 'list-panes', '--json'))
            if not isinstance(rows, list) or any('id' not in p or 'is_plugin' not in p for p in rows):
                raise ValueError('Incomplete pane inspection')
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
            failures += 1
            return failures >= 3
        failures = 0
        return not any(not p['is_plugin'] and p['id'] == pane_id for p in rows)

    try:
        shared.follow(state, open_log=open_shared_log, should_stop=closed)
    finally:
        try:
            if json.loads(marker.read_text(encoding='utf-8')).get('pid') == os.getpid():
                marker.unlink(missing_ok=True)
        except (OSError, ValueError):
            pass


def open_shared_log(path):
    """Allow a log producer to rename/delete the file while it is being followed."""
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                                  wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    handle = kernel.CreateFileW(str(path), 0x80000000, 1 | 2 | 4, None, 3, 0x80, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    return os.fdopen(msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY), 'rb')


def watch(session):
    directory = session_state(session)
    with locked(directory / 'watch.lock', blocking=False) as acquired:
        if not acquired:
            return
        os.environ.pop('ZELLIJ_PANE_ID', None)
        failures = 0
        while failures < 3:
            try:
                rows = panes(session)
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
                failures += 1
            else:
                failures = 0
                try:
                    sync_logs(session, directory, rows, discover())
                except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
                    print(f'Ralphex watcher: {error}', file=sys.stderr, flush=True)
            time.sleep(float(os.environ.get('DOTFILES_ZELLIJ_POLL_SECONDS', '5')))


def start(session):
    directory = session_state(session)
    with locked(directory / 'watch.lock', blocking=False) as acquired:
        if not acquired:
            return
    with (directory / 'watcher.log').open('ab') as log:
        subprocess.Popen([sys.executable, str(SCRIPT), 'watch', session], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=log, creationflags=subprocess.CREATE_NO_WINDOW, close_fds=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('pick', 'monitor', 'processes', 'events', 'start', 'watch', 'follow', 'run-ralphex', 'prepare-resurrection'))
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == 'processes':
        shared.monitor_loop()
    elif args.action == 'events':
        events()
    elif args.action == 'run-ralphex':
        return run_runner(args.arguments)
    elif args.action == 'follow':
        follow(args.arguments[0])
    else:
        session = args.arguments[0] if args.arguments else os.environ.get('ZELLIJ_SESSION_NAME')
        if not session:
            raise RuntimeError('Run this helper inside Zellij')
        {'pick': picker, 'monitor': monitor, 'start': start, 'watch': watch, 'prepare-resurrection': prepare_resurrection}[args.action](session)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
