#!/usr/bin/env bash
# build-firmware.sh
#
# Firmware for the air/OS images, all from repositories pinned in
# forks/forks.lock.json (jmgasper/airos-firmware for the linux-firmware files,
# the Raspberry Pi firmware, firmware-nonfree and bluez-firmware forks) and
# HaikuPorts:
#
#   $AIROS_PACKAGES/any/      intel_, realtek_ and mediatek_bluetooth_firmwares,
#                             mediatek_wifi_firmwares (architecture any), as
#                             tools/rock5-itx/build-bluetooth-firmware-packages.sh
#                             and docs/x399-workstation/tools/build-mediatek-
#                             wifi-firmware-package.sh make them
#   $AIROS_PACKAGES/arm64/    HaikuPorts' Intel, Ralink and Realtek Wi-Fi sets,
#                             recompressed with zlib (packagefs on arm64 reads no
#                             zstd); x86_64 images get them from HaikuPorts
#   $AIROS_ROOT/image-inputs/arm64/firmware/mali/arch10.8/mali_csffw.bin
#   $AIROS_ROOT/image-inputs/rpi4/rpi-firmware/   the Pi 4 boot firmware
#   $AIROS_ROOT/image-inputs/rpi4/firmware/       CYW43455 Wi-Fi and Bluetooth
#
# Every file from the Raspberry Pi repositories is checked against
# deps/rpi4-firmware.sha256 (the files the current Pi images were made with).
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
. "$AIROS_CI/lib/fork.sh"
. "$AIROS_SDK/arm64/env.sh"

PACKAGE=$TOOLS/package/package
WORK=$AIROS_WORK/firmware
INPUTS=$AIROS_ROOT/image-inputs
# linux-firmware 20240318 (git 3b128b60): what the workstation packages were
# made from; -2 because these are rebuilt from git rather than Ubuntu's copy.
VERSION=20240318
REVISION=2
mkdir -p "$WORK" "$AIROS_PACKAGES/any" "$AIROS_PACKAGES/arm64"

note "airos-firmware"
fw=$WORK/airos-firmware
fork_checkout airos-firmware "$fw"
FW_COMMIT=$FORK_COMMIT

