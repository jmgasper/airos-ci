#!/usr/bin/env bash
# build-deps.sh ARCH [RECIPE...]
#
# Cross-build third-party libraries from the jmgasper forks (pinned in
# forks/forks.lock.json) with the air/OS SDK of ARCH. For each recipe in
# deps/recipes/ (default: all of them, in dependency order):
#
#   1. check out the fork at its pinned commit;
#   2. build it and install into a stage with the Haiku layout: libraries in
#      lib/, headers in develop/headers/, static libraries, the libX.so links
#      and pkg-config files in develop/lib/;
#   3. merge the stage into $AIROS_SDK/ARCH/deps/boot/system (DEPS), which app
#      builds and later recipes compile against;
#   4. package it as airos_<name>-<version>-ARCH.hpkg into the package pool
#      ($AIROS_PACKAGES/ARCH), from which the images install it.
#
# A recipe is skipped when its fork commit and recipe are unchanged since the
# last build (stamp in the work tree), unless FORCE=1.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: build-deps.sh x86_64|arm64 [recipe...]}
shift
# Exclusive: app builds read DEPS under the shared haiku-ARCH lock.
if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	exec env AIROS_LOCKED=haiku-$ARCH flock "$AIROS_LOCKS/haiku-$ARCH.lock" "$0" "$ARCH" "$@"
fi
export AIROS_ARCH=$ARCH
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

if [[ $ARCH == arm64 ]]; then
	ORDER=(openssl nghttp2 curl sqlite taglib pcre2 scintilla lexilla rock5_ffmpeg)
else
	ORDER=(haikuports)
fi
RECIPES=("${@:-${ORDER[@]}}")
WORKDIR=$AIROS_WORK/deps-$ARCH
PREFIX=/boot/system
mkdir -p "$WORKDIR" "$AIROS_PACKAGES/$ARCH" "$DEPS"

# --- cross environment the recipes use -------------------------------------
DEPS_ROOT=${DEPS%/boot/system}
export CC="${CROSS}gcc --sysroot=$SYSROOT -specs=$UNWIND_SPECS"
export CXX="${CROSS}g++ --sysroot=$SYSROOT -specs=$UNWIND_SPECS"
export AR=${CROSS}ar RANLIB=${CROSS}ranlib STRIP=${CROSS}strip NM=${CROSS}nm LD=${CROSS}ld \
	OBJDUMP=${CROSS}objdump
export CPPFLAGS="-I$DEPS/develop/headers"
export CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC"
export LDFLAGS="-L$DEPS/develop/lib -L$DEPS/lib -Wl,-rpath-link,$DEPS/lib -Wl,-rpath-link,$SYSROOT/boot/system/lib"
export PKG_CONFIG_LIBDIR=$DEPS/develop/lib/pkgconfig PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=$DEPS_ROOT
BUILD_TRIPLET=$(uname -m)-pc-linux-gnu
TOOLCHAIN_FILE=$WORKDIR/toolchain.cmake
case $ARCH in arm64) PROCESSOR=aarch64 ;; x86_64) PROCESSOR=x86_64 ;; esac
cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR $PROCESSOR)
set(CMAKE_SYSROOT $SYSROOT)
set(CMAKE_C_COMPILER ${CROSS}gcc)
set(CMAKE_CXX_COMPILER ${CROSS}g++)
set(CMAKE_C_FLAGS_INIT "-fPIC -I$DEPS/develop/headers")
set(CMAKE_CXX_FLAGS_INIT "-fPIC -I$DEPS/develop/headers")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-specs=$UNWIND_SPECS -L$DEPS/develop/lib -Wl,-rpath-link,$DEPS/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-specs=$UNWIND_SPECS -L$DEPS/develop/lib -Wl,-rpath-link,$DEPS/lib")
set(CMAKE_FIND_ROOT_PATH $SYSROOT/boot/system $SYSROOT/boot/system/develop $DEPS $DEPS/develop)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# configure_ac [args]: autotools cross configure into the Haiku layout.
configure_ac() {
	./configure --host="$TRIPLET" --build="$BUILD_TRIPLET" --prefix=$PREFIX \
		--libdir=$PREFIX/lib --includedir=$PREFIX/develop/headers \
		--datarootdir=$PREFIX/data --sysconfdir=$PREFIX/settings "$@"
}
# cmake_build [args]: configure, build and install a CMake project.
cmake_build() {
	cmake -S . -B _build -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
		-DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_INCLUDEDIR=develop/headers "$@" >/dev/null
	cmake --build _build -j"$JOBS" >/dev/null
	DESTDIR=$STAGE cmake --install _build >/dev/null
}

