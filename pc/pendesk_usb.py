"""
PenDesk USB – PC mit dem Apple Pencil bedienen, Verbindung nur über USB-C.

Benötigt:
  - Python 3 (keine Zusatzpakete)
  - iTunes (von apple.com) oder die App "Apple Devices": liefert den Apple-Gerätedienst,
    über den der PC per USB mit dem iPad spricht.
  - Auf dem iPad: die PenDesk-App (geöffnet).

Start: start.bat doppelklicken.
"""
import ctypes
import json
import plistlib
import queue
import socket
import struct
import sys
import threading
import time

APP_PORT = 7770                      # Port der iPad-App
USBMUX = ("127.0.0.1", 27015)        # Apple-Gerätedienst (Windows)
IS_WIN = sys.platform == "win32"

if IS_WIN:
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        ctypes.windll.user32.SetProcessDPIAware()


# ================================================================ Monitore
def list_monitors():
    if not IS_WIN:
        return [{"x": 0, "y": 0, "w": 1920, "h": 1080, "primary": True},
                {"x": 1920, "y": 0, "w": 2048, "h": 1536, "primary": False}]
    from ctypes import wintypes as wt
    mons = []

    class MONITORINFO(ctypes.Structure):
        _fields_ = [("cbSize", wt.DWORD), ("rcMonitor", wt.RECT),
                    ("rcWork", wt.RECT), ("dwFlags", wt.DWORD)]

    PROC = ctypes.WINFUNCTYPE(wt.BOOL, ctypes.c_void_p, ctypes.c_void_p,
                              ctypes.POINTER(wt.RECT), ctypes.c_void_p)
    u = ctypes.windll.user32
    u.GetMonitorInfoW.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

    def cb(hmon, hdc, rect, data):
        mi = MONITORINFO()
        mi.cbSize = ctypes.sizeof(mi)
        u.GetMonitorInfoW(hmon, ctypes.byref(mi))
        r = mi.rcMonitor
        mons.append({"x": r.left, "y": r.top, "w": r.right - r.left,
                     "h": r.bottom - r.top, "primary": bool(mi.dwFlags & 1)})
        return True

    u.EnumDisplayMonitors(None, None, PROC(cb), None)
    return mons or [{"x": 0, "y": 0, "w": u.GetSystemMetrics(0), "h": u.GetSystemMetrics(1), "primary": True}]


def primary_index(mons):
    for i, m in enumerate(mons):
        if m["primary"]:
            return i
    return 0


# ================================================================ Stift-Einspeisung
if IS_WIN:
    from ctypes import wintypes as wt

    class POINTER_INFO(ctypes.Structure):
        _fields_ = [
            ("pointerType", ctypes.c_uint32), ("pointerId", ctypes.c_uint32),
            ("frameId", ctypes.c_uint32), ("pointerFlags", ctypes.c_uint32),
            ("sourceDevice", ctypes.c_void_p), ("hwndTarget", ctypes.c_void_p),
            ("ptPixelLocation", wt.POINT), ("ptHimetricLocation", wt.POINT),
            ("ptPixelLocationRaw", wt.POINT), ("ptHimetricLocationRaw", wt.POINT),
            ("dwTime", wt.DWORD), ("historyCount", ctypes.c_uint32),
            ("InputData", ctypes.c_int32), ("dwKeyStates", wt.DWORD),
            ("PerformanceCount", ctypes.c_uint64), ("ButtonChangeType", ctypes.c_int),
        ]

    class POINTER_PEN_INFO(ctypes.Structure):
        _fields_ = [
            ("pointerInfo", POINTER_INFO), ("penFlags", ctypes.c_uint32),
            ("penMask", ctypes.c_uint32), ("pressure", ctypes.c_uint32),
            ("rotation", ctypes.c_uint32), ("tiltX", ctypes.c_int32), ("tiltY", ctypes.c_int32),
        ]

    class POINTER_TOUCH_INFO(ctypes.Structure):
        _fields_ = [
            ("pointerInfo", POINTER_INFO), ("touchFlags", ctypes.c_uint32),
            ("touchMask", ctypes.c_uint32), ("rcContact", wt.RECT), ("rcContactRaw", wt.RECT),
            ("orientation", ctypes.c_uint32), ("pressure", ctypes.c_uint32),
        ]

    class _U(ctypes.Union):
        _fields_ = [("touchInfo", POINTER_TOUCH_INFO), ("penInfo", POINTER_PEN_INFO)]

    class POINTER_TYPE_INFO(ctypes.Structure):
        _anonymous_ = ("u",)
        _fields_ = [("type", ctypes.c_uint32), ("u", _U)]

