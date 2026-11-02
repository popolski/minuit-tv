# Architecture technique

## Vue d'ensemble

```
minuit-tv/
├── Package.swift                 MinuitCore : logique métier pure (Foundation seule)
├── Sources/MinuitCore/
│   ├── Xtream/       client player_api.php, décodage tolérant, URL, erreurs
│   ├── Domain/       modèles, catalogue, préférences, recherche, zapping
│   ├── EPG/          XMLTV (SAX), index EPG, nettoyage, fuseaux, frise du guide
│   ├── Catchup/      disponibilité replay / Start Over, sondage d'archive
│   ├── Playback/     planification moteur × format, santé de lecture, reprise
│   ├── Persistence/  préférences (UserDefaults), caches (Caches/), réglages
│   ├── Networking/   HTTPClient (URLSession), classification des erreurs
│   └── Diagnostics/  masquage des secrets, journal circulaire, statistiques
├── Tests/MinuitCoreTests/        79 tests, exécutés sous Linux (Docker)
└── App/                          application tvOS (SwiftUI + UIKit)
    ├── project.yml               spécification XcodeGen (aucun .xcodeproj versionné)
    └── Sources/
        ├── App/        point d'entrée, AppModel (état global), routeur
        ├── Services/   Keychain, EPGService, ArchiveService
        ├── Player/     moteurs (AVPlayer, AetherEngine), PlaybackController, lecteur UIKit
        ├── Guide/      grille EPG UICollectionView virtualisée
        ├── Screens/    accueil, chaînes, favoris, réglages, fiche programme, connexion
        ├── Theme/      direction artistique « Minuit »
        └── Components/ logos (cache), éléments communs
```

**Principe directeur : tout ce qui peut être testé sans Apple l'est.** Le cœur
`MinuitCore` n'importe ni UIKit, ni AVFoundation, ni SwiftUI. Il compile et se teste
sous Linux, gratuitement, sur le NAS ou sur le PC Windows (Docker). La couche tvOS
est volontairement mince : elle traduit des décisions prises et testées dans le cœur.

## Choix structurants

| Sujet | Choix | Raison |
|---|---|---|
| Langage | Swift 6 (cœur, mode strict) ; Swift 5 + concurrence « targeted » (app) | Sûreté maximale là où c'est testable ; risque de compilation réduit dans la couche non compilable ici |
| Concurrence | async/await, `@MainActor` pour l'UI et la lecture | Natif, sans dépendance |
| UI | SwiftUI pour les écrans ; **UIKit** pour le lecteur (télécommande) et la grille EPG | Contrôle exact des appuis Siri Remote ; virtualisation éprouvée de `UICollectionView` pour des milliers de lignes |
| État | `@Observable` (Observation) | Mises à jour fines, sans Combine côté app |
| Persistance | Keychain (identifiants), UserDefaults (préférences < 128 Ko), Caches (catalogue, EPG) | tvOS n'offre pas de stockage local persistant garanti : seul le petit et précieux est stocké durablement, le reste est reconstructible |
| Projet Xcode | XcodeGen sur le runner | Pas de `.pbxproj` à maintenir à la main sans Mac |
| Dépendances | AetherEngine (épinglé 7.54.0), rien d'autre | Voir ci-dessous |

## Moteur vidéo : comparaison et décision

| Critère | AVPlayer seul | **AetherEngine** | VLCKit 4 | KSPlayer | libmpv |
|---|---|---|---|---|---|
| HLS en direct | Excellent | Oui (natif ou ingestion) | Oui | Oui | — |
| **MPEG-TS brut en HTTP** (format natif Xtream) | **Non** | **Oui** (connexion unique, reconnexion) | Oui | Oui | — |
| H.264 / HEVC matériel | Oui | Oui (VideoToolbox) | Oui | Oui | — |
| HDR10 / HLG / Dolby Vision, correspondance de l'écran | Oui | Oui (AVPlayer en rendu final) | Mappage logiciel | Partiel (version payante) | Pas de tvOS |
| 1080i (fréquent en IPTV) | Pas de désentrelacement | Désentrelacement GPU | Oui | Oui | — |
| Audio MP2 / AC-3 / E-AC-3 / Atmos | AAC, AC-3, E-AC-3 ; Atmos | Large ; E-AC-3 JOC transmis | Décodé en PCM | Oui | — |
| Licence | Système | LGPL-3.0 + exception App Store | LGPL | GPL (gratuit) | GPL |
| Maintenance | Apple | Très active (risque : publications fréquentes) | Lente (4.0 en alpha) | — | — |

**Décision : AetherEngine en moteur principal, AVPlayer en repli indépendant.**

- Les fournisseurs Xtream servent nativement du **MPEG-TS** ; le HLS est souvent un
  remuxage côté serveur, parfois désactivé (`allowed_output_formats`). AVPlayer seul
  laisserait de côté une partie des comptes et le contenu 1080i.
- AetherEngine garde AVPlayer comme moteur de rendu chaque fois que c'est possible :
  HDR, Dolby Vision, Atmos et correspondance de fréquence restent ceux du système.
