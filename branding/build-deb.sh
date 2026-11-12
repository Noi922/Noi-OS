#!/usr/bin/env bash
# Baut das Paket <distro>-branding_<version>_all.deb
#   - rendert Hintergrundbild, Logo und Installer-Grafiken (SVG -> PNG)
#   - ersetzt Platzhalter (@DISTRO_NAME@ …) durch Werte aus config.sh
# Aufruf: branding/build-deb.sh AUSGABEVERZEICHNIS
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../config.sh
source "$ROOT/config.sh"

OUT="${1:?Ausgabeverzeichnis fehlt}"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/pkg"

cp -a "$HERE/files" "$PKG"
cp -a "$HERE/DEBIAN" "$PKG/DEBIAN"
# Python-Zwischendateien (entstehen beim lokalen Testen) gehören nicht ins Paket
find "$PKG" -type d -name __pycache__ -prune -exec rm -rf {} +

# --- Grafiken rendern ------------------------------------------------------
svg="$STAGE/wallpaper.svg"
render() { rsvg-convert -w "$2" -h "$3" -o "$4" "$1"; }

python3 "$ROOT/tools/make-camo-wallpaper.py" "$svg"
python3 "$ROOT/tools/make-camo-wallpaper.py" "$STAGE/plain.svg" --no-text

# (Ordner explizit anlegen – Git speichert keine leeren Verzeichnisse)
WP="$PKG/usr/share/wallpapers/NoiCamo/contents"
mkdir -p "$WP/images"
for res in 3840x2160 2560x1440 1920x1080; do
    render "$svg" "${res%x*}" "${res#*x}" "$WP/images/$res.png"
done
render "$svg" 400 225 "$WP/screenshot.png"

# Weitere Camo-Varianten zur Auswahl (Systemeinstellungen → Hintergrundbild)
for v in "Wueste:wueste:Wüste" "Nacht:nacht:Nacht" "Winter:winter:Winter"; do
    id="NoiCamo${v%%:*}"; rest="${v#*:}"; pal="${rest%%:*}"; label="${rest#*:}"
    dir="$PKG/usr/share/wallpapers/$id/contents/images"
    mkdir -p "$dir"
    python3 "$ROOT/tools/make-camo-wallpaper.py" "$STAGE/$id.svg" --palette "$pal"
    for res in 3840x2160 2560x1440 1920x1080; do
        render "$STAGE/$id.svg" "${res%x*}" "${res#*x}" "$dir/$res.png"
    done
    render "$STAGE/$id.svg" 400 225 "$dir/../screenshot.png"
    cat > "$PKG/usr/share/wallpapers/$id/metadata.json" <<EOF
{
    "KPlugin": {
        "Authors": [ { "Name": "@DISTRO_NAME@ Team" } ],
        "Id": "$id",
        "License": "CC-BY-SA-4.0",
        "Name": "Noi Camo $label"
    }
}
EOF
done

LNF="$PKG/usr/share/plasma/look-and-feel/org.noios.desktop/contents/previews"
mkdir -p "$LNF"
render "$svg" 1920 1080 "$LNF/fullscreenpreview.png"
render "$svg" 480 270 "$LNF/preview.png"

install -Dm644 "$svg" "$PKG/usr/share/noi-os/wallpaper.svg"
install -Dm644 "$HERE/artwork/logo.svg" "$PKG/usr/share/noi-os/logo.svg"
install -Dm644 "$HERE/artwork/logo.svg" \
    "$PKG/usr/share/icons/hicolor/scalable/apps/${DISTRO_ID}-logo.svg"
mkdir -p "$PKG/usr/share/pixmaps"
render "$HERE/artwork/logo.svg" 256 256 "$PKG/usr/share/pixmaps/${DISTRO_ID}-logo.png"

CAL="$PKG/etc/calamares/branding/noios"
render "$HERE/artwork/logo.svg" 256 256 "$CAL/logo.png"
render "$STAGE/plain.svg" 1024 576 "$CAL/slide-bg.png"
# Willkommensbild: Camo-Ausschnitt mit Logo in der Mitte
cat > "$STAGE/welcome.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="800" height="400" viewBox="0 0 800 400">
  <image width="800" height="400" preserveAspectRatio="xMidYMid slice"
         xlink:href="file://$CAL/slide-bg.png"/>
  <rect width="800" height="400" fill="#1c2118" fill-opacity="0.35"/>
  <image x="300" y="40" width="200" height="200" xlink:href="file://$CAL/logo.png"/>
  <text x="400" y="320" text-anchor="middle" font-family="Noto Sans, DejaVu Sans, sans-serif"
        font-size="56" font-weight="700" fill="#e2e6d4">${DISTRO_NAME}</text>
</svg>
EOF
rsvg-convert -o "$CAL/welcome.png" "$STAGE/welcome.svg"

# Boot-Animation (Plymouth): Logo + Schriftzug als "Wasserzeichen"
PLY="$PKG/usr/share/plymouth/themes/noios"
mkdir -p "$PLY"
render "$HERE/artwork/logo.svg" 160 160 "$STAGE/logo160.png"
cat > "$STAGE/plymouth.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="360" height="250" viewBox="0 0 360 250">
  <image x="100" y="0" width="160" height="160" xlink:href="file://$STAGE/logo160.png"/>
  <text x="180" y="228" text-anchor="middle" font-family="Noto Sans, DejaVu Sans, sans-serif"
        font-size="44" font-weight="700" fill="#e2e6d4">${DISTRO_NAME}</text>
</svg>
EOF
rsvg-convert -o "$PLY/watermark.png" "$STAGE/plymouth.svg"

# --- KDE-Systemvorgaben: kdeglobals = Grundeinstellungen + Farbschema -------
cat "$HERE/kdeglobals.head" "$HERE/NoiCamo.colors" > "$PKG/etc/xdg/kdeglobals"

# --- Platzhalter ersetzen --------------------------------------------------
grep -rIl '@[A-Z_]*@' "$PKG" | while read -r f; do
    sed -i \
        -e "s|@DISTRO_NAME@|${DISTRO_NAME}|g" \
        -e "s|@DISTRO_ID@|${DISTRO_ID}|g" \
        -e "s|@DISTRO_VERSION@|${DISTRO_VERSION}|g" \
        -e "s|@DISTRO_CODENAME@|${DISTRO_CODENAME}|g" \
        -e "s|@UBUNTU_CODENAME@|${UBUNTU_CODENAME}|g" \
        -e "s|@UBUNTU_VERSION@|${UBUNTU_VERSION}|g" \
        -e "s|@HOME_URL@|${HOME_URL}|g" \
        -e "s|@SUPPORT_URL@|${SUPPORT_URL}|g" \
        -e "s|@BUG_URL@|${BUG_URL}|g" \
        "$f"
done

# --- Paket bauen -----------------------------------------------------------
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f ! -path '*/DEBIAN/p*' -exec chmod 644 {} +
chmod 755 "$PKG"/usr/bin/*
DEB="$OUT/${DISTRO_ID}-branding_${DISTRO_VERSION}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB" >/dev/null
echo "$DEB"