PT_PEN = 3
F_NEW, F_INRANGE, F_INCONTACT, F_FIRSTBUTTON = 0x1, 0x2, 0x4, 0x10
F_DOWN, F_UPDATE, F_UP = 0x10000, 0x20000, 0x40000
PEN_BARREL, PEN_ERASER = 0x1, 0x2
PEN_MASK = 0x1 | 0x4 | 0x8  # Druck, Neigung X/Y


class PenInjector:
    """Echte Windows-Ink-Stifteingabe mit Druck (Windows 10 1809+)."""
    mode = "Stift mit Druck (Windows Ink)"

    def __init__(self):
        u = ctypes.windll.user32
        u.CreateSyntheticPointerDevice.restype = ctypes.c_void_p
        u.CreateSyntheticPointerDevice.argtypes = [ctypes.c_uint32] * 3
        u.InjectSyntheticPointerInput.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(POINTER_TYPE_INFO), ctypes.c_uint32]
        u.InjectSyntheticPointerInput.restype = wt.BOOL
        self.u = u
        self.dev = u.CreateSyntheticPointerDevice(PT_PEN, 1, 1)
        if not self.dev:
            raise OSError("CreateSyntheticPointerDevice fehlgeschlagen")
        self.down = self.inrange = False
        self.last = (0, 0)

    def _inject(self, x, y, flags, change, pressure, tx, ty, pflags):
        info = POINTER_TYPE_INFO()
        info.type = PT_PEN
        pi = info.penInfo.pointerInfo
        pi.pointerType = PT_PEN
        pi.pointerFlags = flags
        pi.ptPixelLocation.x, pi.ptPixelLocation.y = x, y
        pi.ButtonChangeType = change
        info.penInfo.penFlags = pflags
        info.penInfo.penMask = PEN_MASK
        info.penInfo.pressure = pressure
        info.penInfo.tiltX, info.penInfo.tiltY = tx, ty
        self.u.InjectSyntheticPointerInput(self.dev, ctypes.byref(info), 1)

    def move(self, x, y, p, tx, ty, contact, barrel, eraser):
        pflags = (PEN_BARREL if barrel else 0) | (PEN_ERASER if eraser else 0)
        pressure = int(min(max(p, 0.0), 1.0) * 1024)
        change = 0
        if contact:
            pressure = max(pressure, 1)
            if not self.down:
                flags = F_INRANGE | F_INCONTACT | F_FIRSTBUTTON | F_DOWN | (0 if self.inrange else F_NEW)
                change = 1
            else:
                flags = F_INRANGE | F_INCONTACT | F_FIRSTBUTTON | F_UPDATE
        else:
            pressure = 0
            if self.down:
                flags, change = F_INRANGE | F_UP, 2
            else:
                flags = F_INRANGE | F_UPDATE | (0 if self.inrange else F_NEW)
        self._inject(x, y, flags, change, pressure, int(tx), int(ty), pflags)
        self.down, self.inrange, self.last = contact, True, (x, y)

    def leave(self):
        if self.down:
            self.move(*self.last, 0, 0, 0, False, False, False)
        if self.inrange:
            self._inject(*self.last, F_UPDATE, 0, 0, 0, 0, 0)
        self.inrange = False


