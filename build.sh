#!/usr/bin/env bash
# ===========================================================================
#  Noi OS – Build-Skript
#  Erzeugt eine bootfähige Live-ISO (BIOS + UEFI) mit Installer.
#
#  Aufruf:  sudo ./build.sh            alles bauen (setzt nach Abbruch fort)
#           sudo ./build.sh clean      Build-Verzeichnis löschen
#           sudo ./build.sh rebuild    clean + alles bauen
#           sudo ./build.sh <stufe>    ab einer Stufe neu bauen:
#                                      bootstrap | branding | chroot | squashfs | iso
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$ROOT/config.sh"

WORK="${NOI_WORK:-$ROOT/build}"     # per Umgebungsvariable umlenkbar (z. B. CI)
CHROOT="$WORK/chroot"
IMAGE="$WORK/image"
OUTDIR="${NOI_OUT:-$ROOT/out}"
STAGES=(bootstrap branding chroot squashfs iso)

log()  { echo -e "\n\e[1;32m==>\e[0m \e[1m$*\e[0m"; }
die()  { echo -e "\e[1;31mFehler:\e[0m $*" >&2; exit 1; }

# --- Hilfsfunktionen -------------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || die "Bitte mit sudo ausführen."; }

check_host() {
    local missing=() tool
    declare -A need=(
        [debootstrap]=debootstrap [mksquashfs]=squashfs-tools [xorriso]=xorriso
        [grub-mkrescue]=grub-common [mformat]=mtools [mkfs.vfat]=dosfstools
        [rsvg-convert]=librsvg2-bin [python3]=python3 [dpkg-deb]=dpkg
    )
    for tool in "${!need[@]}"; do
        command -v "$tool" >/dev/null || missing+=("${need[$tool]}")
    done
    [[ -d /usr/lib/grub/i386-pc ]]    || missing+=(grub-pc-bin)
    [[ -d /usr/lib/grub/x86_64-efi ]] || missing+=(grub-efi-amd64-bin)
    if ((${#missing[@]})); then
        log "Fehlende Build-Werkzeuge werden installiert: ${missing[*]}"
        apt-get update && apt-get install -y "${missing[@]}"
    fi
}

mount_chroot() {
    for d in dev dev/pts proc sys run; do
        mountpoint -q "$CHROOT/$d" && continue
        mkdir -p "$CHROOT/$d"
        case $d in
            proc) mount -t proc proc "$CHROOT/proc" ;;
            sys)  mount -t sysfs sysfs "$CHROOT/sys" ;;
            run)  mount -t tmpfs tmpfs "$CHROOT/run" ;;
            *)    mount --bind "/$d" "$CHROOT/$d" ;;
        esac
    done
}

umount_chroot() {
    local d
    for d in run sys proc dev/pts dev; do
        if mountpoint -q "$CHROOT/$d" 2>/dev/null; then
            umount -l "$CHROOT/$d" || true
        fi
    done
}
trap umount_chroot EXIT

done_stage()  { touch "$WORK/.done-$1"; }
is_done()     { [[ -f "$WORK/.done-$1" ]]; }
reset_from()  {
    local s found=0
    for s in "${STAGES[@]}"; do
        [[ $s == "$1" ]] && found=1
        ((found)) && rm -f "$WORK/.done-$s"
    done
    ((found)) || die "Unbekannte Stufe: $1 (erlaubt: ${STAGES[*]})"
    # chroot-Stufe ändert das Dateisystem -> ab bootstrap neu
    if [[ $1 == bootstrap || $1 == branding || $1 == chroot ]]; then
        umount_chroot; rm -rf "$CHROOT"; rm -f "$WORK/.done-bootstrap"
    fi
}

# --- Stufen ----------------------------------------------------------------
stage_bootstrap() {
    log "1/5 Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}) Grundsystem mit debootstrap"
    rm -rf "$CHROOT"; mkdir -p "$CHROOT"
    debootstrap --arch="$ARCH" --variant=minbase \
        --components=main,restricted,universe,multiverse \
        "$UBUNTU_CODENAME" "$CHROOT" "$MIRROR"
}

