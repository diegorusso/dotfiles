"""Disposable native ConPTY client; no visible windows or external dependencies."""
import ctypes as c
from ctypes import wintypes as w
import subprocess
import threading


class Coord(c.Structure):
    _fields_ = [('x', c.c_short), ('y', c.c_short)]


class Startup(c.Structure):
    _fields_ = [('cb', w.DWORD), ('reserved', w.LPWSTR), ('desktop', w.LPWSTR), ('title', w.LPWSTR),
                ('x', w.DWORD), ('y', w.DWORD), ('width', w.DWORD), ('height', w.DWORD),
                ('cols', w.DWORD), ('rows', w.DWORD), ('fill', w.DWORD), ('flags', w.DWORD),
                ('show', w.WORD), ('reserved_size', w.WORD), ('reserved_ptr', c.c_void_p),
                ('stdin', w.HANDLE), ('stdout', w.HANDLE), ('stderr', w.HANDLE)]


class StartupEx(c.Structure):
    _fields_ = [('startup', Startup), ('attributes', c.c_void_p)]


class Process(c.Structure):
    _fields_ = [('process', w.HANDLE), ('thread', w.HANDLE), ('pid', w.DWORD), ('tid', w.DWORD)]


class Console:
    def __init__(self, command, cwd, env, width=160, height=45):
        self.kernel = k = c.WinDLL('kernel32', use_last_error=True)
        k.CreatePipe.argtypes = [c.POINTER(w.HANDLE), c.POINTER(w.HANDLE), c.c_void_p, w.DWORD]
        k.CreatePseudoConsole.argtypes = [Coord, w.HANDLE, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE)]
        k.CreatePseudoConsole.restype = c.c_long
        k.InitializeProcThreadAttributeList.argtypes = [c.c_void_p, w.DWORD, w.DWORD, c.POINTER(c.c_size_t)]
        k.UpdateProcThreadAttribute.argtypes = [c.c_void_p, w.DWORD, c.c_size_t, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p]
        k.CreateProcessW.argtypes = [w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL, w.DWORD,
                                     c.c_void_p, w.LPCWSTR, c.POINTER(StartupEx), c.POINTER(Process)]
        k.ReadFile.argtypes = [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p]
        k.WriteFile.argtypes = [w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p]
        k.CloseHandle.argtypes = [w.HANDLE]
        k.ClosePseudoConsole.argtypes = [w.HANDLE]
        k.DeleteProcThreadAttributeList.argtypes = [c.c_void_p]
        k.TerminateProcess.argtypes = [w.HANDLE, w.UINT]
        k.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
        k.CreateJobObjectW.argtypes = [c.c_void_p, w.LPCWSTR]
        k.CreateJobObjectW.restype = w.HANDLE
        k.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        k.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
        k.ResumeThread.argtypes = [w.HANDLE]
        incoming, self.input, self.output, outgoing = w.HANDLE(), w.HANDLE(), w.HANDLE(), w.HANDLE()
        self.check(k.CreatePipe(c.byref(incoming), c.byref(self.input), None, 0))
        self.check(k.CreatePipe(c.byref(self.output), c.byref(outgoing), None, 0))
        self.console = w.HANDLE()
        result = k.CreatePseudoConsole(Coord(width, height), incoming, outgoing, 0, c.byref(self.console))
        if result:
            raise OSError(f'CreatePseudoConsole failed: {result:#x}')
        k.CloseHandle(incoming)
        k.CloseHandle(outgoing)
        size = c.c_size_t()
        k.InitializeProcThreadAttributeList(None, 1, 0, c.byref(size))
        attributes = c.create_string_buffer(size.value)
        self.check(k.InitializeProcThreadAttributeList(attributes, 1, 0, c.byref(size)))
        self.check(k.UpdateProcThreadAttribute(attributes, 0, 0x20016, self.console, c.sizeof(w.HANDLE), None, None))
        startup = StartupEx()
        startup.startup.cb = c.sizeof(startup)
        startup.attributes = c.cast(attributes, c.c_void_p)
        self.process = Process()
        environment = c.create_unicode_buffer('\0'.join(f'{key}={value}' for key, value in sorted(env.items())) + '\0\0')
        try:
            # Reopen console devices explicitly: the test runner can have
            # redirected standard handles even though its child has a ConPTY.
            command_line = 'cmd.exe /d /s /c "' + subprocess.list2cmdline(list(map(str, command))) + ' <CONIN$ >CONOUT$ 2>&1"'
            self.check(k.CreateProcessW(None, c.create_unicode_buffer(command_line),
                                        None, None, False, 0x80000 | 0x400 | 0x4, environment, str(cwd),
                                        c.byref(startup), c.byref(self.process)))
        finally:
            k.DeleteProcThreadAttributeList(attributes)
        self.job = k.CreateJobObjectW(None, None)
        self.check(self.job)
        self.check(k.AssignProcessToJobObject(self.job, self.process.process))
        k.ResumeThread(self.process.thread)
        k.CloseHandle(self.process.thread)
        self.data = bytearray()
        self.drainer = threading.Thread(target=self.drain, daemon=True)
        self.drainer.start()

    @staticmethod
    def check(result):
        if not result:
            raise c.WinError(c.get_last_error())

    def write(self, data):
        count = w.DWORD()
        self.check(self.kernel.WriteFile(self.input, data, len(data), c.byref(count), None))

    def drain(self):
        buffer, count = c.create_string_buffer(65536), w.DWORD()
        while self.kernel.ReadFile(self.output, buffer, len(buffer), c.byref(count), None) and count.value:
            data = buffer.raw[:count.value]
            self.data.extend(data)
            if b'\x1b[6n' in data:
                self.write(b'\x1b[1;1R')

    def close(self):
        # Only this disposable client's process tree belongs to the job.
        self.kernel.TerminateJobObject(self.job, 0)
        self.kernel.WaitForSingleObject(self.process.process, 5000)
        self.kernel.CloseHandle(self.process.process)
        self.kernel.CloseHandle(self.job)
        def close_console():
            # ConPTY shutdown can wait for terminal I/O; keep the drainer and
            # input available until it finishes, and never block the test runner.
            self.kernel.ClosePseudoConsole(self.console)
            self.kernel.CloseHandle(self.input)
            self.kernel.CloseHandle(self.output)
        closer = threading.Thread(target=close_console, daemon=True)
        closer.start()
        closer.join(timeout=5)
        self.drainer.join(timeout=1)
