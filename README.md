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
- IPA non signée produite à la demande par GitHub Actions, signée et installée par atvloadly.

```bash
sh scripts/test-core.sh
```

Minuit ne fournit aucun contenu : il lit uniquement le compte que vous lui confiez.
