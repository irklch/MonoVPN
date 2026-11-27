#!/usr/bin/env bash
#
# Обновляет уведомления о сторонних компонентах Mono VPN:
#   MonoVPN/Resources/ThirdPartyNotices.json (экран «Лицензии» в приложении) и THIRD_PARTY_NOTICES.md.
#
# Берёт те же закреплённые версии, что и build-libxray.sh (libXray, Xray-core, Go), и список
# пакетов, которые реально компилируются в libXray.a для iOS (`go list -deps`, GOOS=ios).
# libXray не собирается. Нужны Go и git; архивов модулей хватает из кэша Go или с proxy.golang.org.
#
# Запускать после каждого обновления libXray / Xray-core:
#   MonoVPN/Scripts/generate-third-party-notices.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Версии читаются из build-libxray.sh, чтобы не расходиться с фактической сборкой.
pinned() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$SCRIPT_DIR/build-libxray.sh"; }
LIBXRAY_REPO="$(pinned LIBXRAY_REPO)"
LIBXRAY_VERSION="$(pinned LIBXRAY_VERSION)"
LIBXRAY_COMMIT="$(pinned LIBXRAY_COMMIT)"
GO_TOOLCHAIN="$(pinned GO_TOOLCHAIN)"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/.build/libxray}"
SRC_DIR="$WORK_DIR/libXray-$LIBXRAY_VERSION"

export GOTOOLCHAIN="$GO_TOOLCHAIN" GOFLAGS="-mod=readonly" GOWORK=off

if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --depth 1 --branch "$LIBXRAY_VERSION" "$LIBXRAY_REPO" "$SRC_DIR"
fi
[ "$(git -C "$SRC_DIR" rev-parse HEAD)" = "$LIBXRAY_COMMIT" ] || { echo "error: unexpected libXray commit"; exit 1; }

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
(cd "$SRC_DIR" && GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go list -deps -json ./cgo_bridge > "$LIST")
GOROOT_DIR="$(cd "$SRC_DIR" && go env GOROOT)"

python3 -I "$SCRIPT_DIR/third_party_notices.py" "$LIST" "$GOROOT_DIR" "$LIBXRAY_VERSION" "$GO_TOOLCHAIN" "$REPO_ROOT"
