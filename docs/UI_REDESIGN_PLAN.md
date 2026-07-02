# Talkie — Plan de redesign UI/UX « natif iOS »

> Handoff pour implémentation. Cible : l'écran principal de `ios/Talkie/Talkie/Resources/web/index.html`
> (WKWebView, HTML/CSS/JS vanilla, variables CSS). Ne pas casser les IDs/fonctions JS existants :
> `renderSuggestionCards`, `updateContextDisplay`, `renderTableThread`, `renderVoiceControls`,
> `speakSuggestion`, `startListening`/`stopListening`, bridges `window._native*`.

---

## A. Diagnostic — pourquoi l'UI actuelle fait « template IA »

1. **Emojis utilisés comme icônes UI** (😐 ⏱️ 👤 👥 🖐️ ❌ ✅ 🤔 💬). Marqueur n°1 d'UI générée.
   Les apps natives utilisent des symboles vectoriels monochromes (SF Symbols).
2. **Police web générique** (DM Sans). Dans une WKWebView on peut utiliser la stack système
   (`-apple-system` → SF Pro) : rendu instantanément « natif ».
3. **Tout est une pilule grise du même poids** : 4 chips + barre d'écoute + carte transcript
   empilées avant le moindre contenu. Aucune hiérarchie, l'œil ne sait pas où aller.
4. **Labels criards** : « L'INTERLOCUTEUR DIT » en uppercase + letterspacing. Bruit.
5. **Logo + nom de l'app sur l'écran principal**. Une app-outil native ne se re-brande pas
   à chaque écran.
6. **État vide pauvre** : 60 % d'écran noir avec une bulle emoji. Or « en attente » est l'état
   le plus fréquent d'une app AAC — il doit être calme et vivant, pas un placeholder.
7. **3+ teintes simultanées** (violet, vert, jaune emoji, rouge emoji) → aspect « jouet ».
8. Boutons bas ambigus (deux carrés gris sans label), soundboard vert-sur-vert.

## B. Direction — « instrument calme »

L'app est la **voix** d'une personne qui entend parfaitement mais ne parle plus.
Références : Apple Notes/Journal (sobriété), Siri (état d'écoute vivant), WhatsApp (fil lisible).

Principes :
- **Une seule surface élevée à la fois** : les cartes-réponses. Tout le reste est posé sur le fond.
- **Hiérarchie par l'espace, pas par des boîtes.** Le transcript n'est pas une carte, c'est du texte.
- **Un accent unique** (indigo). Le vert n'existe que pour l'état « écoute active ». Rien d'autre.
- **Zéro emoji dans le chrome UI.** Emojis tolérés uniquement comme *contenu* utilisateur
  (quick phrases personnalisées).
- **L'état d'attente est vivant** : indicateur d'écoute animé discret (waveform 5 barres, amplitude
  faible), pas un trou noir.
- **Dignité** : c'est une app d'adulte. Épuré, contrasté, généreux.

## C. Design tokens (remplacer dans `:root`)

### Couleurs — dark (défaut)
```css
--bg:            #0B0B0F;   /* fond profond, quasi noir bleuté */
--surface:       #1A1A20;   /* cartes-réponses (seule surface élevée) */
--surface-hi:    #23232B;   /* état pressé */
--text:          #F5F5F7;
--text-2:        #A0A0AC;   /* secondaire */
--text-3:        #63636E;   /* tertiaire / placeholders */
--accent:        #7A86FF;   /* indigo recalibré pour AA sur #0B0B0F (4.6:1) */
--accent-dim:    rgba(122,134,255,0.14);
--listen:        #30D08C;   /* vert écoute UNIQUEMENT */
--listen-dim:    rgba(48,208,140,0.12);
--separator:     rgba(255,255,255,0.07);
--danger:        #FF6961;
```
### Couleurs — light
```css
--bg: #F2F2F7;  --surface: #FFFFFF;  --surface-hi: #F0F0F5;
--text: #111116; --text-2: #55555F; --text-3: #8E8E98;
--accent: #5560E8; --accent-dim: rgba(85,96,232,0.10);
--listen: #1FA870; --listen-dim: rgba(31,168,112,0.10);
--separator: rgba(17,17,22,0.08);
```
OLED : `--bg:#000`, surfaces `#141419`, le reste inchangé.

### Typographie — stack système obligatoire
```css
--font: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
```
Échelle (html font-size 17px, le réglage taille de texte existant continue de scaler via %) :
- **Suggestion (héros)** : 1.30rem (≈22px) / weight 600 / line-height 1.32
- Transcript final : 1.0rem / 400 / `--text-2`
- Nom de locuteur : 0.94rem / 600 / couleur du locuteur
- Interim : 1.0rem / 400 italic / `--text-3`
- Labels/chips : 0.88rem / 500
- Supprimer **tout** uppercase+letterspacing.
- Chiffres/horodatage : `font-variant-numeric: tabular-nums`.

