# ccs

A terminal dashboard for every Claude Code session running on your Mac. It shows which
sessions are busy and which are idle, pings when one finishes, and jumps to its window
when you press Enter.

```
 CLAUDE SESSIONS                                   3 live · 1 busy  🔔
 ⠹ Terminal app for Claude code…  busy   2m  ~/projects/my-app
    ↳ ⚙ Write: ~/projects/my-app/src/index.js
 ○ Tower game assets upgrade op…  idle  26h  ~/projects/game
    ↳ "are there music options I can buy for a reasonable price"
```

## Install

```sh
git clone https://github.com/NickS55/cc-status.git
cd cc-status
npm install
npm link        # puts `ccs` on your PATH
```

Needs Node 20+. Built for macOS: the sounds are macOS system sounds, and the jump to a
window uses [Ghostty](https://ghostty.org)'s AppleScript support (1.3+).

## Use

Run `ccs` in a spare terminal tab and leave it open.

| Key | |
|---|---|
| `↑↓` / `j k` | select a session |
| `Enter` | bring that session's Ghostty window and tab to the front |
| `i` | details: status, tokens, last tool, recap, the last few messages |
| `o` | open the session's folder in Finder |
| `c` | copy a `claude --resume` command for it |
| `d` | show or hide sessions that have ended |
| `s` | sound on/off |
| `n` | macOS notifications on/off |
| `t` | test ping |
| `q` | quit |

Options: `--sound <name>` (any of `/System/Library/Sounds`, default `Glass`),
`--quiet`, `--notify`.

When a session goes from busy to idle (it finished, or it's waiting on you), `ccs` plays
the sound and shows which session is ready.

## How it works

It only reads files. Claude Code keeps a file per running session in
`~/.claude/sessions/<pid>.json` (its folder, name and `busy`/`idle` status) and a
transcript in `~/.claude/projects/<folder>/<sessionId>.jsonl`. `ccs` watches the first
and reads the end of the second for the title, last prompt, last tool and recap.

None of that is a documented API, so a Claude Code update could break it. All the
parsing is in `src/sessions.js`, which is the place to fix it.

Ghostty can't say which tab a process runs in, so Enter matches the tab title (Claude
Code names each tab after the session's title), then falls back to the one tab open in
the session's folder. Other terminals would need their own few lines in `src/focus.js`.

## License

MIT
