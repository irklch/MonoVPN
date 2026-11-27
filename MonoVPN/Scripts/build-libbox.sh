#!/usr/bin/env bash
#
# Собирает Libbox.xcframework (VPN-ядро sing-box) для Mono VPN.
#
# Воспроизводимо: версии всех зависимостей закреплены ниже.
# Результат: <repo>/Frameworks/Libbox.xcframework (игнорируется git).
#
# Требования:
#   - macOS с Xcode (iOS SDK) и command line tools
#   - Go >= 1.25 в PATH (точный тулчейн ниже `go` скачает сам
#     через GOTOOLCHAIN, так что достаточно `brew install go`)
#   - git
#
# Использование:
#   MonoVPN/Scripts/build-libbox.sh            # устройство (arm64) + симулятор
#   PLATFORMS=ios MonoVPN/Scripts/build-libbox.sh   # только устройство, быстрее
#
set -euo pipefail

# ---- Закреплённые версии ---------------------------------------------------
# Репозиторий sing-box, из которого собирается ядро.
SING_BOX_REPO="https://github.com/SagerNet/sing-box.git"
# Тег версии sing-box.
SING_BOX_VERSION="v1.14.4"
# Коммит тега v1.14.4; проверяется после клонирования, чтобы заметить перемещённый тег.
SING_BOX_COMMIT="c005f35300ce76427dc285481ec5695f5b179cd2"
# github.com/sagernet/gomobile (форк, которого требует sing-box).
GOMOBILE_VERSION="v0.1.13"
# Тот же тулчейн, что в CI апстрим-релиза.
GO_TOOLCHAIN="go1.26.10"
# Минимум для libbox; само приложение нацелено на iOS 17.
IOS_MIN_VERSION="15.0"

# Только то, что нужно Mono VPN. Так Network Extension остаётся заметно ниже
# лимита памяти iOS, и не нужны тулчейны naive (cronet) / tailscale.
#   with_gvisor      - TCP/IP-стек в пользовательском пространстве для входа TUN
#   with_utls        - отпечатки uTLS, обязательны для VLESS REALITY
#   with_low_memory  - режим экономии памяти, который апстрим использует для iOS
#   badlinkname, tfogo_checklinkname0 - нужны для апстрим-сборки
BUILD_TAGS="with_gvisor,with_utls,with_low_memory,badlinkname,tfogo_checklinkname0"

# Целевые платформы gomobile; по умолчанию устройство и симулятор.
PLATFORMS="${PLATFORMS:-ios,iossimulator}"

# ---- Пути ------------------------------------------------------------------
# Каталог этого скрипта.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Корень репозитория (на два уровня выше скрипта).
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Куда кладётся готовый фреймворк.
OUTPUT_DIR="$REPO_ROOT/Frameworks"
# Рабочий каталог для исходников и промежуточных файлов.
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.build/libbox}"
# Каталог с клоном sing-box нужной версии.
SRC_DIR="$WORK_DIR/sing-box-$SING_BOX_VERSION"

# Go сам скачает и использует закреплённый тулчейн.
export GOTOOLCHAIN="$GO_TOOLCHAIN"
export GOPATH="${GOPATH:-$(go env GOPATH)}"
# Чтобы установленные gomobile/gobind находились в PATH.
export PATH="$GOPATH/bin:$PATH"
export GOFLAGS="-mod=mod"

# Проверка обязательных инструментов.
command -v go >/dev/null || { echo "error: Go is not installed (brew install go)"; exit 1; }
command -v xcrun >/dev/null || { echo "error: Xcode command line tools are missing"; exit 1; }

echo "==> Go toolchain: $(go version)"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

# Клонируем исходники, только если их ещё нет.
if [ ! -d "$SRC_DIR/.git" ]; then
  echo "==> Cloning sing-box $SING_BOX_VERSION"
  git clone --depth 1 --branch "$SING_BOX_VERSION" "$SING_BOX_REPO" "$SRC_DIR"
fi

# Проверяем, что тег указывает на ожидаемый коммит.
ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$SING_BOX_COMMIT" ]; then
  echo "error: sing-box $SING_BOX_VERSION resolved to $ACTUAL_COMMIT, expected $SING_BOX_COMMIT"
  exit 1
fi

echo "==> Installing gomobile $GOMOBILE_VERSION"
go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"

# Флаги линковщика: версия sing-box, настройки GODEBUG, удаление отладочной информации.
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

# Заменяем старый фреймворк новым.
rm -rf "$OUTPUT_DIR/Libbox.xcframework"
mv Libbox.xcframework "$OUTPUT_DIR/Libbox.xcframework"

# Записываем, из чего собран фреймворк.
cat > "$OUTPUT_DIR/LIBBOX_VERSION" <<EOF
sing-box: $SING_BOX_VERSION ($SING_BOX_COMMIT)
gomobile: $GOMOBILE_VERSION
go: $GO_TOOLCHAIN
tags: $BUILD_TAGS
platforms: $PLATFORMS
EOF

echo "==> Done: $OUTPUT_DIR/Libbox.xcframework"
