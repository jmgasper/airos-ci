# nghttp2 1.64.0 (jmgasper/nghttp2 airos-1.64.0): curl's HTTP/2.
VERSION=1.64.0
SUMMARY="HTTP/2 C library"
COPYRIGHT="2012-2024 Tatsuhiro Tsujikawa, nghttp2 contributors"
LICENSE="MIT"
build() {
	cmake_build -DENABLE_LIB_ONLY=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_SHARED_LIBS=ON -DENABLE_DOC=OFF
}
