// Chatbot frontend, inlined as a single HTML string served by this Edge
// Function's GET route. Same contract as the original chatbot/frontend/
// (index.html + app.js): no login of its own, token only ever arrives via
// the URL fragment (`#session_token=...`, never sent to any server), calls
// back to this same function's /api/search and /api/escalate.
//
// Difference from the original: mermaid is loaded from a CDN
// (cdnjs.cloudflare.com, already used elsewhere in this repo, e.g.
// admin.html) instead of the ~3.5MB vendored mermaid.min.js — simpler than
// bundling that file into the function, and this is an internal tool, not
// something that needs to work offline.
//
// chatbot/frontend/index.html + app.js are kept as the source of truth for
// this logic; keep them in sync by hand if either changes (see README).

export const FRONTEND_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Meensha — How Does This Work?</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background:#0E0A04; color:#E8D5A3; margin:0; }
  .login-view { max-width:360px; margin:80px auto; padding:24px; background:#1A1208; border-radius:8px; }
  .login-view h1 { font-size:18px; }
  #chat-input-row button { background:#8B6914; color:#fff; border:none; padding:10px 16px; border-radius:4px; cursor:pointer; }
  #chat-view { max-width:800px; margin:0 auto; padding:16px; display:none; }
  #chat-header { display:flex; justify-content:space-between; align-items:center; margin-bottom:12px; }
  #chat-log { height:70vh; overflow-y:auto; border:1px solid #8B6914; border-radius:8px; padding:12px; background:#1A1208; }
  .msg { margin:10px 0; padding:10px 12px; border-radius:6px; }
  .msg.user { background:#2a1f10; text-align:right; }
  .msg.bot { background:#15100a; }
  .msg.weak { border:1px dashed #c9a84c; }
  .msg.error { border:1px solid #ff6b6b; }
  .msg.external { border:1px solid #ff9f43; }
  .msg .source { font-size:11px; opacity:0.7; margin-top:6px; }
  .external-warning { background:#ff9f43; color:#1A1208; padding:6px 10px; border-radius:4px; font-weight:bold; margin-bottom:8px; }
  #escalate-btn { background:#444; color:#fff; border:1px solid #ff9f43; padding:8px 12px; border-radius:4px; cursor:pointer; }
  #chat-input-row { display:flex; gap:8px; margin-top:12px; }
  #chat-input { flex:1; padding:10px; border-radius:4px; border:1px solid #8B6914; background:#0E0A04; color:#E8D5A3; }
  table { border-collapse:collapse; width:100%; margin:8px 0; }
  table, th, td { border:1px solid #8B6914; padding:4px 8px; font-size:13px; }
  pre { background:#0E0A04; padding:8px; border-radius:4px; overflow-x:auto; }
  pre.mermaid { background:#fff; color:#000; }
  code { background:#0E0A04; padding:1px 4px; border-radius:3px; }
</style>
</head>
<body>

<div id="no-session-view" class="login-view">
  <h1>Meensha — How Does This Work?</h1>
  <p style="font-size:13px;opacity:0.8;">
    This page has no login of its own — open it from the Help link inside admin.html
    (or the "How does this work?" option in the India/Australia Telegram bot), which already
    knows who you are.
  </p>
</div>

<div id="chat-view" style="display:none;">
  <div id="chat-header"><h1 style="font-size:16px;margin:0;">Meensha — How Does This Work?</h1></div>
  <div id="chat-log"></div>
  <div id="chat-input-row">
    <input id="chat-input" placeholder="Ask how something works…">
    <button id="send-btn">Ask</button>
  </div>
</div>

<script src="https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js"></script>
<script>
// API_BASE resolves to this function's own path with a trailing slash,
// regardless of whether the browser loaded it with or without one, so
// /api/search and /api/escalate always hit this same function
// (…/functions/v1/chatbot/api/search), not the Supabase project root.
var API_BASE = window.location.pathname.endsWith('/') ? window.location.pathname : window.location.pathname + '/';

let sessionToken = null;

function getTokenFromHash() {
  const hash = window.location.hash.replace(/^#/, '');
  const params = new URLSearchParams(hash);
  return params.get('session_token');
}

// ---------- Markdown -> HTML ----------
function escapeHtml(s) {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function renderInline(text) {
  let html = escapeHtml(text);
  html = html.replace(/\`([^\`]+)\`/g, '<code>$1</code>');
  html = html.replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>');
  return html;
}

function isTableSeparator(line) {
  return /^\\s*\\|?[\\s:|-]+\\|?\\s*$/.test(line) && line.includes('-');
}

function splitTableRow(line) {
  return line.trim().replace(/^\\|/, '').replace(/\\|$/, '').split('|').map((c) => c.trim());
}

function markdownToHtml(md) {
  const lines = md.replace(/\\r\\n/g, '\\n').split('\\n');
  const out = [];
  let i = 0;
  let listBuffer = null;

  function flushList() {
    if (!listBuffer) return;
    const tag = listBuffer.type;
    out.push('<' + tag + '>' + listBuffer.items.map((it) => '<li>' + renderInline(it) + '</li>').join('') + '</' + tag + '>');
    listBuffer = null;
  }

  while (i < lines.length) {
    const line = lines[i];

    const fenceMatch = line.match(/^\`\`\`\\s*(\\w+)?\\s*$/);
    if (fenceMatch) {
      flushList();
      const lang = (fenceMatch[1] || '').toLowerCase();
      const body = [];
      i += 1;
      while (i < lines.length && !/^\`\`\`\\s*$/.test(lines[i])) {
        body.push(lines[i]);
        i += 1;
      }
      i += 1;
      const raw = body.join('\\n');
      if (lang === 'mermaid') {
        out.push('<pre class="mermaid">' + escapeHtml(raw) + '</pre>');
      } else {
        out.push('<pre><code>' + escapeHtml(raw) + '</code></pre>');
      }
      continue;
    }

    const headingMatch = line.match(/^(#{1,3})\\s+(.*)/);
    if (headingMatch) {
      flushList();
      const level = headingMatch[1].length;
      out.push('<h' + level + '>' + renderInline(headingMatch[2]) + '</h' + level + '>');
      i += 1;
      continue;
    }

    if (line.trim().startsWith('|') && lines[i + 1] && isTableSeparator(lines[i + 1])) {
      flushList();
      const header = splitTableRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.push(splitTableRow(lines[i]));
        i += 1;
      }
      let table = '<table><thead><tr>' + header.map((h) => '<th>' + renderInline(h) + '</th>').join('') + '</tr></thead><tbody>';
      for (const r of rows) {
        table += '<tr>' + r.map((c) => '<td>' + renderInline(c) + '</td>').join('') + '</tr>';
      }
      table += '</tbody></table>';
      out.push(table);
      continue;
    }

    const olMatch = line.match(/^\\s*\\d+\\.\\s+(.*)/);
    if (olMatch) {
      if (!listBuffer || listBuffer.type !== 'ol') {
        flushList();
        listBuffer = { type: 'ol', items: [] };
      }
      listBuffer.items.push(olMatch[1]);
      i += 1;
      continue;
    }

    const ulMatch = line.match(/^\\s*[-*]\\s+(.*)/);
    if (ulMatch) {
      if (!listBuffer || listBuffer.type !== 'ul') {
        flushList();
        listBuffer = { type: 'ul', items: [] };
      }
      listBuffer.items.push(ulMatch[1]);
      i += 1;
      continue;
    }

    if (!line.trim()) {
      flushList();
      i += 1;
      continue;
    }

    flushList();
    const para = [line];
    i += 1;
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^#{1,3}\\s/.test(lines[i]) &&
      !/^\`\`\`/.test(lines[i]) &&
      !/^\\s*\\d+\\.\\s+/.test(lines[i]) &&
      !/^\\s*[-*]\\s+/.test(lines[i]) &&
      !lines[i].trim().startsWith('|')
    ) {
      para.push(lines[i]);
      i += 1;
    }
    out.push('<p>' + renderInline(para.join(' ')) + '</p>');
  }
  flushList();
  return out.join('\\n');
}

// ---------- Session ----------
function initSession() {
  const fromHash = getTokenFromHash();
  if (fromHash) {
    sessionToken = fromHash;
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
  div.className = 'msg ' + (cls || '');
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
    const r = await fetch(API_BASE + 'api/search', {
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
        markdownToHtml(m.text) + '<div class="source">Source: ' + escapeHtml(m.source) + (m.heading ? ' — ' + escapeHtml(m.heading) : '') + '</div>',
        'bot'
      );
    }
    return;
  }

  if (result.matches && result.matches.length) {
    lastWeakSnippet = result.matches[0].text;
    addMessage(
      '<p>No confident local match. Closest related content:</p>' +
        markdownToHtml(result.matches[0].text) +
        '<div class="source">Source: ' + escapeHtml(result.matches[0].source) + '</div>',
      'bot weak'
    );
  } else {
    addMessage('<p>No confident local match found for that question.</p>', 'bot weak');
  }

  addMessage(
    '<button id="escalate-btn" onclick="doEscalate()">Ask an external AI instead (sends your question to OpenRouter)</button>',
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
    const r = await fetch(API_BASE + 'api/escalate', {
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
    addMessage('Escalation failed: ' + escapeHtml(result.error || 'unknown error'), 'bot error');
    return;
  }

  addMessage(
    '<div class="external-warning">⚠️ Answered by external AI (' + escapeHtml(result.model) + '), not local docs — verify before relying on this.</div>' +
      markdownToHtml(result.answer),
    'bot external'
  );
}

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
</script>
</body>
</html>
`;
