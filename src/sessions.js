// Everything that knows Claude Code's on-disk layout lives here. None of it is
// a documented API, so if an update breaks the app, this is the file to fix.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const CLAUDE_DIR = path.join(os.homedir(), '.claude');
export const SESSIONS_DIR = process.env.CCS_SESSIONS_DIR || path.join(CLAUDE_DIR, 'sessions');
const PROJECTS_DIR = path.join(CLAUDE_DIR, 'projects');
const TAIL_BYTES = 256 * 1024;

const transcriptPaths = new Map(); // sessionId -> path
const titles = new Map(); // sessionId -> ai title (it can sit far back in the file)
const tails = new Map(); // sessionId -> { size, mtime, info }

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

function findTranscript(sessionId, cwd) {
  const cached = transcriptPaths.get(sessionId);
  if (cached && fs.existsSync(cached)) return cached;
  const file = `${sessionId}.jsonl`;
  const guess = path.join(PROJECTS_DIR, cwd.replace(/[^A-Za-z0-9]/g, '-'), file);
  let found = fs.existsSync(guess) ? guess : null;
  if (!found) {
    for (const dir of safeReaddir(PROJECTS_DIR)) {
      const p = path.join(PROJECTS_DIR, dir, file);
      if (fs.existsSync(p)) { found = p; break; }
    }
  }
  if (found) transcriptPaths.set(sessionId, found);
  return found;
}

function safeReaddir(dir) {
  try { return fs.readdirSync(dir); } catch { return []; }
}

function readTail(file, size, bytes) {
  const fd = fs.openSync(file, 'r');
  try {
    const start = Math.max(0, size - bytes);
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    const lines = buf.toString('utf8').split('\n');
    if (start > 0) lines.shift(); // first line is probably cut in half
    return lines;
  } finally {
    fs.closeSync(fd);
  }
}

function parse(lines) {
  const out = [];
  for (const l of lines) {
    if (!l) continue;
    try { out.push(JSON.parse(l)); } catch { /* partial line */ }
  }
  return out;
}

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter((c) => c.type === 'text').map((c) => c.text).join(' ');
}

function describeTool(t) {
  const i = t.input || {};
  const arg = i.description || i.command || i.file_path || i.pattern || i.url || i.prompt || '';
  return `${t.name}${arg ? `: ${String(arg).split('\n')[0]}` : ''}`;
}

const isPush = (t) => t.name === 'Bash' && /\bgit\s+push\b/.test(t.input?.command || '');

function summarize(entries) {
  const info = { title: null, lastPrompt: null, lastReply: null, lastTool: null, recap: null,
    cost: null, linesAdded: 0, linesRemoved: 0, models: {}, subagents: 0, exchanges: [],
    pushed: false }; // pushed: the last thing Claude did was a git push that worked
  let pushId = null; // the last tool call, if it was a push
  for (const d of entries) {
    if (d.type === 'ai-title') info.title = d.aiTitle;
    else if (d.type === 'last-prompt') info.lastPrompt = d.lastPrompt;
    else if (d.type === 'system' && d.subtype === 'away_summary') info.recap = d.content;
    else if (d.type === 'cost-state') {
      info.cost = d.totalCostUSD;
      info.linesAdded = d.totalLinesAdded || 0;
      info.linesRemoved = d.totalLinesRemoved || 0;
      info.models = d.modelUsage || {};
    } else if (d.isSidechain) {
      info.subagents++;
    } else if (d.type === 'user' && !d.isMeta && typeof d.message?.content === 'string') {
      const t = d.message.content.trim();
      if (t && !t.startsWith('<')) {
        info.exchanges.push({ who: 'you', text: t });
        info.recap = null; // a new prompt makes the older recap stale
        info.pushed = false;
        pushId = null;
      }
    } else if (d.type === 'user' && pushId && Array.isArray(d.message?.content)) {
      const r = d.message.content.find((c) => c.tool_use_id === pushId);
      if (r) info.pushed = !r.is_error;
    } else if (d.type === 'assistant') {
      for (const c of d.message?.content || []) {
        if (c.type === 'tool_use') {
          info.lastTool = describeTool(c);
          pushId = isPush(c) ? c.id : null;
          info.pushed = false;
        }
      }
      const t = textOf(d.message?.content).trim();
      if (t) {
        info.lastReply = t;
        const last = info.exchanges.at(-1);
        if (last?.who === 'claude') last.text = t;
        else info.exchanges.push({ who: 'claude', text: t });
      }
    }
  }
  info.exchanges = info.exchanges.slice(-6);
  return info;
}

function transcriptInfo(sessionId, cwd) {
  const file = findTranscript(sessionId, cwd);
  if (!file) return null;
  let st;
  try { st = fs.statSync(file); } catch { return null; }
  const prev = tails.get(sessionId);
  if (prev && prev.size === st.size && prev.mtime === st.mtimeMs) return prev.info;

  const info = summarize(parse(readTail(file, st.size, TAIL_BYTES)));
  if (info.title) titles.set(sessionId, info.title);
  else if (!titles.has(sessionId)) {
    // Not in the tail: look once through the whole file, then remember it.
    let title = null;
    if (st.size > TAIL_BYTES && st.size < 50 * 1024 * 1024) {
      for (const d of parse(fs.readFileSync(file, 'utf8').split('\n'))) {
        if (d.type === 'ai-title') title = d.aiTitle;
      }
    }
    titles.set(sessionId, title);
  }
  info.title = titles.get(sessionId) || null;
  info.transcript = file;
  info.updatedAt = st.mtimeMs;
  tails.set(sessionId, { size: st.size, mtime: st.mtimeMs, info });
  return info;
}

export function loadSessions() {
  const out = [];
  for (const f of safeReaddir(SESSIONS_DIR)) {
    if (!f.endsWith('.json')) continue;
    let s;
    try { s = JSON.parse(fs.readFileSync(path.join(SESSIONS_DIR, f), 'utf8')); } catch { continue; }
    if (!s.sessionId) continue;
    const live = alive(s.pid);
    out.push({
      pid: s.pid,
      id: s.sessionId,
      name: s.name || s.sessionId.slice(0, 8),
      cwd: s.cwd || '',
      kind: s.kind,
      version: s.version,
      startedAt: s.startedAt,
      live,
      status: live ? s.status || 'unknown' : 'dead',
      statusSince: s.statusUpdatedAt || s.updatedAt || s.startedAt,
      ...(transcriptInfo(s.sessionId, s.cwd || '') || {}),
    });
  }
  const rank = (s) => (s.status === 'busy' ? 0 : s.live ? 1 : 2);
  return out.sort((a, b) => rank(a) - rank(b) || b.statusSince - a.statusSince);
}
