#!/usr/bin/env bash
# Vérifie le contenu d'une IPA tvOS avant distribution.
#
# Contrôles :
#  - structure Payload/*.app, Info.plist lisible ;
#  - identifiant de bundle, versions, plateforme (AppleTVOS), MinimumOSVersion ;
#  - binaire principal et chaque framework embarqué : architecture arm64 seule,
#    plateforme Mach-O tvOS (LC_BUILD_VERSION platform 3), pas de tranche simulateur ;
#  - présence du catalogue d'icônes et des frameworks d'AetherEngine (FFmpeg).
#
# Usage : scripts/verify-ipa.sh <fichier.ipa> [identifiant-de-bundle-attendu]
# Écrit un rapport Markdown sur la sortie standard (et dans $GITHUB_STEP_SUMMARY si défini).
set -euo pipefail

IPA="${1:?IPA requise}"
EXPECTED_ID="${2:-app.minuit.tv}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
REPORT="$WORK/report.md"

say() { echo "$*" | tee -a "$REPORT"; }
fail() { say "- ❌ $*"; FAIL=1; }
ok() { say "- ✅ $*"; }

unzip -q "$IPA" -d "$WORK/x"
APP="$(find "$WORK/x/Payload" -maxdepth 1 -name "*.app" -type d | head -n 1)"
say "## Vérification de l'IPA $(basename "$IPA")"
say ""
[[ -n "$APP" ]] || { fail "aucun .app dans Payload/"; cat "$REPORT"; exit 1; }
ok "bundle : Payload/$(basename "$APP") ($(du -sh "$APP" | cut -f1))"

PLIST="$APP/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
BUNDLE_ID="$(read_key CFBundleIdentifier)"
EXEC="$(read_key CFBundleExecutable)"
VERSION="$(read_key CFBundleShortVersionString)"
BUILD="$(read_key CFBundleVersion)"
MINOS="$(read_key MinimumOSVersion)"
PLATFORMS="$(read_key CFBundleSupportedPlatforms:0)"

[[ "$BUNDLE_ID" == "$EXPECTED_ID" ]] && ok "identifiant : $BUNDLE_ID" || fail "identifiant $BUNDLE_ID ≠ $EXPECTED_ID"
[[ -n "$VERSION" && -n "$BUILD" ]] && ok "version : $VERSION ($BUILD)" || fail "version absente"
[[ "$PLATFORMS" == "AppleTVOS" ]] && ok "plateforme : $PLATFORMS" || fail "plateforme inattendue : '$PLATFORMS' (simulateur ?)"
[[ -n "$MINOS" ]] && ok "tvOS minimum : $MINOS" || fail "MinimumOSVersion absent"

check_macho() {
  local bin="$1" label="$2"
  [[ -f "$bin" ]] || { fail "$label : binaire absent"; return; }
  local archs
  archs="$(lipo -archs "$bin" 2>/dev/null || echo "?")"
  if [[ "$archs" != "arm64" && "$archs" != "arm64e arm64" && "$archs" != "arm64 arm64e" ]]; then
    fail "$label : architectures « $archs » (arm64 attendu)"
    return
  fi
  # platform 3 = TVOS, 8 = TVOSSIMULATOR
  local platform
  platform="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')"
  if [[ "$platform" == "3" || "$platform" == "TVOS" ]]; then
    ok "$label : $archs, tvOS"
  else
    fail "$label : plateforme Mach-O « $platform » (3/TVOS attendu)"
  fi
}

check_macho "$APP/$EXEC" "exécutable $EXEC"

say ""
say "### Frameworks embarqués"
if [[ -d "$APP/Frameworks" ]]; then
  while IFS= read -r fw; do
    name="$(basename "$fw" .framework)"
    fexec="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$fw/Info.plist" 2>/dev/null || echo "$name")"
    check_macho "$fw/$fexec" "$name.framework"
  done < <(find "$APP/Frameworks" -maxdepth 1 -name "*.framework" -type d | sort)
  while IFS= read -r dylib; do
    check_macho "$dylib" "$(basename "$dylib")"
  done < <(find "$APP/Frameworks" -maxdepth 1 -name "*.dylib" | sort)
else
  say "- (aucun)"
fi

say ""
say "### Extensions"
if [[ -d "$APP/PlugIns" ]]; then
  while IFS= read -r ext; do
    name="$(basename "$ext" .appex)"
    eplist="$ext/Info.plist"
    eexec="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$eplist" 2>/dev/null || echo "$name")"
    eid="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$eplist" 2>/dev/null || echo "?")"
    epoint="$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$eplist" 2>/dev/null || echo "?")"
    ever="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$eplist" 2>/dev/null || echo "?")"
    [[ "$eid" == "$BUNDLE_ID".* ]] && ok "$name : identifiant $eid" || fail "$name : identifiant $eid hors de $BUNDLE_ID"
    [[ "$ever" == "$BUILD" ]] && ok "$name : version $ever (identique à l'app)" || fail "$name : version $ever ≠ $BUILD"
    ok "$name : point d'extension $epoint"
    check_macho "$ext/$eexec" "$name.appex"
  done < <(find "$APP/PlugIns" -maxdepth 1 -name "*.appex" -type d | sort)
else
  say "- (aucune)"
fi

say ""
say "### Ressources"
for f in Assets.car Frameworks/AetherLibavformat.framework Frameworks/AetherLibavcodec.framework; do
  [[ -e "$APP/$f" ]] && ok "$f" || fail "$f manquant"
done
if find "$APP" -name "*.bundle" -maxdepth 1 | grep -q .; then
  ok "bundles de ressources SwiftPM : $(find "$APP" -name "*.bundle" -maxdepth 1 -exec basename {} \; | tr '\n' ' ')"
fi

say ""
if [[ -d "$APP/_CodeSignature" ]]; then
  say "Signature : présente ($(codesign -dv "$APP" 2>&1 | grep -E '^Authority|^TeamIdentifier' | head -n 2 | tr '\n' ' '))"
else
  say "Signature : aucune (IPA à signer par atvloadly)"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"; fi
if [[ "$FAIL" != "0" ]]; then
  echo "::error::Vérification de l'IPA en échec"
  exit 1
fi
