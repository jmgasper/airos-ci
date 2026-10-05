#!/usr/bin/env bash
# sdk/build-rust.sh [ARCH]
#
# A Rust toolchain that can build for Haiku (default x86_64), for Mesa's NAK
# (NVK's shader compiler, deps/build-nvk.sh). x86_64-unknown-haiku is a tier 3
# Rust target with no prebuilt standard library, so:
#
#   1. rustup installs a pinned nightly with rust-src into
#      $AIROS_TOOLCHAIN/rust (RUSTUP_HOME, CARGO_HOME);
#   2. cargo -Zbuild-std builds std and panic_abort for the target, linking
#      with the air/OS SDK's cross GCC;
#   3. the rlibs are laid out as a rustc sysroot,
#      $AIROS_TOOLCHAIN/rust/sysroot-ARCH, which rustc takes with --sysroot.
#
# Also installs bindgen-cli (NAK's C bindings) and cbindgen (nil's C header)
# into CARGO_HOME.
# Writes $AIROS_TOOLCHAIN/rust/env-ARCH.sh (PATH, RUSTUP_HOME, CARGO_HOME,
# RUST_TARGET, RUST_SYSROOT). Done again only when the toolchain or the SDK's
# compiler changes.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:-x86_64}
TOOLCHAIN=${RUST_TOOLCHAIN:-nightly-2026-09-15}
case $ARCH in
	x86_64) TARGET=x86_64-unknown-haiku ;;
	*) die "no Rust target for $ARCH" ;;
esac
R=$AIROS_TOOLCHAIN/rust
export RUSTUP_HOME=$R/rustup CARGO_HOME=$R/cargo
export PATH="$CARGO_HOME/bin:$PATH"
mkdir -p "$R"

exec 9>"$AIROS_LOCKS/rust.lock"
flock 9

if [[ ! -x $CARGO_HOME/bin/rustup ]]; then
	curl -sSf https://sh.rustup.rs -o "$R/rustup-init.sh"
	sh "$R/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain "$TOOLCHAIN" \
		-c rust-src > "$R/rustup-init.log" 2>&1
fi
rustup toolchain list | grep -q "^$TOOLCHAIN" \
	|| rustup toolchain install -q --profile minimal -c rust-src "$TOOLCHAIN"
rustc=$(rustup which --toolchain "$TOOLCHAIN" rustc)
# bindgen for NAK's C bindings (Mesa needs 0.71.1 or newer; it uses the host's
# libclang)
# and cbindgen for NVK's nil (the C header of its Rust image layout code)
for tool in bindgen-cli:bindgen:0.72.1 cbindgen:cbindgen:0.29.0; do
	IFS=: read -r crate binary version <<< "$tool"
	if [[ $("$CARGO_HOME/bin/$binary" --version 2>/dev/null) != "$binary $version" ]]; then
		cargo "+$TOOLCHAIN" install -q --locked "$crate" --version "$version" \
			> "$R/$crate-install.log" 2>&1 || { tail -20 "$R/$crate-install.log"; die "$crate failed"; }
	fi
done

# The SDK's cross compiler links; keep a copy of its env (lock held briefly,
# unless the caller holds it already: deps/build-nvk.sh).
(
	[[ ${AIROS_LOCKED:-} == haiku-$ARCH ]] || flock -s 8
	. "$AIROS_SDK/$ARCH/env.sh"
	printf 'CROSS=%s\nSYSROOT=%s\nUNWIND_SPECS=%s\n' "$CROSS" "$SYSROOT" "$UNWIND_SPECS" > "$R/sdk-$ARCH.env"
) 8>"$AIROS_LOCKS/haiku-$ARCH.lock"
. "$R/sdk-$ARCH.env"

SYSROOT_OUT=$R/sysroot-$ARCH
key=$({ "$rustc" -vV; "${CROSS}gcc" --version | head -n 1; echo rmeta unwind; } | sha256sum | cut -c1-16)
if [[ $(cat "$SYSROOT_OUT/.key" 2>/dev/null) != "$key" ]]; then
	note "std for $TARGET ($("$rustc" --version))"
	W=$AIROS_WORK/rust-std-$ARCH
	rm -rf "$W"
	mkdir -p "$W/src" "$W/.cargo"
	cat > "$W/Cargo.toml" <<EOF
[package]
name = "stdprobe"
version = "0.1.0"
edition = "2021"

[lib]
path = "src/lib.rs"
EOF
	echo 'pub fn now() -> String { format!("{:?}", std::time::Instant::now()) }' > "$W/src/lib.rs"
	cat > "$W/cc.sh" <<EOF
#!/bin/sh
exec ${CROSS}gcc --sysroot=$SYSROOT -specs=$UNWIND_SPECS "\$@"
EOF
	chmod +x "$W/cc.sh"
	cat > "$W/.cargo/config.toml" <<EOF
[target.$TARGET]
linker = "$W/cc.sh"

[env]
CC_${TARGET//-/_} = "$W/cc.sh"
AR_${TARGET//-/_} = "${CROSS}ar"
EOF
	# Unwinding std (Mesa's crates use the default panic strategy), with
	# panic_abort for crates that ask for it.
	(cd "$W" && cargo "+$TOOLCHAIN" build -Zbuild-std=std,panic_unwind,panic_abort --target "$TARGET" --release) \
		> "$W/build.log" 2>&1 || { tail -30 "$W/build.log"; die "std for $TARGET failed (log: $W/build.log)"; }
	rm -rf "$SYSROOT_OUT"
	mkdir -p "$SYSROOT_OUT/lib/rustlib/$TARGET/lib"
	# (newer cargo leaves them in build/<crate>/<hash>/out, older in deps; a
	# recent rustc keeps the full metadata in .rmeta files beside the rlibs)
	find "$W/target/$TARGET/release" \( -name '*.rlib' -o -name '*.rmeta' \) ! -name 'libstdprobe*' \
		-exec cp {} "$SYSROOT_OUT/lib/rustlib/$TARGET/lib/" \;
	ls "$SYSROOT_OUT/lib/rustlib/$TARGET/lib/"libstd-*.rlib >/dev/null || die "no libstd in the std build"
	echo "$key" > "$SYSROOT_OUT/.key"
fi
cat > "$R/env-$ARCH.sh" <<EOF
# written by airos-ci sdk/build-rust.sh
export RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME RUSTUP_TOOLCHAIN=$TOOLCHAIN
export PATH="$CARGO_HOME/bin:\$PATH"
RUST_TARGET=$TARGET
RUST_SYSROOT=$SYSROOT_OUT
EOF
echo "Rust $("$rustc" --version) for $TARGET: sysroot $SYSROOT_OUT ($(ls "$SYSROOT_OUT/lib/rustlib/$TARGET/lib" | wc -l) rlibs)"
