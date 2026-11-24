# Shared Project Protocol (v2) — Claude Code · Codex/ChatGPT · Antigravity

Several AI agents (Claude Code, Codex, Antigravity) work in turn on the same project folders.
Your chat history is private to you; **the project's `.ai/` folder is the shared memory.**
Anything another agent needs must be written there. Your tool's own plans, brain or memory
files do not count: they live outside the project.

## 0. Identity and when this applies
- **Signature** = `<surface>/<model>`, e.g. `codex-app/gpt-6.1`, `antigravity-ide/gemini-3.5-pro`, `claude-cli/opus-5.5`.
  Leave out `/<model>` if you don't know it. Use it in every `.ai/` entry and git commit. Surfaces:
  | Tool | Surface names |
  |---|---|
  | Claude Code | `claude-desktop` (Code tab in the Claude app), `claude-cli` (any terminal, including Herdr), `claude-ide` (VS Code/JetBrains) |
  | Codex | `codex-app` (ChatGPT desktop app, Codex mode), `codex-cli` (any terminal, including Herdr), `codex-ide` |
  | Antigravity | `antigravity-app` (Antigravity 2.0 app), `antigravity-ide` (Antigravity IDE), `antigravity-cli` (`agy`, including Herdr) |
  **Inside Herdr** (env var `HC_TERMINAL_ID` is set): always use the `-cli` surface (`claude-cli`, `codex-cli`, `antigravity-cli`).
  Otherwise pick the surface from what you know about your own environment (Claude Code: env var `CLAUDE_CODE_ENTRYPOINT`).
  If you can't tell, use `claude`, `codex` or `antigravity`.
- Applies when you work **inside a project folder** (you read, create or change files there).
  Skip it for one-off questions that touch no project.
- **Light mode**: a read-only session inside a project (a question, an explanation, looking at code, no file changes,
  no decisions) reads only `.ai/STATE.md` if it helps, doesn't set `Active:`, writes nothing and doesn't commit.
  Small changes (a typo, a one-line fix) do the end-of-session steps briefly: one LOG line, STATE only if it changed, commit.
- Reviews, tests and multi-agent loops happen only when the user asks or a relay assigns the role. Never start one yourself.
- Never put secrets, tokens or passwords in `.ai/` files.

