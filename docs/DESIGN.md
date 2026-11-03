# Direction artistique « Minuit »

> **Version 2 (verre)** — inspirée de l'esprit de Chillio (retour utilisateur), sans en copier
> l'identité : fond bleu nuit à halo coloré qui suit la chaîne focalisée, surfaces de verre
> translucides, **focus inversé** (pastille claire, texte nuit), capsule de navigation flottante
> (Recherche · Direct · Guide · Réglages), écran Direct en deux volets (catégories / chaînes),
> tuiles de logo à la couleur du logo, lecteur épuré (chaîne en haut à gauche, DIRECT en haut
> à droite, boutons ronds et menu flottant en bas à droite), réglages avec panneau d'identité.
> La version 1 est décrite ci-dessous ; palette et typographie restent valables.

## Intention

La télévision du soir : une pièce sombre, un écran qui ne crie pas. L'interface
s'efface devant l'image et ne se montre que pour répondre. Trois lumières seulement :

| Rôle | Couleur | Usage |
|---|---|---|
| Nuit | `#070B16` → `#0B1426` | Fonds, voiles au-dessus de la vidéo |
| Surface | `#111C33` / focus `#18264A` | Cartes, cases du guide |
| **Lune** | `#8FB8FF` | Focus, sélection, favoris |
| **Braise** | `#FF8A5B` | Direct, ligne « maintenant », progression |
| Archive | `#B49CFF` | Replay, Start Over |

Textes : `#EEF2FA` (principal), `#9AA8C7` (secondaire), `#5F6E8F` (tertiaire).

## Typographie

- **Titres de programmes en serif (New York)** : lecture éditoriale, comme un
  programme imprimé ; c'est la signature visuelle de l'application.
- Interface, chaînes et réglages en **SF Pro**.
- Horaires en **chiffres tabulaires** (alignés dans le guide et les bandeaux).
- Tailles pensées pour 3 m de distance : titres 34–56 pt, corps 24–28 pt, jamais sous 18 pt.

## Principes

1. **Le focus est une lumière, pas un effet.** Liseré lunaire, légère élévation
   (×1,04), ombre douce. Pas de parallaxe ni de rotation.
2. **La braise signifie « maintenant ».** Pastille DIRECT, ligne verticale du guide,
   barres de progression : un seul code couleur pour le temps réel.
3. **Panneaux latéraux plutôt que fenêtres.** Chaînes à gauche (◀), programmes à
   droite (▶), transport en bas : la direction du geste annonce le contenu.
4. **Voiles, pas de cadres.** Les informations sur la vidéo reposent sur des dégradés
   nuit, jamais sur des boîtes opaques.
5. **Mouvement discret** : 0,18 s pour le focus, ressort amorti pour les panneaux.
6. **Les absences sont dites.** « Programme non communiqué », « Replay expiré »,
   « Non archivé par le fournisseur » : jamais de case vide ni de bouton qui ne mène à rien.

## Icône

**Cadran à minuit** : couronne claire, index lunaires, aiguilles superposées sur 12 h,
aiguille des minutes en braise — le nom de l'application en image, lisible en petit.
Icône tvOS à deux couches (parallaxe système) et Top Shelf générées par
`scripts/make_assets.py` ; même dessin dans l'application (`MinuitMark`).
Les autres pistes étudiées sont dans `docs/icon-concepts/planche.png`.

## Écrans

- **Accueil** : grande carte « Reprendre » (chaîne, programme, progression), rangées
  Favoris et Récentes.
- **Guide TV** : grille chaînes × temps, ligne braise, cases replay marquées, navigation
  Plus tôt / Maintenant / Plus tard, glissement automatique aux bords.
- **Chaînes** : catégories à gauche, chaînes à droite avec programme en cours, recherche.
- **Favoris** : grille, réorganisation par appui long.
- **Lecteur** : image seule par défaut ; bandeau au clic ; panneaux latéraux.
- **Réglages** : compte, lecture, catégories, guide, replay, réseau, diagnostics.
