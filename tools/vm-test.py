#!/usr/bin/env python3
"""Automatischer VM-Test für Noi OS.

Startet die Live-ISO in QEMU (UEFI, mit KVM falls vorhanden), wartet auf den
QEMU-Gastagenten im laufenden System und prüft darüber:
  - Netzwerk verbunden + Internet erreichbar
  - Desktop läuft (Screenshot mit Camo-Hintergrund)
  - Firewall aktiv, zram aktiv, Sicherheitsupdates richtig eingestellt
  - keine fehlgeschlagenen Systemdienste
Screenshots und ein Bericht landen im Ausgabeordner.

Aufruf: vm-test.py ISO AUSGABEORDNER [--timeout 900]
Exit-Code 0 = alle Pflicht-Prüfungen bestanden.
"""
import argparse
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import zlib


def ppm_to_png(ppm_path, png_path):
    """PPM (P6) -> PNG ohne externe Bibliotheken. Gibt (w, h, pixels) zurück."""
    with open(ppm_path, "rb") as f:
        data = f.read()
    parts = data.split(maxsplit=4)
    assert parts[0] == b"P6", "unerwartetes Bildformat"
    w, h, maxval = int(parts[1]), int(parts[2]), int(parts[3])
    pix = parts[4][: w * h * 3]
    raw = b"".join(b"\x00" + pix[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        c = struct.pack(">I", len(body)) + tag + body
        return c + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    with open(png_path, "wb") as f:
        f.write(png)
    return w, h, pix


def png_decode(data):
    """Minimaler PNG-Decoder (8 Bit RGB/RGBA, nicht interlaced) -> (w, h, rgb)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "kein PNG"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        tag, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and ctype in (2, 6), "PNG-Format nicht unterstützt"
            bpp = 3 if ctype == 2 else 4
        elif tag == b"IDAT":
            idat += body
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    i = 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        prev = line
        if bpp == 3:
            out += line
        else:
            for x in range(0, stride, 4):
                out += line[x:x + 3]
    return w, h, bytes(out)


def camo_ratio(w, h, pix):
    """Anteil der Pixel, die nach Camo-Grün aussehen (Desktop-Hintergrund)."""
    hits = total = 0
    for y in range(0, h, 8):
        for x in range(0, w, 8):
            i = (y * w + x) * 3
            r, g, b = pix[i], pix[i + 1], pix[i + 2]
            total += 1
            if g >= r and g > b + 8 and 25 < g < 200:
                hits += 1
    return hits / max(total, 1)


class Monitor:
    def __init__(self, path):
        self.path = path

    def cmd(self, line):
        s = socket.socket(socket.AF_UNIX)
        s.connect(self.path)
        s.settimeout(5)
        try:
            s.recv(4096)
        except socket.timeout:
            pass
        s.sendall(line.encode() + b"\n")
        time.sleep(1.5)
        s.close()


class GuestAgent:
    """Minimaler Client für den QEMU-Gastagenten (qemu-guest-agent)."""

    def __init__(self, path):
        self.path = path
        self.sock = None
        self.buf = b""

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(self.path)
        self.sock.settimeout(10)
        self.buf = b""

    def _send(self, obj):
        self.sock.sendall(json.dumps(obj).encode() + b"\n")

    def _recv(self, timeout=10):
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("Gastagent hat die Verbindung geschlossen")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def sync(self):
        token = int(time.time()) % 100000
        self._send({"execute": "guest-sync", "arguments": {"id": token}})
        while True:
            r = self._recv(timeout=5)
            if r.get("return") == token:
                return True

    def run(self, shell_cmd, timeout=60):
        self._send({"execute": "guest-exec", "arguments": {
            "path": "/bin/sh", "arg": ["-c", shell_cmd], "capture-output": True}})
        pid = self._recv()["return"]["pid"]
        end = time.time() + timeout
        while time.time() < end:
            self._send({"execute": "guest-exec-status", "arguments": {"pid": pid}})
            st = self._recv()["return"]
            if st.get("exited"):
                out = base64.b64decode(st.get("out-data", "")).decode(errors="replace")
                err = base64.b64decode(st.get("err-data", "")).decode(errors="replace")
                return st.get("exitcode", -1), out.strip(), err.strip()
            time.sleep(1)
        return -1, "", "Zeitüberschreitung"


def find_ovmf():
    for code in ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/ovmf/OVMF.fd"):
        if os.path.exists(code):
            return code
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("iso")
    ap.add_argument("outdir")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    mon_path = os.path.join(a.outdir, "monitor.sock")
    qga_path = os.path.join(a.outdir, "qga.sock")

    kvm = os.access("/dev/kvm", os.R_OK | os.W_OK)
    args = ["qemu-system-x86_64", "-m", "4096", "-smp", "2", "-machine", "q35",
            "-cdrom", a.iso, "-boot", "d", "-vga", "virtio", "-display", "none",
            "-nic", "user,model=virtio-net-pci",
            "-monitor", f"unix:{mon_path},server,nowait",
            "-chardev", f"socket,path={qga_path},server=on,wait=off,id=qga0",
            "-device", "virtio-serial",
            "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"]
    args += ["-enable-kvm", "-cpu", "host"] if kvm else \
            ["-cpu", "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt"]
    ovmf = find_ovmf()
    if ovmf:
        vars_copy = os.path.join(a.outdir, "ovmf-vars.fd")
        src_vars = ovmf.replace("CODE", "VARS")
        if os.path.exists(src_vars) and src_vars != ovmf:
            shutil.copy(src_vars, vars_copy)
            args += ["-drive", f"if=pflash,format=raw,readonly=on,file={ovmf}",
                     "-drive", f"if=pflash,format=raw,file={vars_copy}"]
        else:
            args += ["-bios", ovmf]
    print(f"Starte VM ({'KVM' if kvm else 'ohne KVM, langsam'}, {'UEFI' if ovmf else 'BIOS'})", flush=True)
    vm = subprocess.Popen(args)
    mon = Monitor(mon_path)
    results = []

    def check(name, ok, detail="", required=True):
        mark = "OK  " if ok else ("FEHLER" if required else "WARN")
        results.append((name, ok, detail, required))
        print(f"[{mark}] {name}: {detail}", flush=True)

    def screenshot(tag):
        ppm = os.path.join(a.outdir, f"{tag}.ppm")
        try:
            mon.cmd(f"screendump {ppm}")
            time.sleep(1)
            w, h, pix = ppm_to_png(ppm, os.path.join(a.outdir, f"{tag}.png"))
            os.remove(ppm)
            return w, h, pix
        except Exception as e:  # noqa: BLE001
            print(f"Screenshot {tag} fehlgeschlagen: {e}", flush=True)
            return None

    try:
        start = time.time()
        time.sleep(20)
        screenshot("01-boot")
        qga = GuestAgent(qga_path)
        ready = False
        shot = 1
        while time.time() - start < a.timeout:
            try:
                qga.connect()
                qga.sync()
                ready = True
                break
            except Exception:  # noqa: BLE001
                time.sleep(10)
                if int(time.time() - start) // 60 >= shot:
                    shot += 1
                    screenshot(f"0{min(shot, 9)}-warten")
        check("System startet (Gastagent erreichbar)", ready,
              f"nach {int(time.time() - start)} s")
        if not ready:
            return 1

        # Dem Desktop Zeit zum Laden geben
        desktop_ok = False
        for _ in range(18):
            time.sleep(10)
            code, out, _ = qga.run("pgrep -x plasmashell >/dev/null && echo ja")
            if out == "ja":
                desktop_ok = True
                break
        time.sleep(30)
        check("Plasma-Desktop läuft", desktop_ok)
        screenshot("10-desktop")
        # Screenshot im System (zeigt genau, was der Nutzer sieht)
        sess = ("p=$(pgrep -x plasmashell | head -1); u=$(ps -o user= -p $p); "
                "uid=$(id -u $u); x=$(tr '\\0' '\\n' < /proc/$p/environ | grep '^XAUTHORITY=' | cut -d= -f2); "
                "runuser -u $u -- env DISPLAY=:0 XAUTHORITY=$x XDG_RUNTIME_DIR=/run/user/$uid "
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus ")
        ratio = None
        for attempt in range(6):
            code, out, err = qga.run(sess + "spectacle -b -n -f -o /tmp/noi-shot.png >/dev/null 2>&1; "
                                     "base64 -w0 /tmp/noi-shot.png", timeout=120)
            if code == 0 and out:
                try:
                    png = base64.b64decode(out)
                    with open(os.path.join(a.outdir, "11-desktop-im-system.png"), "wb") as f:
                        f.write(png)
                    ratio = camo_ratio(*png_decode(png))
                    if ratio > 0.25:
                        break
                except Exception as e:  # noqa: BLE001
                    print(f"Screenshot-Auswertung: {e}", flush=True)
            time.sleep(20)
        if ratio is None:
            check("Camo-Hintergrund sichtbar", False, "kein Screenshot im System möglich",
                  required=False)
        else:
            check("Camo-Hintergrund sichtbar", ratio > 0.25, f"{ratio:.0%} grüne Pixel")
        code, out, _ = qga.run(sess + "kscreen-doctor -j", timeout=60)
        try:
            outs = json.loads(out[out.index("{"):]).get("outputs", [])
            info = ", ".join(f"{o.get('name')}: sizeMM={o.get('sizeMM')}, scale={o.get('scale')}"
                             for o in outs if o.get("enabled"))
            check("Bildschirmdaten lesbar (kscreen-doctor)", bool(outs), info, required=False)
        except Exception as e:  # noqa: BLE001
            check("Bildschirmdaten lesbar (kscreen-doctor)", False, str(e)[:120], required=False)
        code, out, _ = qga.run(sess + "noios-autoscale --dry-run 2>&1 | tail -3")
        if out:
            check("Automatische Skalierung", "Fehler" not in out, out.replace("\n", " / "),
                  required=False)

        code, out, _ = qga.run("nmcli -t -f TYPE,STATE device | grep '^ethernet:connected'")
        check("Kabel-Netzwerk verbunden (NetworkManager)", code == 0, out or "nicht verbunden")
        code, out, _ = qga.run("for i in 1 2 3 4 5 6; do curl -fsS -o /dev/null -m 10 "
                               "http://connectivity-check.ubuntu.com && echo ok && exit 0; "
                               "sleep 5; done; exit 1", timeout=90)
        check("Internet erreichbar", code == 0, out or "keine Verbindung")
        code, out, _ = qga.run(". /etc/os-release; echo \"$PRETTY_NAME / ID=$ID\"")
        check("System-Name", "Noi OS" in out and "ID=ubuntu" in out, out)
        code, out, _ = qga.run("ufw status | head -1")
        check("Firewall aktiv", "aktiv" in out.lower() or "active" in out.lower(), out)
        code, out, _ = qga.run("swapon --show=NAME --noheadings | grep zram")
        check("zram-Auslagerung aktiv", code == 0, out or "keine", required=False)
        code, out, _ = qga.run("lsb_release -is")
        check("Sicherheitsupdates finden Ubuntu-Quellen", out == "Ubuntu", f"lsb_release -is = {out}")
        code, out, _ = qga.run("ls /home/*/Desktop/*.desktop 2>/dev/null | wc -l")
        check("Genau ein Installer-Symbol auf dem Desktop", out == "1", f"{out} Symbol(e)")
        code, out, _ = qga.run("systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\\n' ' '")
        check("Keine fehlgeschlagenen Dienste", out == "", out or "keine", required=False)
        screenshot("20-ende")
    finally:
        try:
            mon.cmd("quit")
        except Exception:  # noqa: BLE001
            pass
        try:
            vm.wait(timeout=30)
        except subprocess.TimeoutExpired:
            vm.kill()

    with open(os.path.join(a.outdir, "bericht.md"), "w") as f:
        f.write("# Noi OS – VM-Test\n\n| Prüfung | Ergebnis | Details |\n|---|---|---|\n")
        for name, ok, detail, req in results:
            f.write(f"| {name} | {'✅' if ok else ('❌' if req else '⚠️')} | {detail} |\n")
    failed = [n for n, ok, _, req in results if req and not ok]
    print("\nALLE PFLICHT-PRÜFUNGEN BESTANDEN" if not failed else f"\nFEHLGESCHLAGEN: {', '.join(failed)}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
