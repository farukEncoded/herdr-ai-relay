# Contributing

Thanks for helping. Bug reports, fixes and new teams are all welcome. Please open an issue before a large change
so we can agree on the approach.

## Layout

```
mods/ai-relay-kit/            the panel + setup screen (main.js, setup.js, lib.js, icons/)
mods/ai-relay-kit/payload/    the engine setup copies to ~/.agents/protocol:
                              ai-relay.ps1, setup.ps1, AI-PROTOCOL.md, RELAY-AGENT.md, relay-defaults.json, bin/
mods/ai-relay-kit-launcher/   Start AI relay dialog
mods/ai-relay-kit-commands/   AI commands list
mods/ai-relay-kit-handoff/    handoff viewer pane
mods/ai-relay-kit-drawer/     optional floating relay drawer
mods/ai-relay-kit-overnight/  Make overnight / Limits box
keys.json                     the keys the mods expect (merged into the user's keys.json)
tests/                        test-setup.ps1, check-setup-render.ps1
tools/                        sync-lib.ps1, check-all.ps1
RECIPE.md  preview.png        what herdr.dev shows; RECIPE.md is the brief to rebuild the mods from scratch
```

Mods are Herdr app mods: JavaScript describing native UI (gpui-kit). The reference is `~/.config/herdr-app/AGENTS.md`
plus `herdr.d.ts` and `gpui-kit.d.ts` in the same folder, which Herdr rewrites on every start.

## Working on it

1. Copy the folders in `mods/` into `~/.config/herdr-app/mods/` (or edit them there and copy back). Herdr reloads a
   mod as soon as you save it. `herdr-app status` shows load errors, and `herdr-app shot file.png` saves a
   screenshot of the window.
2. **Shared code lives in `mods/ai-relay-kit/lib.js`.** Mods can't import across folders, so every mod carries a
   copy. Edit only the panel's copy, then run:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-lib.ps1
   ```
3. Run every check before you commit:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-all.ps1
   ```
   This runs `node --check` on every `.js` and a parse + ASCII check on every `.ps1`. It also checks the JSON
   files, confirms the lib.js copies are in sync, and runs `herdr-app check` on each mod. Then it runs both tests:
   - `tests/test-setup.ps1`: adds the mods to a throwaway Herdr home and runs every setup action (detect,
     install, protocol, PATH, programs, remove) against a throwaway user home. It never touches your real home,
     PATH or Herdr folder.
   - `tests/check-setup-render.ps1`: `herdr-app check` renders only a mod's first state, so this renders the
     setup screen in four states, the project view with awkward relay data, and the dialog with Overnight ticked.

## Rules

- **Windows PowerShell 5.1 and ASCII.** Every `.ps1` must run in 5.1 (and 7). 5.1 reads BOM-less files as ANSI,
  so keep scripts ASCII. Watch out for 5.1 quirks: `"$x?"` reads a variable named `x?`, so write `"$($x)?"`.
  Native programs' stderr can turn into terminating errors, so capture output with `Invoke-Native`.
- **Start native programs with `Invoke-Native` / `Quote-Arg`** (in `ai-relay.ps1`), never `& exe @args` when an
  argument can contain spaces or quotes: 5.1 doesn't quote them. Herdr runs argv through the tab's shell, which
  drops inner `"`, so goals use `'`.
- **The relay never runs as an agent's child process.** Agents' tool limits kill long commands. `ai-relay.ps1`
  detects an agent among its parents and relaunches itself in its own Herdr tab.
- **Never pass null or undefined to `.child()`** in a mod: the whole mod fails to render. Use `.when()` or an empty
  `div()`. Keep host calls out of module scope, animate with `.loop()`/`.frames()` (not timers), and never keep a
  `cx` for later.
- **Setup changes nothing without a click**, never downloads or runs a remote installer, backs up every file it
  edits, and records each change so Remove can undo it.