# normalize: move what install(1) put in the usual places to the Haiku layout.
normalize_stage() {
	local root=$STAGE$PREFIX lib target
	mkdir -p "$root/develop/lib" "$root/develop/headers"
	if [[ -d $root/include ]]; then cp -a "$root/include/." "$root/develop/headers/"; rm -rf "$root/include"; fi
	if [[ -d $root/lib/pkgconfig ]]; then
		mkdir -p "$root/develop/lib/pkgconfig"
		mv "$root/lib/pkgconfig"/* "$root/develop/lib/pkgconfig/"
		rmdir "$root/lib/pkgconfig"
	fi
	if [[ -d $root/lib/cmake ]]; then mv "$root/lib/cmake" "$root/develop/lib/"; fi
	find "$root/lib" -maxdepth 1 \( -name '*.a' -o -name '*.la' \) -exec mv {} "$root/develop/lib/" \;
	rm -f "$root"/develop/lib/*.la
	# libX.so development links point into lib/
	for lib in "$root"/lib/*.so; do
		[[ -e $lib ]] || continue
		if [[ -L $lib ]]; then
			# libX.so -> libX.so.N: the link belongs in develop/lib
			target=$(readlink -f "$lib")
			rm -f "$lib"
			ln -sf "../../lib/$(basename "$target")" "$root/develop/lib/$(basename "$lib")"
		else
			# an unversioned library (Scintilla, Lexilla) stays in lib/
			ln -sf "../../lib/$(basename "$lib")" "$root/develop/lib/$(basename "$lib")"
		fi
	done
	# pkg-config files: everything below /boot/system
	sed -i "s|^includedir=.*|includedir=\${prefix}/develop/headers|" "$root"/develop/lib/pkgconfig/*.pc 2>/dev/null || true
	rm -rf "$root/share/man" "$root/data/man" "$root/share/doc" "$root/data/doc"
	[[ -d $root/share ]] && { mkdir -p "$root/data"; cp -a "$root/share/." "$root/data/"; rm -rf "$root/share"; }
	return 0
}

# package: airos_<name> with lib: provides for every shared library.
make_package() {
	local root=$STAGE$PREFIX pkg=airos_${NAME//-/_} file soname provides="" lib
	for lib in "$root"/lib/*.so*; do
		[[ -f $lib && ! -L $lib ]] || continue
		soname=$(${CROSS}readelf -d "$lib" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		[[ -n $soname ]] || continue
		soname=${soname%%.so*}
		# resolvable names take no '-' (Haiku writes lib:libpcre2_8)
		provides+="	lib:${soname//-/_} = ${VERSION//-/_}"$'\n'
	done
	cat > "$root/.PackageInfo" <<EOF
name			$pkg
version			${VERSION//-/_}-${PKG_REVISION:-1}
architecture	$ARCH
summary			"$SUMMARY"
description		"$SUMMARY. Built by air/OS CI from $(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch))."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"$COPYRIGHT"
}
licenses {
	"$LICENSE"
}
provides {
	$pkg = ${VERSION//-/_}
$provides}
requires {
	haiku >= r1~beta6
$(for r in ${REQUIRES:-}; do printf '\tairos_%s\n' "$r"; done)
}
EOF
	file=$AIROS_PACKAGES/$ARCH/$pkg-${VERSION//-/_}-${PKG_REVISION:-1}-$ARCH.hpkg
	with_lock packages-$ARCH bash -c 'rm -f "$1"/"$2"-[0-9]*-"$3".hpkg' _ "$AIROS_PACKAGES/$ARCH" "$pkg" "$ARCH"
	"$TOOLS/package/package" create -q -C "$root" "$file"
	rm -f "$root/.PackageInfo"
	echo "package: $file"
}

build_recipe() {
	NAME=$1
	local recipe=$AIROS_CI/deps/recipes/$NAME.sh
	[[ -f $recipe ]] || die "no recipe $recipe"
	unset VERSION FORK SUMMARY COPYRIGHT LICENSE REQUIRES PKG_REVISION NO_PACKAGE STAMP_EXTRA
	FORK=$NAME
	. "$recipe"
	local dir=$WORKDIR/$NAME stamp
	stamp="$(fork_info "$FORK" commit 2>/dev/null || echo none) $(sha256sum "$recipe" | cut -c1-16) $(cat "$AIROS_SDK/$ARCH/revision") ${STAMP_EXTRA:-}"
	if [[ ${FORCE:-0} != 1 && -f $dir/stamp && $(cat "$dir/stamp") == "$stamp" ]]; then
		echo "== $NAME (up to date)"
		return
	fi
	note "$NAME $VERSION ($ARCH)"
	SRC=$dir/src STAGE=$dir/stage
	if declare -F fetch_source >/dev/null; then
		fetch_source
	else
		fork_checkout "$FORK" "$SRC"
	fi
	rm -rf "$STAGE"
	mkdir -p "$STAGE"
	( cd "$SRC" && build ) > "$dir/build.log" 2>&1 || { tail -40 "$dir/build.log"; die "$NAME failed (log: $dir/build.log)"; }
	normalize_stage
	cp -a "$STAGE$PREFIX/." "$DEPS/"
	[[ ${NO_PACKAGE:-0} == 1 ]] || make_package
	echo "$stamp" > "$dir/stamp"
	unset -f build fetch_source
}

for recipe in "${RECIPES[@]}"; do
	build_recipe "$recipe"
done
note "deps for $ARCH in $DEPS"
