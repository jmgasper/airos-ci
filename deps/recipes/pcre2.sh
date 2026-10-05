# PCRE2 10.45 with its JIT (jmgasper/pcre2 airos-10.45, sljit from jmgasper/sljit):
# Kiri's search.
VERSION=10.45
SUMMARY="PCRE2 Perl-compatible regular expression library"
COPYRIGHT="1997-2024 University of Cambridge"
LICENSE="BSD (3-clause)"
build() {
	cmake_build -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DPCRE2_BUILD_TESTS=OFF \
		-DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_SUPPORT_JIT=ON
}
