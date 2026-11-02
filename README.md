# Minuit

Application native **Apple TV 4K** de télévision en direct pour comptes **Xtream Codes** :
direct, zapping, guide des programmes, favoris, replay et « Reprendre au début ».

- [Architecture et moteur vidéo](docs/ARCHITECTURE.md)
- [Direction artistique](docs/DESIGN.md)
- [Compilation, coûts, installation atvloadly](docs/BUILD.md)
- [Plan](docs/PLAN.md) · [État de validation](docs/STATUS.md)

## En bref

- Cœur métier `MinuitCore` en Swift 6, testé sous Linux (Docker, gratuit).
- Application tvOS SwiftUI + UIKit, moteur vidéo AetherEngine (MPEG-TS, HDR, Atmos)
  avec repli AVPlayer (HLS).
- IPA non signée compilée par GitHub Actions à chaque push, publiée en Release, signée et installée par atvloadly.

## Installer

1. Télécharger le dernier IPA : [Releases](https://github.com/popolski/minuit-tv/releases)
   (`build-N`, fichier `Minuit-…-unsigned.ipa`).
2. L'installer sur l'Apple TV avec [atvloadly](https://github.com/bitxeno/atvloadly) et un
   compte Apple (gratuit suffit).
3. Pour une mise à jour : **ouvrir d'abord une autre app sur l'Apple TV**, puis installer par-dessus.

Tests du cœur en local (NAS, Docker) : `sh scripts/test-core.sh`.

Minuit ne fournit aucun contenu : il lit uniquement le compte que vous lui confiez.
