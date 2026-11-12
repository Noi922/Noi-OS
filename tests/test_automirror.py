#!/usr/bin/env python3
"""Schnelltest für chroot/calamares/automirror.py (ohne Calamares, ohne root).

Spielt die Fälle durch, bei denen das Ubuntu-Original die Installation abbrach:
Gäste-WLAN-Anmeldeseite statt Standortdaten, leere Antwort, Verbindungsabbruch,
fehlende /etc/apt/sources.list.   Aufruf: python3 tests/test_automirror.py
"""
import sys, types, os, tempfile, importlib.util, http.server, threading
MODULE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "chroot", "calamares", "automirror.py")
def load(conf, internet=True, root=None):
    lc = types.ModuleType("libcalamares"); store = {"hasInternet": internet, "rootMountPoint": root}
    lc.globalstorage = types.SimpleNamespace(value=store.get, insert=store.__setitem__)
    lc.job = types.SimpleNamespace(configuration=conf)
    lc.utils = types.SimpleNamespace(warning=lambda m: print("   WARN", m))
    sys.modules["libcalamares"] = lc
    spec = importlib.util.spec_from_file_location("am", MODULE); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m, store
body = {"v": b""}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if body["v"] is None: self.connection.close(); return
        self.send_response(200); self.end_headers(); self.wfile.write(body["v"])
    def log_message(self,*a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
url = "http://127.0.0.1:%d/lookup" % srv.server_port
cases = [("ok DE", b"<Response><CountryCode>DE</CountryCode></Response>", True, True, "de."),
         ("captive portal html", b"<html><body><p>Login<br></body>", True, True, ""),
         ("empty", b"", True, True, ""), ("no tag", b"<Response/>", True, True, ""),
         ("conn closed", None, True, True, ""), ("offline", b"", False, True, ""),
         ("sources.list missing", b"<Response><CountryCode>AT</CountryCode></Response>", True, False, "at.")]
fail = 0
for name, b, inet, has_sl, sub in cases:
    body["v"] = b
    root = tempfile.mkdtemp(); os.makedirs(root + "/etc/apt/sources.list.d")
    open(root + "/etc/os-release", "w").write('NAME="Noi OS"\nVERSION_CODENAME=noble\nUBUNTU_CODENAME=noble\n')
    if has_sl: open(root + "/etc/apt/sources.list", "w").write("# x\n")
    m, store = load({"baseUrl": "archive.ubuntu.com", "distribution": "Kubuntu", "geoip": {"style": "xml", "url": url}}, inet, root)
    try:
        r = m.run(); src = open(root + "/etc/apt/sources.list.d/ubuntu.sources").read()
        ok = r is None and store["mirrorURL"] == f"http://{sub}archive.ubuntu.com/ubuntu" and store["ubuntuCodename"] == "noble" \
             and not os.path.exists(root + "/etc/apt/sources.list") and "Suites: noble noble-updates" in src
    except Exception as e: ok = False; print("   EXC", repr(e))
    print("PASS" if ok else "FAIL", name, store.get("mirrorURL")); fail += not ok
sys.exit(fail)
