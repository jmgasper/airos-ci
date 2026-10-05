#!/usr/bin/env bash
# summit/build-deps.sh ARCH
#
# The third-party libraries of Summit's WebKit engine, cross-built from the
# jmgasper forks (forks/forks.lock.json) into a prefix of their own,
# $AIROS_ROOT/summit/ARCH/deps (include/, lib/, lib/pkgconfig/). The engine
# links them and the summit_webkit package carries them privately in
# /boot/system/lib/summit-webkit/lib, as Summit's own arm64 build does
# (summit: engine/arm64/build-deps.sh, tools/pi/build-gl-deps.sh and
# tools/pi/build-deps-gnu-hash.sh):
#
#   zlib (the SDK's), OpenSSL, nghttp2, libpsl, curl, SQLite, libxml2,
#   libxslt, libjpeg-turbo, libpng, libwebp, Little-CMS, Brotli, WOFF2,
#   libzip, ICU 78.3, and for GL compositing FreeType, Expat, Fontconfig,
#   HarfBuzz (with ICU) and libepoxy (EGL from the GL stack, deps/build-gl.sh).
#
# Every library gets a GNU hash table and binds its own functions at link time
# (Haiku's runtime_loader resolves every symbol at load; on the Pi the SysV
# hash chains cost seconds of start-up).
#
# A library is rebuilt when its fork commit or its recipe below changes, or
# when one built before it was rebuilt.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: build-deps.sh x86_64|arm64}
if [[ ${AIROS_SUMMIT_LOCKED:-} != summit-$ARCH ]]; then
	exec env AIROS_SUMMIT_LOCKED=summit-$ARCH flock "$AIROS_LOCKS/summit-$ARCH.lock" "$0" "$@"
fi
. "$AIROS_CI/summit/lib.sh"
. "$AIROS_CI/lib/fork.sh"
summit_sdk

P=$SUMMIT_ROOT/deps
W=$AIROS_WORK/summit-deps-$ARCH
mkdir -p "$P/lib/pkgconfig" "$P/include" "$W"
case $ARCH in arm64) PROCESSOR=aarch64 ;; x86_64) PROCESSOR=x86_64 ;; esac
LINK="-Wl,--hash-style=both -Wl,-Bsymbolic-functions"

export CC="${CROSS}gcc --sysroot=$SYSROOT -specs=$UNWIND_SPECS"
export CXX="${CROSS}g++ --sysroot=$SYSROOT -specs=$UNWIND_SPECS"
export AR=${CROSS}ar RANLIB=${CROSS}ranlib STRIP=${CROSS}strip NM=${CROSS}nm LD=${CROSS}ld
export CPPFLAGS="-I$P/include" CFLAGS="-O2 -fPIC -I$P/include" CXXFLAGS="-O2 -fPIC -I$P/include"
export LDFLAGS="-L$P/lib -Wl,-rpath-link,$P/lib -Wl,-rpath-link,$SYSROOT/boot/system/lib $LINK"
export PKG_CONFIG_LIBDIR=$P/lib/pkgconfig PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=
BUILD_TRIPLET=$(uname -m)-pc-linux-gnu