class MouseFallback:
    mode = "Maus OHNE Druck (Windows zu alt?)"

    def __init__(self):
        self.u = ctypes.windll.user32
        self.down = None

    def move(self, x, y, p, tx, ty, contact, barrel, eraser):
        self.u.SetCursorPos(x, y)
        if contact and not self.down:
            self.down = "r" if barrel else "l"
            self.u.mouse_event(0x8 if barrel else 0x2, 0, 0, 0, 0)
        elif not contact and self.down:
            self.u.mouse_event(0x10 if self.down == "r" else 0x4, 0, 0, 0, 0)
            self.down = None

    def leave(self):
        if self.down:
            self.u.mouse_event(0x10 if self.down == "r" else 0x4, 0, 0, 0, 0)
            self.down = None


class DryRun:
    mode = "Testmodus (kein Windows)"

    def __init__(self):
        self.n = 0

    def move(self, *a):
        self.n += 1
        if self.n % 40 == 1:
            print("  Stift:", a)

    def leave(self):
        pass


def make_injector():
    if not IS_WIN:
        return DryRun()
    try:
        return PenInjector()
    except Exception as e:
        print("Stift-Einspeisung nicht möglich:", e)
        return MouseFallback()


INJ = make_injector()
INJ_LOCK = threading.Lock()


