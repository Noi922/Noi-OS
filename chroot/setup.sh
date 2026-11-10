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

# --- Installer (Calamares) an Noi OS anpassen --------------------------------
log "Calamares-Installer anpassen"
CAL=/etc/calamares
sed -i "s/^branding:.*/branding: ${DISTRO_ID}/" "$CAL/settings.conf"
# Snap-/Paketauswahl-Seite entfernen (Noi OS nutzt kein Snap)
sed -i -e '/^  - pkgselect$/d' \
       -e '/contextualprocess@pkgselect_action/d' \
       -e '/contextualprocess@pkgselect_snap_action/d' "$CAL/settings.conf"
sed -i "s/kubuntu_/${DISTRO_ID}_/g" "$CAL/modules/partition.conf"
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

# --- Systemtexte -------------------------------------------------------------
printf "%s %s \\\\n \\\\l\\n" "${DISTRO_NAME}" "${DISTRO_VERSION}" > /etc/issue
echo "${DISTRO_NAME} ${DISTRO_VERSION}" > /etc/issue.net
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
