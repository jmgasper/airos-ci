# Lexilla 5.4.6 (jmgasper/lexilla airos-5.4.6), built against the Scintilla
# headers as the HaikuPorts recipe does: Kiri's syntax highlighting.
VERSION=5.4.6
SUMMARY="Lexilla lexers for Scintilla"
COPYRIGHT="1998-2024 Neil Hodgson"
LICENSE="Scintilla"
build() {
	local scintilla=$WORKDIR/scintilla/src
	[[ -d $scintilla/include ]] || die "build the scintilla recipe first"
	mkdir -p ../scintilla
	rm -rf ../scintilla/include
	cp -R "$scintilla/include" ../scintilla/include
	make -C src -j"$JOBS" CXX="$CXX" AR="$AR"
	local inc=$STAGE$PREFIX/develop/headers/lexilla
	mkdir -p "$STAGE$PREFIX/lib" "$inc"
	cp -a bin/liblexilla.so "$STAGE$PREFIX/lib/"
	cp include/Lexilla.h include/SciLexer.h "$inc/"
	mkdir -p "$STAGE$PREFIX/data/licenses"
	cp License.txt "$STAGE$PREFIX/data/licenses/Scintilla"
}