# build_package NAME FIRMWARE_DIR LICENSE_FILE LICENSE_NAME COPYRIGHT SUMMARY DESCRIPTION SOURCE...
build_package() {
	local name=$1 dir=$2 license=$3 licenseName=$4 copyright=$5 summary=$6 description=$7
	shift 7
	local stage=$WORK/stage-$name
	rm -rf "$stage"
	mkdir -p "$stage/data/firmware/$dir" "$stage/data/licenses"
	local source count=0
	for source in "$@"; do
		[[ -e $source || -L $source ]] || continue
		cp -P "$source" "$stage/data/firmware/$dir/"
		[[ -L $source ]] || chmod 0444 "$stage/data/firmware/$dir/$(basename "$source")"
		count=$((count + 1))
	done
	(( count > 0 )) || die "$name: no firmware files"
	for source in "$stage/data/firmware/$dir"/*; do
		[[ -e $source ]] || die "dangling link $source"
	done
	cp "$license" "$stage/data/licenses/$licenseName"
	cat > "$stage/.PackageInfo" <<EOF
name			$name
version			$VERSION-$REVISION
architecture		any
summary			"$summary"
description		"$description (linux-firmware $VERSION, from jmgasper/airos-firmware ${FW_COMMIT:0:12})"
packager		"air/OS CI"
vendor			"Haiku Project"
licenses {
	"$licenseName"
}
copyrights {
	"$copyright"
}
provides {
	$name = $VERSION
}
urls {
	"https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git"
}
EOF
	local output=$AIROS_PACKAGES/any/$name-$VERSION-$REVISION-any.hpkg
	rm -f "$AIROS_PACKAGES/any/$name"-[0-9]*-any.hpkg
	(cd "$stage" && "$PACKAGE" create -q "$output")
	echo "$(basename "$output"): $count files"
}

build_package intel_bluetooth_firmwares intel "$fw/LICENCE.ibt_firmware" \
	"Intel Bluetooth Firmware" "2014-2024 Intel Corporation" "Intel Bluetooth firmware" \
	"Firmware for the Bluetooth half of Intel Wi-Fi cards, Wireless 7260 to Wi-Fi 7 BE200, loaded by bt_firmware" \
	"$fw"/intel/ibt-*
build_package realtek_bluetooth_firmwares rtl_bt "$fw/LICENCE.rtlwifi_firmware.txt" \
	"Realtek Bluetooth Firmware" "Realtek Semiconductor Corp." "Realtek Bluetooth firmware" \
	"Firmware and configuration for Realtek USB Bluetooth controllers and the Bluetooth half of Realtek Wi-Fi cards (RTL8723 to RTL8922), loaded by bt_firmware" \
	"$fw"/rtl_bt/*
build_package mediatek_bluetooth_firmwares h2generic "$fw/LICENCE.mediatek" \
	"MediaTek Firmware" "MediaTek Inc." "MediaTek Bluetooth firmware" \
	"Firmware for the Bluetooth half of MediaTek MT7921 and MT7922 Wi-Fi cards, loaded by the h2generic driver" \
	"$fw"/mediatek/BT_RAM_CODE_MT79*
build_package mediatek_wifi_firmwares mt7922wifi "$fw/LICENCE.mediatek" \
	"MediaTek Firmware" "MediaTek Inc." "MediaTek Wi-Fi firmware" \
	"Firmware for the Wi-Fi half of MediaTek MT7921 and MT7922 cards (such as the TP-Link Archer TX55E), loaded by the mt7922wifi driver" \
	"$fw"/mediatek/WIFI_MT7922_* "$fw"/mediatek/WIFI_RAM_CODE_MT7922_* \
	"$fw"/mediatek/WIFI_MT7961_* "$fw"/mediatek/WIFI_RAM_CODE_MT7961_*

note "HaikuPorts Wi-Fi firmware for arm64 (zlib)"
# Heap compression: the 16-bit field at offset 18 of the hpkg header (2 = zstd).
compression() { od -An -tu1 -j18 -N2 -- "$1" | awk '{print $1 * 256 + $2}'; }
for source in $(AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" \
		fetch --no-deps x86_64 intel_wifi_firmwares ralink_wifi_firmwares realtek_wifi_firmwares); do
	name=$(basename "$source")
	rm -f "$AIROS_PACKAGES/arm64/${name%%-[0-9]*}"-[0-9]*-any.hpkg
	if [[ $(compression "$source") == 2 ]]; then
		"$PACKAGE" recompress -q -z zlib "$source" "$AIROS_PACKAGES/arm64/$name"
	else
		cp "$source" "$AIROS_PACKAGES/arm64/$name"
	fi
	[[ $(compression "$AIROS_PACKAGES/arm64/$name") != 2 ]] || die "$name is still zstd"
	echo "$name"
done

note "Mali CSF firmware (ROCK 5)"
mkdir -p "$INPUTS/arm64/firmware/mali/arch10.8"
cp "$fw/arm/mali/arch10.8/mali_csffw.bin" "$INPUTS/arm64/firmware/mali/arch10.8/"
sha256sum "$INPUTS/arm64/firmware/mali/arch10.8/mali_csffw.bin"

note "Raspberry Pi 4 firmware"
# raw file from a fork at its pinned commit
fetch_raw() { # fetch_raw LOCK_NAME PATH DEST
	local url
	url="https://raw.githubusercontent.com/$GITHUB_OWNER/$(fork_info "$1" repo)/$(fork_info "$1" commit)/$2"
	mkdir -p "$(dirname "$3")"
	curl -sfL --retry 3 -o "$3" "$url" || die "cannot fetch $url"
}
rpi=$INPUTS/rpi4
rm -rf "$rpi/rpi-firmware" "$rpi/firmware"
for file in start4.elf fixup4.dat LICENCE.broadcom bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb \
		bcm2711-rpi-cm4.dtb overlays/overlay_map.dtb overlays/disable-bt.dtbo \
		overlays/miniuart-bt.dtbo overlays/vc4-kms-v3d-pi4.dtbo; do
	fetch_raw rpi-firmware "boot/$file" "$rpi/rpi-firmware/$file"
done
nonfree=debian/config/brcm80211
fetch_raw rpi-firmware-nonfree "$nonfree/cypress/cyfmac43455-sdio-standard.bin" \
	"$rpi/firmware/broadcomfmac/brcmfmac43455-sdio.bin"
fetch_raw rpi-firmware-nonfree "$nonfree/cypress/cyfmac43455-sdio.clm_blob" \
	"$rpi/firmware/broadcomfmac/brcmfmac43455-sdio.clm_blob"
fetch_raw rpi-firmware-nonfree "$nonfree/brcm/brcmfmac43455-sdio.txt" \
	"$rpi/firmware/broadcomfmac/brcmfmac43455-sdio.txt"
fetch_raw rpi-bluez-firmware debian/firmware/broadcom/BCM4345C0.hcd "$rpi/firmware/h4bcm/BCM4345C0.hcd"
(cd "$rpi" && sha256sum -c --quiet "$AIROS_CI/deps/rpi4-firmware.sha256") \
	|| die "Raspberry Pi firmware does not match deps/rpi4-firmware.sha256"
echo "Raspberry Pi firmware: $(wc -l < "$AIROS_CI/deps/rpi4-firmware.sha256") files verified"
