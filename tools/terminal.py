"""Talk to the guest COM2 terminal through a VMware Windows named pipe."""

import ctypes
from ctypes import wintypes
import os
import queue
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

PROMPT = re.compile(rb"\nobsidian \[[^\]]*\]> $")
LOGIN = re.compile(rb"\nlogin: $")
SECRET = re.compile(rb"password: $")
OFF = re.compile(rb"shutdown: powering off\r\n")
KEYS = {"H": b"\x1b[A", "P": b"\x1b[B", "M": b"\x1b[C", "K": b"\x1b[D", "G": b"\x1b[H", "O": b"\x1b[F", "S": b"\x1b[3~"}


class Pipe:
    def __init__(self, name, timeout=10):
        if os.name != "nt":
            raise RuntimeError("Windows named pipes are required")
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateFileW.argtypes = (
            wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
            wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
        )
        self.kernel.CreateFileW.restype = wintypes.HANDLE
        self.kernel.PeekNamedPipe.argtypes = (
            wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
            ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
        )
        for name_io in ("ReadFile", "WriteFile"):
            function = getattr(self.kernel, name_io)
            function.argtypes = (
                wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
            )
        self.kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        deadline = time.monotonic() + timeout
        while True:
            self.handle = self.kernel.CreateFileW(rf"\\.\pipe\{name}", 0xC0000000, 0, None, 3, 0, None)
            if self.handle != ctypes.c_void_p(-1).value:
                break
            if time.monotonic() >= deadline:
                raise ctypes.WinError(ctypes.get_last_error())
            time.sleep(0.05)

    def close(self):
        self.kernel.CloseHandle(self.handle)

    def read(self):
        available = wintypes.DWORD()
        if not self.kernel.PeekNamedPipe(self.handle, None, 0, None, ctypes.byref(available), None):
            raise ctypes.WinError(ctypes.get_last_error())
        if not available.value:
            return b""
        buffer = ctypes.create_string_buffer(min(available.value, 4096))
        count = wintypes.DWORD()
        if not self.kernel.ReadFile(self.handle, buffer, len(buffer), ctypes.byref(count), None):
            raise ctypes.WinError(ctypes.get_last_error())
        return buffer.raw[:count.value]

    def write(self, data):
        for byte in data:
            buffer = ctypes.create_string_buffer(bytes((byte,)))
            count = wintypes.DWORD()
            if not self.kernel.WriteFile(self.handle, buffer, 1, ctypes.byref(count), None) or count.value != 1:
                raise ctypes.WinError(ctypes.get_last_error())
            time.sleep(0.015)


def session(name, transcript, script):
    pipe = Pipe(name)
    captured = bytearray()

    def command(text, until=PROMPT, timeout=10):
        captured.extend(pipe.read())
        pipe.write(text)
        response = bytearray()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response.extend(pipe.read())
            if until.search(response):
                captured.extend(response)
                return response.decode("ascii", errors="replace")
            time.sleep(0.01)
        captured.extend(response)
        raise RuntimeError(f"Terminal command timed out: {text!r}\n{response!r}")

    def require(condition, detail):
        if not condition:
            raise RuntimeError(f"Terminal acceptance failed: {detail}")

    try:
        script(command, require)
    finally:
        Path(transcript).write_bytes(captured)
        pipe.close()


def login(command, name, password):
    command(b"\r", LOGIN)
    command(name + b"\r", SECRET)
    return command(password + b"\r")


def choose(command, request, password, until=PROMPT):
    command(request, SECRET)
    command(password + b"\r", SECRET)
    return command(password + b"\r", until)


def setup(command, require):
    command(b"\r")
    require("\r\nnobody\r\n" in command(b"whoami\r"), "setup runs before any account exists")
    created = choose(command, b"useradd admin\r", b"granite", LOGIN)
    require("created admin" in created and "Log in" in created, "first account")
    command(b"admin\r", SECRET)
    require("Welcome, admin" in command(b"granite\r"), "administrator login")


