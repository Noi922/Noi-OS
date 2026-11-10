#!/usr/bin/env bash
# ===========================================================================
#  Noi OS – fertige VM-Images bauen (nach ./build.sh)
#
#  Erzeugt ein vorinstalliertes System. Beim ersten Start fragt ein
#  Einrichtungsassistent nach Sprache, Tastatur und dem eigenen Benutzerkonto.
#
#  Formate (VM_FORMATS, Standard: "qcow2 ova vhdx"):
#    qcow2  Proxmox, virt-manager/KVM, GNOME Boxes, UTM (Intel-Mac)
#    ova    VirtualBox, VMware Workstation/Player/Fusion/ESXi (Import per Doppelklick)
#    vhdx   Hyper-V (als .zip)
#
#  Aufruf:  sudo ./make-vm.sh
#           sudo VM_FORMATS=qcow2 VM_DISK_SIZE=40G ./make-vm.sh
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
source "$ROOT/config.sh"

WORK="${NOI_WORK:-$ROOT/build}"
OUTDIR="${NOI_OUT:-$ROOT/out}"
SQUASH="$WORK/image/casper/filesystem.squashfs"
VM="$WORK/vm"
IMG="$VM/disk.raw"
MNT="$VM/mnt"
DISK_SIZE="${VM_DISK_SIZE:-30G}"
FORMATS="${VM_FORMATS:-qcow2 ova vhdx}"
BASENAME="${DISTRO_ID}-${DISTRO_VERSION}-${ARCH}"
LOOP=""

