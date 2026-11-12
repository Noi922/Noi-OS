#!/usr/bin/env bash
# ===========================================================================
#  Noi OS Server – automatischer Test der ISO
#
#  1. ISO in QEMU starten und ein Bildschirmfoto machen (zeigt den Installer)
#  2. Installer unbeaufsichtigt auf eine virtuelle Festplatte laufen lassen
#  3. Installiertes System starten (BIOS, danach UEFI) und per SSH prüfen:
#     Anmeldung, Netzwerk, Firewall, Web-Verwaltung, noi-Werkzeug
#
#  Aufruf:  sudo tools/server-test.sh out/noios-server-1.0-amd64.iso [AUSGABEORDNER]
#  Umgebung: BOOT_TIMEOUT (Sekunden pro Start, Standard 600), SKIP_ISO_BOOT=1
# ===========================================================================
set -uo pipefail

ISO="${1:?ISO-Datei fehlt}"
OUT="${2:-server-test}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
SSH_PORT=2222 WEB_PORT=9091
TESTUSER=admin TESTPASS='Noi-Test-12345' TESTHOST=noi-test

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen."; exit 1; }
[[ -f $ISO ]] || { echo "ISO nicht gefunden: $ISO"; exit 1; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/noi-server-test.XXXXXX")"
DISK="$WORK/disk.raw"
LOOP="" QEMU_PID=""
RESULTS=()
FAILED=0

check() {   # check "Name" 0|1 "Details" [optional]
    local name=$1 ok=$2 detail=${3:-} optional=${4:-}
    if [[ $ok == 0 ]]; then
        echo "[OK  ] $name: $detail"; RESULTS+=("| $name | ✅ | $detail |")
    elif [[ -n $optional ]]; then
        echo "[WARN] $name: $detail"; RESULTS+=("| $name | ⚠️ | $detail |")
    else
        echo "[FAIL] $name: $detail"; RESULTS+=("| $name | ❌ | $detail |"); FAILED=1
    fi
}
stop_vm() {
    [[ -n $QEMU_PID ]] && kill "$QEMU_PID" 2>/dev/null && wait "$QEMU_PID" 2>/dev/null
    QEMU_PID=""
}
cleanup() {
    stop_vm
    mountpoint -q "$WORK/squash" 2>/dev/null && umount -l "$WORK/squash"
    [[ -n $LOOP ]] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

for t in qemu-system-x86_64 xorriso unsquashfs sgdisk sshpass rsync; do
    command -v "$t" >/dev/null || { echo "Werkzeug fehlt: $t"; exit 1; }
done
ACCEL=(-accel tcg -cpu max)
[[ -w /dev/kvm ]] && ACCEL=(-enable-kvm -cpu host)
qemu() {    # gemeinsame Optionen; weitere per Argument
    qemu-system-x86_64 "${ACCEL[@]}" -m 2048 -smp 2 -display none \
        -monitor "unix:$WORK/mon.sock,server,nowait" -serial "file:$WORK/serial.log" "$@" &
    QEMU_PID=$!
}
mon() { printf '%s\n' "$1" | socat - "unix-connect:$WORK/mon.sock" >/dev/null 2>&1; }
screenshot() {
    command -v socat >/dev/null || return 0
    mon "screendump $WORK/shot.ppm"; sleep 2
    if [[ -s $WORK/shot.ppm ]] && command -v python3 >/dev/null; then
        python3 - "$WORK/shot.ppm" "$OUT/$1.png" <<'PY' 2>/dev/null || cp "$WORK/shot.ppm" "$OUT/$1.ppm"
import sys
from PIL import Image
Image.open(sys.argv[1]).save(sys.argv[2])
PY
    fi
}
ssh_run() {
    sshpass -p "$TESTPASS" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20 \
        "$TESTUSER@127.0.0.1" "$@"
}
wait_ssh() {   # wartet, bis sich der SSH-Dienst meldet
    local t=0
    while (( t < BOOT_TIMEOUT )); do
        kill -0 "$QEMU_PID" 2>/dev/null || return 2
        if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$SSH_PORT; head -c 7 <&3" 2>/dev/null \
                | grep -q '^SSH-2'; then
            return 0
        fi
        sleep 5; t=$((t + 5))
    done
    return 1
}

# --- 1. ISO startet und zeigt den Installer ------------------------------------
if [[ ${SKIP_ISO_BOOT:-0} != 1 ]]; then
    echo "== 1. ISO starten (Live-System)"
    truncate -s 12G "$WORK/blank.raw"
    qemu -cdrom "$ISO" -boot d -drive "file=$WORK/blank.raw,format=raw,if=virtio" -nic none
    t=0
    while (( t < BOOT_TIMEOUT )); do
        sleep 15; t=$((t + 15))
        kill -0 "$QEMU_PID" 2>/dev/null || break
        screenshot "01-live-installer"
        # Der Installer-Dialog (whiptail) hat einen einfarbig blauen Hintergrund
        if [[ -f $OUT/01-live-installer.png ]] && python3 - "$OUT/01-live-installer.png" <<'PY' 2>/dev/null
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = [im.getpixel((x, y)) for x in range(0, im.width, 16) for y in range(0, im.height, 16)]
blue = sum(1 for r, g, b in px if b > 120 and r < 90 and g < 90)
sys.exit(0 if blue > len(px) * 0.4 else 1)
PY
        then break; fi
    done
    if (( t < BOOT_TIMEOUT )) && kill -0 "$QEMU_PID" 2>/dev/null; then
        check "ISO startet, Installer erscheint" 0 "nach ${t}s (Bildschirmfoto 01-live-installer.png)"
    else
        check "ISO startet, Installer erscheint" 1 "kein Installer-Dialog nach ${t}s"
    fi
    stop_vm
    rm -f "$WORK/blank.raw"
fi

# --- 2. Installation (unbeaufsichtigt) -------------------------------------------
echo "== 2. Installer auf virtuelle Festplatte"
xorriso -osirrox on -indev "$ISO" -extract /casper/filesystem.squashfs "$WORK/fs.squashfs" \
    >/dev/null 2>&1
mkdir -p "$WORK/squash" "$WORK/target"
if ! mount -o loop,ro "$WORK/fs.squashfs" "$WORK/squash" 2>/dev/null; then
    unsquashfs -f -d "$WORK/squash" "$WORK/fs.squashfs" >/dev/null   # ohne squashfs-Modul
fi
rm -f "$WORK/fs.squashfs.tmp"
truncate -s 12G "$DISK"
LOOP="$(losetup -fP --show "$DISK")"
# Den Installer aus dem Abbild nehmen – genau der, der auch auf der ISO läuft
if bash "$WORK/squash/usr/sbin/noi-server-install" --source "$WORK/squash" \
        --target "$WORK/target" --disk "$LOOP" --hostname "$TESTHOST" \
        --user "$TESTUSER" --password "$TESTPASS" --yes > "$OUT/install.log" 2>&1; then
    check "Installer läuft durch" 0 "siehe install.log"
else
    check "Installer läuft durch" 1 "$(tail -3 "$OUT/install.log" | tr '\n' ' ')"
fi
mountpoint -q "$WORK/squash" && umount -l "$WORK/squash"
losetup -d "$LOOP"; LOOP=""
rm -rf "$WORK/squash" "$WORK/fs.squashfs"

# --- 3. Installiertes System starten und prüfen ------------------------------------
NET=(-nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$WEB_PORT-:9090")
boot_and_check() {   # $1 = Name, Rest = zusätzliche QEMU-Optionen
    local mode=$1; shift
    echo "== 3. Installiertes System starten ($mode)"
    qemu -drive "file=$DISK,format=raw,if=virtio" "${NET[@]}" "$@"
    wait_ssh; local rc=$?
    screenshot "02-installiert-$mode"
    if (( rc != 0 )); then
        check "$mode: System startet, SSH erreichbar" 1 "keine Antwort nach ${BOOT_TIMEOUT}s"
        stop_vm; return 1
    fi
    check "$mode: System startet, SSH erreichbar" 0 "Netzwerk (DHCP), Firewall-Freigabe und Host-Schlüssel ok"
    [[ $mode == BIOS ]] || { stop_vm; return 0; }   # die Detailprüfungen genügen einmal

    local out
    out=$(ssh_run 'hostname; . /etc/os-release; echo "$PRETTY_NAME"; echo "$ID"' 2>&1)
    check "Anmeldung per SSH mit dem angelegten Benutzer" \
        "$([[ $out == *"$TESTHOST"* ]] && echo 0 || echo 1)" "$(echo "$out" | tr '\n' ' ')"
    check "System-Name" "$([[ $out == *"Noi OS Server"* && $out == *ubuntu* ]] && echo 0 || echo 1)" \
        "$(echo "$out" | sed -n 2p)"
    out=$(ssh_run "echo '$TESTPASS' | sudo -S -p '' id -u" 2>&1)
    check "Benutzer hat sudo-Rechte" "$([[ $out == 0 ]] && echo 0 || echo 1)" "id -u = $out"
    out=$(ssh_run "echo '$TESTPASS' | sudo -S -p '' ufw status | head -1" 2>&1)
    check "Firewall aktiv" "$([[ ${out,,} == *aktiv* || ${out,,} == *active* ]] && echo 0 || echo 1)" "$out"
    out=$(ssh_run "echo '$TESTPASS' | sudo -S -p '' passwd -S root | cut -d' ' -f2" 2>&1)
    check "root-Konto gesperrt" "$([[ $out == L ]] && echo 0 || echo 1)" "Status $out"
    out=$(ssh_run 'dpkg-query -W -f="\${Status}" casper 2>/dev/null; ls /usr/sbin/noi-server-install 2>/dev/null' 2>&1)
    check "Live-Werkzeuge entfernt" "$([[ $out != *"ok installed"* && $out != *noi-server-install* ]] && echo 0 || echo 1)" "${out:-sauber}"
    out=$(ssh_run 'getent ahosts archive.ubuntu.com >/dev/null && echo dns-ok; curl -fsS -m 15 -o /dev/null http://archive.ubuntu.com/ubuntu/dists/ && echo web-ok' 2>&1)
    check "Internet (DNS + Web)" "$([[ $out == *dns-ok* && $out == *web-ok* ]] && echo 0 || echo 1)" \
        "$(echo "$out" | tr '\n' ' ')" optional
    out=$(ssh_run 'noi hilfe | grep -c "noi "; noi info | grep -c Server' 2>&1 | tr '\n' ' ')
    check "noi-Werkzeug" "$([[ $out =~ ^[0-9]+\ [1-9] ]] && echo 0 || echo 1)" "$out"
    out=$(ssh_run 'systemctl is-enabled cockpit.socket fail2ban ufw unattended-upgrades 2>&1 | tr "\n" " "' 2>&1)
    check "Dienste eingeschaltet (Cockpit, fail2ban, ufw, Updates)" \
        "$([[ $out != *disabled* && $out == *enabled* ]] && echo 0 || echo 1)" "$out"
    out=$(curl -ksS -m 30 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$WEB_PORT/" 2>&1)
    check "Web-Verwaltung (Cockpit) antwortet" "$([[ $out == 200 ]] && echo 0 || echo 1)" "HTTP $out"
    out=$(ssh_run 'podman --version' 2>&1)
    check "Podman vorhanden" "$([[ $out == podman* ]] && echo 0 || echo 1)" "$out" optional
    out=$(ssh_run 'systemctl --failed --no-legend --plain | awk "{print \$1}" | tr "\n" " "' 2>&1)
    check "Keine fehlgeschlagenen Dienste" "$([[ -z ${out// /} ]] && echo 0 || echo 1)" "${out:-keine}" optional
    ssh_run "echo '$TESTPASS' | sudo -S -p '' poweroff" >/dev/null 2>&1
    for _ in $(seq 1 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
    stop_vm
}

if [[ $FAILED == 0 ]]; then
    boot_and_check BIOS
    OVMF=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f $f ]] && { OVMF=$f; break; }
    done
    if [[ -n $OVMF ]]; then
        VARS=()
        for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
            [[ -f $v ]] && { cp "$v" "$WORK/vars.fd"; VARS=(-drive "if=pflash,format=raw,file=$WORK/vars.fd"); break; }
        done
        boot_and_check UEFI -drive "if=pflash,format=raw,readonly=on,file=$OVMF" "${VARS[@]}"
    else
        check "UEFI: System startet" 1 "OVMF nicht installiert – übersprungen" optional
    fi
fi

{
    echo "# Noi OS Server – Test"
    echo
    echo "| Prüfung | Ergebnis | Details |"
    echo "|---|---|---|"
    printf '%s\n' "${RESULTS[@]}"
} > "$OUT/bericht.md"
if [[ $FAILED == 0 ]]; then echo; echo "ALLE PFLICHT-PRÜFUNGEN BESTANDEN"; else echo; echo "FEHLGESCHLAGEN – siehe $OUT/bericht.md"; fi
exit $FAILED