- Il est conçu pour ce cas d'usage (zapping `fastZap`, `liveSourceReset`, gestion des
  refus de connexion Xtream, archives à origine séquentielle) et déjà utilisé par
  plusieurs applications IPTV tvOS.
- **Risques assumés et mesures :** projet jeune à publication très fréquente (version
  **figée**, montée de version délibérée) ; binaires FFmpeg (taille de l'IPA, liaison
  dynamique conforme LGPL) ; exige Xcode 26.3+ (disponible sur les runners). Si
  AetherEngine pose problème, `EngineFactory` permet de compiler sans lui : l'app
  reste fonctionnelle en HLS via AVPlayer.

Échelle de repli (testée dans `PlaybackPlanningTests`) :

1. AetherEngine + MPEG-TS
2. AVPlayer + HLS (moteur indépendant)
3. AetherEngine + HLS

Une combinaison qui a fonctionné pour une chaîne est mémorisée et rejouée en premier.
Si le compte n'autorise que TS et qu'AetherEngine est absent, l'application le dit
au lieu de prétendre lire.

## Lecture : garanties

`PlaybackController` (app) applique les décisions de `MinuitCore/Playback` :

- **Un seul moteur à la fois** : l'ancien est arrêté et retiré avant d'en créer un autre ;
  une seule vue hôte existe dans toute l'application.
- **Jetons de génération** : chaque chargement incrémente une génération ; tout
  événement (première image, erreur) d'une génération périmée est ignoré.
- **Zapping groupé** (`ZapAccumulator`) : le bandeau suit chaque appui ; un seul
  chargement part 350 ms après le dernier appui.
- **Première image réelle** : `AVPlayerLayer.isReadyForDisplay` ou
  `hasFirstFrameReadyForDisplay` d'AetherEngine — jamais « prêt à lire » ni l'état `.playing`.
- **Santé** (`PlaybackHealthMonitor`, 2 Hz) : l'horloge seule ne prouve rien. Image
  figée = horloge qui avance sans progression vidéo (cadence de la piste vidéo) ;
  son sans image ; blocage ; démarrage trop long. Testé par scénarios.
- **Reprise bornée** (`RecoveryPlanner`) : 3 rechargements espacés (1, 3, 6 s) sur une
  fenêtre de 2 min, puis repli moteur, puis échec affiché. Jamais de boucle infinie.
  Pas de repli inutile quand le compte est saturé (connexions max).
- **Réseau** : `NWPathMonitor` ; en cas de coupure, attente puis reprise au direct.
- **Veille / arrière-plan** : tout est libéré (connexion comprise) ; au retour, le
  direct reprend au point de direct, l'archive à sa position.

## EPG

- Sources : XMLTV complet (`xmltv.php`, analyse en flux filtrée par chaînes et fenêtre),
  `get_short_epg` à la demande pour les chaînes visibles (4 requêtes simultanées max),
  `get_simple_data_table` pour le panneau d'une chaîne (indicateurs `has_archive`).
- Fusion par richesse de source, nettoyage (doublons, chevauchements, durées nulles ou
  aberrantes), trous explicites (« Programme non communiqué »).
- Temps absolu partout ; seules les graduations dépendent du fuseau de l'appareil.
  Fuseau serveur (IANA, sinon déduit de `time_now`/`timestamp_now`) utilisé pour les
  horaires Xtream sans horodatage et pour les URL de timeshift. Changements d'heure testés.
- Grille : `UICollectionView` + mise en page maison ne calculant que les lignes visibles,
  fenêtre glissante de 12 h pour borner le nombre de cases, colonnes et frise collantes.

## Catch-up / Start Over

- `CatchupEvaluator` : capacité **annoncée** (tv_archive, durée, `has_archive`, fenêtre).
- `ArchiveProbe` + `ArchiveService` : avant toute lecture, sondage réel (≤ 4 Ko) de l'URL
  d'archive ; seuls un flux TS (paquets 0x47) ou une playlist HLS avec segments sont
  acceptés. Les deux styles d'URL Xtream sont essayés puis le bon est mémorisé.
- Archive HLS : AVPlayer, repositionnement précis. Archive TS : AetherEngine en
  origine séquentielle, repositionnement par nouvelle requête (précision : la minute).
- Aucun replay n'est simulé : en cas d'échec du sondage, message explicite et le direct continue.

## Sécurité

- Identifiants dans le Keychain (`AfterFirstUnlock`, sans groupe d'accès : compatible
  avec la re-signature atvloadly).
- `XtreamCredentials` masque ses secrets dans toute description.
- `Redactor` masque utilisateur et mot de passe dans les URL (chemin et requête) et en
  littéral ; tout journal passe par `DiagnosticsLog`, qui l'applique. Script
  `static-checks.sh` : interdit `print`/`NSLog` et les secrets codés en dur.
- Transport : HTTP accepté par défaut (la plupart des serveurs Xtream n'offrent que HTTP) ;
  « Préférer HTTPS » (bascule si le serveur annonce un port HTTPS fonctionnel) et
  « Exiger HTTPS » disponibles dans les réglages. ATS : `NSAllowsArbitraryLoads` seul
  (toute autre clé ATS le neutraliserait).
