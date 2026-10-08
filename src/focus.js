// Brings a session's terminal to the front. Ghostty only, through its
// AppleScript dictionary: its terminals expose a title and a working
// directory, not a tty or pid, so a session is matched by the title Claude
// Code gives its tab (a status glyph, then the session's title), then by folder.
import { execFile } from 'node:child_process';

const osa = (script) => new Promise((resolve, reject) => {
  execFile('osascript', ['-e', script], (err, out) => (err ? reject(err) : resolve(out)));
});

async function ghosttyTerminals() {
  const out = await osa(`tell application "Ghostty"
    set out to ""
    set sep to character id 9
    repeat with t in terminals
      set out to out & (id of t) & sep & (name of t) & sep & (working directory of t) & linefeed
    end repeat
    return out
  end tell`);
  return out.split('\n').filter(Boolean).map((l) => {
    const [id, name, cwd] = l.split('\t');
    return { id, name, title: name.replace(/^[^\p{L}\p{N}]+/u, '').trim(), cwd };
  });
}

// sessions: every live session, so a folder match can skip terminals that
// another session's title already claims.
export async function focusSession(s, sessions) {
  const terms = await ghosttyTerminals();
  let t = s.title && terms.find((x) => x.title === s.title);
  if (!t) {
    const claimed = new Set(sessions.filter((o) => o.id !== s.id && o.title).map((o) => o.title));
    const inDir = terms.filter((x) => x.cwd === s.cwd && !claimed.has(x.title) && x.title !== 'ccs');
    if (inDir.length === 1) t = inDir[0];
  }
  if (!t) return false;
  await osa(`tell application "Ghostty"
    focus (first terminal whose id is "${t.id}")
    activate
  end tell`);
  return true;
}
