#!/usr/bin/env python3
"""Virtual pointer injector for the nested-compositor E2E tests.

Speaks zwlr_virtual_pointer_v1 directly on the wire (no pywayland dep):
labwc exposes the manager to every client by default, so a plain unix
socket client can warp, click, and drag inside the nested session.

  wl_vptr.py move   X Y               warp (absolute) + frame
  wl_vptr.py click  X Y               press+release at X,Y
  wl_vptr.py clicks X Y N             N rapid presses at X,Y (<400 ms apart:
                                      the host Input counts 2=word, 3=line)
  wl_vptr.py drag   X0 Y0 X1 Y1 [N]   press, N motions to X1,Y1, release

Coordinates are logical pixels of the labwc output. The extent for
motion_absolute is read from the live wl_output (mode size / scale), so
grim screenshot coordinates inject unchanged. An assumed extent rescales
every press by the size ratio and silently misses its target (assumed
1440x900 against a 1280x720 nested output shifted everything by x*8/9).
"""

import os
import socket
import struct
import sys
import time

BTN_LEFT = 272
PRESSED, RELEASED = 1, 0
EXTENT_X, EXTENT_Y = 1440, 900  # fallback if no wl_output is announced


class Wayland:
    def __init__(self):
        name = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        path = (
            name
            if name.startswith("/")
            else os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), name)
        )
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.next_id = 2
        self.inbox = b""
        self.globals = {}
        self.registry = self.new_id()
        self.send(1, 1, struct.pack("=I", self.registry))  # wl_display.get_registry
        self.done = None
        # obj id -> {"w": int|None, "h": int|None, "scale": int}
        self.outputs = {}

    def new_id(self):
        i = self.next_id
        self.next_id += 1
        return i

    @staticmethod
    def string(s):
        b = s.encode() + b"\0"
        return struct.pack("=I", len(b)) + b + b"\0" * (-len(b) % 4)

    def send(self, obj, opcode, payload=b""):
        self.sock.sendall(
            struct.pack("=II", obj, ((8 + len(payload)) << 16) | opcode) + payload
        )

    def read(self):
        data = self.sock.recv(65536)
        if not data:
            raise SystemExit("compositor gone")
        self.inbox += data
        while len(self.inbox) >= 8:
            obj, word = struct.unpack_from("=II", self.inbox)
            size, opcode = word >> 16, word & 0xFFFF
            if len(self.inbox) < size:
                break
            body, self.inbox = self.inbox[8:size], self.inbox[size:]
            if obj == 1 and opcode == 0:  # wl_display.error
                raise SystemExit("wayland error on display object")
            if obj == self.registry and opcode == 0:  # wl_registry.global
                name, n = struct.unpack_from("=II", body)
                iface = body[8 : 8 + n - 1].decode()
                ver_off = 8 + n + (-n % 4)
                version = struct.unpack_from("=I", body, ver_off)[0]
                self.globals[iface] = (name, version)
                if iface == "wl_output":
                    oid = self.new_id()
                    ver = min(version, 2)
                    self.outputs[oid] = {"w": None, "h": None, "scale": 1, "ver": ver}
                    # bind v2: scale event needed for hiDPI-correct extent
                    self.send(
                        self.registry,
                        0,
                        struct.pack("=I", name)
                        + self.string(iface)
                        + struct.pack("=II", ver, oid),
                    )
            elif obj in self.outputs:
                self._output_event(obj, opcode, body)
            if obj == self.done:  # wl_callback.done
                self.done = None

    def roundtrip(self):
        self.done = self.new_id()
        self.send(1, 0, struct.pack("=I", self.done))  # wl_display.sync
        while self.done is not None:
            self.read()

    @staticmethod
    def _read_string(body, off):
        (n,) = struct.unpack_from("=I", body, off)
        s = body[off + 4 : off + 4 + n - 1].decode(errors="replace")
        return s, off + 4 + n + (-n % 4)

    def _output_event(self, obj, opcode, body):
        out = self.outputs[obj]
        if opcode == 1:  # mode: flags width height refresh
            flags, w, h, _refresh = struct.unpack_from("=IIII", body)
            if out["w"] is None or flags & 0x1:  # current mode wins
                out["w"], out["h"] = w, h
        elif opcode == 2:  # v2: scale | v1: done (empty body)
            if out["ver"] >= 2 and len(body) >= 4:
                (out["scale"],) = struct.unpack_from("=I", body)

    def extent(self):
        """Logical size of the first output that announced a mode."""
        for out in self.outputs.values():
            if out["w"] and out["h"]:
                s = out["scale"] or 1
                return out["w"] // s, out["h"] // s
        return EXTENT_X, EXTENT_Y


def now_ms():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


class VPointer:
    def __init__(self, wl):
        if "zwlr_virtual_pointer_manager_v1" not in wl.globals:
            raise SystemExit("no zwlr_virtual_pointer_manager_v1")
        name, _ver = wl.globals["zwlr_virtual_pointer_manager_v1"]
        manager = wl.new_id()
        wl.send(
            wl.registry,
            0,
            struct.pack("=I", name)
            + wl.string("zwlr_virtual_pointer_manager_v1")
            + struct.pack("=II", 1, manager),
        )
        self.wl = wl
        self.ptr = wl.new_id()
        # create_virtual_pointer(seat: null, id: new_id)
        wl.send(manager, 0, struct.pack("=II", 0, self.ptr))
        wl.roundtrip()
        # wl_output events arrive asynchronously; one more sync collects them
        wl.roundtrip()
        self.extent = wl.extent()

    def motion_absolute(self, x, y):
        self.wl.send(self.ptr, 1, struct.pack("=IIIII", now_ms(), x, y, *self.extent))

    def button(self, button, state):
        self.wl.send(self.ptr, 2, struct.pack("=III", now_ms(), button, state))

    def frame(self):
        self.wl.send(self.ptr, 4)

    def warp(self, x, y):
        self.motion_absolute(x, y)
        self.frame()
        self.wl.roundtrip()

    def press(self, x, y):
        self.button(BTN_LEFT, PRESSED)
        self.frame()
        self.wl.roundtrip()

    def release(self):
        self.button(BTN_LEFT, RELEASED)
        self.frame()
        self.wl.roundtrip()


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cmd = sys.argv[1]
    args = [int(a) for a in sys.argv[2:]]

    wl = Wayland()
    wl.roundtrip()
    vp = VPointer(wl)

    if cmd == "move":
        vp.warp(*args[:2])
    elif cmd == "click":
        vp.warp(*args[:2])
        vp.press(*args[:2])
        time.sleep(0.03)
        vp.release()
    elif cmd == "clicks":
        x, y, n = args[0], args[1], args[2]
        vp.warp(x, y)
        for _ in range(n):
            vp.press(x, y)
            time.sleep(0.02)
            vp.release()
            time.sleep(0.02)
    elif cmd == "drag":
        x0, y0, x1, y1 = args[:4]
        steps = args[4] if len(args) > 4 else 12
        vp.warp(x0, y0)
        vp.press(x0, y0)
        for i in range(1, steps + 1):
            t = i / steps
            vp.motion_absolute(int(x0 + (x1 - x0) * t), int(y0 + (y1 - y0) * t))
            vp.frame()
            wl.roundtrip()
            time.sleep(0.012)
        vp.release()
    else:
        raise SystemExit(f"unknown command {cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
