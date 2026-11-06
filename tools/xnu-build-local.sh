#!/bin/bash
# Build the Khaje (or plain SWEET) kernel on your own Mac, instead of GitHub Actions
# (macos-14 runners were retired on 2026-11-02 and macos-15 only has Xcode 16+).
#
# Needs: macOS 13.5+ (Intel or Apple silicon), Xcode 15.x (NOT 16: its iig emits
# IORPC.kernelContent that xnu-8796 lacks), Homebrew, ~30 GB free, internet.
#
# Usage:  tools/xnu-build-local.sh [OUTDIR]       (default xnu/out; log in OUTDIR/build.log)
# Env:    VARIANT=KHAJE|SWEET   (default KHAJE)
#         XCODE=/Applications/Xcode_15.4.app     (default: first Xcode 15.x under /Applications)
#         KERNEL_CONFIG=DEVELOPMENT|RELEASE      (default DEVELOPMENT)
# The KDK 13.5 is downloaded and installed by blacktop's build.sh if missing (asks for sudo).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:-$REPO/xnu/out}" && cd "${1:-$REPO/xnu/out}" && pwd)
VARIANT=${VARIANT:-KHAJE}
KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT}
WORK=$REPO/research/xnu-build
DXB_REPO=https://github.com/blacktop/darwin-xnu-build
DXB_SHA=663906528d1cd5ea8fde7de6f16de73db9511549

[ "$(uname)" = Darwin ] || { echo "this must run on macOS" >&2; exit 1; }

# --- Xcode 15 ---------------------------------------------------------------
if [ -z "${XCODE:-}" ]; then
	for x in /Applications/Xcode*.app; do
		v=$(DEVELOPER_DIR="$x/Contents/Developer" xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')
		case "$v" in 15.*) XCODE=$x; break ;; esac
	done
fi
[ -n "${XCODE:-}" ] && [ -d "$XCODE" ] || { echo "no Xcode 15.x found under /Applications (set XCODE=...)" >&2; exit 1; }
export DEVELOPER_DIR="$XCODE/Contents/Developer"
echo "Xcode: $(xcodebuild -version | tr '\n' ' ')  ($XCODE)"
xcrun --find iig >/dev/null || { echo "iig not found in $XCODE" >&2; exit 1; }

# --- Homebrew tools -----------------------------------------------------------
BREW=$(command -v brew || true)
[ -n "$BREW" ] || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
for t in jq gum bash cmake ninja; do "$BREW" list "$t" >/dev/null 2>&1 || "$BREW" install "$t"; done
BASH5=$("$BREW" --prefix)/bin/bash
# build.sh only checks that an 'xcodes' command exists (Xcode is already installed)
mkdir -p "$REPO/research/bin"
printf '#!/bin/sh\nexit 0\n' > "$REPO/research/bin/xcodes"; chmod +x "$REPO/research/bin/xcodes"

# --- blacktop/darwin-xnu-build at the pinned commit ----------------------------
if [ ! -d "$WORK/.git" ]; then
	git init -q "$WORK"
	git -C "$WORK" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
	git -C "$WORK" checkout -q FETCH_HEAD
fi
git -C "$WORK" checkout -q -- build.sh
# libfirehose_kernel: plain arm64 for a Cortex-A53 class CPU (no LSE/LDAPR from Xcode's default CPU).
sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="arm64" VALID_ARCHS="arm64" OTHER_CFLAGS='"'"'$(inherited) -mcpu=cortex-a53'"'"'/' "$WORK/build.sh"
grep -q "mcpu=cortex-a53" "$WORK/build.sh" || { echo "build.sh edit failed (upstream changed?)" >&2; exit 1; }

# our patches next to blacktop's
rm -f "$WORK"/patches/0[0-9][0-9][0-9]-* "$WORK"/patches/*.sh.ours
cp "$REPO"/xnu/patches/*.patch "$REPO"/xnu/patches/*.sh "$WORK/patches/"
if [ "$VARIANT" = KHAJE ]; then
	cp "$REPO"/xnu/patches-khaje/*.patch "$WORK/patches/"
fi

# pristine xnu source every run (dependency clones, fakeroot and objects stay: incremental)
if [ -d "$WORK/xnu/.git" ]; then
	git -C "$WORK/xnu" reset -q --hard
	git -C "$WORK/xnu" clean -qfdx
fi

cd "$WORK"
rm -rf "$OUT"/kernel.* "$OUT/SHA256SUMS"
# build.sh skips the kernel if this exists; make still rebuilds only what changed
rm -rf build/xnu.obj/kernel.*.sweet* fakeroot/System/Library/Kernels/kernel.*.sweet*
env PATH="$REPO/research/bin:$PATH" SWEET_VARIANT="$VARIANT" \
	MACOS_VERSION=13.5 KERNEL_CONFIG="$KERNEL_CONFIG" MACHINE_CONFIG=SWEET MAKEFLAGS=-k \
	"$BASH5" build.sh 2>&1 | tee "$OUT/build.log"

# build.sh only warns when a patch does not apply: refuse a stale/incomplete kernel
if grep -E 'Skipping patch .*/(0[0-9]{3})-' "$OUT/build.log"; then
	echo "error: some of our patches were not applied" >&2; exit 1
fi
cp -R fakeroot/System/Library/Kernels/. "$OUT/"
(cd "$OUT" && for f in kernel.*; do [ -f "$f" ] && shasum -a 256 "$f"; done | tee SHA256SUMS)
echo "kernel(s) in $OUT; error summary: grep -n 'error:' $OUT/build.log"
