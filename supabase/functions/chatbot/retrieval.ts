// Local lexical search over the bundled KB_DATA — no embeddings, no vector
// DB. Faithful port of chatbot/server/retrieval.js's chunking/scoring logic,
// reading from the inlined kb_data.ts constants instead of the filesystem
// (Edge Functions don't reliably support reading arbitrary sibling files at
// runtime — see kb_data.ts's header comment).

import { KB_DATA } from "./kb_data.ts";
import { SYNONYMS } from "./synonyms_data.ts";

const STOPWORDS = new Set([
  "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
  "do", "does", "did", "how", "what", "when", "where", "why", "who",
  "to", "of", "in", "on", "for", "and", "or", "but", "with", "as",
  "it", "its", "this", "that", "these", "those", "i", "you", "we",
  "can", "could", "should", "would", "will", "my", "me",
  "at", "by", "from", "about", "into", "if", "so",
]);

export type Chunk = { source: string; heading: string | null; text: string };
export type ScoredChunk = Chunk & { score: number; matchedTerms: number };
export type SearchResult = { confident: boolean; matches: (Chunk & { score: number })[] };

function tokenize(text: string): string[] {
  return (text.toLowerCase().match(/[a-z0-9]+/g) || []).filter(
    (w) => w.length > 1 && !STOPWORDS.has(w),
  );
}

function expandWithSynonyms(terms: string[]): string[] {
  const expanded = new Set(terms);
  for (const t of terms) {
    (SYNONYMS[t] || []).forEach((s) => expanded.add(s));
  }
  return [...expanded];
}

// Splits one markdown file's text into chunks by `##` heading. Content
// before the first `##` (typically the `#` title + intro) becomes its own
// chunk with heading = the `#` title if present, else null.
function chunkMarkdown(text: string, filename: string): Chunk[] {
  const lines = text.split("\n");
  const chunks: { heading: string | null; body: string[] }[] = [];
  let current: { heading: string | null; body: string[] } = { heading: null, body: [] };
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

  return chunks
    .map((c) => ({ source: filename, heading: c.heading, text: c.body.join("\n").trim() }))
    .filter((c) => c.text || c.heading);
}

// Loads and chunks every bundled .md "file" for a tier.
function loadTierChunks(tier: string): Chunk[] {
  const files = KB_DATA[tier];
  if (!files) return [];
  const chunks: Chunk[] = [];
  for (const [filename, text] of Object.entries(files)) {
    chunks.push(...chunkMarkdown(text, filename));
  }
  return chunks;
}

// Scores one chunk against the query terms. Heading matches count more than
// body matches; an exact-phrase substring match adds a flat boost on top.
function scoreChunk(chunk: Chunk, queryTerms: string[], rawQueryLower: string): { score: number; matchedTerms: number } {
  const headingLower = (chunk.heading || "").toLowerCase();
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

// Returns { confident, matches }. `matches` is capped to the top 3 chunks.
// Fewer than 2 matched terms on the best chunk means "no confident local
// match" — weak matches are still returned so the caller can show them
// alongside the escalation prompt, per the original design.
export function search(tier: string, query: string): SearchResult {
  const chunks = loadTierChunks(tier);
  const rawQueryLower = query.trim().toLowerCase();
  const terms = expandWithSynonyms(tokenize(query));

  if (!terms.length) {
    return { confident: false, matches: [] };
  }

  const scored: ScoredChunk[] = chunks
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
