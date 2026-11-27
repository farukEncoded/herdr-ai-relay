# Model selection in the AI relay (D-034, D-035)

The relay picks agent, model and effort **per stage**. The aim: the cheapest choice that still does the job well,
moving seamlessly to another agent or model when one runs out, stalls or gets too expensive.
The code is in `relay-select.ps1` (parsing and merging), `ai-relay.ps1` (`Select-StageModel`, the stage loop) and
`tools/selection-tuner.ps1` (the daily tuner).

## 0. The planner does the heavy lifting (D-035)

**1. The project, once.** On a project without `.ai/relay-profile.json`, the planner first decides what kind of project it is and writes that file:

```json
{ "projectType": "content-site", "complexity": "M", "risk": "medium", "default": "content-site",
  "budget": { "runCapUsd": 1.0 }, "why": "twelve service pages with claims to check" }
```

- **Project types** (`selection.projectTypes`): landing, brochure, content-site, blog-cms, ecommerce, booking, web-app, pwa, dashboard, api-backend, redesign-migration, bulk-content, brand-assets.
- Each type names the profile that tasks without labels use, the kinds of tasks such projects usually need, and an OpenRouter budget.
- When complexity is L or risk is high, the planner itself thinks at xhigh from then on.

**2. Tasks with one kind of work each, labelled.** Every task file gets:

```
Labels: kind=ui, size=M, risk=low
```

- **Kinds:** ui, content, bulk, assets, logic, backend, data, integration, deploy, bugfix, refactor, tests, docs, research.
- **Size:** S = a small change in a few files; M = one feature or page set; L = many files or a new subsystem.
- **Risk:** high = payments, accounts, personal data, legal claims, or a live site at stake.
- The planner writes a `Relay:` line only to override, with the reason in Notes.
- The planner's prompt also gets a short "what worked in past relays" summary from the tuner.

**3. Labels to models (the kind matrix, `selection.kinds`).** Each kind has chains across all four agents, so the planner doesn't pick models:

| Kind | Executor | Tester | Reviewer |
|---|---|---|---|
| ui | Antigravity Hydrogen, then Sonnet | Sonnet | Opus |
| content | Sonnet | Haiku, then Sonnet | Sonnet |
| bulk | Sonnet, then OpenCode DeepSeek | Haiku, then OpenCode | Sonnet |
| assets | Codex Sol (image generation), then Antigravity | Haiku | Sonnet |
| logic, data, integration, refactor | Sonnet ~ Codex Sol | Sonnet | Opus |
| backend | Sonnet xhigh ~ Codex Sol | Sonnet high | Opus |
| deploy, tests | Codex Sol ~ Sonnet | Sonnet / Haiku | Opus / Sonnet |
| bugfix | Sonnet xhigh, then Codex Sol | Sonnet | Opus |
| docs, research | Sonnet / Opus | Haiku | Sonnet |

- `a ~ b` = equally good: the one whose plan has more quota left starts. Claude's headroom counts against its 75 % reserve.
- **Risk** on top: high â†’ tester Sonnet@high and reviewer Opus@xhigh; low â†’ reviewer Sonnet.
- **Size L** â†’ the executor thinks at xhigh.
- The labels are the task's own level, so they beat a run-wide `-Model`. A `Relay:` line still beats the labels.

**4. The refiner.** A task of Size L or Risk high gets a refiner stage (Opus, else Codex Sol) before its first build. It sharpens the task file (approach, files, testable criteria, test plan, pitfalls) and writes no production code. A task whose work is already committed skips it.

**5. Exploration.** 1 in 10 low-risk tasks (not Size L) tries one model cheaper for the executor and tester, on Claude or Codex only. It never touches the reviewer, paid OpenRouter models, or models named at the stage, task or run level. This is how the relay learns where Haiku is enough.

**6. The daily tuner** (`tools/selection-tuner.ps1`, run by the supervisor with `-Apply`):
- **Score:** for each kind Ã— role Ã— model, a stage counts as good when its round was approved, it didn't stall, and (for a tester) it didn't miss a failure. Only with at least 5 stages (`selection.tuner.minSamples`).
- **Safe changes it applies itself:**
  - demote a model whose stall or miss rate reaches 30 %;
  - put a cheaper model of the same plan agent first when it scored at least as well (Claude: haiku < sonnet < opus < fable; Codex: luna < terra < astra < sol).
