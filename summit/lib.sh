# Source from the summit/ scripts after lib/env.sh, with ARCH set and the
# summit-ARCH lock held.
#
# summit_sdk: a snapshot of the ARCH SDK (sysroot with the GL stack laid
# over it, cross compiler, unwinder specs) in $SUMMIT_ROOT, so the engine
# build, which takes hours, does not hold the SDK's lock that image builds
# take to update it. Files are copied by content (rsync -c, no times): a new
# Haiku revision rewrites only the headers that changed, and the engine's
# ninja rebuilds only what includes them.
# Sets ARCH, TRIPLET, CROSS, SYSROOT, UNWIND_SPECS, HAIKU_REVISION, HAIKU_SHA
# and DEPS (the GL stack and app libraries of deps/build-deps.sh), and puts
# the host rc and xres on PATH.

SUMMIT_ROOT=$AIROS_ROOT/summit/$ARCH

summit_sdk() {
	mkdir -p "$SUMMIT_ROOT"
	(
		flock -s 9
		[[ -f $AIROS_SDK/$ARCH/env.sh ]] || die "no $ARCH SDK; run sdk/build-sdk.sh $ARCH"
		. "$AIROS_SDK/$ARCH/env.sh"
		# with the GL stack (deps/build-gl.sh) laid over it
		local gl=()
		[[ ! -d $AIROS_ROOT/gl/$ARCH/boot ]] || gl=("$AIROS_ROOT/gl/$ARCH/")
		rsync -rlc --delete "$SYSROOT/" "${gl[@]}" "$SUMMIT_ROOT/sysroot/"
		rsync -rlc --delete "${CROSS%/bin/*}/" "$SUMMIT_ROOT/cross-tools/"
		cp "$UNWIND_SPECS" "$SUMMIT_ROOT/shared-unwinder.specs"
		# The host rc and xres (WebKit's Haiku resources) with their libraries.
		local tools=$SUMMIT_ROOT/host-tools.new tool lib
		rm -rf "$tools"
		mkdir -p "$tools/bin" "$tools/lib"
		cp -L "$TOOLS/rc/rc" "$TOOLS/xres" "$tools/bin/"
		for lib in $(ldd "$TOOLS/rc/rc" "$TOOLS/xres" | awk '$3 ~ /objects\/linux\/lib/ {print $3}' | sort -u); do
			cp -L "$lib" "$tools/lib/"
		done
		for tool in "$tools"/bin/*; do
			patchelf --set-rpath '$ORIGIN/../lib' "$tool"
		done
		rsync -rlc --delete "$tools/" "$SUMMIT_ROOT/host-tools/"
		rm -rf "$tools"
		cat > "$SUMMIT_ROOT/sdk-env.sh" <<EOF
# snapshot of $AIROS_SDK/$ARCH, made by summit/lib.sh
HAIKU_REVISION=$HAIKU_REVISION
HAIKU_SHA=$HAIKU_SHA
TRIPLET=$TRIPLET
CROSS=$SUMMIT_ROOT/cross-tools/bin/$TRIPLET-
SYSROOT=$SUMMIT_ROOT/sysroot
UNWIND_SPECS=$SUMMIT_ROOT/shared-unwinder.specs
EOF
	) 9>"$AIROS_LOCKS/haiku-$ARCH.lock"
	. "$SUMMIT_ROOT/sdk-env.sh"
	DEPS=${DEPS:-$AIROS_ROOT/deps/$ARCH/boot/system}
	export PATH="$SUMMIT_ROOT/host-tools/bin:$PATH"
	mkdir -p "$AIROS_WORK"
	echo "SDK $HAIKU_REVISION ($ARCH), snapshot in $SUMMIT_ROOT"
}
