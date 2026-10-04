// Chatbot frontend logic: NO login of its own — this page is only ever
// opened from somewhere that already has a valid Supabase admin session
// (currently: admin.html's Help Guide, see openHelpGuide() there), which
// hands it a session_token via the URL fragment (`#session_token=...`, not
// a query string — a fragment is never sent to the server or logged there,
// unlike `?session_token=...`). If no token shows up this way, there is no
// fallback login form; the page just says so and stops.
//
// Chat UI, local-match vs. escalation UX, and the markdown->HTML conversion
// needed to render KB answers (including mermaid blocks) below.

let sessionToken = null;

function getTokenFromHash() {
  const hash = window.location.hash.replace(/^#/, '');
  const params = new URLSearchParams(hash);
  return params.get('session_token');
}

// ---------- Markdown -> HTML ----------
// Handles the subset of markdown actually used in chatbot/kb/: headings
// (# ## ###), bold (**text**), inline `code`, fenced code blocks (``` and
// ```mermaid specifically), ordered/unordered lists, simple pipe tables, and
// plain paragraphs. Not a full markdown parser — deliberately scoped to what
// the curated docs use.

function escapeHtml(s) {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

// Inline formatting: bold + inline code. Applied after escaping, so **/`
// markers themselves are safe to match literally.
function renderInline(text) {
  let html = escapeHtml(text);
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  return html;
}

function isTableSeparator(line) {
  return /^\s*\|?[\s:|-]+\|?\s*$/.test(line) && line.includes('-');
}

function splitTableRow(line) {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
}

function markdownToHtml(md) {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const out = [];
  let i = 0;
  let listBuffer = null; // { type: 'ul'|'ol', items: [] }

  function flushList() {
    if (!listBuffer) return;
    const tag = listBuffer.type;
    out.push(`<${tag}>` + listBuffer.items.map((it) => `<li>${renderInline(it)}</li>`).join('') + `</${tag}>`);
    listBuffer = null;
  }

  while (i < lines.length) {
    const line = lines[i];

    // Fenced code block (``` or ```mermaid). Mermaid blocks become
    // <pre class="mermaid"> so app.js can call mermaid.run() on them;
    // anything else becomes a plain <pre><code>.
    const fenceMatch = line.match(/^```\s*(\w+)?\s*$/);
    if (fenceMatch) {
      flushList();
      const lang = (fenceMatch[1] || '').toLowerCase();
      const body = [];
      i += 1;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        body.push(lines[i]);
        i += 1;
      }
      i += 1; // skip closing fence
      const raw = body.join('\n');
      if (lang === 'mermaid') {
        out.push(`<pre class="mermaid">${escapeHtml(raw)}</pre>`);
      } else {
        out.push(`<pre><code>${escapeHtml(raw)}</code></pre>`);
      }
      continue;
    }

    // Heading
    const headingMatch = line.match(/^(#{1,3})\s+(.*)/);
    if (headingMatch) {
      flushList();
      const level = headingMatch[1].length;
      out.push(`<h${level}>${renderInline(headingMatch[2])}</h${level}>`);
      i += 1;
      continue;
    }

    // Table: a row starting with | immediately followed by a separator row.
    if (line.trim().startsWith('|') && lines[i + 1] && isTableSeparator(lines[i + 1])) {
      flushList();
      const header = splitTableRow(line);
      i += 2; // skip header + separator
      const rows = [];
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.push(splitTableRow(lines[i]));
        i += 1;
      }
      let table = '<table><thead><tr>' + header.map((h) => `<th>${renderInline(h)}</th>`).join('') + '</tr></thead><tbody>';
      for (const r of rows) {
        table += '<tr>' + r.map((c) => `<td>${renderInline(c)}</td>`).join('') + '</tr>';
      }
      table += '</tbody></table>';
      out.push(table);
      continue;
    }

    // Ordered list item
    const olMatch = line.match(/^\s*\d+\.\s+(.*)/);
    if (olMatch) {
      if (!listBuffer || listBuffer.type !== 'ol') {
        flushList();
        listBuffer = { type: 'ol', items: [] };
      }
      listBuffer.items.push(olMatch[1]);
      i += 1;
      continue;
    }

    // Unordered list item (- or *), including indented sub-bullets — kept
    // flat (one level) since the KB docs don't nest deeper than that.
    const ulMatch = line.match(/^\s*[-*]\s+(.*)/);
    if (ulMatch) {
      if (!listBuffer || listBuffer.type !== 'ul') {
        flushList();
        listBuffer = { type: 'ul', items: [] };
      }
      listBuffer.items.push(ulMatch[1]);
      i += 1;
      continue;
    }

    // Blank line: ends the current list/paragraph
    if (!line.trim()) {
      flushList();
      i += 1;
      continue;
    }

    // Paragraph: accumulate consecutive non-blank, non-special lines.
    flushList();
    const para = [line];
    i += 1;
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^#{1,3}\s/.test(lines[i]) &&
      !/^```/.test(lines[i]) &&
      !/^\s*\d+\.\s+/.test(lines[i]) &&
      !/^\s*[-*]\s+/.test(lines[i]) &&
      !lines[i].trim().startsWith('|')
    ) {
      para.push(lines[i]);
      i += 1;
    }
    out.push(`<p>${renderInline(para.join(' '))}</p>`);
  }
  flushList();
  return out.join('\n');
}

// ---------- Session (no login UI — token only ever arrives via the hash) ----------

function initSession() {
  const fromHash = getTokenFromHash();
  if (fromHash) {
    sessionToken = fromHash;
    // Drop it from the visible URL/history immediately — it's already read
    // into memory, no reason to leave it sitting in the address bar.
    history.replaceState(null, '', window.location.pathname);
  }

  if (!sessionToken) {
    document.getElementById('no-session-view').style.display = '';
    document.getElementById('chat-view').style.display = 'none';
    return;
  }

  document.getElementById('no-session-view').style.display = 'none';
  document.getElementById('chat-view').style.display = '';
}

// ---------- Chat ----------

let lastQuestion = '';
let lastWeakSnippet = '';

function addMessage(html, cls) {
  const log = document.getElementById('chat-log');
  const div = document.createElement('div');
  div.className = `msg ${cls || ''}`;
  div.innerHTML = html;
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
  if (window.mermaid) {
    try {
      window.mermaid.run({ nodes: div.querySelectorAll('pre.mermaid') });
    } catch (e) {
      console.error('mermaid render error', e);
    }
  }
}

async function askQuestion() {
  const input = document.getElementById('chat-input');
  const question = input.value.trim();
  if (!question) return;
  input.value = '';
  lastQuestion = question;
  lastWeakSnippet = '';

  addMessage(escapeHtml(question), 'user');

  let result;
  try {
    const r = await fetch('/api/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-admin-session': sessionToken },
      body: JSON.stringify({ question }),
    });
    if (r.status === 401) {
      addMessage('Your session has expired — close this and reopen it from the Help link.', 'bot error');
      return;
    }
    result = await r.json();
  } catch {
    addMessage('Could not reach the chatbot server.', 'bot error');
    return;
  }

  if (result.confident && result.matches.length) {
    for (const m of result.matches) {
      addMessage(
        markdownToHtml(m.text) + `<div class="source">Source: ${escapeHtml(m.source)}${m.heading ? ' — ' + escapeHtml(m.heading) : ''}</div>`,
        'bot'
      );
    }
    return;
  }

  // No confident match — show whatever weak matches exist, then the
  // explicit escalation button. Nothing is sent externally until clicked.
  if (result.matches && result.matches.length) {
    lastWeakSnippet = result.matches[0].text;
    addMessage(
      `<p>No confident local match. Closest related content:</p>` +
        markdownToHtml(result.matches[0].text) +
        `<div class="source">Source: ${escapeHtml(result.matches[0].source)}</div>`,
      'bot weak'
    );
  } else {
    addMessage('<p>No confident local match found for that question.</p>', 'bot weak');
  }

  addMessage(
    `<button id="escalate-btn" onclick="doEscalate()">Ask an external AI instead (sends your question to OpenRouter)</button>`,
    'bot escalate-prompt'
  );
}

async function doEscalate() {
  const btn = document.getElementById('escalate-btn');
  if (btn) {
    btn.disabled = true;
    btn.textContent = 'Asking external AI…';
  }

  let result;
  try {
    const r = await fetch('/api/escalate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-admin-session': sessionToken },
      body: JSON.stringify({ question: lastQuestion, weakSnippet: lastWeakSnippet }),
    });
    result = await r.json();
  } catch {
    addMessage('Could not reach the chatbot server for escalation.', 'bot error');
    return;
  }

  if (!result.ok) {
    addMessage(`Escalation failed: ${escapeHtml(result.error || 'unknown error')}`, 'bot error');
    return;
  }

  addMessage(
    `<div class="external-warning">⚠️ Answered by external AI (${escapeHtml(result.model)}), not local docs — verify before relying on this.</div>` +
      markdownToHtml(result.answer),
    'bot external'
  );
}

// ---------- Init ----------

document.addEventListener('DOMContentLoaded', () => {
  initSession();

  document.getElementById('send-btn').addEventListener('click', askQuestion);
  document.getElementById('chat-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') askQuestion();
  });

  if (window.mermaid) {
    window.mermaid.initialize({ startOnLoad: false });
  }
});
