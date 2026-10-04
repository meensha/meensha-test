// Chatbot server: a single small Node process (built-in `http`, no
// framework — only 3 routes, per the plan's simplicity preference) serving
// the frontend as static files plus /api/search and /api/escalate.
//
// No database, no external service calls except the two already named in
// the plan: Supabase (auth.js, to resolve a session to a role) and
// OpenRouter (escalate.js, only on an explicit user click).

const http = require('http');
const fs = require('fs');
const path = require('path');
const { PORT, FRONTEND_DIR } = require('./config');
const { resolveKbTierFromHeaders } = require('./auth');
const { search } = require('./retrieval');
const { escalate } = require('./escalate');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
};

function sendJson(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (chunk) => (data += chunk));
    req.on('end', () => {
      try {
        resolve(JSON.parse(data || '{}'));
      } catch {
        resolve({});
      }
    });
  });
}

// Serves a file from chatbot/frontend/, defaulting to index.html for "/".
// Blocks path traversal outside FRONTEND_DIR.
function serveStatic(req, res) {
  let reqPath = decodeURIComponent(req.url.split('?')[0]);
  if (reqPath === '/') reqPath = '/index.html';
  const filePath = path.join(FRONTEND_DIR, reqPath);

  if (!filePath.startsWith(FRONTEND_DIR + path.sep)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    const ext = path.extname(filePath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];

  if (req.method === 'POST' && url === '/api/search') {
    const tier = await resolveKbTierFromHeaders(req.headers);
    if (!tier) {
      sendJson(res, 401, { error: 'Invalid or expired session.' });
      return;
    }
    const { question } = await readBody(req);
    if (!question || !question.trim()) {
      sendJson(res, 400, { error: 'Missing question.' });
      return;
    }
    const result = search(tier, question);
    sendJson(res, 200, result);
    return;
  }

  if (req.method === 'POST' && url === '/api/escalate') {
    const tier = await resolveKbTierFromHeaders(req.headers);
    if (!tier) {
      sendJson(res, 401, { error: 'Invalid or expired session.' });
      return;
    }
    // The frontend only shows the escalate button after a user click on an
    // already-rendered "no confident match" state — this route itself has
    // no way to be reached except that explicit POST, so there's no
    // automatic-firing path to guard against here.
    const { question, weakSnippet } = await readBody(req);
    const result = await escalate(question, weakSnippet);
    sendJson(res, result.ok ? 200 : 502, result);
    return;
  }

  if (req.method === 'GET') {
    serveStatic(req, res);
    return;
  }

  res.writeHead(404);
  res.end('Not found');
});

server.listen(PORT, () => {
  console.log(`Meensha chatbot server listening on http://localhost:${PORT}`);
});

module.exports = { server };