### Forme & profondeur
- Radius : cartes 22px, chips 999px (capsule), bottom bar 26px.
- Ombres : une seule — `0 8px 24px rgba(0,0,0,0.35)` (dark) / `0 6px 20px rgba(17,17,22,0.08)` (light),
  réservée aux cartes-réponses et à la bottom bar. **Aucune bordure** sur les surfaces sombres ;
  en light, hairline `--separator` sur les surfaces blanches.
- Backdrop-filter : uniquement bottom bar + sheets (`blur(24px) saturate(160%)`). Pas sur les cartes.

### Iconographie
- **SVG inline monochromes, style SF Symbols** (stroke 1.8, round caps, viewBox 24) — set type Lucide :
  `gear`, `mic`, `waveform`, `person`, `person.2`, `arrow.clockwise`, `clock`, `keyboard`,
  `speaker.wave.2`, `flag`, `xmark`, `chevron.right`.
- Taille 20–22px, `currentColor`. **Remplacer chaque emoji du chrome.**

### Motion
- Courbe iOS : `cubic-bezier(0.32, 0.72, 0, 1)`, durées 180–320ms.
- Apparition des 3 cartes : translateY(10px)+fade, stagger 60ms.
- Waveform écoute : 5 barres, scaleY 0.4→1.0, 1.6s, désynchronisées, **amplitude faible** (calme).
- `prefers-reduced-motion` : conserver le bloc kill-switch existant.

## D. Écran principal — architecture par états

Structure verticale (padding latéral 20px, gouttières verticales 14px) :

```
[status row]      gear (droite) + listening chip (gauche)          ~44px
[transcript]      texte flottant, PAS de carte                     max 20vh
[suggestions]     3 cartes — le héros                              flex:1
[quick phrases]   rangée horizontale discrète                      ~52px
[bottom bar]      barre flottante glass : refresh · historique · Écrire
```

### 1. Status row (remplace header logo + 4 pills + grosse barre d'écoute)
- **Supprimer** logo/« Talkie » et le label « Suggestions générées par… » remonte en tout petit
  sous les cartes (inchangé fonctionnellement).