# ================================================================ Bildschirmaufnahme
class WinGrabber:
    """Monitor per GDI aufnehmen, mit Windows-eigenem GDI+ als JPEG kodieren."""
    SRCCOPY = 0x00CC0020
    JPEG_CLSID = "{557CF401-1A04-11D3-9A73-0000F81EF32E}"
    QUALITY_GUID = "{1D5BE4B5-FA4A-452D-9CDD-5DB35105E7EB}"

    def __init__(self):
        c = ctypes
        self.u, self.g = c.windll.user32, c.windll.gdi32
        self.gp, self.ole, self.k = c.windll.gdiplus, c.windll.ole32, c.windll.kernel32
        H = c.c_void_p
        u, g, gp, ole, k = self.u, self.g, self.gp, self.ole, self.k
        u.GetDC.restype = H; u.GetDC.argtypes = [H]
        u.ReleaseDC.argtypes = [H, H]
        g.CreateCompatibleDC.restype = H; g.CreateCompatibleDC.argtypes = [H]
        g.CreateCompatibleBitmap.restype = H; g.CreateCompatibleBitmap.argtypes = [H, c.c_int, c.c_int]
        g.SelectObject.restype = H; g.SelectObject.argtypes = [H, H]
        g.DeleteObject.argtypes = [H]; g.DeleteDC.argtypes = [H]
        g.SetStretchBltMode.argtypes = [H, c.c_int]
        g.SetBrushOrgEx.argtypes = [H, c.c_int, c.c_int, H]
        g.BitBlt.argtypes = [H, c.c_int, c.c_int, c.c_int, c.c_int, H, c.c_int, c.c_int, wt.DWORD]
        g.StretchBlt.argtypes = [H, c.c_int, c.c_int, c.c_int, c.c_int, H,
                                 c.c_int, c.c_int, c.c_int, c.c_int, wt.DWORD]
        u.DrawIconEx.argtypes = [H, c.c_int, c.c_int, H, c.c_int, c.c_int, c.c_uint, H, c.c_uint]
        u.GetIconInfo.argtypes = [H, H]
        u.GetCursorInfo.argtypes = [H]
        gp.GdipCreateBitmapFromHBITMAP.argtypes = [H, H, c.POINTER(H)]
        gp.GdipSaveImageToStream.argtypes = [H, H, H, H]
        gp.GdipDisposeImage.argtypes = [H]
        ole.CreateStreamOnHGlobal.argtypes = [H, wt.BOOL, c.POINTER(H)]
        ole.GetHGlobalFromStream.argtypes = [H, c.POINTER(H)]
        k.GlobalLock.restype = H; k.GlobalLock.argtypes = [H]
        k.GlobalUnlock.argtypes = [H]

        class GUID(c.Structure):
            _fields_ = [("a", c.c_uint32), ("b", c.c_uint16), ("c", c.c_uint16), ("d", c.c_ubyte * 8)]

        class StartupInput(c.Structure):
            _fields_ = [("ver", c.c_uint32), ("cb", H), ("noThread", wt.BOOL), ("noCodecs", wt.BOOL)]

        class EncParam(c.Structure):
            _fields_ = [("guid", GUID), ("n", c.c_ulong), ("type", c.c_ulong), ("value", H)]

        class EncParams(c.Structure):
            _fields_ = [("count", c.c_uint), ("p", EncParam * 1)]

        class CURSORINFO(c.Structure):
            _fields_ = [("cbSize", wt.DWORD), ("flags", wt.DWORD), ("hCursor", H), ("pt", wt.POINT)]

        class ICONINFO(c.Structure):
            _fields_ = [("fIcon", wt.BOOL), ("xHot", wt.DWORD), ("yHot", wt.DWORD),
                        ("hbmMask", H), ("hbmColor", H)]

        self.CURSORINFO, self.ICONINFO = CURSORINFO, ICONINFO
        self.token = c.c_size_t()
        si = StartupInput(1, None, False, False)
        if gp.GdiplusStartup(c.byref(self.token), c.byref(si), None) != 0:
            raise OSError("GDI+ konnte nicht gestartet werden")
        self.clsid = GUID()
        ole.CLSIDFromString(c.c_wchar_p(self.JPEG_CLSID), c.byref(self.clsid))
        self.qval = c.c_ulong(60)
        self.params = EncParams()
        self.params.count = 1
        ole.CLSIDFromString(c.c_wchar_p(self.QUALITY_GUID), c.byref(self.params.p[0].guid))
        self.params.p[0].n, self.params.p[0].type = 1, 4
        self.params.p[0].value = c.cast(c.byref(self.qval), H)
        self.screen_dc = u.GetDC(None)
        self.mem_dc = g.CreateCompatibleDC(self.screen_dc)
        self.bmp, self.old, self.size = None, None, (0, 0)

    def _ensure(self, ow, oh):
        if self.size == (ow, oh):
            return
        if self.bmp:
            self.g.SelectObject(self.mem_dc, self.old)
            self.g.DeleteObject(self.bmp)
        self.bmp = self.g.CreateCompatibleBitmap(self.screen_dc, ow, oh)
        self.old = self.g.SelectObject(self.mem_dc, self.bmp)
        self.size = (ow, oh)

    def _cursor(self, mx, my, mw, mh, sx, sy):
        c = ctypes
        ci = self.CURSORINFO()
        ci.cbSize = c.sizeof(ci)
        if not self.u.GetCursorInfo(c.byref(ci)) or not (ci.flags & 1) or not ci.hCursor:
            return
        px, py = ci.pt.x - mx, ci.pt.y - my
        if not (-64 <= px < mw + 64 and -64 <= py < mh + 64):
            return
        ii = self.ICONINFO()
        hx = hy = 0
        if self.u.GetIconInfo(ci.hCursor, c.byref(ii)):
            hx, hy = ii.xHot, ii.yHot
            if ii.hbmMask:
                self.g.DeleteObject(ii.hbmMask)
            if ii.hbmColor:
                self.g.DeleteObject(ii.hbmColor)
        self.u.DrawIconEx(self.mem_dc, int(px * sx) - hx, int(py * sy) - hy, ci.hCursor, 0, 0, 0, None, 3)

    def frame(self, mon, scale, quality):
        c = ctypes
        H = c.c_void_p
        x, y, w, h = mon["x"], mon["y"], mon["w"], mon["h"]
        ow, oh = max(int(w * scale), 2), max(int(h * scale), 2)
        self._ensure(ow, oh)
        if (ow, oh) == (w, h):
            self.g.BitBlt(self.mem_dc, 0, 0, w, h, self.screen_dc, x, y, self.SRCCOPY)
        else:
            self.g.SetStretchBltMode(self.mem_dc, 4)
            self.g.SetBrushOrgEx(self.mem_dc, 0, 0, None)
            self.g.StretchBlt(self.mem_dc, 0, 0, ow, oh, self.screen_dc, x, y, w, h, self.SRCCOPY)
        self._cursor(x, y, w, h, ow / w, oh / h)
        self.qval.value = quality
        img, stream = H(), H()
        self.gp.GdipCreateBitmapFromHBITMAP(self.bmp, None, c.byref(img))
        self.ole.CreateStreamOnHGlobal(None, True, c.byref(stream))
        try:
            self.gp.GdipSaveImageToStream(img, stream, c.byref(self.clsid), c.byref(self.params))
            vtbl = c.cast(stream, c.POINTER(c.POINTER(H))).contents
            seek = c.WINFUNCTYPE(c.c_long, H, c.c_int64, c.c_uint32, c.POINTER(c.c_uint64))(vtbl[5])
            pos = c.c_uint64()
            seek(stream, 0, 1, c.byref(pos))
            hg = H()
            self.ole.GetHGlobalFromStream(stream, c.byref(hg))
            ptr = self.k.GlobalLock(hg)
            data = c.string_at(ptr, pos.value)
            self.k.GlobalUnlock(hg)
        finally:
            self.gp.GdipDisposeImage(img)
            vtbl = c.cast(stream, c.POINTER(c.POINTER(H))).contents
            c.WINFUNCTYPE(c.c_ulong, H)(vtbl[2])(stream)
        return data

    def close(self):
        if self.bmp:
            self.g.SelectObject(self.mem_dc, self.old)
            self.g.DeleteObject(self.bmp)
        self.g.DeleteDC(self.mem_dc)
        self.u.ReleaseDC(None, self.screen_dc)
        self.gp.GdiplusShutdown(self.token)


