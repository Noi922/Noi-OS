**@NAME@ @VERSION@**, automatisch gebaut aus `@SHA@`.

## Welche Datei brauche ich?

| Datei | Wofür |
|---|---|
| `@BASE@.iso` | **Live-System und Installer.** Für echte PCs (USB-Stick) oder zum Installieren in jeder VM |
| `@BASE@.ova` | **Fertige VM für VirtualBox und VMware** (Workstation, Player, Fusion, ESXi). Doppelklick bzw. „Appliance importieren“ |
| `@BASE@.qcow2` | **Fertige VM für Proxmox, virt-manager/KVM, GNOME Boxes, UTM** |
| `@BASE@.vhdx.zip` | **Fertige VM für Hyper-V** (entpacken, dann als Festplatte einer neuen VM verwenden) |

Bei den **fertigen VMs** öffnet sich beim ersten Start ein Assistent. Dort wählst du
Sprache und Tastatur und **erstellst dein eigenes Benutzerkonto** mit Passwort.
Danach startet Noi OS ganz normal.

## Dateien mit `.part00`, `.part01` …

GitHub erlaubt höchstens 2 GB pro Datei, deshalb sind große Dateien geteilt.
Lade **alle Teile** einer Datei herunter und füge sie zusammen:

**Windows** (Eingabeaufforderung im Download-Ordner), Beispiel für die OVA:
```
copy /b @BASE@.ova.part00 + @BASE@.ova.part01 @BASE@.ova
```
Gibt es mehr Teile, hänge sie alle der Reihe nach mit `+` an.

**Linux / macOS:**
```
cat @BASE@.ova.part* > @BASE@.ova
```

Prüfsummen stehen in `SHA256SUMS`.

## Tipps

- **USB-Stick:** ISO mit [Ventoy](https://www.ventoy.net) oder [balenaEtcher](https://etcher.balena.io) schreiben. Startet auch mit aktivem Secure Boot.
- **VirtualBox:** Nach dem Import unter *Anzeige* den Grafikcontroller **VMSVGA** wählen und mindestens 128 MB Grafikspeicher einstellen.
- **Hyper-V:** VM der *Generation 2* anlegen und unter *Sicherheit* die Vorlage „**Microsoft UEFI-Zertifizierungsstelle**“ wählen. Alternativ *Generation 1* nehmen.
- **Proxmox:** `qm importdisk <vmid> @BASE@.qcow2 <storage>`, danach die Festplatte anhängen und als Boot-Laufwerk setzen.
- Die fertigen VMs haben 30 GB Festplatte (wächst dynamisch), 2 CPUs und 4 GB RAM. Das lässt sich in jeder VM-Software anpassen.