- **No personal data**: no user names, home paths, emails or project names in code, docs or screenshots. Paths come
  from `home()` / `appHome()` (JS) and `USERPROFILE` (PowerShell) at run time. In `RELAY-AGENT.md` the script path is
  the token `{{PROTOCOL_DIR}}`, which setup fills in.
- **The executor always runs at high effort or above.**

## Design decisions

These are the choices the relay is built on. If one has to change, say why in the pull request.

1. **One protocol file**: `AI-PROTOCOL.md` is the single source. Setup puts it between `AI-PROTOCOL:BEGIN/END` markers
   in each agent's global rules; Claude imports it with `@~/.agents/protocol/AI-PROTOCOL.md`.
2. **A new Herdr space only when the old one is gone**: on a `tab.new` failure, the relay checks `herdr-app ls` first.
3. **Herdr app, not the Herdr TUI**: the + menu points at the agents through `programs.json`.
4. **Effort per role for every agent**: Claude and agy get `--effort`, Codex gets `-c model_reasoning_effort=`.
   *Recommended* means each role's own effort.
5. **Model per role**, with short names checked against each stage's agent before the run starts.
6. **Dashboard**: `.ai/relay/status.json` carries stages, queue, waiting questions and plan usage. Claude's usage
   comes from a relay-only status line, Codex's from its session files; Antigravity reports none.
7. **`relay` inside any agent** (`RELAY-AGENT.md`): one setup message with defaults. The agent may take roles
   ("me"): the relay types the task into its terminal only at a normal prompt, then presses Enter again 1.5 s later.
8. **`relay-defaults.json` is the one place for defaults**; anything chosen at start overrides it.
9. **Teams with a judge**: roles in order, each with a job, an agent and an effort; `once` roles run in the first
   pass only. Exactly one `judge` (by default the last role) says APPROVED or CHANGES_REQUESTED.
10. **Queue mode**: the planner splits a big goal into task files, each naming its agents. The user approves the
    queue, and tasks run **one at a time**, because they share the same files and git.
11. **No stage leaves servers or test runs behind**: the protocol's end-of-session step 1 is "Clean up", and
    `Stop-StageLeftovers` stops what a finished stage left anyway. Each stage records what it stopped as `cleaned`.
12. **Survive Herdr restarts and never die silently**: the relay waits up to 20 minutes for Herdr. Any error that
    ends it writes status `stopped` plus `error`.
13. **Codex `--approve-for-me`**: Codex keeps its sandbox, and its auto-reviewer answers its own approval requests.
    The Windows sandbox mode is the `codexWindowsSandbox` option.
14. **Overnight mode**: opt-in per run, with a pre-flight and one "y". It works on its own branch, never pushed,
    and starts every agent with its skip-permission flag. There are no questions, a watchdog handles stalls and
    limits, the PC is kept awake, and a morning report is written.
15. **Make overnight**: a running relay switches when `.ai/relay/OVERNIGHT` appears; the file also carries the
    limits. The relay's questions read keys themselves, so the switch also lands mid-question.
16. **Overnight end per run**: `-Until <time>|done` and `-MaxCycles N` (0 = no limit). Whichever comes first ends
    the night, as does an empty queue.
17. **Packaged as a Herdr-home-shaped folder**: six mods plus `keys.json`. The engine is the panel's `payload/`, and
    `setup.ps1` does one action per click.

## Pull requests

- One topic per pull request; describe what changed and how you tested it (the output of `tools/check-all.ps1`).
- UI changes: add a screenshot (`herdr-app shot`), cropped to the kit's own UI.
- Update `CHANGELOG.md` under "Unreleased", and `README.md` / `RECIPE.md` when behaviour changes.

## Releasing

1. Run `tools/check-all.ps1`. Load the mods in a real Herdr window and update `preview.png` if the UI changed.
2. Bump `$KitVersion` in `mods/ai-relay-kit/payload/setup.ps1` (the panel offers an update when it differs) and move
   "Unreleased" in `CHANGELOG.md` to the new version.
3. Tag the release. herdr.dev lists the repo through its `herdr-mod` topic, with `RECIPE.md` and `preview.png`.
