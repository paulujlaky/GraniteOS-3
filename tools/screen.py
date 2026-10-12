"""Look at and drive the guest desktop through VMware's built-in VNC server.

Usage: py tools/screen.py [--port N] STEP...
Steps run in order: `shot FILE.png`, `move X Y`, `click X Y`, `right X Y`, `drag X Y TO_X TO_Y`, `scroll X Y N`
(N steps, negative scrolls up), `type TEXT`, `key NAME[+NAME...]` (for example `key super+a`
or `key Return`), and `wait SECONDS`.
"""

import socket
import struct
import sys
import time
import zlib
from pathlib import Path

KEYS = {
    "return": 0xFF0D, "enter": 0xFF0D, "tab": 0xFF09, "escape": 0xFF1B, "backspace": 0xFF08,
    "delete": 0xFFFF, "home": 0xFF50, "end": 0xFF57, "left": 0xFF51, "up": 0xFF52,
    "right": 0xFF53, "down": 0xFF54, "pageup": 0xFF55, "pagedown": 0xFF56, "space": 0x20,
    "shift": 0xFFE1, "control": 0xFFE3, "ctrl": 0xFFE3, "alt": 0xFFE9, "super": 0xFFEB,
    **{f"f{number}": 0xFFBD + number for number in range(1, 13)},
}


class Screen:
    def __init__(self, port, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.socket = socket.create_connection(("127.0.0.1", port), timeout=10)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.5)
        version = self.read(12)
        if not version.startswith(b"RFB "):
            raise RuntimeError(f"Not a VNC server: {version!r}")
        self.socket.sendall(b"RFB 003.008\n")
        types = self.read(self.read(1)[0])
        if 1 not in types:
            raise RuntimeError(f"The VNC server wants authentication: {list(types)}")
        self.socket.sendall(b"\x01")
        if struct.unpack(">I", self.read(4))[0] != 0:
            raise RuntimeError("VNC security handshake failed")
        self.socket.sendall(b"\x01")
        self.width, self.height = struct.unpack(">HH", self.read(4))
        self.read(16)
        self.read(struct.unpack(">I", self.read(4))[0])
        # 32-bit little-endian pixels, then raw rectangles only.
        self.socket.sendall(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
        self.socket.sendall(struct.pack(">BxHi", 2, 1, 0))
        self.pixels = bytearray(self.width * self.height * 4)
        self.buttons = 0

    def read(self, count):
        data = bytearray()
        while len(data) < count:
            chunk = self.socket.recv(count - len(data))
            if not chunk:
                raise RuntimeError("VNC connection closed")
            data.extend(chunk)
        return bytes(data)

    def capture(self):
        self.socket.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.width, self.height))
        while True:
            kind = self.read(1)[0]
            if kind == 0:
                break
            if kind == 2:
                continue
            if kind == 3:
                self.read(3)
                self.read(struct.unpack(">I", self.read(4))[0])
                continue
            raise RuntimeError(f"Unexpected VNC message {kind}")
        self.read(1)
        for _ in range(struct.unpack(">H", self.read(2))[0]):
            x, y, width, height, encoding = struct.unpack(">HHHHi", self.read(12))
            if encoding == -223:
                self.width, self.height = width, height
                self.pixels = bytearray(width * height * 4)
                continue
            if encoding != 0:
                raise RuntimeError(f"Unexpected VNC encoding {encoding}")
            data = self.read(width * height * 4)
            for row in range(height):
                start = ((y + row) * self.width + x) * 4
                self.pixels[start:start + width * 4] = data[row * width * 4:(row + 1) * width * 4]

    def save(self, path):
        self.capture()
        rows = bytearray()
        for y in range(self.height):
            rows.append(0)
            line = self.pixels[y * self.width * 4:(y + 1) * self.width * 4]
            pixel = bytearray(self.width * 3)
            pixel[0::3], pixel[1::3], pixel[2::3] = line[2::4], line[1::4], line[0::4]
            rows.extend(pixel)

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        header = struct.pack(">IIBBBBB", self.width, self.height, 8, 2, 0, 0, 0)
        Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))

    def point(self, x, y, buttons=None):
        if buttons is not None:
            self.buttons = buttons
        self.socket.sendall(struct.pack(">BBHH", 5, self.buttons, x, y))
        time.sleep(0.05)

    def key(self, symbol, down):
        self.socket.sendall(struct.pack(">BBxxI", 4, int(down), symbol))
        time.sleep(0.03)


def symbol(name):
    if len(name) == 1:
        return ord(name)
    return KEYS[name.lower()]


def run(screen, steps):
    index = 0
    while index < len(steps):
        step = steps[index]
        if step == "shot":
            screen.save(steps[index + 1])
            index += 2
        elif step in ("move", "click", "right"):
            x, y = int(steps[index + 1]), int(steps[index + 2])
            screen.point(x, y, 0)
            if step != "move":
                button = 1 if step == "click" else 4
                screen.point(x, y, button)
                # Held as long as a person would, so a USB mouse polled every few milliseconds sees it.
                time.sleep(0.05)
                screen.point(x, y, 0)
            index += 3
        elif step == "drag":
            x, y, to_x, to_y = (int(value) for value in steps[index + 1:index + 5])
            screen.point(x, y, 0)
            screen.point(x, y, 1)
            for part in range(1, 11):
                screen.point(x + (to_x - x) * part // 10, y + (to_y - y) * part // 10)
            screen.point(to_x, to_y, 0)
            index += 5
        elif step == "scroll":
            x, y, count = int(steps[index + 1]), int(steps[index + 2]), int(steps[index + 3])
            for _ in range(abs(count)):
                screen.point(x, y, 8 if count < 0 else 16)
                time.sleep(0.03)
                screen.point(x, y, 0)
            index += 4
        elif step == "type":
            # VMware types the key a symbol names, so capitals and shifted symbols need Shift held.
            for char in steps[index + 1]:
                shifted = char.isupper() or char in '~!@#$%^&*()_+{}|:"<>?'
                if shifted:
                    screen.key(KEYS["shift"], True)
                screen.key(ord(char), True)
                screen.key(ord(char), False)
                if shifted:
                    screen.key(KEYS["shift"], False)
            index += 2
        elif step == "key":
            names = [symbol(name) for name in steps[index + 1].split("+")]
            for name in names:
                screen.key(name, True)
            for name in reversed(names):
                screen.key(name, False)
            index += 2
        elif step == "wait":
            time.sleep(float(steps[index + 1]))
            index += 2
        else:
            raise SystemExit(f"Unknown step {step!r}\n{__doc__}")


if __name__ == "__main__":
    arguments = sys.argv[1:]
    port = 5901
    if arguments[:1] == ["--port"]:
        port, arguments = int(arguments[1]), arguments[2:]
    if not arguments:
        raise SystemExit(__doc__)
    run(Screen(port), arguments)
