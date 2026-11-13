#!/usr/bin/env python3
"""Schnelltest der Noi-Apps ohne Bildschirm (braucht python3-pyqt5).

Aufruf:  QT_QPA_PLATFORM=offscreen python3 tests/test_apps.py
"""
import os, tempfile, importlib.machinery, importlib.util
BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "branding", "files", "usr", "bin")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
def load(name):
    l = importlib.machinery.SourceFileLoader(name.replace("-","_"), os.path.join(BIN, name))
    spec = importlib.util.spec_from_loader(l.name, l); m = importlib.util.module_from_spec(spec); l.exec_module(m); return m
from PyQt5.QtWidgets import QApplication, QMessageBox
app = QApplication([])
# Fokus-Logik
f = load("noi-fokus"); a = f.Ablauf(arbeit=1, pause=1, lang=2, runden=2)
seq = []
for _ in range(60*5):
    n = a.tick()
    if n: seq.append(n)
assert seq == ["Pause","Fokus","Lange Pause","Fokus"], seq   # 1+1+1+2 = 5 min, then focus running
assert a.fertig == 2
w = f.Fokus(); w.toggle(); w.tick(); w.toggle(); assert w.zeit.text() == "24:59", w.zeit.text()
w.spins["Fokus"].setValue(10); w.reset(); assert w.zeit.text() == "10:00"
# Notizen
d = tempfile.mkdtemp(); os.environ["NOI_NOTIZEN_DIR"] = d
n = load("noi-notizen"); w = n.Notizen()
w.editor.setPlainText("Einkauf: Milch/Brot?\nEier"); w.save()
assert os.listdir(d) == ["Einkauf MilchBrot.txt"], os.listdir(d)
w.new_note(); w.editor.setPlainText("Einkauf: Milch/Brot?\nzweite"); w.save()
assert sorted(os.listdir(d)) == ["Einkauf MilchBrot (2).txt", "Einkauf MilchBrot.txt"], os.listdir(d)
w.editor.setPlainText("Umbenannt\nx"); w.save()
assert sorted(os.listdir(d)) == ["Einkauf MilchBrot.txt", "Umbenannt.txt"], os.listdir(d)
w.search.setText("eier"); assert w.list.count() == 1
w.search.setText(""); assert w.list.count() == 2
w.list.setCurrentRow(1); assert "Eier" in w.editor.toPlainText()
QMessageBox.question = staticmethod(lambda *a, **k: QMessageBox.Yes)
w.delete_note(); assert os.listdir(d) == ["Umbenannt.txt"], os.listdir(d)
assert open(d+"/Umbenannt.txt").read() == "Umbenannt\nx"
w.new_note(); w.close(); assert os.listdir(d) == ["Umbenannt.txt"], os.listdir(d)
# Aufgaben
import json
df = os.path.join(tempfile.mkdtemp(), "a.json"); os.environ["NOI_AUFGABEN_DATEI"] = df
au = load("noi-aufgaben"); L = au.Liste(df)
assert not L.add("   ") and L.add("  Milch   kaufen ") and L.add("Steuer")
assert [i["text"] for i in L.sorted()] == ["Steuer", "Milch kaufen"]
L.toggle(L.items[1], True)
assert [i["text"] for i in L.sorted()] == ["Milch kaufen", "Steuer"] and L.open_count() == 1
assert [i["text"] for i in au.Liste(df).sorted()] == ["Milch kaufen", "Steuer"]   # gespeichert
assert L.clear_done() == 1 and json.load(open(df))[0]["text"] == "Milch kaufen"
open(df, "w").write("{kaputt")                       # beschädigte Datei: nicht abstürzen
L2 = au.Liste(df); assert L2.items == [] and os.path.exists(df + ".defekt") and L2.error
w = au.Aufgaben(); w.entry.setText("Test"); w.add(); assert w.view.count() == 1
from PyQt5.QtCore import Qt
w.view.item(0).setCheckState(Qt.Checked); assert w.liste.open_count() == 0
w.clear_done(); assert w.view.count() == 0
# Passwort
pw = load("noi-passwort")
for n in (4, 8, 20, 64):
    t, bits = pw.erzeugen(n)
    assert len(t) == max(n, 4) and bits > 20
    assert any(c in pw.KLEIN for c in t) and any(c in pw.GROSS for c in t)
    assert any(c in pw.ZIFFERN for c in t) and any(c in pw.SONDER for c in t)
t, _ = pw.erzeugen(40, sonder=False, eindeutig=True)
assert not any(c in pw.SONDER + pw.VERWECHSELBAR for c in t)
try: pw.erzeugen(10, False, False, False, False); raise SystemExit("kein Fehler")
except ValueError: pass
assert len({pw.erzeugen(20)[0] for _ in range(50)}) == 50
t, bits = pw.passphrase(5); assert len(t.split("-")) == 6 and bits > 30
assert len(set(pw.WOERTER)) == len(pw.WOERTER) and all(x.isascii() and x.islower() for x in pw.WOERTER)
print("ALLE APP-TESTS OK")
