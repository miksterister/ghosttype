# GhostType Inline (Obsidian plugin)

Native CodeMirror-6 ghost-text renderer over the same local FIM server the
Hammerspoon GhostType uses (`127.0.0.1:8790/complete`). Inside the editor the
layout engine positions the ghost text itself, so it's pixel-true — no AX
geometry estimation, no wrapped-line drift.

- Type, pause ~260ms → gray inline suggestion (capped at 4 words)
- The prompt includes the note title and the enclosing headings that scrolled out of the 2000-char window, so suggestions track your topic
- **Tab** accepts one word at a time, keeping the rest as ghost (only when a ghost is showing — indent/lists unaffected)
- **§** accepts the whole suggestion (types a normal § when no ghost is showing)
- **Escape** dismisses; typing *into* the suggestion trims it locally
- Requires the GhostType server running (launchd agent `com.local.ghosttype-server`)

## Install (per vault)

No build step — copy the folder:

```
cp -R obsidian-plugin "<vault>/.obsidian/plugins/ghosttype-inline"
```

**After every change to `main.js`, re-copy and reload** — the vault holds a
copy, not a symlink, and Obsidian caches loaded plugin code (toggle the
plugin off/on in Settings → Community plugins, or restart Obsidian).
Then enable "GhostType Inline" in Settings → Community plugins (and reload
Obsidian). If you use the Hammerspoon GhostType too, set Obsidian to
`"enabled": false` in `~/.config/ghosttype/config.json` — otherwise both
render ghost text and both fight over Tab.

## Test

```
node tests/test_logic.js
```
