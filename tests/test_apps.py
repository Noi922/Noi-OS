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
print("ALLE APP-TESTS OK")
