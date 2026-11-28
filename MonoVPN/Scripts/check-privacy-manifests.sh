#!/usr/bin/env bash
#
# Ручная проверка Privacy Manifest перед загрузкой в App Store Connect (macOS, Xcode).
#
# 1. В каждом бандле архива (MonoVPN.app, PacketTunnel.appex, MonoVPNWidget.appex) в корне
#    лежит PrivacyInfo.xcprivacy.
# 2. Required Reason API, которые импортирует настоящий iOS-бинарник PacketTunnel (в нём
#    статически слинкован libXray), задекларированы в манифесте PacketTunnel, и наоборот.
#    Если передан LibXray.xcframework, то же проверяется для его среза ios-arm64.
#
# Использование:
#   MonoVPN/Scripts/check-privacy-manifests.sh <путь к .xcarchive или MonoVPN.app> [LibXray.xcframework]
#
# Ничего не собирает и не меняет. Код выхода 1 — найдено расхождение.
set -euo pipefail

NM="${NM:-nm}"
INPUT="${1:?usage: $0 <archive.xcarchive|MonoVPN.app> [LibXray.xcframework]}"
XCFRAMEWORK="${2:-}"

if [ -d "$INPUT/Products/Applications" ]; then
  APP="$(find "$INPUT/Products/Applications" -maxdepth 1 -name '*.app' | head -1)"
else
  APP="$INPUT"
fi
[ -d "$APP" ] || { echo "error: app bundle not found in $INPUT"; exit 1; }

status=0
TUNNEL="$APP/PlugIns/PacketTunnel.appex"
WIDGET="$APP/PlugIns/MonoVPNWidget.appex"

echo "==> Privacy manifests"
for bundle in "$APP" "$TUNNEL" "$WIDGET"; do
  manifest="$bundle/PrivacyInfo.xcprivacy"
  if [ -f "$manifest" ]; then
    categories="$( (grep -o 'NSPrivacyAccessedAPICategory[A-Za-z]*' "$manifest" || true) | sort -u | tr '\n' ' ')"
    reasons="$( (grep -o '[0-9A-F]\{4\}\.[0-9]' "$manifest" || true) | sort -u | tr '\n' ' ')"
    echo "ok      $(basename "$bundle"): ${categories:-no API categories} ${reasons:+(reasons: $reasons)}"
  else
    echo "MISSING $(basename "$bundle"): PrivacyInfo.xcprivacy"
    status=1
  fi
done

# Импортированные символы → категории Required Reason API (документация Apple,
# NSPrivacyAccessedAPIType). getattrlist* входят и в FileTimestamp, и в DiskSpace.
categories_of() {
  local symbols="$1" found=""
  grep -Eq '^_(stat|fstat|fstatat|lstat|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat)(\$.*)?$' <<<"$symbols" \
    && found="$found NSPrivacyAccessedAPICategoryFileTimestamp"
  grep -Eq '^_(mach_absolute_time)(\$.*)?$' <<<"$symbols" \
    && found="$found NSPrivacyAccessedAPICategorySystemBootTime"
  grep -Eq '^_(statfs|statvfs|fstatfs|fstatvfs|getattrlist|fgetattrlist|getattrlistat)(\$.*)?$' <<<"$symbols" \
    && found="$found NSPrivacyAccessedAPICategoryDiskSpace"
  echo "$found"
}

check_binary() {
  local label="$1" binary="$2" symbols found declared
  symbols="$("$NM" -u "$binary" 2>/dev/null | awk '{print $NF}' | sort -u)"
  echo "    Required Reason symbols in $label:"
  grep -E '^_(stat|fstat|fstatat|lstat|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat|statfs|statvfs|fstatfs|fstatvfs|mach_absolute_time)(\$.*)?$' <<<"$symbols" \
    | sed 's/^/      /' || echo "      (none)"
  found="$(categories_of "$symbols")"
  declared="$(grep -o 'NSPrivacyAccessedAPICategory[A-Za-z]*' "$TUNNEL/PrivacyInfo.xcprivacy" 2>/dev/null | sort -u || true)"
  for category in $found; do
    if ! grep -qx "$category" <<<"$declared"; then
      echo "MISSING $category is used by $label but not declared in PacketTunnel manifest"
      status=1
    fi
  done
  for category in $declared; do
    if ! grep -qw "$category" <<<"$found"; then
      echo "UNUSED  $category is declared in PacketTunnel manifest but not imported by $label (check Swift code before removing)"
    fi
  done
}

echo "==> PacketTunnel binary (iOS, from the archive)"
if [ -f "$TUNNEL/PacketTunnel" ]; then
  check_binary "PacketTunnel.appex/PacketTunnel" "$TUNNEL/PacketTunnel"
else
  echo "MISSING $TUNNEL/PacketTunnel"
  status=1
fi

if [ -n "$XCFRAMEWORK" ]; then
  echo "==> LibXray.xcframework (ios-arm64)"
  LIB="$(find "$XCFRAMEWORK" -path '*ios-arm64/*' -not -path '*simulator*' -name 'libXray.a' | head -1)"
  if [ -n "$LIB" ]; then
    check_binary "libXray.a (ios-arm64)" "$LIB"
  else
    echo "MISSING ios-arm64 libXray.a in $XCFRAMEWORK"
    status=1
  fi
fi

exit "$status"
