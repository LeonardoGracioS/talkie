# Talkie 4.1 (build 30) — kit de publication

Build envoyé à App Store Connect le 2026-11-03 : **4.1 (30)**. Les builds 26 à 29 sont des étapes TestFlight, à ignorer (le 28 n'a pas le correctif haut-parleur).
Captures d'écran : inchangées (celles de la 4.0).
Politique de confidentialité : mise à jour pour les textes préparés et les sauvegardes (`docs/privacy*.html`, copie in-app dans `Resources/web/legal/`).

---

## TestFlight — « What to Test »

**FR**
Talkie 4.1 — merci de tester :
- Avec des aides auditives ou des AirPods connectés : la voix de Talkie doit sortir du haut-parleur de l'iPhone.
- Le volume de la voix, surtout en mode Groupe.
- « Textes » (barre du bas) : écrivez un texte, un passage par ligne, puis lisez-le passage par passage.
- Les réponses restent affichées le temps de les lire ; « Nouvelle phrase » apparaît quand l'interlocuteur a reparlé.
- Voix ElevenLabs : nouveau modèle (Eleven v4).

**EN**
Talkie 4.1 — please test:
- With hearing aids or AirPods connected: Talkie's voice should come out of the iPhone speaker.
- Voice volume, especially in Group mode.
- "Texts" (bottom bar): write a text, one passage per line, then read it passage by passage.
- Replies stay on screen long enough to read them; "New phrase" appears when the other person spoke again.
- ElevenLabs voice: new model (Eleven v4).

---

## App Store — Nouveautés de la version 4.1

**FR**
• Toujours entendu : la voix de Talkie sort du haut-parleur de l'iPhone, même quand des aides auditives ou des AirPods sont connectés.
• Une voix plus forte, y compris en mode Groupe.
• Nouveau : « Textes ». Écrivez à l'avance une présentation, une prière ou un discours, puis lisez-le passage par passage d'un simple tap.
• Les réponses proposées restent affichées le temps de les lire ; les nouvelles phrases attendent leur tour.
• En tête-à-tête : plus de faux interlocuteurs « Voix 2 ».
• Voix clonée ElevenLabs : nouveau modèle, plus naturel et plus expressif.

**EN**
• Always heard: Talkie's voice comes out of the iPhone speaker, even when hearing aids or AirPods are connected.
• A louder voice, including in Group mode.
• New: "Texts". Write a presentation, a prayer or a speech in advance, then read it passage by passage with a single tap.
• Suggested replies stay on screen long enough to read them; new phrases wait their turn.
• One-on-one: no more ghost "Voice 2" speakers.
• ElevenLabs cloned voice: new model, more natural and more expressive.

---

## Description — changements

**FR** : retirer « NOUVEAU : » du titre « LES CONVERSATIONS À PLUSIEURS » et « (nouveau) » du mode Groupe ; ajouter dans FONCTIONNALITÉS :
• Textes préparés : écrivez à l'avance ce que vous voulez dire et lisez-le passage par passage (nouveau)
• Toujours entendu : la voix sort du haut-parleur de l'iPhone, même avec des aides auditives (nouveau)

**EN** : same changes —
• Prepared texts: write what you want to say in advance and read it passage by passage (new)
• Always heard: the voice comes out of the iPhone speaker, even with hearing aids (new)

Texte promotionnel : inchangé.

---

## Notes pour la validation Apple — ajout en tête

NEW IN 4.1: Talkie's speech always plays on the iPhone built-in speaker (even with hearing aids or AirPods connected), so people in the room hear it. New "Texts" screen: the user writes passages in advance and taps to have them spoken; texts are stored only on the device. The optional ElevenLabs voice (user's own API key, off by default) now uses the eleven_v4 model.

---

## Checklist App Store Connect

1. TestFlight ▸ build 4.1 (30) : conformité à l'export → chiffrement exempté (HTTPS uniquement).
2. Distribution ▸ « + » version **4.1** : nouveautés FR + 4 localisations EN, description, notes de validation, sélectionner le build 30.
3. Publier les pages `docs/privacy*.html` et `docs/support*.html` sur le site GitHub Pages (`talkie-support`).
4. Confidentialité de l'app (étiquettes) : inchangée — les textes restent sur l'appareil.
5. Ne PAS cliquer sur « Soumettre pour vérification » sans le feu vert de Samuel.
