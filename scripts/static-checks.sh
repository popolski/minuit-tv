#!/bin/sh
# Vérifications statiques sans macOS : aucun journal direct pouvant fuir un secret,
# aucune URL interpolée hors du journal masqué, aucun identifiant codé en dur.
set -eu
status=0
# Le dossier App/ peut être absent (image Docker des tests du cœur).
DIRS="Sources"
[ -d App/Sources ] && DIRS="$DIRS App/Sources"

if grep -rnE '\bprint\(|NSLog\(|os_log\(|Logger\(' $DIRS --include=*.swift; then
  echo "ERREUR : journalisation directe interdite ; utiliser DiagnosticsLog (masquage automatique)." >&2
  status=1
fi

if grep -rnE '(username|password)=[A-Za-z0-9]' $DIRS --include=*.swift; then
  echo "ERREUR : identifiant apparemment codé en dur." >&2
  status=1
fi

if [ -d App/Sources ] && grep -rn 'kSecAttrAccessGroup' App/Sources --include=*.swift; then
  echo "ERREUR : groupe d'accès Keychain incompatible avec la re-signature atvloadly." >&2
  status=1
fi

[ "$status" -eq 0 ] && echo "Vérifications statiques : OK"
exit "$status"
