#!/usr/bin/env bash
# build-sdk.sh ARCH [REF]
#
# Build jmgasper/haiku at REF (default: origin/master) for ARCH (x86_64 or
# arm64) and assemble the air/OS cross SDK that app and dependency builds use:
#
#   $AIROS_SDK/ARCH/env.sh     CROSS, SYSROOT, TOOLS, MIMEDB, ... (source it)
#   $AIROS_SDK/ARCH/sysroot    boot/system with haiku + haiku_devel, the build
#                              packages (gcc_syslibs, zlib, ...), the private
#                              headers and libshared.a / liblocalestub.a
#   $AIROS_SDK/ARCH/revision   the haiku revision (hrev...-g<sha>) it was built from
#
# The Haiku build directory is $AIROS_BUILD/haiku-ARCH, using the source
# worktree $AIROS_SRC/wt/haiku-ARCH; the cross compiler is built on first use
# from jmgasper/buildtools at the revision pinned in tools/rock5-itx/sources.json.
# Host tools use --no-full-xattr: attribute data stays in the emulation store
# but each file is tied to it by an xattr hash (not its inode number)
# and parallel jobs cannot pick up each other's stale attributes.
#
# Holds the exclusive lock haiku-ARCH; consumers take it shared (see
# lib/sdk.sh), so the SDK never changes under a running app build.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: build-sdk.sh x86_64|arm64 [ref]}
REF=${2:-origin/master}
TRIPLET=$(haiku_triplet "$ARCH")
CLONE=$AIROS_SRC/haiku
WT=$AIROS_SRC/wt/haiku-$ARCH
BUILD=$AIROS_BUILD/haiku-$ARCH
SDK=$AIROS_SDK/$ARCH
CROSS_DIR=$BUILD/cross-tools-$ARCH

if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	exec env AIROS_LOCKED=haiku-$ARCH flock "$AIROS_LOCKS/haiku-$ARCH.lock" "$0" "$@"
fi

update_sources() {
	note "sources: $HAIKU_REPO $REF"
	if [[ ! -d $CLONE/.git ]]; then
		# Full clone with tags: the hrev tags make the revision (hrevNNNNN-NN).
		git clone -q "$HAIKU_REPO" "$CLONE"
	fi
	# Only one job fetches at a time; worktrees of other arches are untouched.
	with_lock haiku-clone git -C "$CLONE" fetch -q --tags --prune --force origin
	SHA=$(git -C "$CLONE" rev-parse --verify "$REF^{commit}")
	if [[ ! -d $WT ]]; then
		mkdir -p "$(dirname "$WT")"
		with_lock haiku-clone git -C "$CLONE" worktree add -q --detach "$WT" "$SHA"
	else
		git -C "$WT" checkout -q --detach --force "$SHA"
		git -C "$WT" clean -qfdx
	fi
	REVISION=$(git -C "$WT" describe --tags --match 'hrev*' --long 2>/dev/null || true)
	[[ $REVISION == hrev* ]] || die "no hrev tag reachable from $SHA (shallow clone?)"
	echo "revision: $REVISION ($SHA)"
}

update_buildtools() {
	local pin
	pin=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["buildtools_revision"])' \
		"$WT/tools/rock5-itx/sources.json")
	if [[ ! -d $AIROS_SRC/buildtools/.git ]]; then
		git clone -q "$BUILDTOOLS_REPO" "$AIROS_SRC/buildtools"
	fi
	if ! git -C "$AIROS_SRC/buildtools" cat-file -e "$pin^{commit}" 2>/dev/null; then
		git -C "$AIROS_SRC/buildtools" fetch -q origin
	fi
	BUILDTOOLS_PIN=$pin
	if [[ ! -x $AIROS_TOOLCHAIN/bin/jam ]]; then
		note "jam"
		with_lock buildtools bash -c "cd '$AIROS_SRC/buildtools' && git checkout -q '$pin' \
			&& cd jam && make -s && ./jam0 -sBINDIR='$AIROS_TOOLCHAIN/bin' install"
	fi
}

