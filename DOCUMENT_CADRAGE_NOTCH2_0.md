# C2 - RESTREINT - NE PAS DIFFUSER

# Document de cadrage Notch2.0

Version : 1.0  
Date : Avril 2026  
Statut : Document de travail  
Porteur du projet : Notch2.0  
Référent : Produit/Technique

## 1. Résumé exécutif
Notch2.0 est un utilitaire macOS orienté expérience "Now Playing" et HUD visuel en zone notch/menu bar.  
Le projet vise à proposer une couche d'interaction rapide, élégante et non intrusive pour piloter la lecture média et afficher un retour visuel immédiat (titre, artiste, progression, artwork, contrôles).

L'objectif du présent cadrage est de formaliser la vision produit, le périmètre réel du code actuel, les risques techniques (Apple Events, APIs privées, variabilité des lecteurs), les priorités de livraison et les critères de succès.

## 2. Contexte et origine du projet
Les usages audio/vidéo desktop restent fragmentés entre applications natives (Spotify, Music, VLC, QuickTime) et lecteurs web (Safari/Chrome/Brave/Edge/Arc).  
Les contrôles système sont souvent génériques et peu contextualisés. L'utilisateur manque d'un point unique, compact et visuel, centré sur l'action.

Notch2.0 répond à ce besoin via :
- une détection multi-source du contenu en cours de lecture,
- un HUD top-center animé, réactif et pilotable,
- une logique d'orchestration orientée usage quotidien.

## 3. Problématique
Comment fournir, sur macOS, une expérience de contrôle média unifiée, fiable et fluide malgré :
- des sources hétérogènes,
- des permissions Apple Events sensibles,
- des informations parfois incomplètes ou bruitées selon les apps ?

## 4. Vision du projet
Faire de Notch2.0 un "runtime de surface média" pour macOS :
- lisible en un coup d'œil,
- actionnable en un geste (play/pause, next/prev, seek),
- extensible à d'autres feedbacks système (volume, luminosité, clavier).

La vision cible est un composant utilitaire premium, toujours disponible, qui réduit la friction entre intention utilisateur et action média.

## 5. Ambition et positionnement
### 5.1 Ambition
Construire un produit macOS de référence sur le segment des overlays notch/HUD média, avec un socle technique robuste et extensible.

### 5.2 Positionnement
Notch2.0 se positionne comme :
- une couche UX système orientée lecture média,
- un orchestrateur multi-probes (native + web + metadata center),
- un produit "desktop-native first" privilégiant réactivité et finesse visuelle.

### 5.3 Différenciation
- pipeline de détection multi-source dans un même service (`NowPlayingService`),
- fallbacks progressifs (Spotify realtime, startup probe, desktop probes, browser probes, MPNowPlayingInfo),
- HUD notch interactif avec cycle expand/collapse, animations d'entrée et timeline seek.

## 6. Objectifs du projet
### 6.1 Objectif principal
Livrer une expérience Notch "Now Playing" stable et cohérente pour les lecteurs médias majeurs sur macOS.

### 6.2 Objectifs opérationnels
- détecter automatiquement la lecture active,
- afficher un HUD compact et actionnable,
- piloter lecture et navigation pistes,
- gérer la progression locale/seek avec cohérence UI,
- enrichir la couverture artwork sans affichages erronés.

### 6.3 Objectifs SMART (phase actuelle)
- stabiliser la détection multi-source avec un taux de faux positifs faible,
- garantir une latence perçue faible sur les actions play/pause/seek,
- maintenir un comportement HUD prévisible (auto-collapse + réouverture),
- réduire les erreurs AppleScript non gérées via cooldowns et garde-fous.

## 7. Publics cibles
### 7.1 Cibles principales
- utilisateurs macOS qui consomment du média en continu (musique, vidéo),
- profils "power user" sensibles aux workflows clavier et au feedback visuel rapide.

### 7.2 Cibles secondaires
- créateurs/streamers/monteurs avec multi-app média,
- utilisateurs recherchant un utilitaire desktop premium, discret et réactif.

## 8. Proposition de valeur
Pour l'utilisateur final :
- contexte média centralisé sans changer d'application,
- commandes immédiates dans une surface compacte,
- meilleure lisibilité de la lecture en cours (titre, artiste, timeline, artwork).

Pour le produit :
- architecture modulaire orientée évolutions futures,
- base solide pour ajouter des surfaces volume/luminosité/clavier.

