#!/usr/bin/env bash
# Läuft INNERHALB des chroot. Richtet Noi OS **Server** ein (ohne Desktop).
# Erwartet unter /tmp/noi-build: config.sh, packages.list, server/, noi, noi.completion
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
# Noi OS: snapd wird nicht installiert
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
fi

apt-get update
"${APT[@]}" install --no-install-recommends ca-certificates curl gnupg apt-utils

# --- Grundsystem -----------------------------------------------------------
log "Grundsystem aktualisieren"
"${APT[@]}" install systemd-sysv
"${APT[@]}" dist-upgrade

log "Sprache, Tastatur und Zeitzone"
"${APT[@]}" install --no-install-recommends locales tzdata keyboard-configuration console-setup
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
log "Pakete aus packages-server.list installieren"
mapfile -t PKGS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$B/packages.list" | grep -v '^$')
"${APT[@]}" install --no-install-recommends "${PKGS[@]}"

# --- Identität: os-release ---------------------------------------------------
# os-release gehört zu base-files; per dpkg-divert bleibt unsere Fassung auch
# nach Updates erhalten. ID bleibt "ubuntu" (Sicherheitsupdates, PPAs).
log "Noi OS Server: Name, Werkzeuge, Begrüßung"
dpkg-divert --local --rename --divert /usr/lib/os-release.ubuntu --add /usr/lib/os-release
cat > /usr/lib/os-release <<EOF
PRETTY_NAME="${DISTRO_NAME} Server ${DISTRO_VERSION}"
NAME="${DISTRO_NAME}"
VERSION_ID="${UBUNTU_VERSION}"
VERSION="${DISTRO_VERSION} Server (${DISTRO_CODENAME})"
VERSION_CODENAME=${UBUNTU_CODENAME}
ID=ubuntu
ID_LIKE=debian
VARIANT="${DISTRO_NAME} Server"
VARIANT_ID=${DISTRO_ID}-server
HOME_URL="${HOME_URL}"
SUPPORT_URL="${SUPPORT_URL}"
BUG_REPORT_URL="${BUG_URL}"
UBUNTU_CODENAME=${UBUNTU_CODENAME}
NOIOS_VERSION="${DISTRO_VERSION}"
NOIOS_EDITION=server
EOF
printf "%s Server %s \\\\n \\\\l\\n\\n" "${DISTRO_NAME}" "${DISTRO_VERSION}" > /etc/issue
echo "${DISTRO_NAME} Server ${DISTRO_VERSION}" > /etc/issue.net
sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=\"${DISTRO_NAME} Server ${DISTRO_VERSION} (basiert auf Ubuntu ${UBUNTU_VERSION} LTS)\"/" /etc/lsb-release

# --- noi-Werkzeug, Installer, Begrüßung --------------------------------------
install -m 755 "$B/noi" /usr/bin/noi
install -D -m 644 "$B/noi.completion" /usr/share/bash-completion/completions/noi
install -m 755 "$B/server/noi-server-install" /usr/sbin/noi-server-install
install -m 755 "$B/server/motd" /etc/update-motd.d/20-noios
# Ubuntus Werbung/Hilfetexte bei der Anmeldung abschalten
chmod -x /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news \
         /etc/update-motd.d/00-header 2>/dev/null || true
sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true

