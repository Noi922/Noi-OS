# shellcheck shell=bash
# ===========================================================================
#  Noi OS – zentrale Konfiguration
#  Alle Namen, Versionen und Spracheinstellungen werden nur hier geändert.
# ===========================================================================

# --- Identität -------------------------------------------------------------
DISTRO_NAME="Noi OS"            # Anzeigename
DISTRO_ID="noios"               # technischer Name (klein, ohne Leerzeichen)
DISTRO_VERSION="1.0"
DISTRO_CODENAME="moos"          # eigener Codename (Moos – passt zu Camo-Grün)
HOME_URL="https://github.com/Noi922/Noi-OS"
SUPPORT_URL="https://github.com/Noi922/Noi-OS/issues"
BUG_URL="https://github.com/Noi922/Noi-OS/issues"

# --- Ubuntu-Basis ----------------------------------------------------------
UBUNTU_CODENAME="noble"         # 24.04 LTS
UBUNTU_VERSION="24.04"
ARCH="amd64"
MIRROR="http://archive.ubuntu.com/ubuntu/"

# --- Live-System & Sprache -------------------------------------------------
LIVE_USER="noi"                 # Benutzer der Live-Sitzung (ohne Passwort)
LIVE_HOSTNAME="noios"
LOCALE="de_DE.UTF-8"
KEYMAP="de"                     # XKB-Layout (de, us, ch, at …)
TIMEZONE="Europe/Berlin"

# --- Optionen --------------------------------------------------------------
BLOCK_SNAP="yes"                # snapd sperren (wie Linux Mint)
FIREFOX_FROM_MOZILLA="yes"      # Firefox als .deb aus Mozillas APT-Repo statt Snap
SQUASHFS_COMP="xz"              # xz = kleinste ISO, zstd = schneller Build

# --- Edition -----------------------------------------------------------------
# desktop = KDE Plasma mit grafischem Installer (Standard)
# server  = ohne Desktop: SSH, Firewall, Web-Verwaltung, Text-Installer
# Auswahl beim Bauen:  sudo NOI_EDITION=server ./build.sh
EDITION="${NOI_EDITION:-desktop}"

# --- Abgeleitet (nicht ändern) ----------------------------------------------
case "$EDITION" in
    desktop)
        ISO_LABEL="NOIOS_${DISTRO_VERSION//./_}"
        ISO_NAME="${DISTRO_ID}-${DISTRO_VERSION}-${ARCH}.iso" ;;
    server)
        LIVE_HOSTNAME="noios-server"
        ISO_LABEL="NOIOS_SRV_${DISTRO_VERSION//./_}"
        ISO_NAME="${DISTRO_ID}-server-${DISTRO_VERSION}-${ARCH}.iso" ;;
    *)  echo "Unbekannte Edition: $EDITION (erlaubt: desktop, server)" >&2; exit 1 ;;
esac
