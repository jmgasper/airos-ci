# Source after lib/env.sh in scripts that build against an air/OS cross SDK.
#
#   AIROS_ARCH=x86_64|arm64 (required)
#
# Sets ARCH, CROSS, TRIPLET, SYSROOT, TOOLS, ATTRS, MIMEDB, UNWIND_SPECS,
# HAIKU_REVISION (from $AIROS_SDK/ARCH/env.sh) and DEPS, the staged
# third-party prefix (deps/stage-deps.sh). Holds the haiku-ARCH lock shared
# for the life of the calling script, so build-sdk.sh cannot replace the SDK
# or rebuild its host tools under it.

ARCH=${AIROS_ARCH:?set AIROS_ARCH to x86_64 or arm64}
[[ -f $AIROS_SDK/$ARCH/env.sh ]] || die "no $ARCH SDK; run sdk/build-sdk.sh $ARCH"
if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	exec {AIROS_SDK_LOCK_FD}>"$AIROS_LOCKS/haiku-$ARCH.lock"
	flock -s "$AIROS_SDK_LOCK_FD"
fi
. "$AIROS_SDK/$ARCH/env.sh"
DEPS=${DEPS:-$AIROS_SDK/$ARCH/deps/boot/system}
mkdir -p "$DEPS" "$AIROS_WORK"
