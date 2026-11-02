# État de validation

Légende : ✅ fait · ⏳ à faire · — sans objet

| Fonctionnalité | 1. Implémentée | 2. Compilée | 3. Test automatisé | 4. Vérifiée sur Apple TV |
|---|---|---|---|---|
| Analyse de l'adresse serveur, URL Xtream (direct, timeshift ×2 styles) | ✅ | ✅ Linux | ✅ | ⏳ |
| Authentification, états de compte (actif, expiré, banni, refus) | ✅ | ✅ | ✅ | ✅ connexion (serveur HTTP) |
| Décodage tolérant (types variables, entrées invalides, doublons, VOD égarée) | ✅ | ✅ Linux | ✅ | ⏳ |
| Nouvelles tentatives bornées, erreurs sans secret | ✅ | ✅ Linux | ✅ | — |
| Masquage des secrets dans les journaux | ✅ | ✅ Linux | ✅ | — |
| EPG Xtream (base64, horodatages, forme objet) | ✅ | ✅ Linux | ✅ | ⏳ |
| XMLTV (flux, filtres, multilingue, fichier tronqué, liaison par nom) | ✅ | ✅ Linux | ✅ | ⏳ |
| Index EPG, fusion, nettoyage, trous, cache | ✅ | ✅ Linux | ✅ | ⏳ |
| Fuseaux horaires et changements d'heure | ✅ | ✅ Linux | ✅ | ⏳ |
| Catalogue, recherche, catégories masquées/réordonnées, adultes | ✅ | ✅ Linux | ✅ | ⏳ |
| Favoris, récentes, dernière chaîne (persistance) | ✅ | ✅ Linux | ✅ | ⏳ |
| Zapping (boucle, rappel, regroupement des appuis) | ✅ | ✅ Linux | ✅ (logique) | ⏳ |
| Planification moteur × format, mémoire par chaîne | ✅ | ✅ Linux | ✅ | ⏳ |
| Détection image figée / son sans image / blocage | ✅ | ✅ Linux | ✅ (scénarios) | ⏳ |
| Échelle de reprise bornée | ✅ | ✅ Linux | ✅ | ⏳ |
| Disponibilité replay / Start Over, sondage d'archive | ✅ | ✅ Linux | ✅ | ⏳ |
| Keychain, reconnexion automatique, mode dégradé | ✅ | ✅ | ⏳ | ⏳ |
| Moteur AVPlayer (HLS) | ✅ | ✅ | ⏳ | ⏳ |
| Moteur AetherEngine (TS, HLS, archives) | ✅ | ✅ | ⏳ | ⏳ |
| Contrôleur de lecture (génération, un seul moteur, veille, réseau) | ✅ | ✅ | ⏳ | ⏳ |
| Lecteur : télécommande, bandeau, panneaux, transport replay | ✅ | ✅ | ⏳ | ⏳ |
| Guide TV (grille virtualisée, ligne maintenant, fenêtre glissante) | ✅ | ✅ | ⏳ | ⏳ |
| Écrans : connexion, accueil, chaînes, recherche, favoris, réglages | ✅ | ✅ | ⏳ | ✅ connexion ; reste à détailler |
| Icône et Top Shelf | ✅ | ✅ | — | ⏳ |

État au 2 novembre 2026 :
- **82 tests réussis** sous Linux (Swift 6.1.3) ; vérifications statiques OK.
- **Application tvOS compilée** par la CI (image `xcode-27`, Xcode 27.1), sans avertissement
  dans le code de Minuit ; IPA vérifiée (arm64, tvOS, frameworks FFmpeg) — Release `build-3`.
- **Apple TV (retour utilisateur)** : installation via atvloadly OK, connexion à un serveur
  Xtream en HTTP OK, application jugée « déjà très fonctionnelle ». Les fonctions sont à
  qualifier une par une (lecture, zapping, guide, replay…).

## Limites connues et incertitudes

- Chemin logiciel d'AetherEngine (codecs non pris en charge par le matériel) : pas
  de signal vidéo indépendant de l'horloge ; la détection d'image figée y repose sur
  la première image et l'horloge.
- AVPlayer (repli) applique les critères d'affichage après chargement : une variante
  HDR peut être refusée si l'écran n'est pas déjà en HDR (comportement tvOS 26.5+).
- Archives MPEG-TS : repositionnement par nouvelle requête, précision d'une minute.
- Start Over d'un programme en cours : dépend de l'enregistrement côté fournisseur,
  confirmé par sondage seulement.
- Comportement de la télécommande sans élément focalisable (appuis reçus par le
  contrôleur du lecteur) : conforme aux pratiques courantes, à vérifier sur l'appareil.
- Débit, temps de zapping, 4K/HDR, Atmos : non mesurés tant que l'application n'a pas
  tourné sur votre Apple TV avec votre fournisseur.
