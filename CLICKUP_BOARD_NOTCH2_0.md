# Template ClickUp - Notch2.0

## 1) Structure du tableau

- Espace: `Notch2.0`
- Dossier: `Roadmap 2026`
- Listes:
- `P0 - Coeur Now Playing`
- `P1 - HUD UX & Controls`
- `P1 - Extensions Systeme`
- `P2 - Produit & Release`
- `Ops - Qualite & Pilotage`

## 2) Statuts recommandes

- `Backlog`
- `Ready`
- `In Progress`
- `Review`
- `Test`
- `Done`
- `Blocked`

## 3) Priorites

- `Urgent` = blocant user value
- `High` = impact direct sur criteres de reussite
- `Normal` = important, non blocant court terme
- `Low` = optimisation/post-MVP

## 4) Taches proposees (alignees au cadrage)

| Liste | Tache | Priorite | Statut initial | Critere de reussite lie | KPI principal |
|---|---|---|---|---|---|
| P0 - Coeur Now Playing | Formaliser ordre de priorite des sources (Spotify live/startup, desktop, browser, MPNowPlaying) | High | Ready | Lecture active detectee de facon fiable | Taux de detection correcte par source |
| P0 - Coeur Now Playing | Durcir filtre anti faux positifs (messages systeme parasites) | High | Ready | HUD utile et non intrusif | Taux de faux positifs |
| P0 - Coeur Now Playing | Stabiliser startup probe Spotify + retry/cooldown | High | Ready | Lecture active detectee de facon fiable | Taux d'echec startup probe |
| P0 - Coeur Now Playing | Ajouter instrumentation detection par source (logs + compteurs) | High | Backlog | Pilotage qualite runtime | Ratio fallback vs source primaire |
| P0 - Coeur Now Playing | Exposer `EnableSystemNowPlayingCenter` dans Settings + MenuBar | Normal | Backlog | Fiabilite multi-source | Taux de detection correcte |
| P0 - Coeur Now Playing | Campagne de validation multi-app (Spotify/Music/VLC/QuickTime + browsers) | High | Ready | Controles stables sur parcours principaux | Taux de succes play/pause/seek |
| P1 - HUD UX & Controls | Recalibrer auto-collapse/reopen pour non-intrusivite | High | Ready | HUD percu comme utile et non intrusif | Temps moyen de reaction HUD |
| P1 - HUD UX & Controls | Finaliser seek timeline avec rollback UI en cas d'echec commande | High | Ready | Controles lecture stables | Taux de succes seek |
| P1 - HUD UX & Controls | Uniformiser previous/next selon source + fallback explicite | High | Backlog | Controles stables sur parcours principaux | Taux de succes next/prev |
| P1 - HUD UX & Controls | Ajouter mode animations reduites (accessibilite/confort) | Normal | Backlog | HUD non intrusif | Feedback qualite UX |
| P1 - HUD UX & Controls | Optimiser latence percue sur play/pause (<200ms cible) | High | Backlog | Actionnable en un geste | Latence mediane commande |
| P1 - HUD UX & Controls | Verrouiller logique idle notch (pas de spam visuel) | Normal | Backlog | HUD utile et non intrusif | Nombre d'affichages inutiles |
| P1 - Extensions Systeme | Brancher `MediaKeyMonitor` dans `AppModel` (runtime reel) | High | Ready | Extension controls systeme | Taux d'interception touches |
| P1 - Extensions Systeme | Connecter `AudioVolumeService` au HUD volume | High | Ready | Surface media/systeme unifiee | Taux de succes ajustement volume |
| P1 - Extensions Systeme | Connecter `DisplayBrightnessService` au HUD brightness | High | Backlog | Surface media/systeme unifiee | Taux de succes ajustement luminosite |
| P1 - Extensions Systeme | Implementer keyboard brightness service (private API + fallback) | Normal | Backlog | Extension controls systeme | Taux de succes keyboard brightness |
| P1 - Extensions Systeme | Ajouter toggles volume/brightness/keyboard dans Settings + MenuBar | Normal | Backlog | Pilotage utilisateur clair | Taux d'usage des toggles |
| P1 - Extensions Systeme | Durcir gestion permissions/sandbox et messages utilisateur | High | Backlog | Fiabilite en conditions reelles | Frequence erreurs permissions |
| P2 - Produit & Release | Completer integration MenuBarExtra (wiring complet) | High | Ready | Produit toujours disponible | Taux usage menu bar |
| P2 - Produit & Release | Refondre `SettingsView` (General, Sources, HUD, Debug) | Normal | Backlog | Maintenabilite + adoption | Taux completion setup |
| P2 - Produit & Release | Ajouter launch-at-login (`SMAppService`) | Normal | Backlog | Utilitaire quotidien | Retention 7/30 jours |
| P2 - Produit & Release | Build release signe + checklist notarization | High | Backlog | Livrable application macOS signee | Taux succes pipeline release |
| P2 - Produit & Release | Documenter architecture, limites, support et runbook | Normal | Backlog | Support et evolution maitrises | Temps moyen de resolution incident |
| Ops - Qualite & Pilotage | Dashboard KPI produit/qualite (detection, latence, erreurs AppleScript) | High | Ready | Pilotage continu par la valeur | KPI disponibles chaque semaine |
| Ops - Qualite & Pilotage | Journaliser erreurs AppleScript (-609/-1743) + policy cooldown | High | Ready | Reduction erreurs non gerees | Frequence erreurs AppleScript |
| Ops - Qualite & Pilotage | Definir matrice tests macOS x apps tierces | High | Backlog | Fiabilite multi-environnements | Couverture matrice de tests |
| Ops - Qualite & Pilotage | Revue hebdo backlog + registre des risques + decisions | Normal | Backlog | Gouvernance courte et claire | Nb risques critiques non traites |
| Ops - Qualite & Pilotage | Definir Go/No-Go release (criteres objectifs) | High | Backlog | Lancement robuste | Nb criteres valides avant release |

## 5) Ordre d'execution recommande

1. P0 - Coeur Now Playing
2. P1 - HUD UX & Controls
3. P1 - Extensions Systeme
4. P2 - Produit & Release
5. Ops - Qualite & Pilotage (en continu)

