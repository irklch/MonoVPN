#!/usr/bin/env bash
#
# Собирает LibXray.xcframework (VPN-ядро Xray-core через libXray) для Mono VPN.
#
# Воспроизводимо: версии libXray, Xray-core и Go закреплены ниже и проверяются.
# Зависимости берутся строго из go.mod/go.sum тега libXray (-mod=readonly, go mod verify).
# Встроенный build/main.py libXray не используется: он удаляет go.mod/go.sum и заново
# разрешает зависимости, из-за чего сборка не воспроизводится. Флаги cgo повторяют
# build/app/apple_go.py этого тега.
#
# Результат: <repo>/Frameworks/LibXray.xcframework (статическая библиотека libXray.a,
# заголовок libXray.h и module.modulemap → `import LibXray`) и Frameworks/LIBXRAY_VERSION.
# Оба игнорируются git.
#
# Требования:
#   - macOS с Xcode (iOS SDK) и command line tools
#   - Go >= 1.21 в PATH (`brew install go`); точный тулчейн ниже Go скачает сам через GOTOOLCHAIN
#   - git
#
# Использование:
#   MonoVPN/Scripts/build-libxray.sh                  # устройство (arm64) + симулятор (arm64, x86_64)
#   PLATFORMS=ios MonoVPN/Scripts/build-libxray.sh    # только устройство, быстрее
#
set -euo pipefail

# ---- Закреплённые версии ---------------------------------------------------
# Репозиторий libXray (обёртка XTLS над Xray-core с C API CGoInvoke/CGoFree).
LIBXRAY_REPO="https://github.com/XTLS/libXray.git"
# Тег libXray.
LIBXRAY_VERSION="v26.11.9"
# Коммит тега v26.11.9; проверяется после клонирования, чтобы заметить перемещённый тег.
LIBXRAY_COMMIT="5a0f7d8d1c28b34afb5727b04b26a10f6dbac7e3"
# Xray-core, на который указывает go.mod этого тега libXray: псевдоверсия коммита
# 676eaf66f8f05d4d558ee7a74b4736623d3feeb9 = тег Xray-core v26.11.9.
XRAY_CORE_MODULE="github.com/xtls/xray-core"
XRAY_CORE_VERSION="v1.260327.1-0.20261109052709-676eaf66f8f0"
XRAY_CORE_TAG="v26.11.9"
# Тулчейн Go из go.mod libXray (`go 1.27.3`).
GO_TOOLCHAIN="go1.27.3"
# Минимальная версия iOS = минимальная версия приложения.
IOS_MIN_VERSION="17.0"

# Целевые платформы: ios (устройство) и/или iossimulator.
PLATFORMS="${PLATFORMS:-ios,iossimulator}"

# ---- Пути ------------------------------------------------------------------
# Каталог этого скрипта.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Корень репозитория (на два уровня выше скрипта).
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Куда кладётся готовый фреймворк.
OUTPUT_DIR="$REPO_ROOT/Frameworks"
# Рабочий каталог для исходников и промежуточных файлов.
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.build/libxray}"
# Клон libXray нужной версии.
SRC_DIR="$WORK_DIR/libXray-$LIBXRAY_VERSION"
# Промежуточные библиотеки.
STAGE_DIR="$WORK_DIR/stage"

export GOTOOLCHAIN="$GO_TOOLCHAIN"
export GOFLAGS="-mod=readonly"
export GOWORK=off

command -v go >/dev/null || { echo "error: Go is not installed (brew install go)"; exit 1; }
command -v xcrun >/dev/null || { echo "error: Xcode command line tools are missing"; exit 1; }

echo "==> Go toolchain: $(go version)"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

# ---- Исходники -------------------------------------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
  echo "==> Cloning libXray $LIBXRAY_VERSION"
  git clone --depth 1 --branch "$LIBXRAY_VERSION" "$LIBXRAY_REPO" "$SRC_DIR"
fi
ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$LIBXRAY_COMMIT" ]; then
  echo "error: libXray $LIBXRAY_VERSION resolved to $ACTUAL_COMMIT, expected $LIBXRAY_COMMIT"
  exit 1
fi
if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
  echo "error: $SRC_DIR has local changes; delete it and run again"
  exit 1
fi

