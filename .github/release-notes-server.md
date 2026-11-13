**@NAME@ Server @VERSION@**, automatisch gebaut aus `@SHA@`.

Noi OS ohne Desktop – für Heimserver, VMs und Mini-PCs. Basis: Ubuntu 24.04 LTS.

## Installieren

1. `@ISO@` auf einen USB-Stick schreiben ([Ventoy](https://www.ventoy.net) oder
   [balenaEtcher](https://etcher.balena.io)) oder in einer VM als CD einlegen.
2. Davon starten. Der Installer erscheint von selbst und fragt nach Festplatte,
   Rechnername, Benutzer und Passwort.
3. Neu starten, anmelden – oder von einem anderen Rechner: `ssh benutzer@IP-Adresse`

Die IP-Adresse steht nach der Anmeldung an der Konsole.

## Was ist drin?

| | |
|---|---|
| Fernzugriff | SSH (root-Anmeldung gesperrt), fail2ban sperrt Angreifer aus |
| Web-Verwaltung | **Cockpit** unter `https://IP-Adresse:9090` – Auslastung, Dienste, Updates, Speicher, Container |
| Sicherheit | Firewall (nur SSH und Cockpit offen), automatische Sicherheitsupdates, Secure Boot |
| Container | Podman (Docker-kompatibel) |
| Werkzeug | `noi update`, `noi doktor`, `noi netz`, `noi status`, `noi port auf 8080`, `noi bericht` |
| Shell | [hamster](https://github.com/Noi922/Linux-plugin) – erklärt Fehler, vervollständigt Befehle (zurück: `noi shell bash`) |
| Netzwerk | DHCP auf allen Kabel-Netzwerkkarten; feste IP in `/etc/netplan/01-noios-dhcp.yaml` |

Mindestens 8 GB Festplatte und 1 GB RAM. Prüfsumme in `SHA256SUMS`.

## Unbeaufsichtigt installieren

In der Live-Konsole (Dialog mit „Abbrechen“ verlassen):

```
noi-server-install --disk /dev/sda --hostname web1 --user admin --password 'geheim123' --yes --reboot
```
