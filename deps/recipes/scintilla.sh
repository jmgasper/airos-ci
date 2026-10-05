# Scintilla 5.3.4 with the Haiku backend (jmgasper/scintilla airos-5.3.4, made
# from the release tarballs and the HaikuPorts patch set), built and laid out as
# the HaikuPorts recipe does: Kiri's editor component.
VERSION=5.3.4
SUMMARY="Scintilla source code editing component"
COPYRIGHT="1998-2023 Neil Hodgson"
LICENSE="Scintilla"
build() {
	make -C haiku -j"$JOBS" CXX="$CXX" AR="$AR"
	local inc=$STAGE$PREFIX/develop/headers/scintilla
	mkdir -p "$STAGE$PREFIX/lib" "$inc" "$STAGE$PREFIX/data/licenses"
	cp -a bin/libscintilla.so "$STAGE$PREFIX/lib/"
	cp include/ILoader.h include/ILexer.h include/Sci_Position.h include/Scintilla.h \
		include/ScintillaCall.h include/ScintillaMessages.h include/ScintillaStructures.h \
		include/ScintillaTypes.h haiku/ScintillaView.h "$inc/"
	cp License.txt "$STAGE$PREFIX/data/licenses/Scintilla"
}
