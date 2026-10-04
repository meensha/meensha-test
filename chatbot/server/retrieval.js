// Local lexical search over chatbot/kb/<tier>/*.md — no embeddings, no
// vector DB. The corpus is a few dozen markdown files; this keeps the local
// path fully deterministic (it can only ever return text that's already in
// the curated, human-reviewed docs, never something generated).

const fs = require('fs');
const path = require('path');
const { KB_DIR } = require('./config');

let synonyms = {};
try {
  synonyms = JSON.parse(fs.readFileSync(path.join(__dirname, 'synonyms.json'), 'utf8'));
} catch {
  synonyms = {};
}

const STOPWORDS = new Set([
  'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
  'do', 'does', 'did', 'how', 'what', 'when', 'where', 'why', 'who',
  'to', 'of', 'in', 'on', 'for', 'and', 'or', 'but', 'with', 'as',
  'it', 'its', 'this', 'that', 'these', 'those', 'i', 'you', 'we',
  'can', 'could', 'should', 'would', 'will', 'my', 'me',
  'at', 'by', 'from', 'about', 'into', 'if', 'so',
]);

// Lowercase, strip punctuation, split on whitespace, drop stopwords/empties.
function tokenize(text) {
  return (text.toLowerCase().match(/[a-z0-9]+/g) || []).filter(
    (w) => w.length > 1 && !STOPWORDS.has(w)
  );
}

// Expands a token list with the hand-maintained synonym map, so e.g. a
// question using "scan" also matches chunks that only say "coupon"/"voucher".
function expandWithSynonyms(terms) {
  const expanded = new Set(terms);
  for (const t of terms) {
    (synonyms[t] || []).forEach((s) => expanded.add(s));
  }
  return [...expanded];
}

// Splits one markdown file's text into chunks by `##` heading. Content
// before the first `##` (typically the `#` title + intro) becomes its own
// chunk with heading = the `#` title if present, else null.
function chunkMarkdown(text, filename) {
  const lines = text.split('\n');
  const chunks = [];
  let current = { heading: null, body: [] };
  let sawH1 = false;

  for (const line of lines) {
    const h2 = line.match(/^##\s+(.*)/);
    const h1 = line.match(/^#\s+(.*)/);
    if (h2) {
      if (current.body.length || current.heading) chunks.push(current);
      current = { heading: h2[1].trim(), body: [] };
    } else if (h1 && !sawH1 && !current.heading) {
      current.heading = h1[1].trim();
      sawH1 = true;
    } else {
      current.body.push(line);
    }
  }
  if (current.body.length || current.heading) chunks.push(current);

  return chunks.map((c) => ({
    source: filename,
    heading: c.heading,
    text: c.body.join('\n').trim(),
  })).filter((c) => c.text || c.heading);
}

// Loads and chunks every .md file in kb/<tier>/. Called fresh per request —
// the corpus is small, no caching complexity needed (per the plan).
function loadTierChunks(tier) {
  const dir = path.join(KB_DIR, tier);
  let files = [];
  try {
    files = fs.readdirSync(dir).filter((f) => f.endsWith('.md'));
  } catch {
    return [];
  }

  const chunks = [];
  for (const file of files) {
    const text = fs.readFileSync(path.join(dir, file), 'utf8');
    chunks.push(...chunkMarkdown(text, file));
  }
  return chunks;
}

// Scores one chunk against the query terms. Heading matches count more than
// body matches; an exact-phrase substring match (the raw query, not just its
// terms) adds a flat boost on top.
function scoreChunk(chunk, queryTerms, rawQueryLower) {
  const headingLower = (chunk.heading || '').toLowerCase();
  const bodyLower = chunk.text.toLowerCase();
  let score = 0;
  let matchedTerms = 0;

  for (const term of queryTerms) {
    let hit = false;
    if (headingLower.includes(term)) {
      score += 3;
      hit = true;
    }
    if (bodyLower.includes(term)) {
      score += 1;
      hit = true;
    }
    if (hit) matchedTerms += 1;
  }

  if (rawQueryLower.length > 3 && (headingLower.includes(rawQueryLower) || bodyLower.includes(rawQueryLower))) {
    score += 5;
  }

  return { score, matchedTerms };
}

const MIN_MATCHED_TERMS = 2;

// Returns { confident: bool, matches: [{source, heading, text, score}] }.
// `matches` is capped to the top 3 chunks when confident; when not
// confident, returns whatever weak matches exist anyway (caller decides
// whether to show them alongside the escalation prompt), per the plan's
// "no confident match" UX.
function search(tier, query) {
  const chunks = loadTierChunks(tier);
  const rawQueryLower = query.trim().toLowerCase();
  const terms = expandWithSynonyms(tokenize(query));

  if (!terms.length) {
    return { confident: false, matches: [] };
  }

  const scored = chunks
    .map((c) => ({ ...c, ...scoreChunk(c, terms, rawQueryLower) }))
    .filter((c) => c.score > 0)
    .sort((a, b) => b.score - a.score);

  const best = scored[0];
  const confident = !!best && best.matchedTerms >= MIN_MATCHED_TERMS;

  return {
    confident,
    matches: scored.slice(0, 3).map((c) => ({
      source: c.source,
      heading: c.heading,
      text: c.text,
      score: c.score,
    })),
  };
}

module.exports = { search, loadTierChunks, chunkMarkdown, tokenize };