## 1. Start of every session
1. If `.ai/` is missing and you are about to do project work, bootstrap it (section 5) first.
2. Read, in this order: `.ai/STATE.md`, `.ai/HANDOFF.md`, the last 15 lines of `.ai/LOG.md`.
   Open `.ai/DECISIONS.md` only to check something relevant (search it; don't load it all).
   Never read `.ai/archive/` unless you need older detail.
3. Run `git status` (section 7). Uncommitted changes may belong to another agent: don't discard, overwrite or commit
   them. Mention them in your HANDOFF.md so the user can decide.
4. If STATE's `Active:` line names another agent on the same task, say so and ask before continuing.
5. Set `Active: <signature> on <task-id> since <date time>` in STATE.md.
6. Tell the user in one line what you picked up: current status, the next step, and your role.

## 2. While working
- **Decisions:** when a real choice is made (architecture, library, data model, scope, naming convention),
  append it to DECISIONS.md right away, not at the end. Don't reverse an `active` decision silently;
  propose a new one that supersedes it, and get the user's approval if it changes direction.
- **Roles:** if the project's AGENTS.md assigns roles, or the user gives you one, follow its contract (section 4).
- Stay within the task. Note anything out of scope as a follow-up in STATE.md under `Next`.
- **Relay:** if the user's whole message is `relay` (or asks to start a relay), follow `~/.agents/protocol/RELAY-AGENT.md`.

## 3. End of every session (before your final reply, whenever you changed files or made decisions)
1. **Clean up**: stop every process you started (dev/test servers, watchers, background test runs, browsers,
   emulators) and make sure the ports they used are free. Never leave anything running for the next agent: a stale
   server on a port makes the next agent's tests hang. If something must stay up, say so in HANDOFF.md.
2. **STATE.md**: rewrite it (don't append) so it is true now. Clear the `Active:` line.
3. **HANDOFF.md**: overwrite it with a note for whoever comes next (template below). Keep it to 40 lines or fewer.
4. **LOG.md**: append exactly one line:
   `YYYY-MM-DD HH:MM | <signature> | <role> | <task-id or -> | <what changed, ≤15 words>`
5. **Tasks**: update the status and checklist in `.ai/tasks/T-xxx.md` if you worked on one.
6. **Compaction** (section 6), when a limit is exceeded.
7. **Commit** (section 7), last, so the commit includes the `.ai/` updates. The commit hash is the link
   between LOG and git history; don't write it into LOG (that would need a second commit).

## 4. Role contracts
- **Planner**: writes or updates `.ai/tasks/T-xxx.md` (goal, approach, files, acceptance criteria). No production code.
- **Executor**: implements a task file. Doesn't change its acceptance criteria. Records deviations in the task's `Notes`.
- **Tester**: tests against the acceptance criteria, using the task file, not the executor's reasoning. Writes tests
  and fills in `Test report`. Reports bugs back instead of fixing production code, unless the user says otherwise.
- **Reviewer**: reviews the diff against the task and DECISIONS. Writes findings in the task's `Review`.
- No role assigned: do what the user asks, still following sections 1–3.

## 5. Bootstrap (only when `.ai/` is missing)
Create these, without overwriting anything that already exists:
```
AGENTS.md            project facts: purpose, stack, commands, conventions, Roles, Auto-commit (keep under 80 lines)
CLAUDE.md            one line: @AGENTS.md
.ai/STATE.md  .ai/HANDOFF.md  .ai/DECISIONS.md  .ai/LOG.md  .ai/tasks/  .ai/archive/
```
If AGENTS.md already exists, add only this line at the end:
`Shared AI protocol: project memory lives in .ai/ (STATE, HANDOFF, DECISIONS, LOG, tasks).`
Fill in what you can learn from the folder; write `TBD` for the rest. Log `bootstrap` in LOG.md.
**Existing project** (code or history but no `.ai/`, e.g. built earlier with one tool): build STATE from the code, README,
`git log` and any existing AGENTS.md/CLAUDE.md/GEMINI.md; record decisions that are clearly already made as D-entries marked
`(inferred)`; list unknowns under *Blockers / open questions*. Don't change any code during bootstrap.
The user can trigger this at any time with phrases like "set up / start / init / adopt the protocol" or "set up the AI protocol".
Then set up git (section 7) and make the first commit: `[<signature>] bootstrap: shared AI protocol`.

**STATE.md** (60 lines or fewer)
```
# State — <project>
Updated: <date time> by <signature>
Active: none
## Goal
## Status        (done / in progress, 1 line each)
## Next          (ordered, ≤7 items)
## Blockers / open questions
## Key paths & commands
```
**HANDOFF.md**
```
# Handoff — <date time> from <signature> (<role>) → next: <role or "anyone">
Task: <T-xxx>   Result: done | partial | blocked
Did:      - ...
Next:     - ...   (first concrete step)
Watch out: - ...  (gotchas, flaky tests, half-done edits)
Files touched: ...
```
**DECISIONS.md** entry (append; IDs never reused)
```
## D-007 <title> — active            (active | superseded by D-0xx | reverted)
<date> · <signature> · depends on: D-002 · task: T-004
Decision: ...   Why: ...   Rejected: ...
```
The `depends on` and `superseded by` links make this a decision tree. Keep a one-line index of
active decisions at the top of the file.

**tasks/T-xxx.md**
```
# T-xxx <title> — status: planned | in-progress | testing | done
Goal / Approach / Files / Acceptance criteria (checkboxes) / Notes / Test report / Review
```

## 6. Compaction (keep shared memory small and cheap to read)
- STATE.md: 60 lines or fewer, always rewritten. HANDOFF.md: 40 lines or fewer, always overwritten.
- LOG.md: over 150 lines → move the oldest 100 lines to `.ai/archive/log-<YYYY-MM>.md`, leaving a 2-line summary at the top.
- DECISIONS.md: over 250 lines → move superseded or reverted entries to `.ai/archive/decisions-<YYYY-MM>.md`.
  Keep the active ones and the index.
- tasks/: when done, move a task file to `.ai/archive/tasks/` after one more session.
- Compaction never deletes history. It only moves it to the archive.

## 7. Git (every project is a git repo; git is the full history)
- **Not a repo yet** (`git rev-parse --is-inside-work-tree` fails): run `git init` in the project folder.
  Don't do this in your home folder, Desktop, Documents, Downloads, or the root of a drive, OneDrive or Dropbox;
  ask the user which subfolder is the project instead. If a parent folder is already a repo, use that repo.
- **.gitignore**: if it is missing, create one with at least
  `.env`, `.env.*`, `*.pem`, `*.key`, `node_modules/`, `.venv/`, `__pycache__/`, `dist/`, `build/`, `.DS_Store`, `Thumbs.db`.
  Add `!.env.example` if one exists. Commit `.ai/`, `AGENTS.md` and `CLAUDE.md`: they are the shared memory.
- **Identity**: if `git config user.name` or `user.email` is empty, set them for this repo only:
  `git config user.name "AI agents"` and `git config user.email "ai-agents@localhost"`.
- **Commit** at the end of every session that changed files, unless AGENTS.md says `Auto-commit: no`:
  - Stage only the files you changed (`git add <paths>`), not `git add -A`. Another agent's uncommitted work isn't yours to commit.
  - Before committing, check that nothing staged looks like a secret. If something does, unstage it and tell the user.
  - Command: `git commit --author="<surface> <ai@localhost>" -m "[<signature>] <task-id>: <summary>"`,
    e.g. `--author="codex-app <ai@localhost>"` (surface only, no model).
    Then `git log --author=codex-app` lists that surface's work.
- **Never** push, force-push, rebase, `reset --hard`, delete branches or rewrite history unless the user asks.
- If your sandbox blocks git (e.g. Codex keeps `.git/` read-only), ask for approval to run that git command outside the
  sandbox through your tool's normal approval prompt. Only if that is declined or impossible, note it in HANDOFF.md and
  tell the user. Never work around it any other way.

## 8. Helper reviewer in Herdr (only when env var `HC_TERMINAL_ID` is set)
When the user asks for a quick review or second opinion ("get a review", "ask codex to check this"), don't hand off;
start a read-only helper with herdr-core and report back:
1. Pick the helper: the agent the user named, else a different tool than you (claude -> codex, codex -> claude,
   antigravity -> claude).
2. Start it: `hc run --bg --name review --cwd <project> <cmd> "<task>"`, where `<cmd>` is `claude` or `codex`;
   for Antigravity use `hc run --bg --name review --cwd <project> agy -i "<task>"`.
   `<task>` = "Read-only review of <scope> against .ai/tasks/T-xxx.md and .ai/DECISIONS.md. Do not edit files,
   commit or start agents. Report findings, most severe first, with: hc send <your HC_TERMINAL_ID> \"<findings>\"".
   Put your own `HC_TERMINAL_ID` value in literally.
3. `hc wait review` (a timeout is a check-in: wait again). Then `hc read review --lines 80` if no message came.
4. Summarize the findings for the user, record the ones they accept in the task's `Review` section, then `hc rm review`.
Never start helpers unless the user asks. The helper is read-only; you (the lead) do the end-of-session steps.