log() { echo -e "\n\e[1;32m==>\e[0m \e[1m$*\e[0m"; }
die() { echo -e "\e[1;31mFehler:\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausführen."
[[ -f $SQUASH ]] || die "$SQUASH fehlt – zuerst ./build.sh ausführen."

# --- Werkzeuge ---------------------------------------------------------------
declare -A need=(
    [qemu-img]=qemu-utils [sgdisk]=gdisk [unsquashfs]=squashfs-tools
    [mkfs.ext4]=e2fsprogs [mkfs.vfat]=dosfstools [partx]=util-linux [zip]=zip
    [mcopy]=mtools
)
missing=()
for t in "${!need[@]}"; do command -v "$t" >/dev/null || missing+=("${need[$t]}"); done
if ((${#missing[@]})); then
    log "Installiere fehlende Werkzeuge: ${missing[*]}"
    apt-get update && apt-get install -y "${missing[@]}"
fi

cleanup() {
    set +e
    for d in run sys proc dev/pts dev boot/efi ""; do
        mountpoint -q "$MNT/$d" 2>/dev/null && umount -l "$MNT/$d"
    done
    [[ -n $LOOP ]] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# Partitions-Gerätedateien sicherstellen (fehlen in Containern ohne udev)
part_nodes() {
    local name n dev sys mm
    name="$(basename "$LOOP")"
    partx -u "$LOOP" 2>/dev/null || true
    for n in 1 2 3; do
        dev="${LOOP}p$n"; sys="/sys/block/$name/${name}p$n/dev"
        for _ in $(seq 1 20); do [[ -b $dev || -f $sys ]] && break; sleep 0.5; done
        if [[ ! -b $dev ]]; then
            [[ -f $sys ]] || die "Partition $dev wurde nicht erkannt"
            mm="$(cat "$sys")"
            mknod "$dev" b "${mm%:*}" "${mm#*:}"
        fi
    done
}

# --- 1. Virtuelle Festplatte -------------------------------------------------
log "1/4 Virtuelle Festplatte ($DISK_SIZE) anlegen und partitionieren"
mkdir -p "$VM" "$MNT" "$OUTDIR"
rm -f "$IMG"
truncate -s "$DISK_SIZE" "$IMG"
#   1: BIOS-Boot (GRUB für BIOS)   2: EFI-Partition   3: System (ext4)
sgdisk -Z -n1:1M:+1M -t1:ef02 -c1:bios \
          -n2:0:+512M -t2:ef00 -c2:EFI \
          -n3:0:0 -t3:8300 -c3:"${DISTRO_NAME}" "$IMG" >/dev/null
LOOP="$(losetup -fP --show "$IMG")"
part_nodes
mkfs.vfat -F32 -n EFI "${LOOP}p2" >/dev/null
mkfs.ext4 -q -L noios-root "${LOOP}p3"

# --- 2. System entpacken -----------------------------------------------------
log "2/4 System entpacken"
mount "${LOOP}p3" "$MNT"
unsquashfs -f -d "$MNT" "$SQUASH" >/dev/null
mkdir -p "$MNT/boot/efi"
# Die EFI-Partition wird später per mtools beschrieben (ohne Einhängen –
# funktioniert so auch auf Systemen ohne vfat-Kernelmodul).

ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p3")"
EFI_UUID="$(blkid -s UUID -o value "${LOOP}p2")"
cat > "$MNT/etc/fstab" <<EOF
# <Dateisystem>                            <Mountpunkt> <Typ> <Optionen>          <dump> <pass>
UUID=${ROOT_UUID}  /           ext4  errors=remount-ro  0  1
UUID=${EFI_UUID}                             /boot/efi   vfat  umask=0077         0  1
EOF
echo "${LIVE_HOSTNAME}" > "$MNT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\tlocalhost ip6-localhost ip6-loopback\n' \
    "${LIVE_HOSTNAME}" > "$MNT/etc/hosts"

for d in dev dev/pts proc sys; do mount --bind "/$d" "$MNT/$d"; done
mount -t tmpfs tmpfs "$MNT/run"

# --- 3. Einrichten: Ersteinrichtungs-Assistent + Bootloader -------------------
log "3/4 Ersteinrichtung (Konto beim ersten Start) und Bootloader einrichten"
cat > "$MNT/tmp/vm-setup.sh" <<EOF
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d

# Live-Werkzeuge entfernen (Calamares bleibt für den Assistenten)
apt-get purge -y casper || true
rm -f /usr/share/initramfs-tools/scripts/casper-bottom/34noios_live_settings

# --- OEM-Modus: temporärer Benutzer "oem" startet beim ersten Boot den
#     Einrichtungsassistenten; danach wird er automatisch gelöscht.
useradd -m -u 1000 -c "Ersteinrichtung" -s /bin/bash oem
tar -xzf /etc/calamares/oemconfig.tar.gz -C / --strip-components=2
chown -R oem:oem /home/oem
mv /etc/sudoers /etc/sudoers.orig
mv /etc/sudoers.oem /etc/sudoers
chmod 440 /etc/sudoers

# Assistent auf Noi OS umstellen
rm -rf /etc/calamares/branding/kubuntu /home/oem/Desktop
sed -i 's/^branding:.*/branding: ${DISTRO_ID}/' /etc/calamares/settings.conf
sed -i -e 's/Kubuntu OEM Environment/${DISTRO_NAME} Ersteinrichtung/' \
       -e 's/Starts the Kubuntu OEM Environment/Einrichtungsassistent beim ersten Start/' \
       /usr/share/xsessions/kubuntu-oem-environment.desktop
sed -i -e 's|/usr/share/wallpapers/Next/contents/3840x2160.png|/usr/share/wallpapers/NoiCamo/contents/images/3840x2160.png|' \
       -e "s/-u kubuntu /-u oem /" /usr/libexec/start-kubuntu-oem-env
cat > /etc/sddm.conf <<'SDDM'
[Autologin]
Session=kubuntu-oem-environment
User=oem
SDDM

# --- Bootloader: BIOS hier, UEFI-Dateien danach per mtools
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
# os-prober würde sonst beim Bauen die Platten des Build-Rechners durchsuchen
mkdir -p /etc/default/grub.d
echo 'GRUB_DISABLE_OS_PROBER=true' > /etc/default/grub.d/90-noios-vm.cfg
grub-install --target=i386-pc --recheck "${LOOP}"
update-grub
update-initramfs -u -k all

# Aufräumen
apt-get clean
rm -f /usr/sbin/policy-rc.d
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
EOF
chroot "$MNT" /bin/bash /tmp/vm-setup.sh
rm -f "$MNT/tmp/vm-setup.sh"

# UEFI: signiertes shim + GRUB von Ubuntu in den Standard-Pfad EFI/BOOT legen
# (wie "grub-install --removable"). Bootet in jeder VM-Firmware ohne
# NVRAM-Eintrag und auch mit aktivem Secure Boot.
ESP="${LOOP}p2"
cat > "$VM/grub-efi.cfg" <<EOF
search.fs_uuid ${ROOT_UUID} root
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
EOF
export MTOOLS_SKIP_CHECK=1
mmd -i "$ESP" ::/EFI ::/EFI/BOOT ::/EFI/ubuntu
SHIM="$MNT$(chroot "$MNT" readlink -f /usr/lib/shim/shimx64.efi.signed)"
mcopy -i "$ESP" "$SHIM"                                              ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP" "$MNT/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" ::/EFI/BOOT/grubx64.efi
mcopy -i "$ESP" "$MNT/usr/lib/shim/mmx64.efi"                         ::/EFI/BOOT/mmx64.efi
mcopy -i "$ESP" "$VM/grub-efi.cfg" ::/EFI/BOOT/grub.cfg
mcopy -i "$ESP" "$VM/grub-efi.cfg" ::/EFI/ubuntu/grub.cfg
mdir -i "$ESP" -/ ::/EFI
# Freien Platz nullen, damit die Images kleiner werden
fstrim -v "$MNT" 2>/dev/null || true
cleanup
LOOP=""
trap - EXIT

# --- 4. In VM-Formate umwandeln ---------------------------------------------
log "4/4 VM-Formate erzeugen: $FORMATS"
for fmt in $FORMATS; do
    case $fmt in
        qcow2)
            qemu-img convert -p -m 8 -W -c -O qcow2 -o compression_type=zstd \
                "$IMG" "$OUTDIR/$BASENAME.qcow2" ;;
        vhdx)
            qemu-img convert -p -m 8 -W -O vhdx -o subformat=dynamic \
                "$IMG" "$VM/$BASENAME.vhdx"
            (cd "$VM" && zip -1 -q "$OUTDIR/$BASENAME.vhdx.zip" "$BASENAME.vhdx")
            rm -f "$VM/$BASENAME.vhdx" ;;
        ova)
            "$ROOT/tools/make-ova.sh" "$IMG" "$OUTDIR/$BASENAME.ova" ;;
        *) die "Unbekanntes Format: $fmt" ;;
    esac
done
rm -f "$IMG"
log "Fertig:"
ls -lh "$OUTDIR"
