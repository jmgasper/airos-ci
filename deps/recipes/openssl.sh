# OpenSSL 3.3.2 with the Haiku arm64 fixes (jmgasper/openssl airos-3.3.2).
# Shared and static: Burrow links libssl.a/libcrypto.a statically on arm64.
VERSION=3.3.2
SUMMARY="OpenSSL TLS and cryptography libraries"
COPYRIGHT="1998-2024 The OpenSSL Project Authors"
LICENSE="Apache v2"
build() {
	local target
	case $ARCH in arm64) target=haiku-aarch64 ;; x86_64) target=haiku-x86_64 ;; esac
	CC=${CROSS}gcc CFLAGS="--sysroot=$SYSROOT -O2 -fPIC" LDFLAGS="--sysroot=$SYSROOT" \
		./Configure "$target" shared no-tests no-docs --prefix=$PREFIX --libdir=lib \
		--openssldir=$PREFIX/data/ssl
	make -j"$JOBS"
	make install_sw DESTDIR="$STAGE"
}
