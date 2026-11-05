#!/bin/bash
# Replay darwin-xnu-build's patch step on Linux: does the ios-sweet series (and the Khaje
# 4K patch) still apply to Apple's xnu-8796.141.3? This is NOT a compile: the kernel itself
# can only be built on macOS (CI: .github/workflows/xnu.yml).
#
# Usage: tools/apply-check.sh WORKDIR        (empty or new directory; needs git, python3, network)
# Env:   SKIP_KHAJE=1   leave out xnu/patches-khaje/*.patch (checks plain sweet)
#
# Mirrors dxb/build.sh patches(): GNU sed versions of its inline edits, then patches/*.sh,
# then every *.patch in sorted order with "git apply --check" first; failures are reported
# and skipped exactly like dxb does ("Skipping patch ...").
set -uo pipefail
export LC_ALL=C

WORK=${1:?usage: apply-check.sh WORKDIR}
HERE=$(cd "$(dirname "$0")/.." && pwd)
DXB_SHA=663906528d1cd5ea8fde7de6f16de73db9511549
XNU_TAG=xnu-8796.141.3
mkdir -p "$WORK"

if [ ! -d "$WORK/xnu/.git" ]; then
	git clone -q --depth 1 --branch "$XNU_TAG" https://github.com/apple-oss-distributions/xnu.git "$WORK/xnu" || exit 2
fi
if [ ! -d "$WORK/dxb/.git" ]; then
	git init -q "$WORK/dxb"
	git -C "$WORK/dxb" fetch -q --depth 1 https://github.com/blacktop/darwin-xnu-build "$DXB_SHA" || exit 2
	git -C "$WORK/dxb" checkout -q FETCH_HEAD
fi

cd "$WORK/xnu" || exit 2
git checkout -q -- . && git clean -fdq

# dxb's inline sed edits (GNU sed: no '' after -i)
sed -i 's|^AVAILABILITY_PL="${SDKROOT}/${DRIVERKITROOT}|AVAILABILITY_PL="${FAKEROOT_DIR}|g' bsd/sys/make_symbol_aliasing.sh
sed -i 's|^#include.*BSD.xcconfig.*||g' libsyscall/Libsyscall.xcconfig
sed -i 's|^LDFLAGS_KERNEL_SDK	= -L$(SDKROOT).*|LDFLAGS_KERNEL_SDK	= -L$(FAKEROOT_DIR)/usr/local/lib/kernel -lfirehose_kernel|g' makedefs/MakeInc.def
sed -i 's|^\(INCFLAGS_SDK[[:space:]]*=\) -I$(SDKROOT)/usr/local/include/\(kernel\)\{0,1\}|\1 -I$(FAKEROOT_DIR)/usr/local/include/kernel|' makedefs/MakeInc.def

# Same layout as the workflow's "Fetch build script" step
PDIR=$(mktemp -d)
cp "$WORK"/dxb/patches/*.patch "$PDIR"/
cp "$HERE"/xnu/patches/*.patch "$HERE"/xnu/patches/*.sh "$PDIR"/
if [ "${SKIP_KHAJE:-0}" != 1 ] && compgen -G "$HERE/xnu/patches-khaje/*.patch" >/dev/null; then
	cp "$HERE"/xnu/patches-khaje/*.patch "$PDIR"/
	[ -f "$HERE/xnu/patches-khaje/khaje.env" ] && . "$HERE/xnu/patches-khaje/khaje.env"
fi

export MACHINE_CONFIG=${MACHINE_CONFIG:-SWEET} MACOS_VERSION=13.5
fail_sh=0
for s in "$PDIR"/*.sh; do
	if ! bash "$s" >"$PDIR/$(basename "$s").log" 2>&1; then
		echo "STAGE FAILED: $(basename "$s")  (see $PDIR/$(basename "$s").log)"; tail -3 "$PDIR/$(basename "$s").log" | sed 's/^/    /'
		fail_sh=1
	fi
done

ok=0 skipped=0
for p in "$PDIR"/*.patch; do
	if out=$(git apply --check "$p" 2>&1); then
		git apply "$p"; ok=$((ok + 1))
	else
		skipped=$((skipped + 1))
		echo "SKIPPED $(basename "$p"): $(echo "$out" | head -2 | tr '\n' ' ')"
	fi
done
echo "applied=$ok skipped=$skipped stage_failures=$fail_sh  tree=$WORK/xnu"
