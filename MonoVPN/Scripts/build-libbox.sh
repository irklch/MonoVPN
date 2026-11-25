#!/usr/bin/env bash
#
# Builds Libbox.xcframework (the sing-box VPN core) for Mono VPN.
#
# Reproducible: every dependency version is pinned below.
# Output: <repo>/Frameworks/Libbox.xcframework (ignored by git).
#
# Requirements:
#   - macOS with Xcode (iOS SDK) and command line tools
#   - Go >= 1.25 on PATH (the exact toolchain below is fetched by `go` itself
#     through GOTOOLCHAIN, so `brew install go` is enough)
#   - git
#
# Usage:
#   MonoVPN/Scripts/build-libbox.sh            # device (arm64) + simulator
#   PLATFORMS=ios MonoVPN/Scripts/build-libbox.sh   # device only, faster
#
set -euo pipefail

# ---- Pinned versions ------------------------------------------------------
SING_BOX_REPO="https://github.com/SagerNet/sing-box.git"
SING_BOX_VERSION="v1.14.4"
# Commit of tag v1.14.4, checked after clone so a moved tag is detected.
SING_BOX_COMMIT="c005f35300ce76427dc285481ec5695f5b179cd2"
GOMOBILE_VERSION="v0.1.13"          # github.com/sagernet/gomobile (fork required by sing-box)
GO_TOOLCHAIN="go1.26.10"            # same toolchain as the upstream release CI
IOS_MIN_VERSION="15.0"              # libbox minimum; the app itself targets iOS 17

# Only what Mono VPN needs. Keeps the Network Extension well under the
# iOS memory limit and avoids the naive (cronet) / tailscale toolchains.
#   with_gvisor      - userspace TCP/IP stack for the TUN inbound
#   with_utls        - uTLS fingerprints, required for VLESS REALITY
#   with_low_memory  - memory-constrained mode used by upstream for iOS
#   badlinkname, tfogo_checklinkname0 - required by upstream build
BUILD_TAGS="with_gvisor,with_utls,with_low_memory,badlinkname,tfogo_checklinkname0"

PLATFORMS="${PLATFORMS:-ios,iossimulator}"

# ---- Paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/Frameworks"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.build/libbox}"
SRC_DIR="$WORK_DIR/sing-box-$SING_BOX_VERSION"

export GOTOOLCHAIN="$GO_TOOLCHAIN"
export GOPATH="${GOPATH:-$(go env GOPATH)}"
export PATH="$GOPATH/bin:$PATH"
export GOFLAGS="-mod=mod"

command -v go >/dev/null || { echo "error: Go is not installed (brew install go)"; exit 1; }
command -v xcrun >/dev/null || { echo "error: Xcode command line tools are missing"; exit 1; }

echo "==> Go toolchain: $(go version)"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

if [ ! -d "$SRC_DIR/.git" ]; then
  echo "==> Cloning sing-box $SING_BOX_VERSION"
  git clone --depth 1 --branch "$SING_BOX_VERSION" "$SING_BOX_REPO" "$SRC_DIR"
fi

ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$SING_BOX_COMMIT" ]; then
  echo "error: sing-box $SING_BOX_VERSION resolved to $ACTUAL_COMMIT, expected $SING_BOX_COMMIT"
  exit 1
fi

echo "==> Installing gomobile $GOMOBILE_VERSION"
go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"

LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=${SING_BOX_VERSION#v} -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid="

echo "==> Building Libbox.xcframework for: $PLATFORMS"
cd "$SRC_DIR"
rm -rf Libbox.xcframework
gomobile bind -v \
  -target "$PLATFORMS" \
  -libname=box \
  -iosversion="$IOS_MIN_VERSION" \
  -trimpath -buildvcs=false \
  -ldflags "$LDFLAGS" \
  -tags "$BUILD_TAGS" \
  ./experimental/libbox

rm -rf "$OUTPUT_DIR/Libbox.xcframework"
mv Libbox.xcframework "$OUTPUT_DIR/Libbox.xcframework"

cat > "$OUTPUT_DIR/LIBBOX_VERSION" <<EOF
sing-box: $SING_BOX_VERSION ($SING_BOX_COMMIT)
gomobile: $GOMOBILE_VERSION
go: $GO_TOOLCHAIN
tags: $BUILD_TAGS
platforms: $PLATFORMS
EOF

echo "==> Done: $OUTPUT_DIR/Libbox.xcframework"