TC=$SUMMIT_ROOT/toolchain.cmake
cat > "$TC" <<EOF
# written by airos-ci summit/build-deps.sh
set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR $PROCESSOR)
set(CMAKE_SYSROOT $SYSROOT)
set(CMAKE_C_COMPILER ${CROSS}gcc)
set(CMAKE_CXX_COMPILER ${CROSS}g++)
set(CMAKE_AR ${CROSS}ar CACHE FILEPATH "")
set(CMAKE_RANLIB ${CROSS}ranlib CACHE FILEPATH "")
set(CMAKE_STRIP ${CROSS}strip CACHE FILEPATH "")
set(CMAKE_FIND_ROOT_PATH $P $DEPS/develop $DEPS $SYSROOT/boot/system/develop $SYSROOT/boot/system)
set(CMAKE_PREFIX_PATH $P)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_C_FLAGS_INIT "-I$P/include")
set(CMAKE_CXX_FLAGS_INIT "-I$P/include")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-specs=$UNWIND_SPECS -L$P/lib -Wl,-rpath-link,$P/lib -Wl,-rpath-link,$DEPS/lib -Wl,-rpath-link,$SYSROOT/boot/system/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-specs=$UNWIND_SPECS -L$P/lib -Wl,-rpath-link,$P/lib -Wl,-rpath-link,$DEPS/lib -Wl,-rpath-link,$SYSROOT/boot/system/lib $LINK")
set(ENV{PKG_CONFIG_LIBDIR} "$P/lib/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "")
EOF

# A git checkout gives the files one time in no particular order, and make
# would regenerate aclocal.m4, configure and Makefile.in with the host's
# autotools: make the generated files the newer ones.
autotools_times() {
	local now
	now=$(date +%s)
	find . -name aclocal.m4 -exec touch -d "@$now" {} +
	find . \( -name configure -o -name Makefile.in -o -name config.h.in \) -exec touch -d "@$((now + 1))" {} +
}
ac() { # ac [configure arguments]: autotools build in _b, installed into the prefix
	autotools_times
	rm -rf _b
	mkdir _b
	cd _b
	../configure --host="$TRIPLET" --build="$BUILD_TRIPLET" --prefix="$P" --libdir="$P/lib" \
		--enable-shared --disable-static "$@"
	make -j"$JOBS"
	make install
}
cm() { # cm [cmake arguments]; CMake 4 refuses projects that ask for < 3.5 (WOFF2)
	rm -rf _b
	cmake -S . -B _b -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TC" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON "$@"
	ninja -C _b -j"$JOBS"
	ninja -C _b install
}

# --- recipes: one function per library, run in the fork's checkout ---------

r_zlib() { # the SDK's zlib, visible in the prefix for every consumer
	cp -a "$SYSROOT"/boot/system/develop/lib/libz.so* "$P/lib/" 2>/dev/null \
		|| cp -a "$SYSROOT"/boot/system/lib/libz.so* "$P/lib/"
	cp "$SYSROOT"/boot/system/develop/headers/{zlib,zconf}.h "$P/include/"
	local version
	version=$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$P/include/zlib.h")
	printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\nName: zlib\nDescription: zlib\nVersion: %s\nLibs: -L${libdir} -lz\nCflags: -I${includedir}\n' \
		"$P" "$version" > "$P/lib/pkgconfig/zlib.pc"
}
r_openssl() {
	local target
	case $ARCH in arm64) target=haiku-aarch64 ;; x86_64) target=haiku-x86_64 ;; esac
	CC=${CROSS}gcc CFLAGS="--sysroot=$SYSROOT -O2 -fPIC" LDFLAGS="--sysroot=$SYSROOT $LINK" \
		./Configure "$target" shared no-tests no-docs --prefix="$P" --libdir=lib \
		--openssldir=/boot/system/data/ssl
	make -j"$JOBS"
	make install_sw
}
r_nghttp2() { cm -DENABLE_LIB_ONLY=ON -DBUILD_STATIC_LIBS=OFF -DENABLE_DOC=OFF; }
r_libpsl() {
	[[ -x configure ]] || autoreconf -fi
	ac --disable-runtime --disable-builtin --disable-man --disable-gtk-doc LIBS=-lnetwork
}
r_curl() {
	autoreconf -fi
	ac --with-openssl="$P" --with-nghttp2="$P" --with-zlib="$P" --without-libpsl \
		--without-brotli --without-zstd --without-libidn2 --disable-ldap --disable-manual \
		--disable-docs --with-ca-bundle=/boot/system/data/ssl/CARootCertificates.pem \
		--without-ca-path LIBS=-lnetwork
}
r_sqlite() {
	cd autoconf/sqlite-autoconf-3460100
	autoreconf -fi
	CFLAGS="$CFLAGS -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_FTS3=1 -DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 -DSQLITE_SECURE_DELETE=1" \
		ac --disable-readline --enable-threadsafe
}
r_libxml2() {
	cm -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF -DLIBXML2_WITH_MODULES=OFF \
		-DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ZLIB=ON \
		-DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_READLINE=OFF
}
r_libxslt() {
	cm -DLIBXSLT_WITH_PYTHON=OFF -DLIBXSLT_WITH_TESTS=OFF -DLIBXSLT_WITH_PROGRAMS=OFF \
		-DLIBXSLT_WITH_CRYPTO=OFF -DLIBXSLT_WITH_MODULES=OFF
}
r_libjpeg_turbo() { cm -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_JPEG8=OFF; }
r_libpng() {
	local neon=()
	[[ $ARCH != arm64 ]] || neon=(-DPNG_ARM_NEON=on)
	cm -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF "${neon[@]}"
}
r_libwebp() {
	cm -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
		-DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
		-DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
}
r_lcms2() {
	[[ -x configure ]] || autoreconf -fi
	ac --without-jpeg --without-tiff
}
r_brotli() { cm -DBROTLI_DISABLE_TESTS=ON; }
r_woff2() { cm -DCANONICAL_PREFIXES=ON -DNOISY_LOGGING=OFF; }
r_libzip() {
	cm -DENABLE_COMMONCRYPTO=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=OFF \
		-DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF -DBUILD_TOOLS=OFF \
		-DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF
}
r_icu() { # the native tools first (same ICU, kept per commit), then the cross build
	local host=$AIROS_ROOT/toolchain/icu-host-${FORK_COMMIT:0:12} source=$PWD/icu4c/source
	if [[ ! -f $host/config/icucross.mk ]]; then
		rm -rf "$host" && mkdir -p "$host"
		(cd "$host" && env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u LD -u CFLAGS \
			-u CXXFLAGS -u CPPFLAGS -u LDFLAGS "$source/runConfigureICU" Linux \
			--disable-tests --disable-samples && make -j"$JOBS")
	fi
	(cd icu4c/source && autotools_times)
	rm -rf _cross && mkdir _cross && cd _cross
	../icu4c/source/configure --host="$TRIPLET" --build="$BUILD_TRIPLET" --prefix="$P" \
		--with-cross-build="$host" --disable-tests --disable-samples --disable-extras \
		--disable-tools --enable-shared --disable-static --with-data-packaging=library
	make -j"$JOBS"
	make install
}
r_freetype() {
	cm -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
		-DFT_REQUIRE_PNG=ON -DFT_REQUIRE_ZLIB=ON
}
r_expat() {
	cd expat 2>/dev/null || true
	cm -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF
}
r_fontconfig() {
	# Fonts are where Haiku keeps them; the configuration is the package's
	# (lib/summit-webkit/etc/fonts), the cache the user's.
	autotools_times
	rm -rf _b && mkdir _b && cd _b
	../configure --host="$TRIPLET" --build="$BUILD_TRIPLET" --prefix="$P" --libdir="$P/lib" \
		--enable-shared --disable-static --disable-docs --disable-nls --disable-cache-build \
		--sysconfdir=/boot/system/lib/summit-webkit/etc --localstatedir=/boot/system/var \
		--with-default-fonts=/boot/system/data/fonts \
		--with-add-fonts=/boot/system/non-packaged/data/fonts,/boot/home/config/data/fonts,/boot/home/config/non-packaged/data/fonts \
		--with-cache-dir=/boot/home/config/cache/fontconfig
	make -j"$JOBS"
	make install sysconfdir="$P/etc" fc_cachedir="$PWD/unused-cache"
}
r_harfbuzz() {
	cm -DHB_HAVE_FREETYPE=ON -DHB_HAVE_ICU=ON -DHB_BUILD_UTILS=OFF -DHB_BUILD_SUBSET=OFF \
		-DHB_HAVE_GLIB=OFF
}
r_libepoxy() {
	# EGL and GLES come from the GL stack laid over the SDK snapshot
	# (deps/build-gl.sh, summit/lib.sh); pkg-config files for it, which the
	# engine's CMake reads too.
	local gl=$SYSROOT/boot/system/develop/headers/os/opengl lib=$SYSROOT/boot/system/develop/lib pc
	[[ -f $gl/EGL/egl.h ]] || die "no EGL headers in $gl: build the GL stack first (deps/build-gl.sh)"
	for pc in egl:EGL:1.5 glesv2:GLESv2:3.2; do
		IFS=: read -r name library version <<< "$pc"
		printf 'includedir=%s\nlibdir=%s\nName: %s\nDescription: %s (libglvnd)\nVersion: %s\nLibs: -L${libdir} -l%s\nCflags: -I${includedir}\n' \
			"$gl" "$lib" "$name" "$library" "$version" "$library" > "$P/lib/pkgconfig/$name.pc"
	done
	# No sys_root: meson would prefix it to the absolute paths of the prefix's
	# pkg-config files.
	cat > _cross.ini <<EOF
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'haiku'
cpu_family = '$PROCESSOR'
cpu = '$PROCESSOR'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$P/lib/pkgconfig']

[built-in options]
c_args = ['--sysroot=$SYSROOT', '-I$gl']
c_link_args = ['--sysroot=$SYSROOT', '-specs=$UNWIND_SPECS', '-L$lib', '-Wl,--hash-style=both', '-Wl,-Bsymbolic-functions']
EOF
	rm -rf _b
	env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
		meson setup _b . --cross-file=_cross.ini --prefix="$P" --libdir=lib --buildtype=release \
		-Degl=yes -Dglx=no -Dx11=false -Dtests=false -Ddocs=false
	ninja -C _b -j"$JOBS"
	ninja -C _b install
}

