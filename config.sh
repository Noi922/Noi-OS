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
HOME_URL="https://example.org/noios"      # TODO: eigene Webseite
SUPPORT_URL="https://example.org/noios/hilfe"
BUG_URL="https://example.org/noios/bugs"

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

# --- Abgeleitet (nicht ändern) ----------------------------------------------
ISO_LABEL="NOIOS_${DISTRO_VERSION//./_}"
ISO_NAME="${DISTRO_ID}-${DISTRO_VERSION}-${ARCH}.iso"
