// Pure helpers (no DOM, no globals) — loaded by index.html, unit-tested by
// tests/web/pure.test.js under node. Keep them side-effect free.

// ─── Content filter — applied to AI-GENERATED replies only ───
// What the user hears, types, or picks from quick phrases / history is never
// filtered: an adult has the right to swear. By default we only drop hateful
// slurs and prompt-injection echoes from what the AI *proposes*; with
// { allowCrude: true } (setting "Langage familier / cru") only injection echoes.
// Whole-word, Unicode-aware matching (the old substring filter blocked
// "clinique", "chronique", "dispute", "pique-nique"…).
const _W = '(?<![\\p{L}\\p{N}])';   // word start
const _E = '(?![\\p{L}\\p{N}])';    // word end
const _slurs = [
  'nègres?', 'pédés?', 'tapettes?', 'gouines?', 'bougnoules?', 'youpins?', 'négros?',
  'niggers?', 'faggots?', 'sous-races?', 'race inférieure',
];
const _slurRe = new RegExp(_W + '(?:' + _slurs.join('|') + ')' + _E, 'iu');
const _injectionPatterns = [
  /ignore\s+(tes|les|vos)\s+(instructions|consignes|règles)/i,
  /oublie\s+(tes|les)\s+(instructions|règles|consignes)/i,
  /ignore\s+(?:all\s+|your\s+)?(?:previous\s+)?instructions/i,
  /system\s*prompt/i,
];

function isInappropriate(text, opts) {
  const s = String(text || '');
  if (_injectionPatterns.some(re => re.test(s))) return true;
  if (opts && opts.allowCrude) return false;
  return _slurRe.test(s);
}

/** French typography for DISPLAY: narrow no-break space before ? ! : ; and inside
 *  « » so a lone "?" never wraps onto its own line. */
function frenchSpacing(text) {
  return String(text || '')
    .replace(/\s+([?!:;\u00BB])/g, '\u202F$1')
    .replace(/\u00AB\s+/g, '\u00AB\u202F')
    // keep numbers with their unit ("10 h", "5 min", "20 €")
    .replace(/(\d)\s+(h|min|s|\u20AC|%|km|kg|ans?|heures?|euros?)(?![\p{L}])/gu, '$1\u00A0$2');
}

const _LLM_REFUSAL_RE = /(désolé|desole|je ne peux pas|en tant qu'?ia|en tant qu'?assistant|sorry|i can't help|i cannot help|as an ai|as a language model|i'm unable|i am unable|not able to help)/i;

function isLlmRefusal(text) {
  if (!text || typeof text !== 'string') return true;
  return _LLM_REFUSAL_RE.test(text);
}

function parseSuggestionLines(content, opts) {
  const _preambleRe = /^(voici|here are|suggestions?|réponses?|options?|bien sûr|sure|ok|d'accord|super|je suis prêt|i'm ready|désolé|sorry)/i;
  const _labelRe = /^(directe?|warm|chaleureux|pragmatique|sociale|émotive|émotiv|relance|followup|follow.?up|nuance|autre|option\s*\d|social|emotive)\s*[:–—-]\s*/i;
  const MAX_WORDS = 14;
  function trimToOneIdea(s) {
    const m = s.match(/^(.+?[.!?…])(\s|$)/);
    const first = m ? m[1] : s;
    const words = first.split(/\s+/);
    if (words.length <= MAX_WORDS) return first.trim();
    return words.slice(0, MAX_WORDS).join(' ').replace(/[,;:\-—]\s*$/, '') + '…';
  }
  return content.split('\n')
    .map(s => s.replace(/^\s*(?:\d+[\.\):\-]|[-•*–])\s*/, '').replace(/^["«]|["»]$/g, '').trim())
    .map(s => s.replace(_labelRe, '').trim())
    .filter(s => s.length > 2 && !isInappropriate(s, opts) && !_preambleRe.test(s) && !isLlmRefusal(s))
    .map(trimToOneIdea)
    .filter(s => s.length > 1)
    .slice(0, 3);
}

/** Découpe un texte long aux limites de phrase pour fiabiliser AVSpeech / Web Speech / ElevenLabs. */
function splitTextForTTS(text, maxLen = 900) {
  const normalized = String(text || '').replace(/\s+/g, ' ').trim();
  if (!normalized) return [];
  if (normalized.length <= maxLen) return [normalized];

  const chunks = [];
  let remaining = normalized;
  while (remaining.length > maxLen) {
    const window = remaining.slice(0, maxLen);
    let splitAt = -1;
    const punctIdx = window.search(/[.!?…](?:\s|$)/);
    if (punctIdx >= Math.floor(maxLen * 0.35)) {
      splitAt = punctIdx + 1;
      while (splitAt < window.length && /\s/.test(window[splitAt])) splitAt++;
    } else {
      const clauseIdx = window.search(/[,;:](?:\s|$)/);
      if (clauseIdx >= Math.floor(maxLen * 0.35)) {
        splitAt = clauseIdx + 1;
        while (splitAt < window.length && /\s/.test(window[splitAt])) splitAt++;
      } else {
        splitAt = window.lastIndexOf(' ');
        if (splitAt < Math.floor(maxLen * 0.25)) splitAt = maxLen;
      }
    }
    const piece = remaining.slice(0, splitAt).trim();
    if (piece) chunks.push(piece);
    remaining = remaining.slice(splitAt).trim();
  }
  if (remaining) chunks.push(remaining);
  return chunks.length ? chunks : [normalized.slice(0, maxLen)];
}

// ─── Punctuation post-processing ───
function inferQuestionMarkFor(text, lang) {
  if (/[?!]$/.test(text)) return text;
  // Strip trailing period — Speech API often adds one even for questions
  const cleaned = text.replace(/\.\s*$/, '').trim();
  const lower = cleaned.toLowerCase();
  const frQ = /^(est[-\s]ce qu|qu[''\u2019]est[-\s]ce qu|comment|pourquoi|quand|o[uù]\s|qui\s|que\s|quel|quelle|quels|quelles|combien|ça va|c[''\u2019]est vrai|tu vas|tu veux|tu peux|tu crois|tu penses|vous voulez|vous pouvez|vous pensez|y a[-\s]t[-\s]il|as[-\s]tu|avez[-\s]vous|es[-\s]tu|êtes[-\s]vous|on va|on peut)/i;
  const frEnd = /(n[''\u2019]est[-\s]ce pas|non|hein|d[''\u2019]accord|ou pas|ou quoi)$/i;
  const enQ = /^(is |are |was |were |do |does |did |will |would |could |can |should |shall |have |has |had |how |what |when |where |who |whom |which |why |whose )/i;
  if (lang === 'fr' && (frQ.test(lower) || frEnd.test(lower))) return cleaned + ' ?';
  if (lang === 'en' && enQ.test(lower)) return cleaned + '?';
  return text;
}

if (typeof module !== 'undefined') {
  module.exports = { isInappropriate, frenchSpacing, isLlmRefusal, parseSuggestionLines, splitTextForTTS, inferQuestionMarkFor };
}
