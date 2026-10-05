# wpa_supplicant 2.11 (Haiku's port, jmgasper/wpa_supplicant airos-2.11.haiku.1)
# for arm64 images, built as tools/rock5-itx/build-wpa-supplicant-arm64.sh does:
# internal TLS and libtommath (no OpenSSL dependency), the Haiku resources and
# attributes. x86_64 images get HaikuPorts' wpa_supplicant.
VERSION=2.11.haiku.1
PKG_REVISION=2
NO_PACKAGE=1
SUMMARY="WPA/WPA2 wireless supplicant for Haiku"
build() {
	[[ $ARCH == arm64 ]] || die "wpa_supplicant is built for arm64 only"
	local config=wpa_supplicant/.config
	sed -i "s|-I/system/develop/|-I$SYSROOT/boot/system/develop/|g" "$config"
	printf '\nCONFIG_TLS=internal\nCONFIG_INTERNAL_LIBTOMMATH=y\n' >> "$config"
	sed -i 's/^[[:space:]]*mimeset -F wpa_supplicant$/\ttrue/' wpa_supplicant/Makefile
	PATH="$TOOLS/rc:$TOOLS:$PATH" make -C wpa_supplicant -j"$JOBS" wpa_supplicant \
		CC="${CROSS}gcc --sysroot=$SYSROOT" LDO="${CROSS}g++ --sysroot=$SYSROOT"
	local pkg=$WORKDIR/wpa_supplicant/package
	rm -rf "$pkg"
	mkdir -p "$pkg/bin"
	install -m 0755 wpa_supplicant/wpa_supplicant "$pkg/bin/wpa_supplicant"
	${CROSS}strip --strip-debug "$pkg/bin/wpa_supplicant"
	"$TOOLS/xres" -o "$pkg/bin/wpa_supplicant" wpa_supplicant/wpa_gui-haiku/wpa_supplicant.rsrc
	"$TOOLS/resattr/resattr" -O -o "$pkg/bin/wpa_supplicant" wpa_supplicant/wpa_gui-haiku/wpa_supplicant.rsrc
	cat > "$pkg/.PackageInfo" <<INFO
name wpa_supplicant
version $VERSION-$PKG_REVISION
architecture arm64
summary "WPA/WPA2 wireless supplicant for Haiku"
description "Wireless authentication and association for the network server. Built by air/OS CI from jmgasper/wpa_supplicant ${FORK_COMMIT:0:12}."
packager "air/OS CI"
vendor "air/OS"
urls { "https://github.com/haiku/wpa_supplicant" }
copyrights { "2003-2026 Jouni Malinen and contributors" }
licenses { "BSD (2-clause)" }
provides {
	wpa_supplicant = $VERSION
	cmd:wpa_supplicant = $VERSION
}
requires {
	haiku >= r1~beta6
}
INFO
	local file=$AIROS_PACKAGES/arm64/wpa_supplicant-$VERSION-$PKG_REVISION-arm64.hpkg
	rm -f "$AIROS_PACKAGES"/arm64/wpa_supplicant-[0-9]*-arm64.hpkg
	"$TOOLS/package/package" create -q -C "$pkg" "$file"
	"$TOOLS/package/package" list -a "$file" | grep -q 'BEOS:APP_SIG' || die "no attributes on wpa_supplicant"
	echo "package: $file"
}
