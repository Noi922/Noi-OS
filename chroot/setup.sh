#!/usr/bin/env bash
# Läuft INNERHALB des chroot. Installiert Pakete und richtet Noi OS ein.
# Erwartet unter /tmp/noi-build: config.sh, packages.list, *-branding_*.deb
set -euo pipefail
B=/tmp/noi-build
# shellcheck source=../config.sh
source "$B/config.sh"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export HOME=/root
APT=(apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log() { echo -e "\e[1;32m[chroot]\e[0m $*"; }

# Dienste während des Builds nicht starten
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# --- Paketquellen ----------------------------------------------------------
log "Paketquellen einrichten"
# Wie bei Ubuntu: Hinweisdatei statt Löschen. Der Installer (Calamares-Modul
# automirror) entfernt sie selbst – fehlt sie, bricht die Installation ab.
echo "# Ubuntu sources have moved to /etc/apt/sources.list.d/ubuntu.sources" \
    > /etc/apt/sources.list
cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${MIRROR}
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: ${UBUNTU_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

if [[ "$BLOCK_SNAP" == yes ]]; then
    log "snapd sperren"
    cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
# Noi OS: snapd wird nicht installiert (Flatpak und .deb stattdessen)
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
fi

apt-get update
"${APT[@]}" install --no-install-recommends ca-certificates curl gnupg apt-utils

if [[ "$FIREFOX_FROM_MOZILLA" == yes ]]; then
    log "Mozilla-APT-Repository für Firefox einrichten"
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc
    # Schlüssel nur akzeptieren, wenn der Fingerabdruck dem von Mozilla
    # veröffentlichten entspricht (Schutz vor manipulierten Downloads)
    MOZ_FPR="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
    # --show-keys braucht keinen Schlüsselbund (läuft auch auf frischen Systemen)
    gnupg_tmp="$(mktemp -d)"
    got="$(GNUPGHOME="$gnupg_tmp" gpg --batch --with-colons --show-keys \
        /etc/apt/keyrings/packages.mozilla.org.asc 2>/dev/null \
        | awk -F: '/^fpr:/{print $10; exit}')" || true
    rm -rf "$gnupg_tmp"
    if [[ "$got" != "$MOZ_FPR" ]]; then
        echo "FEHLER: Mozilla-Schlüssel hat unerwarteten Fingerabdruck: '$got'" >&2
        exit 1
    fi
    log "Mozilla-Schlüssel geprüft ($MOZ_FPR)"
    cat > /etc/apt/sources.list.d/mozilla.sources <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
    cat > /etc/apt/preferences.d/mozilla.pref <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
    # Firefox-Sicherheitsupdates ebenfalls automatisch installieren
    cat > /etc/apt/apt.conf.d/52noios-unattended-upgrades <<'EOF'
// Noi OS: Firefox aus Mozillas Paketquelle automatisch aktualisieren
Unattended-Upgrade::Origins-Pattern {
        "site=packages.mozilla.org";
};
EOF
    apt-get update
fi

# --- Grundsystem -----------------------------------------------------------
log "Grundsystem aktualisieren"
"${APT[@]}" install systemd-sysv
"${APT[@]}" dist-upgrade

log "Sprache, Tastatur und Zeitzone"
"${APT[@]}" install locales tzdata keyboard-configuration console-setup
sed -i "s/^# *${LOCALE} /${LOCALE} /" /etc/locale.gen
grep -q "^${LOCALE} " /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG="${LOCALE}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
cat > /etc/default/keyboard <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${KEYMAP}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# --- Pakete ----------------------------------------------------------------
log "Pakete aus packages.list installieren (das dauert eine Weile)"
mapfile -t PKGS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$B/packages.list" | grep -v '^$')
if [[ "$FIREFOX_FROM_MOZILLA" == yes ]]; then
    PKGS+=(firefox firefox-l10n-de)
fi
"${APT[@]}" install "${PKGS[@]}"

log "Flathub als App-Quelle einrichten (Discover)"
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo \
    || log "WARNUNG: Flathub konnte nicht eingerichtet werden (kein Netz?)"

log "Branding-Paket installieren"
"${APT[@]}" install "$B"/"${DISTRO_ID}"-branding_*.deb
# Flatpak-Apps wöchentlich automatisch aktualisieren (Dienst aus dem Branding-Paket)
systemctl enable noios-flatpak-update.timer

# --- Live-System (casper) ----------------------------------------------------
log "Live-System konfigurieren"
cat > /etc/casper.conf <<EOF
# Noi OS Live-Sitzung
export USERNAME="${LIVE_USER}"
export USERFULLNAME="${DISTRO_NAME} Live"
export HOST="${LIVE_HOSTNAME}"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="${DISTRO_NAME}"
EOF
echo "${LIVE_HOSTNAME}" > /etc/hostname

# Live-Sitzung: Bildschirmsperre, Dateiindizierung und KWallet abschalten.
# (casper macht das nur für Kubuntu-Pfade.) Läuft nur beim Live-Start im
# initramfs – das installierte System wird aus dem unveränderten squashfs
# entpackt und ist nicht betroffen.
cat > /usr/share/initramfs-tools/scripts/casper-bottom/34noios_live_settings <<'EOF'
#!/bin/sh
PREREQ=""
DESCRIPTION="Noi OS: Live-Sitzung einrichten..."
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /scripts/casper-functions
log_begin_msg "$DESCRIPTION"
xdg=/root/etc/xdg
mkdir -p "$xdg"
printf "\n[Daemon]\nAutolock=false\nLockOnResume=false\nTimeout=0\n" >> "$xdg/kscreenlockerrc"
printf "[Basic Settings]\nIndexing-Enabled=false\n" >> "$xdg/baloofilerc"
printf "[Wallet]\nEnabled=false\n" >> "$xdg/kwalletrc"
# Willkommens-Assistent erst nach der Installation, nicht im Live-System
rm -f /root/etc/xdg/autostart/org.kde.plasma-welcome.desktop
log_end_msg
EOF
chmod 755 /usr/share/initramfs-tools/scripts/casper-bottom/34noios_live_settings

# --- Installer (Calamares) an Noi OS anpassen --------------------------------
log "Calamares-Installer anpassen"
CAL=/etc/calamares
sed -i "s/^branding:.*/branding: ${DISTRO_ID}/" "$CAL/settings.conf"
# Snap-/Paketauswahl-Seite entfernen (Noi OS nutzt kein Snap)
sed -i -e '/^  - pkgselect$/d' \
       -e '/contextualprocess@pkgselect_action/d' \
       -e '/contextualprocess@pkgselect_snap_action/d' "$CAL/settings.conf"
sed -i "s/kubuntu_/${DISTRO_ID}_/g" "$CAL/modules/partition.conf"
# Standard-Zeitzone (ohne Internet; online erkennt GeoIP den Standort)
sed -i -e "s|^region:.*|region: \"${TIMEZONE%%/*}\"|" \
       -e "s|^zone:.*|zone: \"${TIMEZONE#*/}\"|" "$CAL/modules/locale.conf"
sed -i "s/kubuntu-2404/${DISTRO_ID}-${DISTRO_VERSION//./}/" "$CAL/modules/oemid.conf"
# Nach der Installation: Branding behalten, Installer-Pakete entfernen
sed -i "s/      - calamares-settings-kubuntu/      - calamares-settings-kubuntu\n      - calamares-settings-ubuntu-common\n      - casper/" \
    "$CAL/modules/packages.conf"
# Paketquellen-Schritt des Installers ("automirror") durch die robuste
# Noi-Fassung ersetzen. Das Original bricht die ganze Installation ab
# ("Main Skriptdatei … automirror/main.py … hat eine Ausnahme ausgelöst"),
# wenn die Standortabfrage etwas Unerwartetes liefert (Gäste-WLAN mit
# Anmeldeseite, Verbindungsabbruch) oder /etc/apt/sources.list fehlt.
# dpkg-divert: ein Paket-Update überschreibt unsere Fassung nicht.
AM="$(dirname "$(dpkg -L calamares-settings-ubuntu-common | grep '/automirror/main\.py$')")"
[[ -d $AM ]] || { echo "FEHLER: Calamares-Modul automirror nicht gefunden" >&2; exit 1; }
dpkg-divert --local --rename --divert "$AM/main.py.ubuntu" --add "$AM/main.py"
install -m 644 "$B/calamares/automirror.py" "$AM/main.py"
python3 -m py_compile "$AM/main.py"
rm -rf "$AM/__pycache__"
# Paketlisten vor dem Schritt "packages" selbst aktualisieren – und zwar so,
# dass ein Fehler (Spiegelserver nicht erreichbar, Gäste-WLAN, Zeitüberschreitung)
# die Installation NICHT abbricht. Calamares' eigenes "update_db" wäre fatal
# ("Paketmanager-Fehler"). Das "-" vor dem Befehl heißt: Fehler ignorieren.
cat > "$CAL/modules/shellprocess_noios_aptupdate.conf" <<'EOF'
---
# Noi OS: Paketlisten aktualisieren, Fehler sind nicht schlimm
dontChroot: false
timeout: 300
script:
    - command: "-apt-get -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=1 update"
      timeout: 300
EOF
sed -i 's/^update_db:.*/update_db: false/' "$CAL/modules/packages.conf"
if ! grep -q 'noios_aptupdate' "$CAL/settings.conf"; then
    sed -i -e 's/^instances:$/&\n- id: noios_aptupdate\n  module: shellprocess\n  config: shellprocess_noios_aptupdate.conf/' \
           -e 's/^  - packages$/  - shellprocess@noios_aptupdate\n&/' "$CAL/settings.conf"
fi
grep -q 'shellprocess@noios_aptupdate' "$CAL/settings.conf" \
    || { echo "FEHLER: settings.conf von Calamares hat ein unerwartetes Format" >&2; exit 1; }
# Starter auf dem Live-Desktop
if [[ -f /usr/share/applications/kubuntu-calamares.desktop ]]; then
    sed -i -e "s/Kubuntu 24.04 LTS/${DISTRO_NAME} ${DISTRO_VERSION}/g" \
           -e "s/Kubuntu/${DISTRO_NAME}/g" \
           -e "s|^Icon=.*|Icon=${DISTRO_ID}-logo|" \
           /usr/share/applications/kubuntu-calamares.desktop
fi
sed -i "s/-u kubuntu /-u ${LIVE_USER} /" /usr/bin/calamares-launch-normal 2>/dev/null || true
# Das Installer-Symbol auf dem Live-Desktop legt casper selbst an
# (casper-bottom/25adduser kopiert kubuntu-calamares.desktop). Ein eigener
# Starter würde es doppelt anzeigen – daher keiner mehr.
rm -f /usr/local/bin/noios-live-desktop /etc/xdg/autostart/noios-live-desktop.desktop
# Weitere Installer-Einträge im Startmenü ausblenden, damit es nur einen
# gibt ("Install Noi OS"); "Install System" und Kubuntus OEM-Modus verwirren.
for f in /usr/share/applications/calamares.desktop \
         /usr/share/applications/calamares-launch-oem.desktop; do
    [[ -f $f ]] && { grep -q '^NoDisplay=' "$f" && sed -i 's/^NoDisplay=.*/NoDisplay=true/' "$f" \
                     || sed -i '/^\[Desktop Entry\]/a NoDisplay=true' "$f"; }
done
# Vor der Bootloader-Einrichtung (UEFI) holt Kubuntus Konfiguration GRUB/shim
# per apt-cdrom + apt-get von der ISO bzw. aus dem Internet. Unsere ISO hat kein
# Paketarchiv und offline schlägt apt-get fehl – beides ist aber schon im
# System installiert. Daher: nichts tun (wie im BIOS-Fall).
cat > "$CAL/modules/before_bootloader_context.conf" <<'EOF'
---
# Noi OS: grub-efi-amd64-signed und shim-signed sind bereits installiert
firmwareType:
    "*": "-/bin/true"
EOF
# Lubuntu-Reste im Willkommensbildschirm ersetzen.
# WICHTIG zur Internet-Prüfung: Calamares wertet nur Adressen als "online",
# die INHALT liefern. connectivity-check.ubuntu.com antwortet mit "204 No
# Content" (0 Bytes) – damit meldete der Installer IMMER "kein Internet",
# auch bei funktionierender Verbindung (z. B. in VirtualBox). Daher mehrere
# Adressen, die wirklich Daten liefern; die erste erreichbare genügt.
NETCHECK="[ \"http://archive.ubuntu.com/ubuntu/dists/${UBUNTU_CODENAME}/Release.gpg\","
NETCHECK+=" \"http://security.ubuntu.com/ubuntu/dists/${UBUNTU_CODENAME}-security/Release.gpg\","
NETCHECK+=" \"http://detectportal.firefox.com/success.txt\" ]"
sed -i -e 's|^showDonateUrl:.*|showDonateUrl: false|' \
       -e "s|^\(\s*internetCheckUrl:\).*|\1 ${NETCHECK}|" \
       "$CAL/modules/welcome.conf"
grep -q 'internetCheckUrl:.*Release.gpg' "$CAL/modules/welcome.conf" \
    || { echo "FEHLER: internetCheckUrl in welcome.conf nicht gesetzt" >&2; exit 1; }

# --- Netzwerk: NetworkManager soll ALLE Netzwerkkarten verwalten -------------
# Ubuntu lässt Kabel-Netzwerk sonst "unverwaltet" (nur WLAN/Mobilfunk aktiv);
# das Ubuntu-Desktop-Setup behebt das per Netplan – hier fehlte das, daher
# gab es z. B. in VirtualBox (NAT, Kabel) kein Internet.
log "Netzwerk: NetworkManager für alle Netzwerkkarten"
install -d -m 755 /etc/netplan
cat > /etc/netplan/01-network-manager-all.yaml <<'EOF'
# Noi OS: alle Netzwerkgeräte über NetworkManager verwalten
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 600 /etc/netplan/01-network-manager-all.yaml
# Zusätzlich (unabhängig von Netplan): Ubuntus Sperrliste überschreiben
install -d /etc/NetworkManager/conf.d
: > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf
rm -rf "$CAL/branding/kubuntu"

# --- Firewall: eingehende Verbindungen blockieren, ausgehende erlauben ------
# (Netzwerk-Erkennung per mDNS/DHCP erlaubt ufw standardmäßig.)
# Einstellbar unter Systemeinstellungen → Firewall.
log "Firewall aktivieren"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
# KDE Connect (Handy koppeln: Dateien, Benachrichtigungen, Zwischenablage)
# braucht die Ports 1714-1764 im lokalen Netz. Regeln vor dem Aktivieren
# eintragen – dann schreibt ufw nur die Dateien und braucht kein iptables.
sed -i 's/^ENABLED=.*/ENABLED=no/' /etc/ufw/ufw.conf
ufw allow 1714:1764/udp comment 'KDE Connect' >/dev/null
ufw allow 1714:1764/tcp comment 'KDE Connect' >/dev/null
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw.service >/dev/null 2>&1 || true

# --- Systemtexte -------------------------------------------------------------
printf "%s %s \\\\n \\\\l\\n" "${DISTRO_NAME}" "${DISTRO_VERSION}" > /etc/issue
echo "${DISTRO_NAME} ${DISTRO_VERSION}" > /etc/issue.net
# Begrüßung in der Konsole ("Welcome to …"): nur die Beschreibung ändern.
# DISTRIB_ID/CODENAME bleiben Ubuntu/noble, damit PPAs & Co. weiter funktionieren.
sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=\"${DISTRO_NAME} ${DISTRO_VERSION} (basiert auf Ubuntu ${UBUNTU_VERSION} LTS)\"/" /etc/lsb-release
chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
# GRUB_DISTRIBUTOR muss "Ubuntu" bleiben: shim-signed/grub-install leiten daraus
# den EFI-Ordner ab (EFI/<erstes Wort>). Das signierte GRUB sucht seine
# Konfiguration fest in EFI/ubuntu – mit "Noi OS" landete ein späteres
# shim-/GRUB-Update in EFI/noi (Startprobleme). Ubuntus /etc/default/grub
# liest sonst NAME aus os-release ("Noi OS"), daher hier fest überschreiben.
install -d /etc/default/grub.d
cat > /etc/default/grub.d/10-noios.cfg <<'EOF'
# Noi OS: technischer Name für den Bootloader (EFI-Ordner) – nicht ändern
GRUB_DISTRIBUTOR="Ubuntu"
EOF
# Installer: GRUB_DISTRIBUTOR nicht mit dem Anzeigenamen überschreiben
grep -q '^keep_distributor:' "$CAL/modules/grubcfg.conf" \
    || echo 'keep_distributor: true' >> "$CAL/modules/grubcfg.conf"

# --- initramfs mit casper neu bauen ----------------------------------------
log "initramfs neu erzeugen"
update-initramfs -u -k all

# --- Aufräumen ---------------------------------------------------------------
log "Aufräumen"
"${APT[@]}" autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache
rm -f /usr/sbin/policy-rc.d
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
find /var/log -type f -exec truncate -s 0 {} +
log "chroot-Einrichtung fertig"