# --- Live-System (casper): Installer startet auf der ersten Konsole ----------
log "Live-System konfigurieren"
cat > /etc/casper.conf <<EOF
# Noi OS Server Live-Sitzung
export USERNAME="${LIVE_USER}"
export USERFULLNAME="${DISTRO_NAME} Live"
export HOST="${LIVE_HOSTNAME}"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="${DISTRO_NAME} Server"
EOF
echo "${LIVE_HOSTNAME}" > /etc/hostname
# Läuft nur beim Live-Start (initramfs): root wird auf tty1 automatisch
# angemeldet; /etc/profile.d/noios-live-installer.sh startet dann den Installer.
cat > /usr/share/initramfs-tools/scripts/casper-bottom/35noios_server_live <<'EOF'
#!/bin/sh
PREREQ=""
DESCRIPTION="Noi OS Server: Installer vorbereiten..."
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac
. /scripts/casper-functions
log_begin_msg "$DESCRIPTION"
d=/root/etc/systemd/system/getty@tty1.service.d
mkdir -p "$d"
rm -f "$d"/*.conf
cat > "$d/zz-noios-live.conf" <<EOT
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOT
log_end_msg
EOF
chmod 755 /usr/share/initramfs-tools/scripts/casper-bottom/35noios_server_live
cat > /etc/profile.d/noios-live-installer.sh <<'EOF'
# Noi OS Server: im Live-System auf der ersten Konsole den Installer anbieten
if [ "$(id -u)" = 0 ] && [ "$(tty 2>/dev/null)" = /dev/tty1 ] \
   && [ -z "${NOIOS_INSTALLER_SHOWN:-}" ] && grep -qw boot=casper /proc/cmdline 2>/dev/null \
   && [ -x /usr/sbin/noi-server-install ]; then
    export NOIOS_INSTALLER_SHOWN=1
    /usr/sbin/noi-server-install || true
    echo
    echo "  Installer erneut starten:  noi-server-install"
    echo "  Du bist in einer Live-Konsole (root) – z. B. für Reparaturen."
    echo
fi
EOF

# --- Netzwerk: DHCP auf allen Kabel-Netzwerkkarten (systemd-networkd) --------
log "Netzwerk: DHCP per systemd-networkd"
install -d -m 755 /etc/netplan
cat > /etc/netplan/01-noios-dhcp.yaml <<'EOF'
# Noi OS Server: alle Kabel-Netzwerkkarten per DHCP.
# Feste IP-Adresse? Diese Datei anpassen und "sudo netplan apply" ausführen:
#   https://netplan.readthedocs.io/en/stable/examples/
network:
  version: 2
  renderer: networkd
  ethernets:
    alle-kabel:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: true
      optional: true
EOF
chmod 600 /etc/netplan/01-noios-dhcp.yaml
systemctl enable systemd-networkd.service systemd-resolved.service >/dev/null 2>&1 || true
# Der Start soll nicht minutenlang auf ein Netzwerkkabel warten
systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true

# --- SSH ---------------------------------------------------------------------
log "SSH einrichten"
# Jede Installation bekommt eigene Host-Schlüssel (nicht die aus dem Abbild)
rm -f /etc/ssh/ssh_host_*
install -m 644 "$B/server/noios-ssh-hostkeys.service" /etc/systemd/system/noios-ssh-hostkeys.service
systemctl enable noios-ssh-hostkeys.service >/dev/null
cat > /etc/ssh/sshd_config.d/10-noios.conf <<'EOF'
# Noi OS Server: root darf sich nicht per SSH anmelden (Benutzer + sudo nehmen)
PermitRootLogin no
EOF

# --- Firewall: nur SSH und die Web-Verwaltung von außen erreichbar -----------
log "Firewall aktivieren"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=no/' /etc/ufw/ufw.conf
ufw allow 22/tcp comment 'SSH' >/dev/null
ufw allow 9090/tcp comment 'Cockpit Web-Verwaltung' >/dev/null
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw.service >/dev/null 2>&1 || true

# --- fail2ban: SSH-Angreifer nach Fehlversuchen aussperren -------------------
cat > /etc/fail2ban/jail.d/noios.conf <<'EOF'
# Noi OS Server: nach 5 falschen Passwörtern 1 Stunde gesperrt
[DEFAULT]
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable fail2ban.service >/dev/null 2>&1 || true

# --- Automatische Sicherheitsupdates -----------------------------------------
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# --- Web-Verwaltung ----------------------------------------------------------
systemctl enable cockpit.socket >/dev/null 2>&1 || true

# --- Bootloader --------------------------------------------------------------
# GRUB_DISTRIBUTOR muss "Ubuntu" bleiben (EFI-Ordner EFI/ubuntu, siehe setup.sh).
# Server: Startmeldungen zeigen statt Boot-Animation, kurzes Bootmenü.
install -d /etc/default/grub.d
cat > /etc/default/grub.d/10-noios.cfg <<'EOF'
# Noi OS Server
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=3
GRUB_DISABLE_OS_PROBER=true
EOF

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
log "chroot-Einrichtung (Server) fertig"
