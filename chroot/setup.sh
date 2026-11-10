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
rm -f /etc/apt/sources.list
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

log "Branding-Paket installieren"
"${APT[@]}" install "$B"/"${DISTRO_ID}"-branding_*.deb

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
# Starter auf dem Live-Desktop
if [[ -f /usr/share/applications/kubuntu-calamares.desktop ]]; then
    sed -i -e "s/Kubuntu 24.04 LTS/${DISTRO_NAME} ${DISTRO_VERSION}/g" \
           -e "s/Kubuntu/${DISTRO_NAME}/g" \
           -e "s|^Icon=.*|Icon=${DISTRO_ID}-logo|" \
           /usr/share/applications/kubuntu-calamares.desktop
fi
sed -i "s/-u kubuntu /-u ${LIVE_USER} /" /usr/bin/calamares-launch-normal 2>/dev/null || true
# Installer-Verknüpfung nur in der Live-Sitzung auf den Desktop legen
# (prüft boot=casper, ist daher auf dem installierten System wirkungslos)
cat > /usr/local/bin/noios-live-desktop <<'EOF'
#!/bin/sh
grep -qw 'boot=casper' /proc/cmdline || exit 0
src=/usr/share/applications/kubuntu-calamares.desktop
[ -f "$src" ] || exit 0
desk="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
mkdir -p "$desk"
install -m 755 "$src" "$desk/installieren.desktop"
EOF
chmod 755 /usr/local/bin/noios-live-desktop
cat > /etc/xdg/autostart/noios-live-desktop.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Noi OS Live-Installer-Verknüpfung
Exec=/usr/local/bin/noios-live-desktop
NoDisplay=true
OnlyShowIn=KDE;
EOF
rm -rf "$CAL/branding/kubuntu"

# --- Firewall: eingehende Verbindungen blockieren, ausgehende erlauben ------
# (Netzwerk-Erkennung per mDNS/DHCP erlaubt ufw standardmäßig.)
# Einstellbar unter Systemeinstellungen → Firewall.
log "Firewall aktivieren"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw.service >/dev/null 2>&1 || true

# --- Systemtexte -------------------------------------------------------------
printf "%s %s \\\\n \\\\l\\n" "${DISTRO_NAME}" "${DISTRO_VERSION}" > /etc/issue
echo "${DISTRO_NAME} ${DISTRO_VERSION}" > /etc/issue.net
# Begrüßung in der Konsole ("Welcome to …"): nur die Beschreibung ändern.
# DISTRIB_ID/CODENAME bleiben Ubuntu/noble, damit PPAs & Co. weiter funktionieren.
sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=\"${DISTRO_NAME} ${DISTRO_VERSION} (basiert auf Ubuntu ${UBUNTU_VERSION} LTS)\"/" /etc/lsb-release
chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
sed -i "s/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR=\"${DISTRO_NAME}\"/" /etc/default/grub 2>/dev/null || true

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
