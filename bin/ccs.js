#!/usr/bin/env node
// ccs: every Claude Code session on this machine, live, with a ping when one
// goes from busy to idle (finished, or waiting on you).
import fs from 'node:fs';
import os from 'node:os';
import { spawn, execFile } from 'node:child_process';
import React, { useEffect, useRef, useState } from 'react';
import { render, Box, Text, useApp, useInput, useStdout } from 'ink';
import { loadSessions, SESSIONS_DIR } from '../src/sessions.js';
import { focusSession } from '../src/focus.js';

const h = React.createElement;
const SOUNDS = '/System/Library/Sounds';

const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : null;
};
if (args.includes('--help') || args.includes('-h')) {
  console.log(`ccs: live status of your Claude Code sessions

  --sound <name>   sound for a finished session (default Glass); one of:
                   ${fs.readdirSync(SOUNDS).map((f) => f.replace('.aiff', '')).join(', ')}
  --quiet          start with the sound off
  --notify         also show a macOS notification when a session finishes`);
  process.exit(0);
}
const soundName = flag('sound') || 'Glass';
const soundFile = `${SOUNDS}/${soundName}.aiff`;

function ping() {
  if (process.platform === 'darwin' && fs.existsSync(soundFile)) {
    spawn('afplay', [soundFile], { stdio: 'ignore', detached: true }).unref();
  } else {
    process.stdout.write('\x07'); // terminal bell elsewhere
  }
}

