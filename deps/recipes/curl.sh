# curl 8.10.1 with the Haiku SOCK_NONBLOCK fix (jmgasper/curl airos-8.10.1),
# with OpenSSL, nghttp2 and zlib, and the CA bundle of HaikuPorts'
# ca_root_certificates package.
VERSION=8.10.1
SUMMARY="libcurl URL transfer library"
COPYRIGHT="1996-2024 Daniel Stenberg and curl contributors"
LICENSE="MIT"
REQUIRES="openssl nghttp2"
build() {
	autoreconf -fi
	configure_ac --enable-shared --disable-static --with-openssl --with-nghttp2 --with-zlib \
		--without-libpsl --without-brotli --without-zstd --without-libidn2 --disable-ldap \
		--disable-manual --disable-docs \
		--with-ca-bundle=/boot/system/data/ssl/CARootCertificates.pem --without-ca-path \
		LIBS=-lnetwork
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
}
