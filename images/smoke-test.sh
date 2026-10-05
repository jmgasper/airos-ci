#!/usr/bin/env bash
# smoke-test.sh TARGET [IMAGE_DIR]
#
# Boot a built image in QEMU (no hardware) and check that it reaches the
# desktop: the serial log must show input_server loading its add-ons (it
# starts with the graphical session, after app_server), no kernel debugger
# entry, and a screenshot of the screen 30 seconds later must not be blank.
#   x86_64  qemu-system-x86_64 with KVM, the ISO as a CD
#   arm64   qemu-system-aarch64 (virt, UEFI firmware), the ISO as a USB disk
#   rpi4    not booted (QEMU's raspi4b cannot run Haiku's Pi loader); the SD
#           image's partition table and boot files are checked instead
# Writes smoke.log, serial.log and screen.png next to the image.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

TARGET=${1:?usage: smoke-test.sh x86_64|arm64|rpi4 [image dir]}
DIR=${2:-$AIROS_ARTIFACTS/images/$TARGET/latest}
DIR=$(readlink -f "$DIR")
TIMEOUT=${SMOKE_TIMEOUT:-240}
work=$(mktemp -d "$AIROS_DATA/tmp/smoke-$TARGET-XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT

image=$(ls "$DIR"/*.xz | head -n 1)
xz -dc "$image" > "$work/image"
serial=$work/serial.log    # fresh for every run; copied next to the image at the end
: > "$serial"

if [[ $TARGET == rpi4 ]]; then
	{
		echo "partitions:"
		/sbin/sfdisk -l "$work/image"
		echo "boot partition files:"
		offset=$(( $(/sbin/sfdisk -J "$work/image" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"])') * 512 ))
		mdir -i "$work/image@@$offset" -b ::/ | sort
	} | tee "$DIR/smoke.log"
	for required in start4.elf fixup4.dat config.txt airos-loader.img airos-boot.tgz bcm2711-rpi-4-b.dtb; do
		grep -q "/$required" "$DIR/smoke.log" || die "the boot partition has no $required"
	done
	echo "SMOKE PASS: SD image has the boot files" | tee -a "$DIR/smoke.log"
	exit 0
fi

monitor=$work/monitor.sock
case $TARGET in
	x86_64)
		qemu=(qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4
			-cdrom "$work/image" -boot d -vga std) ;;
	arm64)
		fw=/usr/share/AAVMF/AAVMF_CODE.fd
		[[ -f $fw ]] || fw=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
		cp /usr/share/AAVMF/AAVMF_VARS.fd "$work/vars.fd" 2>/dev/null || truncate -s 64M "$work/vars.fd"
		qemu=(qemu-system-aarch64 -M virt -cpu cortex-a72 -m 4096 -smp 4
			-drive if=pflash,format=raw,readonly=on,file="$fw"
			-drive if=pflash,format=raw,file="$work/vars.fd"
			-device qemu-xhci -device usb-kbd -device usb-tablet
			-drive if=none,id=stick,format=raw,file="$work/image" -device usb-storage,drive=stick
			-device ramfb) ;;
esac
"${qemu[@]}" -display none -serial "file:$serial" -monitor "unix:$monitor,server,nowait" \
	-no-reboot &
qemu_pid=$!

result=FAIL
for ((i = 0; i < TIMEOUT; i += 5)); do
	sleep 5
	kill -0 $qemu_pid 2>/dev/null || break
	if grep -aqE "Welcome to Kernel Debugging Land|PANIC:" "$serial"; then
		result=FAIL
		break
	fi
	if grep -aq "AddOnManager::" "$serial"; then
		result=PASS
		sleep 30   # let the desktop (or the first-start dialog) draw
		break
	fi
done
if kill -0 $qemu_pid 2>/dev/null; then
	printf 'screendump %s\n' "$work/screen.ppm" | socat - "UNIX-CONNECT:$monitor" >/dev/null 2>&1 || true
	sleep 2
	python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).save(sys.argv[2])' \
		"$work/screen.ppm" "$DIR/screen.png" 2>/dev/null || cp "$work/screen.ppm" "$DIR/screen.ppm" 2>/dev/null || true
	printf 'quit\n' | socat - "UNIX-CONNECT:$monitor" >/dev/null 2>&1 || kill $qemu_pid
fi
wait $qemu_pid 2>/dev/null || true
{
	cp "$serial" "$DIR/serial.log"
	echo "SMOKE $result: $TARGET $(basename "$image") after ${i}s"
	grep -aE "Welcome to Kernel Debugging Land|PANIC:|AddOnManager::" "$serial" | head -5
} | tee "$DIR/smoke.log"
if [[ $result == PASS && -f $DIR/screen.png ]]; then
	# A drawn desktop has hundreds of colours; a blank or hung screen a few.
	colours=$(python3 -c 'import sys; from PIL import Image; print(len(Image.open(sys.argv[1]).getcolors(1 << 20) or []))' "$DIR/screen.png")
	echo "screenshot: $colours colours" | tee -a "$DIR/smoke.log"
	(( colours > 64 )) || { echo "SMOKE FAIL: the screen is blank" | tee -a "$DIR/smoke.log"; exit 1; }
fi
[[ $result == PASS ]]