class TestGrabber:
    def __init__(self):
        from PIL import Image, ImageDraw
        self.Image, self.Draw, self.n = Image, ImageDraw, 0

    def frame(self, mon, scale, quality):
        import io
        self.n += 1
        w, h = int(mon["w"] * scale), int(mon["h"] * scale)
        im = self.Image.new("RGB", (w, h), (30, 60, 90))
        x = (self.n * 10) % w
        self.Draw.Draw(im).rectangle([x, h // 3, x + 80, h // 3 + 80], fill=(255, 122, 26))
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=quality)
        return buf.getvalue()

    def close(self):
        pass



# ================================================================ USB (usbmux)
class UsbmuxError(Exception):
    pass


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("Verbindung getrennt")
        buf += chunk
    return bytes(buf)


class Usbmux:
    """Spricht mit dem Apple-Gerätedienst (usbmuxd) im Plist-Protokoll."""

    def __init__(self):
        self.sock = socket.create_connection(USBMUX, timeout=3)
        self.tag = 0

    def request(self, msg):
        self.tag += 1
        msg = dict(msg, ClientVersionString="pendesk-1.0", ProgName="PenDesk", kLibUSBMuxVersion=3)
        body = plistlib.dumps(msg)
        self.sock.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, self.tag) + body)
        length, _ver, _typ, _tag = struct.unpack("<IIII", recv_exact(self.sock, 16))
        return plistlib.loads(recv_exact(self.sock, length - 16))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def list_usb_devices():
    mux = Usbmux()
    try:
        res = mux.request({"MessageType": "ListDevices"})
    finally:
        mux.close()
    out = []
    for d in res.get("DeviceList", []):
        props = d.get("Properties", {})
        if props.get("ConnectionType") == "USB":
            out.append((d.get("DeviceID"), props.get("SerialNumber", "?")))
    return out


RESULT_TEXT = {1: "abgelehnt", 2: "Gerät nicht gefunden", 3: "App nicht offen", 6: "falsche Anfrage"}


def connect_device(device_id, port):
    """Öffnet einen TCP-Tunnel über USB zum Port auf dem iPad."""
    mux = Usbmux()
    port_be = ((port & 0xFF) << 8) | (port >> 8)
    res = mux.request({"MessageType": "Connect", "DeviceID": device_id, "PortNumber": port_be})
    if res.get("MessageType") != "Result" or res.get("Number") != 0:
        mux.close()
        raise UsbmuxError(RESULT_TEXT.get(res.get("Number"), str(res.get("Number"))))
    sock = mux.sock
    sock.settimeout(None)
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass
    return sock


# ================================================================ Sitzung
HELLO, FRAME, PEN, REQUEST, CONFIG = 1, 2, 10, 11, 12


