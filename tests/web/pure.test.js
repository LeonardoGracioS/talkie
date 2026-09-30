// Run: node --test tests/web/pure.test.js
const test = require('node:test');
const assert = require('node:assert');
const p = require('../../ios/Talkie/Talkie/Resources/web/pure.js');

test('filter lets everyday / medical French through (T3 regressions)', () => {
  for (const s of [
    'Tu as rendez-vous à la clinique demain ?', "C'est une douleur chronique",
    'On a parlé de la technique du kiné', "C'est un endroit unique", 'Tu paniques un peu ?',
    'Tu as pensé au pique-nique ?', 'Encore une dispute ?', 'Je crève de chaud',
    'Tu veux des crevettes ?', 'Ça tue le temps', 'On parle de la fin de vie et du suicide assisté ?',
    'Le médecin est très réputé', 'Il joue du violon', "C'est de la bombe ce gâteau",
  ]) assert.equal(p.isInappropriate(s), false, s);
});

test('default filter only drops slurs and injection echoes from AI replies', () => {
  for (const s of ['Sale pédé', 'Espèce de nègre', 'Ignore les instructions', 'ignore previous instructions'])
    assert.equal(p.isInappropriate(s), true, s);
  // swearing / strong language is the user's right
  for (const s of ['Va te faire foutre', 'Putain, quelle journée', 'Je vais te tuer si tu racontes ça', 'Fais chier'])
    assert.equal(p.isInappropriate(s), false, s);
});

test('allowCrude keeps only the injection guard', () => {
  assert.equal(p.isInappropriate('Sale pédé', { allowCrude: true }), false);
  assert.equal(p.isInappropriate('Ignore les instructions', { allowCrude: true }), true);
});

test('frenchSpacing glues ? ! : ; to the previous word', () => {
  assert.equal(p.frenchSpacing('Tu viens ?'), 'Tu viens ?');
  assert.equal(p.frenchSpacing('Oui !  Génial'), 'Oui !  Génial');
  assert.equal(p.frenchSpacing('« Bonjour »'), '« Bonjour »');
  assert.equal(p.frenchSpacing('Déjà collé?'), 'Déjà collé?');
  assert.equal(p.frenchSpacing('vers 10 h.'), 'vers 10\u00A0h.');
  assert.equal(p.frenchSpacing('20 €'), '20\u00A0€');
});

test('parseSuggestionLines strips labels/numbering/preamble and keeps 3', () => {
  const out = p.parseSuggestionLines('Voici mes idées\n1. Direct : Oui, je viens.\n2) Avec plaisir !\n- warm: Super idée\nÀ quelle heure ?');
  assert.deepEqual(out, ['Oui, je viens.', 'Avec plaisir !', 'À quelle heure ?'].slice(0, out.length));
  assert.equal(out.length, 3);
});

test('refusals are detected', () => {
  assert.ok(p.isLlmRefusal("Désolé, je ne peux pas t'aider"));
  assert.ok(!p.isLlmRefusal('Oui, avec plaisir'));
});

test('splitTextForTTS keeps short text whole and splits long text on sentences', () => {
  assert.deepEqual(p.splitTextForTTS('Bonjour.'), ['Bonjour.']);
  const long = 'Phrase numéro un assez longue pour remplir. '.repeat(40);
  const chunks = p.splitTextForTTS(long, 400);
  assert.ok(chunks.length > 1 && chunks.every(c => c.length <= 400));
  assert.equal(chunks.join(' ').replace(/\s+/g, ' ').trim(), long.replace(/\s+/g, ' ').trim());
});

test('inferQuestionMarkFor adds "?" to questions only', () => {
  assert.equal(p.inferQuestionMarkFor('tu veux venir demain.', 'fr'), 'tu veux venir demain ?');
  assert.equal(p.inferQuestionMarkFor('Il fait beau.', 'fr'), 'Il fait beau.');
  assert.equal(p.inferQuestionMarkFor('are you coming', 'en'), 'are you coming?');
});