- **Proposals for you** (Accept or Dismiss in the panel's *Selection tuner* card): another agent, or a dearer model, that did at least 15 points better. Reviewers are only ever demoted.
- **Where it lives:** changes go into `usage/selection-tuning.json`, an overlay on the kind matrix; `relay-defaults.json` is never edited. Every change is in `usage/selection-ledger.jsonl`; undo one with `tools\selection-tuner.ps1 -Rollback <id>`.
- **Its data:** `usage/model-stats.jsonl` (every stage, now with kind, size, risk, project type, exploration, quota pool), `usage/task-outcomes.jsonl` (every task: approved first time or after how many rounds, fix size, misses, stalls, takeovers, cost, the models used), and `usage/tester-misses.jsonl`.
- **The model report** adds three sections: *Day by day* (tasks approved first time, stalls, cost), *By task kind* (the tuner's scores) and *Selection tuner*. It also estimates the Claude API cost saved by not running everything on Opus.

## 1. Five levels, most specific wins

| Level | Where it comes from | Example |
|---|---|---|
| stage | `relay switch` while a relay runs (`.ai/relay/SWITCH.json`) | `relay switch reviewer=claude:opus@xhigh` |
| task | the task file's `Relay:` line, read again before every stage | `Relay: profile=content, tester=claude:haiku` |
| kind | the task's `Labels:` line through the kind matrix and the tuner's overlay (D-035) | `Labels: kind=ui, size=M, risk=low` |
| run | `-Profile`, `-Stages`/`-Loop`, `-Model`, `-Effort` given at start | `-Profile release` |
| project | `.ai/relay-profile.json`, its `default` profile | `{ "default": "content" }` |
| global | `relay-defaults.json` `selection.profile`, then the team's agents and efforts | `"profile": "team"` |

`-Stages` and `-Loop` count as a run-level choice only where a role's agent differs from the team's. The Start dialog and agents always pass them, so repeating the team's defaults must not beat a task line or the project profile. `-Effort none` means each agent's own default effort for this run.

**Fields merge one at a time:**
- **Agent:** comes from the most specific level that names one.
- **Model:** comes from the most specific level that names one that belongs to that agent. A model for a different agent is ignored, with a note.
- **Effort:** works the same way as the model.

So with `Relay: tester=claude` in the task and `-Model tester=sonnet` for the run, the tester runs `claude:sonnet`. When no level names a model, the agent gets `selection.agentModels` (Claude: planner Opus, executor Sonnet, tester Sonnet, reviewer Opus). Agents not listed there use their own default model.

## 2. Spec syntax

```
agent[:model][@effort]   claude:sonnet@high   codex:sol   opencode:deepseek   agy:hydrogen@high
model[@effort]           haiku@low   sonnet-5.5   claude-opus-5-5   z-ai/glm-5.3
@effort                  @xhigh   (effort only)
a|b|c                    a chain, best first: the first candidate that fits right now runs
```

- **Agents:** `claude`, `codex`, `antigravity` (or `agy`), `opencode` (or `oc`), and `here`.
- **Efforts:** `low`, `medium`, `high`, `xhigh`, `max`, `default`. The executor always runs at high or above.
- **Versions:** a short name points at one exact version (`relay-defaults.json` `selection.catalog`):
  - `sonnet` = `claude-sonnet-5-5`, `opus` = `claude-opus-5-5`, `haiku` = `claude-haiku-5-5`, `fable` = `claude-fable-5-2`.
  - An older version can be named (`opus-4.6`, `claude-sonnet-4-6`). One listed in `selection.dominated` runs only when named, and with a warning.

A task line can mix everything:

```
Relay: profile=content, executor=claude:sonnet@high|codex:sol@high, tester=claude:haiku, tester.recheck=haiku@low
```

`role.recheck` is the model for small re-checks in fix rounds (see 4).

## 3. Fits right now

Before each stage, each candidate in the chain is checked:
- **Claude and Codex:** plan quota, Claude's 75 % reserve, and whether the stage will probably fit (D-029).
- **Antigravity:** the model's quota.
- **OpenCode:** the key, the model's listing and tool calling, its quota, and whether free models are allowed. A paid model must also fit the run's OpenRouter budget.

The first candidate that fits runs. If none fits, the first one starts and the fallback rules take over (D-027).

**While a stage runs, it is handed to the next candidate (a "takeover" tab that continues from the repo) when:**
- its quota runs out (as before);
- it stalls: no change on screen for `watchdog.stallMinutes`. That is tester 15, reviewer 20, others 30 minutes, then one nudge. This now applies in the daytime too, but never to your own `here` session, and a permission question on screen doesn't count as a stall;
- a paid OpenCode stage passes `budget.stageCapUsd` ($1.50), or the run passes `budget.runCapUsd` ($3.00).

The PC is kept awake while any relay runs. After a sleep, the timers restart instead of counting the sleep as a stall.

## 4. Spending less without losing quality

- **Step-down on small re-checks.** In a fix round whose code change is at most 120 lines, the tester and the reviewer step one model down the ladder.
  - Claude ladder: fable, opus, sonnet, haiku. Codex ladder: sol, astra, terra, luna.
  - Floors: tester Haiku, reviewer Sonnet. The reviewer is the gate, so it never drops to Haiku.
  - Never stepped down: the executor, the planner, and any model named at the stage, task or run level.
  - A profile's `tester.recheck` replaces the ladder for that role.
- **A free tester is never the only check.**
  - The tester's done file now ends with `PASS` or `FAIL`.
  - If a tester said PASS and the reviewer then asks for changes, it is recorded as a miss in `usage/tester-misses.jsonl`. The next testers of that task are escalated (`selection.escalate.tester`, default `claude:sonnet@high`).
  - The reviewer after a free tester is never free and never steps down.
  - A model with 2 misses in 30 days in a project, or 2 stalls or skips, is left out of automatic picks there. It still runs when a task names it.
- **No executor stage when the work is already done.** It is skipped in round 0 when all of these hold:
  - the task's status is `testing` or `done`;
  - the latest Review isn't `CHANGES_REQUESTED`;
  - git has a commit naming the task that changed files outside `.ai/`.
- **OpenRouter costs are estimated before a model is picked.**
  - The estimate is the model's own median cost for the role. Without that history, it uses typical tokens for the role times the cache-read price where OpenRouter lists one.
  - Coding agents resend about 200K tokens of context on every step. That is why GLM-5.3 as executor cost about $1.80 an hour.
- **Stable prompt prefix.** The stage message starts with the fixed text (role, job, protocol) and ends with what changes (goal, stage, done file), so providers can cache the beginning.

## 5. Change it while it runs

```
relay switch executor=codex:sol@high              next executor stage only (scope next)
relay switch tester=claude:haiku -SwitchScope run  every tester stage from now on
relay switch clear                                 drop earlier switches
relay explain T-037                                show what each role would get, and why (starts nothing)
```

The stage that is running finishes as it is. The task's `Relay:` line and `.ai/relay-profile.json` are read again before every stage, so editing them also changes the next stage. `status.json` shows each stage's cost, tokens and source (`stages[].source`, for example `task/auto`), the run's `spend`, and waiting `switches`. The model report adds three sections: spend per task, latest stages, and testers that missed.

## 6. Recommended profiles by project type

These are in `relay-defaults.json` `selection.profiles`. A project can use one, or extend one in `.ai/relay-profile.json`.

| Profile | Planner | Executor | Tester | Reviewer | Why |
|---|---|---|---|---|---|
| `simple-site` | sonnet@high | sonnet@high \| agy hydrogen | haiku@medium \| opencode | sonnet@high | Small diffs and low risk: Opus planning and review add cost and catch little |
| `content-site` | opus@high | sonnet@high \| agy hydrogen | haiku@medium \| sonnet; re-check haiku@low | sonnet@high \| opus@medium | Structure and claims need a strong plan. Copy is Sonnet work. Checks are mostly links, build and wording, which Haiku does |
| `pwa-app` | opus@high | sonnet@high \| codex sol \| agy hydrogen | sonnet@medium \| codex astra | opus@high | Client state and offline logic go wrong quietly: a real tester and an Opus review |
| `full-app` | opus@xhigh | sonnet@xhigh \| codex sol | sonnet@high | opus@high | The data model, auth and payments are expensive to get wrong; spend on plan and review |
| `bulk-content` | sonnet@medium | sonnet@high \| opencode deepseek | haiku@low \| opencode | sonnet@medium | Many similar items: the pattern is set once, then cheap checks. Paid OpenRouter only within budget |
| `hard-debug` | opus@max | fable@high \| opus@xhigh | sonnet@high | opus@xhigh | Only where normal fixes failed: Fable needs credits, so it is never picked automatically elsewhere |
| `ui-heavy` | opus@high | agy hydrogen@high \| sonnet@high | sonnet@medium | opus@high | Layout and components suit Antigravity's Gemini, with Sonnet as fallback |
| `release` | opus@high | sonnet@high | sonnet@high | opus@xhigh | The last gate before going live: no step-down savings that matter here |

Codex and Antigravity appear as fallbacks in the chains because they use other plan quotas. When Claude's 5-hour window is at the reserve, the chain moves on instead of waiting. The global default stays `"profile": "team"`, which means your team's agents as today, with each agent's model from `agentModels`.

## 7. Migrating existing projects

Nothing breaks. An old `Relay: executor=claude, tester=claude` line reads the same. Without `.ai/relay-profile.json` a project gets what it got before, apart from one change: a Claude executor or tester now gets Sonnet rather than Claude's default (Opus), when relay-defaults.json has `selection.agentModels`. Check any project with `relay explain T-xxx`, then add a `.ai/relay-profile.json` that extends the profile matching the project's type, for example:

```json
{ "default": "content", "profiles": { "content": { "extends": "content-site" }, "release": { "extends": "release" } }, "budget": { "runCapUsd": 2.0 } }
```

Start new relays without `-Model`, so the profile (not a run-wide model) decides.

## 8. Tests

`tests/relay-select.tests.ps1` has 116 checks covering:
- parsing, versions, the five levels and field-by-field merging;
- chains and what fits;
- step-down, free-tester escalation, OpenRouter estimates and budget, learned demotion;
- skipping the executor, on a temp git repo;
- the switch file, queue task reading, and replacement after a stall.

They load the real functions from the scripts and stub only the quota and network checks. Run them with:

```
powershell -ExecutionPolicy Bypass -File tests\relay-select.tests.ps1
```