def smoke(command, require):
    setup(command, require)
    require("Available Commands" in command(b"help\r"), "help")
    permissions = command(b"permissions\r")
    require(all(f"\r\n{name}\r\n" in permissions for name in ("ipc", "memory", "time")), "visible permission array")
    require("ports" not in permissions and "management" not in permissions, "application permission limits")
    require("\r\nhello services\r\n" in command(b"echo hello services\r"), "echo")
    require("\r\nfixed\r\n" in command(b"echo fixex\x08d\r"), "backspace")
    require("^C\r\nobsidian [/home/admin]> " in command(b"echo discarded\x03"), "line cancellation")
    require("\r\nheld\r\n" in command(b"echo hed\x1b[Dl\r"), "cursor editing")
    require("\r\nheld\r\n" in command(b"\x1b[A\r"), "history recall")
    require("\r\nipc\r\n" in command(b"perm\t\r"), "tab completion")
    require("command not found" in command(b"unknown\r"), "unknown command")
    identity = re.findall(r"\r\n(\d+)\r\n", command(b"id\r"))
    require(bool(identity), "application identity")
    require("\r\n42\r\n" in command(b"hello\r"), "helper API")
    require("supervisor will recover" in command(b"crash helper\r"), "service crash")
    time.sleep(0.5)
    require("\r\n42\r\n" in command(b"hello\r"), "helper recovery")
    require(re.findall(r"\r\n(\d+)\r\n", command(b"id\r")) == identity, "shell survived restart")
    require(re.search(r"serial +\d+", command(b"services\r")), "discovery")
    require(re.search(r"storage +\d+", command(b"services\r")), "storage service")
    require(re.search(r"\r\n\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\r\n", command(b"date\r")), "wall clock")
    require(re.search(r"\r\n +\d+ +(display|files) +system +", command(b"ps\r")), "process listing")
    require("permission denied" in command(b"mkdir /docs\r"), "the root directory belongs to the system")
    require("already exists" not in command(b"mkdir docs\r"), "mkdir")
    require("already exists" in command(b"mkdir docs\r"), "duplicate directory")
    require("obsidian [/home/admin/docs]> " in command(b"cd docs\r"), "working directory")
    command(b"write note.txt hello granite\r")
    require("\r\nhello granite\r\n" in command(b"cat note.txt\r"), "file contents")
    require(re.search(r"-rw-r--r-- admin +14  note\.txt\r\n", command(b"ls\r")), "file listing")
    require("directory not empty" in command(b"rm /home/admin/docs\r"), "non-empty directory removal")
    require("obsidian [/home/admin]> " in command(b"cd ..\r"), "parent directory")
    command(b"write scratch temporary\r")
    command(b"rm scratch\r")
    require("not found" in command(b"cat scratch\r"), "file removal")
    require("docs/" in command(b"ls\r"), "home listing")
    require("drwx------ admin" in command(b"ls /home\r"), "private home directory")
    require(re.search(r"\d+ KiB total, \d+ KiB free", command(b"volume\r")), "volume usage")
    require(re.search(r"[1-9] outputs\r\nVolume \d+%", command(b"sound\r")), "audio output")
    require(re.search(r"Played 882\d\d frames, 0 underruns", command(b"tone\r", timeout=15)), "audio stream")
    command(b"sound 40\r")
    require("Volume 40%" in command(b"sound\r"), "volume change")
    # The service writes the volume a second after it last changes.
    time.sleep(1.5)
    require("supervisor will recover" in command(b"crash audio\r"), "audio crash")
    time.sleep(0.5)
    require(re.search(r"Played 882\d\d frames", command(b"tone 880\r", timeout=15)), "audio recovery")
    require("Volume 40%" in command(b"sound\r"), "volume outlives the audio service")
    require("\r\n1280x800\r\n" in command(b"display\r"), "default screen mode")
    require("invalid argument" in command(b"display 320x200\r"), "screen modes have a minimum")
    command(b"display 1024x768\r")
    require("\r\n1024x768\r\n" in command(b"display\r"), "screen mode switch")
    for service in (b"files", b"storage", b"accounts"):
        require("supervisor will recover" in command(b"crash " + service + b"\r"), f"{service.decode()} crash")
        time.sleep(0.5)
        require("\r\nhello granite\r\n" in command(b"cat /home/admin/docs/note.txt\r"), f"{service.decode()} recovery")
    require("\r\nadmin\r\n" in command(b"whoami\r"), "sessions outlive the accounts service")
    for _ in range(4):
        command(b"crash helper\r")
        time.sleep(0.5)
        if "helper unavailable" in command(b"hello\r"):
            break
    else:
        raise RuntimeError("Service restart limit was not enforced")
    time.sleep(0.5)
    require("helper unavailable" in command(b"hello\r"), "exhausted service stays offline")
    require(re.findall(r"\r\n(\d+)\r\n", command(b"id\r")) == identity, "restart exhaustion isolates failure")
    accounts(command, require)
    print("Interactive terminal and shell passed.")