def run_session(sock):
    send_lock = threading.Lock()

    def send(t, payload):
        with send_lock:
            sock.sendall(struct.pack(">BI", t, len(payload)) + payload)

    mons = list_monitors()
    mon = {"cur": mons[primary_index(mons)]}
    send(HELLO, json.dumps({"mode": INJ.mode, "mons": mons, "def": primary_index(mons)}).encode())

    requests = queue.Queue()
    stop = threading.Event()

    def frame_loop():
        try:
            grab = WinGrabber() if IS_WIN else TestGrabber()
        except Exception as e:
            print("  Bildschirmaufnahme nicht möglich:", e)
            return
        local_mons = list_monitors()
        try:
            while not stop.is_set():
                try:
                    r = requests.get(timeout=0.5)
                except queue.Empty:
                    continue
                i = int(r.get("m", 0))
                if not 0 <= i < len(local_mons):
                    local_mons = list_monitors()
                    i = min(max(i, 0), len(local_mons) - 1)
                scale = min(max(float(r.get("s", 0.75)), 0.25), 1.0)
                quality = min(max(int(r.get("q", 60)), 20), 95)
                send(FRAME, grab.frame(local_mons[i], scale, quality))
        except (ConnectionError, OSError):
            stop.set()
        finally:
            grab.close()

    threading.Thread(target=frame_loop, daemon=True).start()
    rf = sock.makefile("rb", buffering=65536)
    try:
        while not stop.is_set():
            head = rf.read(5)
            if len(head) < 5:
                break
            t, n = struct.unpack(">BI", head)
            body = rf.read(n) if n else b""
            if len(body) < n:
                break
            if t == PEN:
                cur = mon["cur"]
                for m in json.loads(body):
                    if m[0] == "p":
                        _, x, y, p, tx, ty, c, b, e = m
                        px = cur["x"] + int(round(min(max(x, 0.0), 1.0) * (cur["w"] - 1)))
                        py = cur["y"] + int(round(min(max(y, 0.0), 1.0) * (cur["h"] - 1)))
                        with INJ_LOCK:
                            INJ.move(px, py, p, tx, ty, bool(c), bool(b), bool(e))
                    elif m[0] == "l":
                        with INJ_LOCK:
                            INJ.leave()
            elif t == REQUEST:
                requests.put(json.loads(body))
            elif t == CONFIG:
                cfg = json.loads(body)
                if "mon" in cfg:
                    mons = list_monitors()
                    i = int(cfg["mon"])
                    mon["cur"] = mons[i] if 0 <= i < len(mons) else mons[primary_index(mons)]
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        stop.set()
        with INJ_LOCK:
            try:
                INJ.leave()
            except Exception:
                pass
        try:
            sock.close()
        except OSError:
            pass


# ================================================================ Start
def main():
    print("=" * 64)
    print("  PenDesk USB läuft")
    print(f"  Stift: {INJ.mode}")
    for i, m in enumerate(list_monitors()):
        print(f"  Monitor {i + 1}: {m['w']} x {m['h']}{'  (Haupt)' if m['primary'] else ''}")
    print("  Beenden: dieses Fenster schliessen")
    print("=" * 64)
    last = None

    def status(msg):
        nonlocal last
        if msg != last:
            print(time.strftime("  %H:%M:%S  ") + msg)
            last = msg

    while True:
        try:
            devices = list_usb_devices()
        except OSError:
            status("Apple-Gerätedienst nicht gefunden -> iTunes von apple.com installieren (siehe LIESMICH).")
            time.sleep(3)
            continue
        if not devices:
            status("Warte auf iPad per USB-C ... (Kabel drin? iPad entsperrt und 'Vertrauen' getippt?)")
            time.sleep(1)
            continue
        connected = False
        for dev_id, serial in devices:
            try:
                sock = connect_device(dev_id, APP_PORT)
            except (UsbmuxError, OSError) as e:
                status(f"iPad gefunden ({serial[-6:]}) - bitte die PenDesk-App öffnen ({e}).")
                continue
            status(f"Verbunden mit iPad ({serial[-6:]}) über USB.")
            run_session(sock)
            status("Verbindung getrennt.")
            connected = True
            break
        if not connected:
            time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