## 9. Périmètre du projet
### 9.1 Périmètre fonctionnel inclus (code actuel)
A. Orchestration applicative
- bootstrap app accessory sans fenêtre principale (`Notch2_0App`, `AppDelegate`),
- pilotage runtime centralisé (`AppModel`).

B. Détection Now Playing
- `NowPlayingService` avec polling + observers distribués,
- support Spotify/Music/VLC/QuickTime + lecteurs web ciblés.

C. Contrôle lecture
- transport controls et seek via `PlaybackControlService`,
- stratégie directe (AppleScript par app) puis fallback media keys.

D. HUD et interaction
- `HUDCoordinator`, `HUDWindowController`, `HUDView`,
- états expanded/collapsed, auto-collapse, hover-reopen, double-click collapse.

E. Artwork et enrichissement metadata
- `ArtworkResolver` (direct URL, Spotify oEmbed, iTunes fallback contraint),
- cache + cooldown de retry.

F. Visualisation audio
- `AudioSpectrumService` via ScreenCaptureKit + FFT (vDSP), rendu mini-spectrum.

### 9.2 Hors périmètre initial (non branché ou partiel)
- intégration menu bar complète (vue présente, wiring incomplet),
- interception média/volume/luminosité via `MediaKeyMonitor` en production,
- flux HUD volume/luminosité/keyboard brightness,
- packaging commercial et canaux de distribution.

## 10. Livrables attendus
- application macOS signée (Debug/Release),
- runtime now-playing stable pour sources priorisées,
- HUD notch interactif avec contrôles playback,
- documentation technique d'architecture et de limites,
- backlog priorisé des extensions système.

## 11. Exigences fonctionnelles principales
### 11.1 Détection et priorité des sources
- ordre de résolution clair (Spotify live/startup, desktop probe, browser, media center),
- filtrage des messages système parasites.

### 11.2 Contrôle playback
- play/pause, piste précédente/suivante,
- seek proportionnel si durée disponible.

### 11.3 HUD interactif
- affichage expand/collapse,
- timeline draggable,
- feedback visuel immédiat.

### 11.4 Artwork
- réutilisation locale par track key,
- fetch asynchrone avec fallback contrôlé.

### 11.5 Robustesse runtime
- cooldown par bundle et par endpoint réseau,
- gestion des cas autorisation refusée Apple Events.

## 12. Exigences non fonctionnelles
- performance : polling et UI fluides,
- fiabilité : pas de spam UI si signature identique,
- maintenabilité : séparation App / Features / Services,
- sécurité : usage explicite des permissions Apple Events,
- observabilité : logs d'erreurs AppleScript et blocages probes.

## 13. Enjeux stratégiques
- enjeu produit : proposer une UX utile au quotidien, pas un gadget visuel,
- enjeu technique : fiabiliser un contexte macOS contraint (permissions + apps tierces),
- enjeu adoption : convaincre par la stabilité, pas seulement par l'animation,
- enjeu roadmap : transformer les services déjà codés en fonctionnalités exposées.

## 14. Hypothèses structurantes
- les utilisateurs acceptent les permissions Apple Events si la valeur est claire,
- la détection multi-source peut rester robuste sans API privée obligatoire active,
- un HUD compact est préférable à une fenêtre persistante classique.

## 15. Parties prenantes
### 15.1 Parties prenantes internes
- direction produit,
- développement macOS/Swift,
- design interaction.

### 15.2 Parties prenantes externes
- utilisateurs finaux macOS,
- éditeurs d'apps tierces intégrées implicitement (Spotify, Apple Music, navigateurs).

## 16. Gouvernance du projet
### 16.1 Pilotage
Pilotage produit/technique court, orienté itérations rapides et validation terrain.

### 16.2 Principes de gouvernance
- arbitrage impact utilisateur > complexité perçue,
- réduction des dépendances fragiles,
- priorisation explicite des sources médias et des fallbacks.

## 17. Organisation et méthode de travail
- cycles courts de stabilisation par sous-système (probe, controls, HUD),
- validation manuelle multi-app sur macOS réel,
- durcissement progressif (gestion erreurs, cooldown, fallback).

## 18. Jalons clés
1. Stabilisation pipeline now-playing multi-source.
2. Fiabilisation transport controls + seek.
3. Qualité UX du HUD notch (collapse/reopen/hover).
4. Intégration effective des services volume/luminosité/media keys.
5. Stabilisation packaging release.

## 19. Planning macro
Phase 1 : fiabilité du cœur now-playing.  
Phase 2 : extension controls système (volume/luminosité/clavier).  
Phase 3 : finition produit (menu bar complet, réglages avancés, distribution).

