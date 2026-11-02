#!/usr/bin/env bash
# Empaquette un .app tvOS en .ipa (structure Payload/<App>.app, zip).
#
# Usage : scripts/package-ipa.sh <chemin/Minuit.app> <sortie.ipa>
#
# L'IPA produite n'est pas signée : atvloadly (mode Apple ID) la signe avec
# votre compte au moment de l'installation. Pour une IPA signée par la CI,
# voir scripts/sign-ipa.sh.
set -euo pipefail

APP="${1:?chemin du .app requis}"
OUT="${2:?chemin de sortie requis}"

[[ -d "$APP" ]] || { echo "::error::$APP introuvable" >&2; exit 1; }
[[ -f "$APP/Info.plist" ]] || { echo "::error::$APP/Info.plist absent" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Payload"
# ditto préserve liens symboliques, attributs et structure des frameworks.
ditto "$APP" "$WORK/Payload/$(basename "$APP")"

# Fichiers parasites éventuels.
find "$WORK/Payload" -name ".DS_Store" -delete

mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$WORK" && zip -qry -X "$OUT_ABS" Payload)

echo "IPA : $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
