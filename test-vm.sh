#!/usr/bin/env bash
# Startet die gebaute ISO in QEMU.
#   ./test-vm.sh          BIOS-Modus
#   ./test-vm.sh uefi     UEFI-Modus (benötigt Paket "ovmf")
#   ./test-vm.sh install  mit virtueller 30-GB-Festplatte zum Testen des Installers
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/config.sh"
ISO="$ROOT/out/$ISO_NAME"
[[ -f $ISO ]] || { echo "ISO nicht gefunden: $ISO – erst ./build.sh ausführen"; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "Bitte installieren: sudo apt install qemu-system-x86 ovmf"; exit 1; }

args=(-m 4096 -smp 2 -cdrom "$ISO" -boot d -vga virtio -display gtk
      -device intel-hda -device hda-duplex -nic user,model=virtio-net-pci)
[[ -w /dev/kvm ]] && args+=(-enable-kvm -cpu host)

for opt in "$@"; do
    case $opt in
        uefi)
            fw=/usr/share/OVMF/OVMF_CODE_4M.fd
            [[ -f $fw ]] || fw=/usr/share/ovmf/OVMF.fd
            args+=(-drive "if=pflash,format=raw,readonly=on,file=$fw") ;;
        install)
            disk="$ROOT/out/test-disk.qcow2"
            [[ -f $disk ]] || qemu-img create -f qcow2 "$disk" 30G
            args+=(-drive "file=$disk,if=virtio") ;;
    esac
done
exec qemu-system-x86_64 "${args[@]}"
