# x86_64: the HaikuPorts development packages in deps/haikuports-x86_64.txt
# (curl, SQLite, TagLib, PCRE2, Scintilla, Lexilla, OpenSSL 3, FFmpeg 6,
# LZO, LZ4) and what they need, from the HaikuPorts repository.
VERSION=current
FORK=haikuports
NO_PACKAGE=1
STAMP_EXTRA="list:$(sha256sum "$AIROS_CI/deps/haikuports-$ARCH.txt" | cut -c1-16)"
fetch_source() { mkdir -p "$SRC"; }
build() {
	AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" stage "$ARCH" \
		"$STAGE$PREFIX" $(grep -v '^#' "$AIROS_CI/deps/haikuports-$ARCH.txt")
	cp "$STAGE$PREFIX/.haikuports.json" "$WORKDIR/haikuports.json"
}
