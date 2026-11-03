# Plan de développement

| # | Étape | État |
|---|---|---|
| 1 | Analyse des contraintes, choix techniques | ✅ |
| 2 | Architecture, choix du moteur vidéo | ✅ `ARCHITECTURE.md` |
| 3 | Direction artistique | ✅ `DESIGN.md` |
| 4 | Parcours utilisateur, correspondance Siri Remote | ✅ (ci-dessous) |
| 5 | Socle : cœur métier testé (Xtream, EPG, catalogue, persistance) | ✅ 84 tests |
| 6 | Lecteur + connexion Xtream (couche tvOS) | ✅ écrit, ✅ compilé |
| 7 | EPG et zapping (guide, mini-guide, panneaux) | ✅ écrit, ✅ compilé |
| 8 | Catch-up et Start Over | ✅ écrit, ✅ compilé |
| 9 | Tests automatisés et vérifications statiques | ✅ (cœur) |
| 10 | Build macOS automatique (méthode Lanterne) | ✅ Release `build-3` |
| 11 | Installation atvloadly, qualification sur Apple TV avec vos retours | 🔄 installé, connexion OK |

## Parcours principaux

1. **Premier lancement** : Connexion (serveur, identifiant, mot de passe) → vérification
   du compte → bascule HTTPS si disponible → catalogue → Accueil.
2. **Lancement quotidien** : catalogue en cache affiché instantanément, vérification en
   arrière-plan ; reprise automatique de la dernière chaîne (réglable).
3. **Zapper** : ▲▼ dans le lecteur ; ◀ ouvre la liste avec programmes en cours.
4. **Que regarder ?** : Guide TV → case → direct (programme en cours) ou fiche (passé / à venir).
5. **Rattraper** : ▶ dans le lecteur → programme passé → vérification → replay ;
   programme en cours → « Reprendre au début » ; « Revenir au direct » à tout moment.

## Siri Remote (lecteur)

| Commande | Direct | Replay |
|---|---|---|
| ▲ / ▼ (clic ou balayage) | Chaîne précédente / suivante | Barre de transport |
| ◀ | Panneau des chaînes | −30 s |
| ▶ | Panneau des programmes | +30 s |
| Clic central | Bandeau d'information | Barre de transport |
| Appui long central | Favori ajouté/retiré | — |
| Lecture/Pause | Pause du direct (tampon 10 min) | Lecture/Pause |
| Retour | Ferme le panneau, puis le lecteur | idem |

## Suite envisagée après qualification

- Saisie numérique de chaîne, double chaîne « rappel » sur un geste dédié.
- Profils multiples, plusieurs comptes.
- Top Shelf dynamique (extension), si le compte de signature le permet.