## 20. Ressources nécessaires
Ressources humaines :
- 1 dev macOS principal,
- support ponctuel design UX motion.

Ressources techniques :
- environnement Xcode/macOS récent,
- comptes de signature,
- jeu de tests multi-app (Spotify/Music/VLC/QuickTime/browsers).

## 21. Contraintes du projet
- dépendance aux permissions Apple Events,
- variabilité comportementale des apps tierces,
- certaines briques basées sur frameworks privés (`DisplayServices`, `MediaRemoteBridge`),
- contraintes de compatibilité version macOS.

## 22. Risques projet
### 22.1 Risques produit
- faux positifs de détection web,
- incohérences perçues entre apps natives et web.

### 22.2 Risques techniques
- échecs AppleScript intermittents (-609, -1743),
- instabilité liée aux APIs privées selon versions OS.

### 22.3 Risques UX
- HUD jugé intrusif si auto-collapse mal calibré,
- surcharge visuelle si animations non maîtrisées.

### 22.4 Risques business
- difficulté de monétisation sans différenciation claire,
- coût support élevé si comportements dépendants des apps tierces.

## 23. Stratégies de réduction des risques
- cooldowns ciblés par type d'erreur,
- fallbacks explicites par source et par action,
- métriques de fiabilité orientées usage réel,
- durcissement progressif avant élargissement du périmètre.

## 24. Indicateurs de suivi
Indicateurs produit :
- taux de détection correcte par source,
- temps moyen de réaction HUD,
- taux de succès play/pause/seek.

Indicateurs qualité :
- fréquence des erreurs AppleScript,
- ratio fallback utilisé vs source primaire,
- incidents d'incohérence artwork.

## 25. Critères de réussite
- lecture active détectée de façon fiable sur les apps cibles,
- HUD perçu comme utile et non intrusif,
- contrôles lecture stables sur les parcours principaux,
- réduction du besoin de changer d'application pour piloter la lecture.

## 26. Modèle économique cible
Pistes cibles (à valider) :
- version gratuite cœur now-playing,
- version premium (thèmes, intégrations avancées, options UX),
- bundle d'utilitaires macOS orientés productivité média.

## 27. Principes directeurs d'exécution
- priorité à la robustesse des flux critiques,
- simplicité d'usage avant accumulation de features,
- architecture modulaire conservée (Services/Features/App),
- décisions guidées par incidents réels et retour utilisateur.

## 28. Décisions structurantes à entériner
- stratégie officielle sur APIs privées (usage, fallback, communication),
- priorisation finale des surfaces système (volume/luminosité/clavier),
- politique de compatibilité macOS minimale et distribution.

## 29. Conclusion
Notch2.0 dispose d'un socle technique déjà solide sur le cœur now-playing + HUD.  
La valeur du produit se jouera maintenant sur la stabilisation, l'intégration complète des services déjà présents, puis la finition produit (menu bar, réglages, packaging).

## 30. Annexes
### 30.1 Architecture logique actuelle
- `Notch2_0App` : bootstrap + defaults.
- `AppDelegate` : mode accessory + anti-duplication process.
- `AppModel` : orchestrateur central état/runtime.
- `NowPlayingService` : acquisition metadata multi-source.
- `PlaybackControlService` : commandes transport et seek.
- `ArtworkResolver` : résolution artwork + cache/cooldown.
- `HUDCoordinator` / `HUDWindowController` / `HUDView` : rendu et interaction.
- `AudioSpectrumService` : FFT temps réel via ScreenCaptureKit.
- `AudioVolumeService`, `DisplayBrightnessService`, `MediaKeyMonitor` : briques système prêtes à intégrer pleinement.

### 30.2 Flux principal
1. `AppModel` démarre `NowPlayingService`.
2. `NowPlayingService` émet un `NowPlayingSnapshot`.
3. `AppModel` résout artwork (si nécessaire) puis compose un `HUDPayload`.
4. `HUDCoordinator` affiche via `HUDWindowController`.
5. Actions utilisateur HUD -> `PlaybackControlService`.
6. Snapshot local mis à jour -> HUD rafraîchi.

### 30.3 Références code (base actuelle)
- `Notch2.0/App/AppModel.swift`
- `Notch2.0/Services/NowPlaying/NowPlayingService.swift`
- `Notch2.0/Services/NowPlaying/PlaybackControlService.swift`
- `Notch2.0/Services/NowPlaying/ArtworkResolver.swift`
- `Notch2.0/Features/HUD/HUDWindowController.swift`
- `Notch2.0/Features/HUD/HUDView.swift`