cd "$SRC_DIR"
# go.mod тега должен указывать ровно на Xray-core v26.11.9.
ACTUAL_XRAY="$(go list -m -f '{{.Version}}' "$XRAY_CORE_MODULE")"
if [ "$ACTUAL_XRAY" != "$XRAY_CORE_VERSION" ]; then
  echo "error: libXray pins $XRAY_CORE_MODULE $ACTUAL_XRAY, expected $XRAY_CORE_VERSION"
  exit 1
fi
echo "==> Downloading and verifying Go modules (go.sum)"
go mod download
go mod verify

# ---- Сборка c-archive ------------------------------------------------------
# build_archive <goarch> <apple-arch> <sdk> <min-version-flag> <out-dir>
build_archive() {
  local goarch="$1" arch="$2" sdk="$3" minflag="$4" out="$5"
  local sdk_path flags
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  flags="-isysroot $sdk_path $minflag -arch $arch"
  mkdir -p "$out"
  echo "==> Building libXray.a for $sdk/$arch"
  env \
    GOOS=ios GOARCH="$goarch" CGO_ENABLED=1 \
    CC="xcrun --sdk $sdk --toolchain $sdk clang" \
    CXX="xcrun --sdk $sdk --toolchain $sdk clang++" \
    CGO_CFLAGS="$flags" CGO_CXXFLAGS="$flags" \
    CGO_LDFLAGS="$flags -Wl,-Bsymbolic-functions" \
    go build -trimpath -buildvcs=false -ldflags "-s -w -buildid=" \
      -buildmode=c-archive -o "$out/libXray.a" ./cgo_bridge
}

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/include"
XCFRAMEWORK_ARGS=()

if [[ ",$PLATFORMS," == *",ios,"* ]]; then
  build_archive arm64 arm64 iphoneos "-miphoneos-version-min=$IOS_MIN_VERSION" "$STAGE_DIR/iphoneos-arm64"
  XCFRAMEWORK_ARGS+=(-library "$STAGE_DIR/iphoneos-arm64/libXray.a" -headers "$STAGE_DIR/include")
  HEADER_SOURCE="$STAGE_DIR/iphoneos-arm64/libXray.h"
fi
if [[ ",$PLATFORMS," == *",iossimulator,"* ]]; then
  build_archive arm64 arm64 iphonesimulator "-mios-simulator-version-min=$IOS_MIN_VERSION" "$STAGE_DIR/iphonesimulator-arm64"
  build_archive amd64 x86_64 iphonesimulator "-mios-simulator-version-min=$IOS_MIN_VERSION" "$STAGE_DIR/iphonesimulator-x86_64"
  mkdir -p "$STAGE_DIR/iphonesimulator"
  lipo -create \
    -arch arm64 "$STAGE_DIR/iphonesimulator-arm64/libXray.a" \
    -arch x86_64 "$STAGE_DIR/iphonesimulator-x86_64/libXray.a" \
    -output "$STAGE_DIR/iphonesimulator/libXray.a"
  XCFRAMEWORK_ARGS+=(-library "$STAGE_DIR/iphonesimulator/libXray.a" -headers "$STAGE_DIR/include")
  HEADER_SOURCE="${HEADER_SOURCE:-$STAGE_DIR/iphonesimulator-arm64/libXray.h}"
fi
if [ ${#XCFRAMEWORK_ARGS[@]} -eq 0 ]; then
  echo "error: PLATFORMS must contain ios and/or iossimulator"
  exit 1
fi

# Заголовок cgo и module.modulemap из шаблона libXray (module LibXray).
cp "$HEADER_SOURCE" "$STAGE_DIR/include/libXray.h"
cp "$SRC_DIR/build/template/module.modulemap" "$STAGE_DIR/include/module.modulemap"

echo "==> Creating LibXray.xcframework"
rm -rf "$OUTPUT_DIR/LibXray.xcframework"
xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "$OUTPUT_DIR/LibXray.xcframework"

# Записываем, из чего собран фреймворк.
cat > "$OUTPUT_DIR/LIBXRAY_VERSION" <<EOF
libXray: $LIBXRAY_VERSION ($LIBXRAY_COMMIT)
xray-core: $XRAY_CORE_TAG ($XRAY_CORE_VERSION)
go: $GO_TOOLCHAIN
ios-min: $IOS_MIN_VERSION
platforms: $PLATFORMS
EOF

echo "==> Done: $OUTPUT_DIR/LibXray.xcframework"
cat "$OUTPUT_DIR/LIBXRAY_VERSION"