ORDER=(zlib openssl nghttp2 libpsl curl sqlite libxml2 libxslt libjpeg-turbo libpng libwebp
	lcms2 brotli woff2 libzip icu freetype expat fontconfig harfbuzz libepoxy)

chain=$(sha256sum "$UNWIND_SPECS" | cut -c1-16)
for name in "${ORDER[@]}"; do
	fn=r_${name//-/_}
	if [[ $name == zlib ]]; then
		FORK_COMMIT=sdk-$(sha256sum "$SYSROOT/boot/system/develop/headers/zlib.h" | cut -c1-16)
	else
		FORK_COMMIT=$(fork_info "$name" commit)
	fi
	chain=$(printf '%s %s %s %s' "$chain" "$FORK_COMMIT" "$(declare -f "$fn" | sha256sum)" "$LINK" \
		| sha256sum | cut -c1-16)
	if [[ ${FORCE:-0} != 1 && -f $W/$name.stamp && $(cat "$W/$name.stamp") == "$chain" ]]; then
		echo "== $name (up to date)"
		continue
	fi
	note "$name"
	src=$W/src/$name
	[[ $name == zlib ]] || fork_checkout "$name" "$src"
	mkdir -p "$src"
	# Not "( ... ) || die": bash ignores set -e inside a subshell that is
	# the left side of ||, and a failing step would go unnoticed.
	set +e
	( set -e; cd "$src"; "$fn" ) > "$W/$name.log" 2>&1
	status=$?
	set -e
	[[ $status == 0 ]] || { tail -40 "$W/$name.log"; die "$name failed (log: $W/$name.log)"; }
	echo "$chain" > "$W/$name.stamp"
done
# What went in, for the package's build record.
python3 - "$AIROS_CI/forks/forks.lock.json" "$P/forks.json" "${ORDER[@]}" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
json.dump({n: {k: lock[n][k] for k in ("url", "branch", "commit")} for n in sys.argv[3:] if n in lock},
          open(sys.argv[2], "w"), indent=1)
EOF
note "Summit's libraries for $ARCH in $P"
