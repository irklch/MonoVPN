#!/usr/bin/env bash
#
# Сохраняет в репозитории Mono VPN (third_party/sources/) точные исходники компонентов,
# для которых лицензия требует доступности исходного кода, и libXray, из которого собирается ядро:
#
#   - Xray-core, XTLS/REALITY, layeh.com/gopher-luar — MPL-2.0 (§3.2: исходный код
#     распространяемых файлов должен быть доступен получателям приложения);
#   - libXray — MIT; источник для воспроизводимой сборки LibXray.xcframework.
#
# Архивы модулей Go — это ровно те zip-файлы, что использует сборка: `go mod download`
# проверяет их по go.sum libXray (хеш h1). libXray — архив тега из git. Для всех файлов
# записываются SHA-256 (third_party/sources/SHA256SUMS).
#
# Запускать после каждого обновления libXray / Xray-core (затем generate-third-party-notices.sh):
#   MonoVPN/Scripts/mirror-third-party-sources.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/third_party/sources"

pinned() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$SCRIPT_DIR/build-libxray.sh"; }
LIBXRAY_REPO="$(pinned LIBXRAY_REPO)"
LIBXRAY_VERSION="$(pinned LIBXRAY_VERSION)"
LIBXRAY_COMMIT="$(pinned LIBXRAY_COMMIT)"
GO_TOOLCHAIN="$(pinned GO_TOOLCHAIN)"

# Модули под MPL-2.0 в сборке (см. THIRD_PARTY_NOTICES.md).
MPL_MODULES=(github.com/xtls/xray-core github.com/xtls/reality layeh.com/gopher-luar)

WORK_DIR="${WORK_DIR:-$REPO_ROOT/.build/libxray}"
SRC_DIR="$WORK_DIR/libXray-$LIBXRAY_VERSION"
export GOTOOLCHAIN="$GO_TOOLCHAIN" GOFLAGS="-mod=readonly" GOWORK=off

if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --depth 1 --branch "$LIBXRAY_VERSION" "$LIBXRAY_REPO" "$SRC_DIR"
fi
[ "$(git -C "$SRC_DIR" rev-parse HEAD)" = "$LIBXRAY_COMMIT" ] || { echo "error: unexpected libXray commit"; exit 1; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

for module in "${MPL_MODULES[@]}"; do
  version="$(cd "$SRC_DIR" && go list -m -f '{{.Version}}' "$module")"
  # Скачивание проверяет архив по go.sum; путь и хеш берутся из ответа go.
  info="$(cd "$SRC_DIR" && go mod download -json "$module@$version")"
  zip="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Zip"])' <<<"$info")"
  sum="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Sum"])' <<<"$info")"
  expected="$(grep -F "$module $version h1:" "$SRC_DIR/go.sum" | awk '{print $3}')"
  [ "$sum" = "$expected" ] || { echo "error: $module $version: $sum != go.sum $expected"; exit 1; }
  name="$(echo "$module" | tr '/' '_')@$version.zip"
  cp "$zip" "$OUT_DIR/$name"
  echo "$name $module $version $sum" >> "$OUT_DIR/.modules"
done

git -C "$SRC_DIR" archive --format=tar --prefix="libXray-$LIBXRAY_VERSION/" "$LIBXRAY_COMMIT" \
  | gzip -n -9 > "$OUT_DIR/libXray-$LIBXRAY_VERSION.tar.gz"

(cd "$OUT_DIR" && sha256sum ./*.zip ./*.tar.gz | sed 's| \./| |' > SHA256SUMS)

{
  echo "# Исходный код сторонних компонентов Mono VPN"
  echo
  echo "Точные исходники компонентов, которые входят в расширение PacketTunnel Mono VPN 1.0.0."
  echo "Хранятся здесь, чтобы исходный код оставался доступным, пока распространяется приложение"
  echo "(MPL-2.0 §3.2), независимо от внешних хостингов. Компоненты не изменены."
  echo "Файлы создаёт \`MonoVPN/Scripts/mirror-third-party-sources.sh\`."
  echo
  echo "| Файл | Компонент | Версия | Лицензия | Хеш go.sum (h1) |"
  echo "|---|---|---|---|---|"
  while read -r name module version sum; do
    echo "| \`$name\` | $module | $version | MPL-2.0 | \`$sum\` |"
  done < "$OUT_DIR/.modules"
  echo "| \`libXray-$LIBXRAY_VERSION.tar.gz\` | github.com/XTLS/libXray | $LIBXRAY_VERSION (commit \`$LIBXRAY_COMMIT\`) | MIT | — |"
  echo
  echo "Xray-core v26.11.9 в Go называется псевдоверсией модуля, которую указывает go.mod libXray;"
  echo "она соответствует тегу v26.11.9 (commit \`676eaf66f8f05d4d558ee7a74b4736623d3feeb9\`)."
  echo
  echo "## Проверка"
  echo
  echo "SHA-256 всех файлов — в \`SHA256SUMS\`:"
  echo
  echo '```bash'
  echo "cd third_party/sources && shasum -a 256 -c SHA256SUMS"
  echo '```'
  echo
  echo "Архивы модулей совпадают с теми, что выдаёт Go module proxy (\`https://proxy.golang.org/<модуль>/@v/<версия>.zip\`),"
  echo "и проверяются хешем h1 из \`go.sum\` libXray $LIBXRAY_VERSION."
  echo
  echo "Остальные компоненты (MIT, BSD, Apache-2.0, LGPL-3.0 со static linking exception)"
  echo "не требуют предоставления исходного кода; ссылки на их исходники — в"
  echo "[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)."
} > "$OUT_DIR/README.md"
rm -f "$OUT_DIR/.modules"

ls -la "$OUT_DIR"