def accounts(command, require):
    require("created alice" in choose(command, b"useradd alice\r", b"alice"), "administrator creates an account")
    listed = command(b"users\r")
    require(re.search(r"admin +1000 +admin", listed) and re.search(r"alice +1001 +\r\n", listed), "account listing")
    command(b"write shared visible\r")
    command(b"logout\r", LOGIN)
    command(b"alice\r", SECRET)
    require("Login incorrect" in command(b"wrong\r", LOGIN), "wrong password")
    command(b"alice\r", SECRET)
    require("obsidian [/home/alice]> " in command(b"alice\r"), "second account login")
    require("permission denied" in command(b"cat /home/admin/shared\r"), "private home directories")
    require("permission denied" in command(b"ls /home/admin\r"), "private home listing")
    require("request denied" in command(b"crash helper\r"), "service control needs an administrator")
    require("permission denied" in command(b"display 1280x800\r"), "screen mode needs an administrator")
    require("permission denied" in command(b"userdel admin\r"), "account removal needs an administrator")
    command(b"write diary shared\r")
    command(b"write secret hidden\r")
    command(b"chmod 600 secret\r")
    command(b"passwd\r", SECRET)
    require("password updated" in choose(command, b"alice\r", b"alice2"), "password change")
    command(b"lock\r", SECRET)
    require("Incorrect password" in command(b"alice\r", SECRET), "lock rejects the old password")
    require("obsidian [/home/alice]> " in command(b"alice2\r"), "unlock")
    command(b"chmod 755 /home/alice\r")
    require("drwxr-xr-x alice" in command(b"ls /home\r"), "owners set permissions")
    command(b"logout\r", LOGIN)
    command(b"admin\r", SECRET)
    require("Welcome, admin" in command(b"granite\r"), "logout and switch account")
    require("\r\nshared\r\n" in command(b"cat /home/alice/diary\r"), "shared after chmod")
    require("permission denied" in command(b"cat /home/alice/secret\r"), "administrators have no file bypass")
    require("permission denied" in command(b"chmod 777 /home/alice/secret\r"), "administrators cannot take over files")
    require("cannot remove your own" in command(b"userdel admin\r"), "self removal")
    command(b"userdel alice\r")
    require("alice" not in command(b"users\r"), "account removal")
    command(b"logout\r", LOGIN)
    command(b"alice\r", SECRET)
    require("Login incorrect" in command(b"alice2\r", LOGIN), "removed accounts cannot log in")
    command(b"admin\r", SECRET)
    command(b"granite\r")