function notify(s) {
  const what = (s.title || s.name).replace(/"/g, "'");
  execFile('osascript', ['-e', `display notification "${what}" with title "Claude is ready" subtitle "${s.name}"`]);
}

const home = os.homedir();
const tilde = (p) => (p.startsWith(home) ? `~${p.slice(home.length)}` : p);
const oneLine = (t) => String(t || '').replace(/\s+/g, ' ').trim();
const clip = (t, n) => {
  t = oneLine(t);
  return n <= 1 ? '' : t.length > n ? `${t.slice(0, n - 1)}…` : t;
};

function ago(ms) {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

const money = (c) => (c == null ? '' : `$${c.toFixed(2)}`);
const SPIN = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

function context(s) {
  if (s.status === 'busy') return s.lastTool ? `⚙ ${s.lastTool}` : s.lastPrompt ? `"${s.lastPrompt}"` : '';
  if (s.recap) return `Recap: ${s.recap}`;
  if (s.lastPrompt) return `"${s.lastPrompt}"`;
  return '';
}

function Row({ s, selected, frame, width }) {
  const busy = s.status === 'busy';
  const dot = busy ? SPIN[frame % SPIN.length] : s.live ? '○' : '✕';
  const color = busy ? 'yellow' : s.live ? 'green' : 'gray';
  const label = busy ? 'busy' : s.live ? 'idle' : 'dead';
  const nameW = 24;
  const right = `${money(s.cost).padStart(7)}`;
  const cwdW = Math.max(10, width - nameW - 22 - right.length);
  return h(Box, { flexDirection: 'column', marginBottom: 0 },
    h(Text, { inverse: selected, dimColor: !s.live },
      h(Text, { color }, ` ${dot} `),
      h(Text, { bold: true }, clip(s.title || s.name, nameW).padEnd(nameW)),
      h(Text, { color }, ` ${label.padEnd(4)}`),
      ` ${ago(s.statusSince).padStart(4)}  `,
      h(Text, { color: 'cyan' }, clip(tilde(s.cwd), cwdW).padEnd(cwdW)),
      h(Text, { dimColor: true }, right),
    ),
    h(Text, { dimColor: true }, `   ↳ ${clip(context(s), width - 6)}`),
  );
}

function Detail({ s, width }) {
  const models = Object.entries(s.models || {}).map(([m, u]) =>
    `${m}: ${((u.inputTokens || 0) + (u.cacheReadInputTokens || 0) + (u.cacheCreationInputTokens || 0)).toLocaleString()} in · ${(u.outputTokens || 0).toLocaleString()} out`);
  const line = (k, v) => h(Text, null, h(Text, { dimColor: true }, k.padEnd(11)), v);
  return h(Box, { flexDirection: 'column', paddingX: 1 },
    h(Text, { bold: true }, s.title || s.name),
    line('session', `${s.name}  ${s.id}`),
    line('status', `${s.status} for ${ago(s.statusSince)} · started ${ago(s.startedAt)} ago · pid ${s.pid} · v${s.version}`),
    line('folder', tilde(s.cwd)),
    line('cost', `${money(s.cost) || '—'}  ·  +${s.linesAdded || 0} −${s.linesRemoved || 0} lines`),
    ...models.map((m) => line('', m)),
    s.subagents ? line('subagents', `${s.subagents} recent sidechain messages`) : null,
    s.lastTool ? line('last tool', clip(s.lastTool, width - 14)) : null,
    s.recap ? line('recap', clip(s.recap, (width - 14) * 2)) : null,
    h(Text, null, ' '),
    ...(s.exchanges || []).map((e, i) =>
      h(Text, { key: i, wrap: 'truncate-end' },
        h(Text, { color: e.who === 'you' ? 'magenta' : 'blue', bold: true }, e.who === 'you' ? 'you    ' : 'claude '),
        clip(e.text, (width - 9) * 2))),
  );
}

function App() {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [sessions, setSessions] = useState(() => loadSessions());
  const [sel, setSel] = useState(0);
  const [detail, setDetail] = useState(false);
  const [showDead, setShowDead] = useState(false);
  const [sound, setSound] = useState(!args.includes('--quiet'));
  const [notifyOn, setNotifyOn] = useState(args.includes('--notify'));
  const [frame, setFrame] = useState(0);
  const [flash, setFlash] = useState('');
  const prev = useRef(new Map(sessions.map((s) => [s.id, s.status])));
  const opts = useRef({});
  opts.current = { sound, notifyOn };

  const say = (m) => { setFlash(m); setTimeout(() => setFlash(''), 2500); };

  useEffect(() => {
    let pending = null;
    const refresh = () => {
      const next = loadSessions();
      const finished = next.filter((s) => prev.current.get(s.id) === 'busy' && s.status !== 'busy' && s.live);
      prev.current = new Map(next.map((s) => [s.id, s.status]));
      if (finished.length) {
        if (opts.current.sound) ping();
        if (opts.current.notifyOn) finished.forEach(notify);
        say(`✔ ready: ${finished.map((s) => s.title || s.name).join(', ')}`);
      }
      setSessions(next);
    };
    const poll = setInterval(refresh, 1500);
    let watcher;
    try {
      watcher = fs.watch(SESSIONS_DIR, () => {
        clearTimeout(pending);
        pending = setTimeout(refresh, 100);
      });
    } catch { /* polling covers it */ }
    const spin = setInterval(() => setFrame((f) => f + 1), 120);
    return () => { clearInterval(poll); clearInterval(spin); watcher?.close(); };
  }, []);

  const shown = sessions.filter((s) => showDead || s.live);
  const cur = shown[Math.min(sel, shown.length - 1)];
  const width = Math.max(60, (stdout?.columns || 100) - 1);

  useInput((input, key) => {
    if (input === 'q' || (key.ctrl && input === 'c')) return exit();
    if (key.escape || (detail && input === 'i')) return setDetail(false);
    if (key.upArrow || input === 'k') setSel((i) => Math.max(0, i - 1));
    if (key.downArrow || input === 'j') setSel((i) => Math.min(shown.length - 1, i + 1));
    if (input === 'i' && cur) setDetail(true);
    if (key.return && cur) {
      if (!cur.live) return say('that session has ended');
      focusSession(cur, sessions.filter((s) => s.live))
        .then((ok) => say(ok ? `→ ${cur.title || cur.name}` : "couldn't find its terminal window"))
        .catch((e) => say(`couldn't focus: ${oneLine(e.message).slice(0, 80)}`));
    }
    if (input === 'd') setShowDead((v) => !v);
    if (input === 's') { setSound((v) => !v); say(`sound ${sound ? 'off' : 'on'}`); }
    if (input === 'n') { setNotifyOn((v) => !v); say(`notifications ${notifyOn ? 'off' : 'on'}`); }
    if (input === 't') { ping(); say(`test ping (${soundName})`); }
    if (input === 'o' && cur) { spawn('open', [cur.cwd], { stdio: 'ignore' }); say(`opened ${tilde(cur.cwd)}`); }
    if (input === 'c' && cur) {
      const cmd = `cd ${JSON.stringify(cur.cwd)} && claude --resume ${cur.id}`;
      const p = spawn('pbcopy');
      p.stdin.end(cmd);
      say('copied resume command');
    }
  });

  const busy = sessions.filter((s) => s.status === 'busy').length;
  const live = sessions.filter((s) => s.live).length;
  const header = h(Box, { justifyContent: 'space-between', width },
    h(Text, { bold: true, color: 'magentaBright' }, ' CLAUDE SESSIONS'),
    h(Text, null,
      h(Text, { color: 'green' }, `${live} live`), ' · ',
      h(Text, { color: busy ? 'yellow' : undefined }, `${busy} busy`), '  ',
      h(Text, { dimColor: true }, `${sound ? '🔔' : '🔕'}${notifyOn ? ' 💬' : ''} `)));

  const footer = h(Text, { dimColor: true },
    detail
      ? ' enter jump to it · esc back · o open folder · c copy resume · q quit'
      : ` ↑↓ select · enter jump to it · i details · o open · c copy resume · d ${showDead ? 'hide' : 'show'} dead · s sound · n notify · t test · q quit`);

  return h(Box, { flexDirection: 'column' },
    header,
    h(Text, { dimColor: true }, '─'.repeat(width)),
    detail && cur
      ? h(Detail, { s: cur, width })
      : shown.length
        ? shown.map((s, i) => h(Row, { key: s.id, s, selected: i === sel, frame, width }))
        : h(Text, { dimColor: true }, '  No Claude Code sessions running.'),
    h(Text, { dimColor: true }, '─'.repeat(width)),
    flash ? h(Text, { color: 'green' }, ` ${flash}`) : footer,
  );
}

render(h(App));