configure_build() {
	mkdir -p "$BUILD"
	cd "$BUILD"
	if [[ ! -x $CROSS_DIR/bin/$TRIPLET-gcc ]] \
			|| [[ $(cat "$CROSS_DIR/.buildtools-revision" 2>/dev/null) != "$BUILDTOOLS_PIN" ]]; then
		note "cross tools $ARCH (buildtools $BUILDTOOLS_PIN)"
		with_lock buildtools git -C "$AIROS_SRC/buildtools" checkout -q "$BUILDTOOLS_PIN"
		rm -rf "$CROSS_DIR"
		"$WT/configure" --distro-compatibility compatible --no-full-xattr \
			--cross-tools-source "$AIROS_SRC/buildtools" --build-cross-tools "$ARCH" -j"$JOBS"
		echo "$BUILDTOOLS_PIN" > "$CROSS_DIR/.buildtools-revision"
	elif ! grep -q "^#c $WT/configure" build/BuildConfig 2>/dev/null \
			|| ! grep -q -- '--no-full-xattr' build/BuildConfig; then
		note "configure $ARCH"
		"$WT/configure" --distro-compatibility compatible --no-full-xattr \
			--cross-tools-prefix "$CROSS_DIR/bin/$TRIPLET-"
	fi
	# CI builds use their own UserBuildConfig (images/); the SDK needs none.
	rm -f UserBuildConfig
}

build_haiku() {
	note "jam: haiku packages and host tools ($ARCH)"
	cd "$BUILD"
	jam -q -j"$JOBS" haiku.hpkg haiku_devel.hpkg \
		'<build>rc' '<build>xres' '<build>mimeset' '<build>resattr' '<build>rm_attrs' \
		'<build>package' '<build>settype' '<build>setversion' '<build>copyattr' \
		'<build>catattr' '<mimedb>mime_db'
}

assemble_sdk() {
	note "SDK $SDK"
	local new=$SDK.new root
	rm -rf "$new"
	root=$new/sysroot/boot/system
	mkdir -p "$root"
	local pkgdir=$BUILD/objects/haiku/$ARCH/packaging/packages
	local package=$BUILD/objects/linux/$(uname -m)/release/tools/package/package
	"$package" extract -C "$root" "$pkgdir/haiku.hpkg"
	"$package" extract -C "$root" "$pkgdir/haiku_devel.hpkg"
	# The build packages the Haiku build links against (gcc_syslibs, zlib, ...).
	local dir
	for dir in "$BUILD"/build_packages/*; do
		[[ $dir == *_source-* ]] && continue
		cp -a "$dir"/. "$root"/
	done
	rm -f "$root/.PackageInfo"
	# Private headers (AirShot, AirTime, Kiri use them; haiku_devel carries
	# libshared.a and liblocalestub.a already).
	mkdir -p "$root/develop/headers"
	cp -a "$WT/headers/private" "$root/develop/headers/"
	# C++ exceptions: link libgcc_s ahead of libgcc's private unwinder copy.
	printf '*libgcc:\n-lgcc_s -lgcc\n\n' > "$new/shared-unwinder.specs"
	local tools=$BUILD/objects/linux/$(uname -m)/release/tools
	cat > "$new/env.sh" <<EOF
# air/OS $ARCH cross SDK, from jmgasper/haiku $REVISION ($SHA)
AIROS_ARCH=$ARCH
HAIKU_REVISION=$REVISION
HAIKU_SHA=$SHA
HAIKU_BUILD=$BUILD
HAIKU_SOURCE=$WT
CROSS=$CROSS_DIR/bin/$TRIPLET-
TRIPLET=$TRIPLET
SYSROOT=$SDK/sysroot
TOOLS=$tools
ATTRS=$BUILD/attributes
MIMEDB=$BUILD/objects/common/data/mime_db/mime_db
UNWIND_SPECS=$SDK/shared-unwinder.specs
EOF
	echo "$REVISION" > "$new/revision"
	rm -rf "$SDK.old"
	[[ -e $SDK ]] && mv "$SDK" "$SDK.old"
	mv "$new" "$SDK"
	# The specs path inside env.sh names the final location.
	rm -rf "$SDK.old"
	echo "SDK ready: $SDK ($REVISION)"
}

mkdir -p "$AIROS_SRC" "$AIROS_BUILD" "$AIROS_SDK"
update_sources
update_buildtools
configure_build
build_haiku
assemble_sdk
