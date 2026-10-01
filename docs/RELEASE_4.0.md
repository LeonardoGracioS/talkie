# Talkie 4.0 (build 25) — kit de publication

Build envoyé à App Store Connect le 2026-10-01 : **4.0 (25)**. Les builds 23 et 24 sont des étapes intermédiaires, à ignorer.
Captures d'écran : `app_Talkie/AppStore_Screenshots_v4/` (1320×2868, emplacement « iPhone 6,9" »). 5 FR (`fr_0*.png`) et 5 EN (`en_0*.png`), dans l'ordre 01→05.
Politique de confidentialité mise à jour et publiée : https://leonardogracios.github.io/talkie-support/privacy.html

---

## TestFlight — « What to Test »

**FR**
Talkie 4.0 — merci de tester :
- Le mode « Groupe » : à plusieurs autour d'une table, chacun parle à tour de rôle. Talkie doit reconnaître qui parle, sans créer de faux interlocuteurs. Touchez « Voix 2 » dans le fil pour dire qui c'est.
- Les grandes cartes de réponse, les phrases rapides et « Talkie parle… » pendant la lecture.
- L'écoute démarre maintenant à l'ouverture (désactivable dans Réglages).
- En appel (téléphone, FaceTime, Teams…) : touchez une phrase. Votre correspondant doit l'entendre.
- Réglages : « Effacer tous les interlocuteurs », « Langage familier / cru », « Personnaliser les suggestions ».
Signalez tout souci via Réglages ▸ Signaler un problème.

**EN**
Talkie 4.0 — please test:
- "Group" mode: several people around a table taking turns. Talkie should recognize who is speaking without creating ghost speakers. Tap "Voice 2" in the thread to say who it is.
- The bigger reply cards, quick phrases, and "Talkie is speaking…" during playback.
- Listening now starts when the app opens (can be turned off in Settings).
- On a call (phone, FaceTime, Teams…): tap a phrase. The other person should hear it.
- Settings: "Delete all speakers", "Casual / crude language", "Personalize suggestions".
Report issues via Settings ▸ Report an issue.

---

## App Store — Nouveautés de la version 4.0

**FR**
Talkie 4.0 est une refonte majeure.
• Mode Groupe repensé : Talkie reconnaît qui parle autour de la table, se souvient des voix d'une fois sur l'autre, et vous laisse dire « c'est Marie » d'un geste.
• Des suggestions plus personnelles : votre profil, vos proches et la conversation en cours guident les réponses.
• Des réponses plus grandes et plus faciles à toucher, une grille de phrases rapides toujours visible.
• L'écoute démarre dès l'ouverture, et ne s'arrête plus en cas d'interruption ou de changement d'écouteurs.
• En appel : une grille de phrases claire, entendues par votre correspondant.
• Votre voix clonée est maintenant accessible directement dans les réglages.
• Option « Langage familier » : c'est vous qui choisissez vos mots.
• Nombreuses corrections de fiabilité et de confidentialité.

**EN**
Talkie 4.0 is a major redesign.
• Rebuilt Group mode: Talkie recognizes who is speaking around the table, remembers voices between sessions, and lets you say "that's Marie" with one tap.
• More personal suggestions: your profile, your loved ones and the ongoing conversation guide the replies.
• Bigger, easier-to-tap replies and an always-visible grid of quick phrases.
• Listening starts as soon as the app opens, and keeps going through interruptions or headphone changes.
• On calls: a clear phrase pad, heard by the other person.
• Your cloned voice is now directly available in Settings.
• "Casual language" option: you choose your own words.
• Many reliability and privacy fixes.

---

## Texte promotionnel (170 caractères max)

**FR** : Répondez d'un simple tap, avec votre voix. Talkie écoute la conversation, reconnaît qui parle et vous propose des réponses prêtes à dire. (139 caractères)

**EN** : Reply with a single tap, in your own voice. Talkie listens, recognizes who is speaking and suggests replies ready to say. (121 caractères)

---

## Notes pour la validation Apple (App Review)

Talkie is an AAC (augmentative and alternative communication) app for people who cannot speak (ALS, aphasia).
- Speech recognition (SpeechTranscriber) and reply suggestions (Apple Foundation Models) run on-device.
- Speaker recognition uses on-device voice embeddings (FluidAudio CoreML). They are never transmitted, and the user can delete them in Settings.
- Optional services, off by default, each behind explicit consent and the user's own API key: ElevenLabs (voice cloning / TTS) and Anthropic Claude (cloud suggestions). Both are disclosed in the in-app privacy policy.
- During phone/FaceTime calls the app uses iOS 18.2+ microphone injection to add the user's chosen phrases to the call. It never listens to the call.
- To try it: open the app, allow microphone + speech recognition, and speak near the device. Three reply cards appear. Tap one to hear it.

---

## Checklist App Store Connect

1. TestFlight ▸ build 4.0 (25) : conformité à l'export → « Aucun chiffrement » / chiffrement exempté (HTTPS uniquement). Ajouter le build aux groupes de test et coller « What to Test ».
2. Distribution ▸ « + » version **4.0** : nouveautés FR/EN, texte promotionnel FR/EN, captures 6,9" FR/EN (remplacer les anciennes), sélectionner le build 25, notes de validation.
3. Confidentialité de l'app (étiquettes « nutrition ») : inchangées. Les empreintes vocales ne quittent pas l'appareil, donc ce ne sont pas des données « collectées » au sens d'Apple. L'envoi optionnel vers Anthropic et ElevenLabs passe par la clé API de l'utilisateur. Revoir seulement si l'étiquette actuelle déclare « aucune donnée collectée » et omet les envois optionnels de contenu utilisateur (« Other User Content »).
4. Ne PAS cliquer sur « Soumettre pour vérification » sans le feu vert de Samuel.