stage_branding() {
    log "2/5 Branding-Paket (Hintergrundbild, Logo, Theme) bauen"
    rm -f "$WORK"/*-branding_*.deb
    "$ROOT/branding/build-deb.sh" "$WORK"
}

stage_chroot() {
    log "3/5 System im chroot einrichten (Pakete, KDE Plasma, Installer)"
    mount_chroot
    local B="$CHROOT/tmp/noi-build"
    mkdir -p "$B"
    cp "$ROOT/config.sh" "$ROOT/config/packages.list" "$ROOT/chroot/setup.sh" "$B/"
    cp "$WORK"/*-branding_*.deb "$B/"
    # DNS für den Build: resolv.conf temporär vom Host übernehmen
    mv "$CHROOT/etc/resolv.conf" "$CHROOT/etc/resolv.conf.noi" 2>/dev/null || true
    cp -L /etc/resolv.conf "$CHROOT/etc/resolv.conf"

    chroot "$CHROOT" /bin/bash /tmp/noi-build/setup.sh

    rm -f "$CHROOT/etc/resolv.conf"
    if [[ -e "$CHROOT/etc/resolv.conf.noi" || -L "$CHROOT/etc/resolv.conf.noi" ]]; then
        mv "$CHROOT/etc/resolv.conf.noi" "$CHROOT/etc/resolv.conf"
    else
        ln -s ../run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
    fi
    rm -rf "$CHROOT/tmp/noi-build"
    umount_chroot
}

stage_squashfs() {
    log "4/5 Dateisystem komprimieren (squashfs, ${SQUASHFS_COMP})"
    umount_chroot
    rm -rf "$IMAGE"; mkdir -p "$IMAGE"/{casper,boot/grub,.disk}

    local kernel initrd
    kernel="$(ls -1 "$CHROOT"/boot/vmlinuz-* | sort -V | tail -1)"
    initrd="$(ls -1 "$CHROOT"/boot/initrd.img-* | sort -V | tail -1)"
    cp "$kernel" "$IMAGE/casper/vmlinuz"
    cp "$initrd" "$IMAGE/casper/initrd"

    chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' \
        > "$IMAGE/casper/filesystem.manifest"
    printf '%s\n' casper calamares calamares-settings-kubuntu \
        calamares-settings-ubuntu-common > "$IMAGE/casper/filesystem.manifest-remove"

    local opts=(-noappend -e boot/grub)
    [[ $SQUASHFS_COMP == xz ]] && opts+=(-comp xz -Xbcj x86 -b 1M) || opts+=(-comp "$SQUASHFS_COMP")
    mksquashfs "$CHROOT" "$IMAGE/casper/filesystem.squashfs" "${opts[@]}"
    du -sx --block-size=1 "$CHROOT" | cut -f1 > "$IMAGE/casper/filesystem.size"
}

stage_iso() {
    log "5/5 Bootfähige ISO erzeugen (BIOS + UEFI)"
    echo "${DISTRO_NAME} ${DISTRO_VERSION} \"${DISTRO_CODENAME}\" - ${ARCH} ($(date +%Y%m%d))" \
        > "$IMAGE/.disk/info"
    touch "$IMAGE/.disk/base_installable"
    echo "full_cd/single" > "$IMAGE/.disk/cd_type"

    sed -e "s|@DISTRO_NAME@|${DISTRO_NAME}|g" \
        -e "s|@DISTRO_VERSION@|${DISTRO_VERSION}|g" \
        -e "s|@LOCALE@|${LOCALE}|g" \
        -e "s|@KEYMAP@|${KEYMAP}|g" \
        "$ROOT/iso/grub.cfg" > "$IMAGE/boot/grub/grub.cfg"

    # Camo-Hintergrund auch im Bootmenü (abgedunkelt, ohne Schriftzug)
    local tmp; tmp="$(mktemp -d)"
    python3 "$ROOT/tools/make-camo-wallpaper.py" "$tmp/boot.svg" --no-text \
        --width 1920 --height 1080
    sed -i 's|</svg>|<rect width="100%" height="100%" fill="#000" fill-opacity="0.45"/></svg>|' "$tmp/boot.svg"
    rsvg-convert -w 1024 -h 768 --keep-aspect-ratio -o "$IMAGE/boot/grub/background.png" "$tmp/boot.svg"
    rm -rf "$tmp"

    (cd "$IMAGE" && find . -type f ! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt)

    mkdir -p "$OUTDIR"
    grub-mkrescue -o "$OUTDIR/$ISO_NAME" "$IMAGE" -- -volid "$ISO_LABEL"
    (cd "$OUTDIR" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256")
    log "Fertig: $OUTDIR/$ISO_NAME ($(du -h "$OUTDIR/$ISO_NAME" | cut -f1))"
}

# --- Ablauf ----------------------------------------------------------------
case "${1:-all}" in
    clean)   require_root; umount_chroot; rm -rf "$WORK"; log "Build-Verzeichnis gelöscht"; exit 0 ;;
    rebuild) require_root; umount_chroot; rm -rf "$WORK" ;;
    all)     ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *)       require_root; mkdir -p "$WORK"; reset_from "$1" ;;
esac

require_root
check_host
mkdir -p "$WORK"
for s in "${STAGES[@]}"; do
    if is_done "$s"; then
        echo "  ✓ Stufe '$s' bereits erledigt – übersprungen"
        continue
    fi
    "stage_$s"
    done_stage "$s"
done