- **Listening chip** (fusion de la barre d'écoute) : capsule à gauche, 44px de haut.
  - Écoute ON : fond `--listen-dim`, waveform animée + « Écoute » en `--listen`.
  - OFF : fond transparent, hairline `--separator`, icône mic barrée + « En pause » en `--text-2`.
  - Tap = toggle (comportement `listeningBar` actuel, garder l'ID ou re-binder).
- **Chip contexte voix** à côté : icône `person`/`person.2` + nom (« Marie », « 3 voix »).
  Tap → sheet locuteurs (renommer ! plus jamais « Locuteur 3 » subi). Le toggle « Plusieurs voix »
  vit DANS ce sheet + reste auto-détecté. Ton & vitesse : déplacés dans un sheet « Voix » ouvert
  depuis Réglages ou appui long sur une carte — **plus de pills permanentes**.
- Gear : 44×44, icône seule, `--text-2`.

### 2. Transcript (remplace la carte gradient)
- **Aucune boîte.** Texte directement sur `--bg`, aligné gauche.
- 1-à-1 : `Marie · Tu viens manger ce soir ?` — nom en accent, texte en `--text-2`.
- Interim : même ligne, italic `--text-3`, caret pulsant 2px.
- Mode groupe : fil de 3 lignes max visibles (scroll), point coloré 8px + nom coloré + texte `--text-2`.
  Palette locuteurs (recalibrée dark) : `#6FA8FF #FF8A7A #4ADE97 #C9A2FF #FFC46B #5AD0D0`.
- Vide : une seule ligne italique `--text-3` « J'écoute… » (si ON) / « Appuyez sur Écoute » (si OFF).

### 3. Cartes-réponses (héros — seules vraies surfaces)
- Fond `--surface`, radius 22, padding 20px 22px, min-height 64px, hauteur = contenu (jamais coupé,
  garder le comportement actuel), gap 12px.
- Texte 1.30rem/600. **Supprimer la pastille speaker verte permanente** (le tap = parler ;
  pendant la lecture, la carte passe en `--accent-dim` + hairline accent → état « je parle »).
- Flag signalement : masqué par défaut, accessible via appui long (menu contextuel) — decluttering.
- Pressed : scale 0.98 + `--surface-hi`. Skeleton loading : shimmer très discret sur `--surface`.
- État vide : petite waveform statique grise + « Les réponses apparaîtront ici » 0.95rem `--text-3`
  (une ligne, pas de gros pictogramme).

### 4. Quick phrases (soundboard)
- Capsules neutres : fond transparent, hairline `--separator`, texte `--text` 0.95rem/500,
  44px de haut. L'emoji utilisateur reste (contenu, pas icône) mais 16px, avant le texte.
  Scroll horizontal inchangé.

### 5. Bottom bar
- Une barre flottante détachée (marges 20px, bottom safe-area+10px), radius 26, glass
  (`blur(24px)` sur fond `rgba(26,26,32,0.72)` dark / `rgba(255,255,255,0.78)` light), ombre unique.
- Contenu : `arrow.clockwise` (44×44, `--text-2`) · `clock` (44×44) · **« Écrire »** bouton principal
  (flex:1, fond `--accent`, texte blanc 1.05rem/600, radius 18, icône keyboard).
- Les IDs/actions actuels (refresh, historique, écrire) sont conservés.

## E. Micro-interactions (le « feel » natif)

1. **Haptics** — nouveau message handler Swift `haptic` (~10 lignes, `UIImpactFeedbackGenerator`) :
   - tap carte-réponse : `.medium` ; toggle écoute : `.light` ; nouvelle suggestion : `.soft` (option).
   - JS : `hapticTap('medium')` best-effort (no-op hors bridge).
2. Apparition cartes : stagger spring (cf. Motion). Changement de locuteur détecté : le chip voix
   fait un léger pulse accent (pas de toast systématique — réserver les toasts aux erreurs).
3. TTS en cours : la carte parlée s'illumine (`--accent-dim`), les autres passent à opacity 0.55.
   L'overlay TTS actuel devient une fine barre de progression accent (2px) en haut de la carte.

## F. Accessibilité SLA (non négociable)

- Cibles ≥ 44×44 ; gap ≥ 12px entre cibles adjacentes.
- Contraste AA vérifié sur tous les tokens ci-dessus (accent recalibré pour ça).
- Dynamic type : tout en rem, le réglage % existant continue de fonctionner.
- `prefers-reduced-motion` : conservé. Aria-labels existants : conservés (icônes → `aria-label`).
- Aucune fonctionnalité accessible uniquement par swipe/appui long : le flag passe en appui long
  MAIS reste dans le menu Réglages > Signaler (fallback visible).

## G. Plan d'implémentation (ordre, chaque étape buildable/testable)

1. **Tokens + typo** : remplacer `:root`/dark/light/OLED + `--font` système. Purge des anciennes
   variables glass si inutilisées. (Risque faible, tout re-skin.)
2. **Icônes** : injecter le set SVG inline (sprite `<symbol>`), remplacer tous les emojis du chrome
   (chips, soundboard par défaut, boutons bas, états vides, TTS bar).
3. **Status row** : supprimer header logo ; listening chip + voice chip + gear ; retirer les pills
   ton/vitesse de l'écran (déplacées dans sheet) ; adapter `renderVoiceControls`.
4. **Transcript sans boîte** : restyler `.context-zone` (transparent, pas de bordure), états
   1-à-1/interim/groupe/vide ; garder `has-thread`.
5. **Cartes + états TTS + skeleton + vide** ; flag → appui long.
6. **Bottom bar + quick phrases**.
7. **Sheets** (locuteurs avec rename, voix ton/vitesse) au style natif (grabber, liste, radius 26).
8. **Swift** : handler `haptic` dans WebAppView + `UIImpactFeedbackGenerator`.
9. **QA visuelle** : servir `Resources/web` en local (config launch.json `talkie-web` existante),
   screenshots mobile 4 états × dark/light, vérifier contrastes (preview_inspect), `node --check`
   sur le script inline, build device.

### Contraintes techniques
- WKWebView iOS 26 : `-webkit-backdrop-filter` requis en plus de `backdrop-filter`.
- Ne pas renommer les IDs : `listeningBar listeningText contextText contextLabel speakerThread
  suggestionsZone aiAttribution soundboardScroll tablePill speakerPill tonePill speedPill…`
  (si un élément disparaît de l'écran, garder l'ID dans le sheet ou no-op les references JS).
- Le splash et l'onboarding gardent le branding (c'est LEUR rôle) — seul l'écran principal se
  débrande.
- `getLangCode`/i18n : tous les nouveaux libellés passent par `t()` (fr/en).

## H. Definition of done

- [ ] Zéro emoji dans le chrome (grep visuel sur l'écran principal).
- [ ] Police système partout (inspect `font-family` → -apple-system).
- [ ] 1 seule teinte accent + vert réservé à l'écoute.
- [ ] 3 cartes visibles entières avec des réponses moyennes ; jamais de texte coupé.
- [ ] Cycle conversation complet sans toucher l'UI (écoute → suggestions → tap → TTS → réécoute).
- [ ] AA sur texte des cartes, transcript, chips (dark ET light).
- [ ] Haptic au tap de carte sur device.
- [ ] Screenshots avant/après 4 états joints à la PR.
