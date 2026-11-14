# Consignes du projet Minuit

## Builds et CI (autorisation permanente du propriétaire)

- Le dépôt est **public**. Depuis le 14 novembre 2026, le compte GitHub est bloqué pour
  facturation : les builds passent par **Codemagic** (`codemagic.yaml`, 500 min macOS/mois),
  comme pour Aurora ; `.github/workflows/build.yml` n'est plus lancé qu'à la main.
- **Lancer des builds sans demander confirmation**, comme pour Lanterne : tout push sur
  `main` déclenche Codemagic (tests du cœur, IPA tvOS vérifiée, Release `build-N`,
  numéro Codemagic + 100). Éviter les pushes inutiles (minutes comptées) : `[skip ci]`
  pour la documentation seule.
- Après un push, suivre le build et corriger les erreurs de compilation jusqu'au vert.
- Si le dépôt devenait privé, redemander l'accord avant tout build macOS (facturable).

## Méthode

- Langue : français (code commenté, messages, documentation).
- Le cœur `MinuitCore` doit rester compilable et testable sous Linux (`sh scripts/test-core.sh`).
- Distinguer toujours : implémenté / compilé / test automatisé / vérifié sur Apple TV
  (`docs/STATUS.md`). Ne jamais prétendre un test sur Apple TV non réalisé.
- ATS : `NSAllowsArbitraryLoads` seul dans `App/project.yml` (toute autre clé ATS le neutralise).
- Ne jamais journaliser d'URL ou d'identifiant hors `DiagnosticsLog` (masquage automatique).
