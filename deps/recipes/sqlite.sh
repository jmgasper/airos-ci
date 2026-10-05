# SQLite 3.46.1, the autoconf amalgamation committed to jmgasper/sqlite
# (airos-3.46.1, autoconf/sqlite-autoconf-3460100), with the options Summit's
# arm64 build used.
VERSION=3.46.1
SUMMARY="SQLite embedded SQL database library"
COPYRIGHT="SQLite authors (public domain)"
LICENSE="Public Domain"
build() {
	cd autoconf/sqlite-autoconf-3460100
	# git checkouts have no meaningful timestamps; regenerate with the host autotools
	autoreconf -fi
	CFLAGS="$CFLAGS -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_FTS3=1 -DSQLITE_ENABLE_FTS5=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 -DSQLITE_SECURE_DELETE=1" \
		configure_ac --enable-shared --disable-static --disable-readline
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
}
