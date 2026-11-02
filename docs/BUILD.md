# Compilation, coûts et installation

## Ce qui est possible (et ce qui ne l'est pas)

- **Compiler une application tvOS exige Xcode, donc macOS.** C'est impossible sous
  Windows et sur le NAS, y compris en Docker (le SDK tvOS n'existe pas pour Linux).
- **Le cœur métier (`MinuitCore`) compile et se teste sous Linux** : Docker sur le
  NAS DS224+ (x86_64) ou Docker Desktop sur Windows. Gratuit et illimité.
- La compilation tvOS se fait donc sur un **runner macOS GitHub Actions**, uniquement
  à la demande.

## Coûts vérifiés (documentation GitHub, novembre 2026)

| Élément | Valeur |
|---|---|
| Runners standard (y compris macOS) en **dépôt public** | **Gratuits** |
| Offre gratuite, dépôt privé : usage inclus | **12 $ / mois** |
| Runner Linux 2 cœurs | 0,006 $/min |
| Runner macOS (M1, 3 cœurs) | **0,062 $/min** → ≈ 190 min macOS incluses/mois |
| Sans moyen de paiement enregistré | usage **bloqué** une fois le quota atteint (aucune facture possible) |
| Stockage d'artefacts inclus (offre gratuite) | 500 Mo |

Estimation : un build tvOS ≈ 8 à 15 min (le premier plus long : téléchargement de
FFmpeg), soit ≈ 0,50 à 0,95 $ en dépôt privé : **12 à 20 builds/mois dans le quota
gratuit**, 0 $ en dépôt public.

## Stratégie retenue

| Étape | Où | Coût | Déclenchement |
|---|---|---|---|
| Tests du cœur + vérifications statiques | NAS / PC (Docker) | 0 | à volonté |
| Idem en CI | runner Linux | ≈ 0,01 $ (0 en public) | automatique si `Sources/`, `Tests/` changent |
| **Compilation tvOS + IPA** | runner macOS | ≈ 0,5–1 $ (0 en public) | **manuel uniquement**, après votre accord |

Économies intégrées au workflow `build-tvos.yml` : déclenchement manuel, annulation
du build précédent, cache des paquets Swift, délai maximal de 35 min, artefacts
conservés 14 jours, journal joint seulement en cas d'échec.

## Lancer les tests localement

NAS (SSH) ou Linux :

```bash
sh scripts/test-core.sh
```

Windows (PowerShell, Docker Desktop), depuis le dossier du dépôt :

```bash
powershell -ExecutionPolicy Bypass -File scripts/test-core.ps1
```

## Produire l'IPA

GitHub → onglet **Actions** → **Build tvOS (IPA non signée)** → **Run workflow**.
L'artefact `Minuit-<n>-unsigned-ipa` contient `Minuit-<n>-unsigned.ipa`.

## Installer avec atvloadly

1. Télécharger l'artefact (zip) depuis la page du build et en extraire l'`.ipa`.
2. Dans l'interface web d'atvloadly (sur le NAS), choisir l'Apple TV appairée,
   importer l'IPA, se connecter avec l'identifiant Apple.
3. atvloadly re-signe l'application (et peut modifier l'identifiant de bundle :
   l'application n'en dépend pas — pas de groupe Keychain, pas d'App Group).
4. Compte Apple gratuit : renouvellement tous les 7 jours (automatisé par atvloadly).

Points d'attention :

- L'IPA embarque les frameworks dynamiques d'AetherEngine/FFmpeg ; atvloadly doit
  les re-signer (comportement standard de Sideloader). À confirmer au premier essai.
- Aucune capacité nécessitant un compte payant n'est utilisée (pas d'iCloud, pas de
  notifications).
