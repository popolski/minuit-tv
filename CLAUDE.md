# Consignes du projet Minuit

## Builds et CI (autorisation permanente du propriétaire)

- Le dépôt est **public** : les runners GitHub (Linux et macOS `xcode-27`) sont gratuits.
- **Lancer des builds sans demander confirmation**, comme pour Lanterne : tout push sur
  `main` déclenche `.github/workflows/build.yml` (tests Linux, IPA tvOS vérifiée, Release
  `build-N`). Un `workflow_dispatch` peut aussi être lancé sans demander.
- Après un push, suivre le build et corriger les erreurs de compilation jusqu'au vert.
- Si le dépôt devenait privé, redemander l'accord avant tout build macOS (facturable).

## Méthode

- Langue : français (code commenté, messages, documentation).
- Le cœur `MinuitCore` doit rester compilable et testable sous Linux (`sh scripts/test-core.sh`).
- Distinguer toujours : implémenté / compilé / test automatisé / vérifié sur Apple TV
  (`docs/STATUS.md`). Ne jamais prétendre un test sur Apple TV non réalisé.
- ATS : `NSAllowsArbitraryLoads` seul dans `App/project.yml` (toute autre clé ATS le neutralise).
- Ne jamais journaliser d'URL ou d'identifiant hors `DiagnosticsLog` (masquage automatique).