def persist(command, require):
    require("Welcome, admin" in login(command, b"admin", b"granite"), "account survived power loss")
    require("\r\nhello granite\r\n" in command(b"cat docs/note.txt\r"), "file survived restart")
    require("not found" in command(b"cat scratch\r"), "removal survived restart")
    require("drwx------ admin" in command(b"ls /home\r"), "permissions survived restart")
    require("\r\n1024x768\r\n" in command(b"display\r"), "screen mode survived restart")
    command(b"rm docs/note.txt\r")
    command(b"rm docs\r")
    require("docs/" not in command(b"ls\r"), "directory removal")
    print("Persistent files and accounts passed.")
    command(b"reboot\r", re.compile(rb"reboot: restarting\r\n"))


def power(command, require):
    require("Welcome, admin" in login(command, b"admin", b"granite"), "login after reboot")
    command(b"shutdown\r", OFF)
    print("Reboot and shutdown requested.")


def install(command, require):
    command(b"\r")
    require("not found" in command(b"volume\r"), "no volume before installation")
    installed = command(b"install\r", timeout=60)
    require(re.search(r"installed to disk \d+; boot entry Boot[0-9A-F]{4}", installed), f"install: {installed}")
    setup(command, require)
    command(b"write installed beside the existing OS\r")
    command(b"shutdown\r", OFF)
    print("Installation passed.")


def installed(command, require):
    login(command, b"admin", b"granite")
    require("\r\nbeside the existing OS\r\n" in command(b"cat installed\r"), "installed system boots from its own disk")
    command(b"shutdown\r", OFF)
    print("Installed boot passed.")


def typed():
    """Yield raw typed bytes (Ctrl+C included) from a Windows console, or from an MSYS pty when there is no console."""
    import msvcrt

    kernel = ctypes.WinDLL("kernel32")
    kernel.GetStdHandle.restype = wintypes.HANDLE
    output, source = kernel.GetStdHandle(-11), kernel.GetStdHandle(-10)
    mode = wintypes.DWORD()
    if kernel.GetConsoleMode(output, ctypes.byref(mode)):
        kernel.SetConsoleMode(output, mode.value | 4)
    if kernel.GetConsoleMode(source, ctypes.byref(mode)):
        kernel.SetConsoleMode(source, mode.value & ~1)
        try:
            while True:
                key = msvcrt.getwch() if msvcrt.kbhit() else ""
                yield KEYS.get(msvcrt.getwch(), b"") if key in ("\x00", "\xe0") else key.encode("ascii", errors="ignore")
        finally:
            kernel.SetConsoleMode(source, mode.value)

    received = queue.Queue()
    threading.Thread(target=lambda: [received.put(os.read(0, 64)) for _ in iter(int, 1)], daemon=True).start()
    subprocess.run(["stty", "raw", "-echo"], stdin=sys.stdin, stderr=subprocess.DEVNULL)
    try:
        while True:
            yield b"".join(received.get_nowait() for _ in range(received.qsize()))
    finally:
        subprocess.run(["stty", "sane"], stdin=sys.stdin, stderr=subprocess.DEVNULL)


def attach(name):
    pipe = Pipe(name, timeout=30)
    print("Connected to GraniteOS 3. Ctrl+] disconnects and stops the VM.", flush=True)
    keys = typed()
    try:
        for key in keys:
            data = pipe.read()
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            if b"\x1d" in key:
                pipe.write(key[:key.index(b"\x1d")])
                break
            if key:
                pipe.write(key)
            else:
                time.sleep(0.005)
    finally:
        keys.close()
        pipe.close()


if __name__ == "__main__":
    try:
        scripts = {"smoke": smoke, "persist": persist, "power": power, "install": install, "installed": installed}
        if sys.argv[1:2] and sys.argv[1] in scripts and len(sys.argv) == 4:
            session(sys.argv[2], sys.argv[3], scripts[sys.argv[1]])
        elif sys.argv[1:2] == ["attach"] and len(sys.argv) == 3:
            attach(sys.argv[2])
        else:
            sys.exit(f"Usage: terminal.py attach PIPE | {'|'.join(scripts)} PIPE TRANSCRIPT")
    except (RuntimeError, OSError) as error:
        sys.exit(str(error))
