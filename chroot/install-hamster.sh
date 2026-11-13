#!/usr/bin/env bash
# Läuft INNERHALB des chroot (von setup.sh und setup-server.sh aufgerufen).
# Installiert die Shell "hamster" (https://github.com/Noi922/Linux-plugin):
# freundliche Shell im Stil von fish, die Fehler erklärt – läuft auf echter bash.
#
#   1. Ist Hamsters apt-Paketquelle erreichbar UND signiert, wird sie
#      eingerichtet – Updates kommen dann mit "noi update" / apt.
#   2. Sonst wird das neueste .deb aus den GitHub-Releases installiert
#      ("noi update" holt später neuere Versionen von dort).
#   Eine unsignierte Paketquelle wird bewusst NICHT fest ins System eingetragen.
#
# Mit HAMSTER_DEFAULT_SHELL=yes wird hamster Standard-Shell für neue Benutzer.
set -euo pipefail
# shellcheck source=../config.sh
source /tmp/noi-build/config.sh
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

REPO_URL="${HAMSTER_REPO_URL:-https://noi922.github.io/Linux-plugin}"
DEB_URL="${HAMSTER_DEB_URL:-https://github.com/Noi922/Linux-plugin/releases/latest/download/hamster_all.deb}"
KEYRING=/usr/share/keyrings/hamster-archive-keyring.gpg
LIST=/etc/apt/sources.list.d/hamster.list
log() { echo -e "\e[1;32m[chroot]\e[0m $*"; }

[[ "${HAMSTER:-yes}" == yes ]] || { log "hamster: abgeschaltet (HAMSTER=no)"; exit 0; }
log "Shell hamster installieren"

installed=0
if curl -fsSL -m 30 "$REPO_URL/hamster.gpg" -o "$KEYRING.tmp" 2>/dev/null && [[ -s $KEYRING.tmp ]] \
        && curl -fsSL -m 30 "$REPO_URL/InRelease" -o /dev/null 2>/dev/null; then
    mv "$KEYRING.tmp" "$KEYRING"
    chmod 644 "$KEYRING"
    echo "deb [signed-by=$KEYRING] $REPO_URL/ ./" > "$LIST"
    if apt-get update -o Dir::Etc::sourcelist="$LIST" -o Dir::Etc::sourceparts=- \
            -o APT::Get::List-Cleanup=0 && apt-get install -y hamster; then
        installed=1
        log "hamster aus der signierten Paketquelle installiert (Updates per apt)"
    else
        rm -f "$LIST" "$KEYRING"
    fi
fi
rm -f "$KEYRING.tmp"

if ((!installed)); then
    tmp="$(mktemp -d)"
    chmod 755 "$tmp"
    if curl -fsSL -m 120 "$DEB_URL" -o "$tmp/hamster_all.deb" \
            && dpkg-deb -f "$tmp/hamster_all.deb" Package 2>/dev/null | grep -qx hamster \
            && apt-get install -y "$tmp/hamster_all.deb"; then
        installed=1
        log "hamster $(dpkg-query -W -f='${Version}' hamster) aus den GitHub-Releases installiert"
    fi
    rm -rf "$tmp"
fi

if ((!installed)) || ! /usr/bin/hamster --version >/dev/null 2>&1; then
    echo "FEHLER: hamster konnte nicht installiert werden (Paketquelle und Releases" >&2
    echo "        nicht erreichbar?). Ohne hamster bauen: HAMSTER=no in config.sh" >&2
    exit 1
fi

if [[ "${HAMSTER_DEFAULT_SHELL:-yes}" == yes ]]; then
    log "hamster als Standard-Shell für neue Benutzer"
    grep -qx /usr/bin/hamster /etc/shells || echo /usr/bin/hamster >> /etc/shells
    # adduser (Benutzer, die später von Hand angelegt werden). useradd bleibt
    # unverändert – das nutzen Pakete für Systemkonten.
    if [[ -f /etc/adduser.conf ]]; then
        if grep -q '^#\? *DSHELL=' /etc/adduser.conf; then
            sed -i 's|^#\? *DSHELL=.*|DSHELL=/usr/bin/hamster|' /etc/adduser.conf
        else
            echo 'DSHELL=/usr/bin/hamster' >> /etc/adduser.conf
        fi
    fi
    # Grafischer Installer (Desktop-Edition): Konto des Benutzers
    if [[ -f /etc/calamares/modules/users.conf ]]; then
        sed -i 's|^\(\s*shell:\s*\)/bin/bash|\1/usr/bin/hamster|' /etc/calamares/modules/users.conf
        grep -q 'shell:\s*/usr/bin/hamster' /etc/calamares/modules/users.conf \
            || echo "WARNUNG: Shell in Calamares' users.conf nicht gefunden" >&2
    fi
fi
