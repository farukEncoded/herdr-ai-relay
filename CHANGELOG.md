# Changelog

## 0.4.0 (2026-11-27)

**Smart model selection: the planner does the heavy lifting, the relay picks the model, and it learns every day.**
- **The planner plans the work, not the models.** On a new project it writes `.ai/relay-profile.json`: the project
  type (13 types, from landing page to web app), its complexity and risk, and an OpenRouter budget. It splits the work
  into tasks with one kind of work each and labels them `Labels: kind=ui, size=M, risk=low` (14 kinds).
- **Labels pick the agent and model** for every role, across all four agents. For example: assets go to Codex (image
  generation), UI to Antigravity, copy and logic to Claude Sonnet, review to Opus. Risk and size adjust the tester and
  reviewer. Equally good choices start on the plan with the most quota left.
- **Large or risky tasks get a refiner** that sharpens the task file before it is built.
- **Five levels, most specific wins:** a live switch, the task's `Relay:` line, its labels, the run's options, the
  project profile, then your defaults. `relay switch executor=claude:sonnet@high` changes the next stage without
  stopping the relay; `relay explain T-012` shows what each role would get, and why.
- **Spends less:** after a small fix, testers and reviewers step one model down. A free tester is never the only check,
  and a tester that passed what the reviewer then failed is upgraded. Every relay has an OpenRouter budget per run and
  per stage. The executor is skipped when the work is already committed. The PC stays awake while a relay runs.
- **Learns day by day:** every task's outcome is recorded. `tools/selection-tuner.ps1` scores each kind, role and
  model. It applies only safe changes itself (it demotes models that stall or miss, and moves a cheaper model of the
  same agent first when it did as well); anything else is a proposal you accept in the panel. Every change can be
  rolled back. 1 in 10 low-risk tasks tries a cheaper model so it can learn.
- **Model report:** day by day, by task kind, the tuner's changes, and what was saved compared with running everything
  on Opus.
- **Daytime permissions, opt-in per project:** list a project in `permissions.skipProjects` (or run with
  `-SkipPermissions`) and its agents start without permission checks, as overnight runs do. The list is empty by
  default.
- **Panel and floating pill:** Pause and Stop show at once as "pausing/stopping after this stage", with buttons to undo
  them. A relay that stopped responding stays visible as a grey pill. A new *Selection tuner* card shows proposals.
- **Fixes:** a queue task no longer inherits the previous task's fix-round number.
- **Setup**: the kit version is 0.4.0. Your relay-defaults.json is kept; copy the new `selection` and `permissions`
  blocks from the kit's file to use the matrix and profiles (without them the relay behaves as before).
## 0.3.1 (2026-11-25)

- **The LOG stays complete.** When a stage finishes without writing its line in `.ai/LOG.md` (some OpenCode models
  skip it), the relay writes one for it (signature, role, task) and commits only that file, as `ai-relay`. Other
  uncommitted work is left alone.
- The stats still record that the agent skipped it (`logFilled`), so the protocol score and the model scout stay honest.
- **Setup**: the kit version is 0.3.1.

## 0.3.0 (2026-11-25)

**Model scout: OpenRouter's new models, graded for your relay.**
- `tools/model-scout.mjs` pulls credible data every day: OpenRouter's model list (price, context, tool calling),
  per-provider uptime, the Artificial Analysis Intelligence Index and Vals Index (from OpenRouter's rankings data),
  OpenRouter's coding usage per task (implementation, testing, code review, planning) and Terminal-Bench. Sources
  older than 180 days (today SWE-bench Verified and Aider) are skipped automatically, never guessed.
- It scores each candidate per role. Your own measurements weigh most: `tools/model-bench.ps1` runs small relay
  tasks with a known right answer (tester: find 2 planted bugs; executor: make acceptance tests pass; reviewer:
  catch a planted problem) and checks every protocol step.
- Changes: the tester list updates itself, only on measured evidence; executor, reviewer and planner get proposals
  you Accept or Dismiss in the panel. Paid models are benchmarked only when credible data says it's worth it and
  within a cap; free ones any time. Every change is logged with its reason (`usage/model-ledger.jsonl`).
- Trials: 1 in 5 tester stages may try the scout's trial model (free models, projects that allow them).
- **Signatures**: the relay tells OpenCode its exact signature (`opencode-cli/<model>`), so LOG lines, commits and
  done files always name the model that did the work, also after a switch.
- Needs Node (already there with OpenCode). **Setup**: the kit version is 0.3.0.

## 0.2.1 (2026-11-25)

- **Fix: OpenCode now gets the shared protocol.** Setup step 3 adds it to `~/.config/opencode/AGENTS.md` (OpenCode's
  global rules), next to Claude, Codex and Antigravity. Before, OpenCode stages were told to follow a protocol they
  had never seen, so they skipped the LOG line and signed wrongly. Measured on a tester benchmark (a task with two
  planted bugs): with the protocol, OpenCode on Nemotron 3 Ultra (free) and on DeepSeek V4.1 Flash both found both
  bugs, left the production code alone and kept every protocol step.
- **Protocol**: OpenCode's signature surface is `opencode-cli` (for example `opencode-cli/deepseek-v4.1-flash`).
- **Setup**: the kit version is 0.2.1.

## 0.2.0 (2026-11-25)

**Quota no longer stops a relay.**
- **Fallback when an agent runs out:** a limit that resets within 20 minutes is waited out; otherwise Antigravity
  switches model inside the running session (its Gemini models share one quota, so it moves to its Claude models),
  and a Claude or Codex stage is handed to another agent in a "(takeover)" tab that continues from the repo's state.
  No quota wait lasts longer than 30 minutes. Antigravity's model picker saves its choice as your default; the relay
  puts your default back.
- **Quota planner:** frontier agents first; relay stages use Claude only up to 75 % of its 5-hour limit (the
  reviewer up to 90 %), so your own Claude chats keep working; before each stage the relay skips an agent that
  probably can't finish it (learned from your past stages); near a limit the tester (and the reviewer in fix rounds)
  starts one effort step lower, never the executor.

**OpenCode + OpenRouter as an optional fourth agent.**
- The relay picks an OpenRouter model per role from live data (listed now, tool calling, quota left, within your
  key's budget, paced weekly), uses it as a backup when your plans run out, and measures its exact cost.
- Free models stay off until you allow them per project (`opencode.freeModelProjects` in relay-defaults.json):
  their providers may keep what they're sent. No key, no OpenCode stages.

**Measured, so it can be tuned.**
- Every stage of every agent is recorded (`usage/model-stats.jsonl`): model, minutes, tokens, cost, round outcome,
  quota switches, and whether the agent kept the protocol (LOG line, signature, its own commit).
- `tools/model-report.ps1` writes a report with charts (pass rate, cost, minutes, protocol kept, rounds to
  approval, OpenRouter price history) and suggestions; `-Apply` makes only the safe ones.

**Easier to watch.**
- Panel: plan use with "safe until ~HH:MM", Claude's reserve, Antigravity outages, the OpenRouter week budget, a
  Models card (Open report, Update, Apply safe), a switch mark on stages that fell back.
- Notifications when a stage switches model, another agent takes over, the relay waits for quota, or it finishes.
- The Start dialog shows an estimate from your past stages (minutes, plan use, cost, per fix round).
- The relay tab prints one line per stage; the full task is in `.ai/relay/stage-N.task.txt`.
- Setup: two new steps, "OpenCode + OpenRouter (optional)" and "Live usage and model report" (two Windows tasks).
- A relay never opens in another project's Herdr space; one relay per project (from 0.1.2).

- **Setup**: the kit version is 0.2.0, so the panel offers to update relay files copied by older versions.
- **Setup fixes (found by installing this release on a real machine)**: Remove no longer deletes a relay file that
  was already there with the same text, no longer re-saves programs.json when every entry was already yours, and
  leaves Windows tasks you set up yourself alone. Step 5 shows "Already there" when your + menu has the entries.

## 0.1.2 (2026-11-25)

- **Fix: a relay never lands in another project's space.** Herdr names an unnamed space after its first terminal's
  folder, while its saved folder can belong to a different project. The relay (and the *Start AI relay* dialog) used
  the saved folder, so a relay could open its tabs in the space the sidebar showed as another project. Now a space is
  used only when its running terminals work in this project alone; otherwise the relay opens its own named space
  (with just the *AI Relay* tab).
- **One relay per project**: starting a second relay on a project whose relay is still running is refused with a
  clear message.
- **Clearer start from an agent**: the relay says where it runs ("space …, tab 'AI Relay'") and how many answers it
  needs (overnight: one y for the pre-flight; queue: one y), and shows its tab when it asks right away.
- **Panel**: follows the tab you look at, so it always shows the same project as that tab.
- **Sturdier stage tabs**: when Herdr is slow to acknowledge a new stage tab, the relay finds it by a unique name
  instead of opening a duplicate.
- **New relay options**: `-PauseOnUnapproved` holds a queue when a task is still not approved after its fix rounds
  (approve it in the task file, then Resume); `-KeepPermissions` keeps normal agent permissions in overnight mode.
- **Docs**: a plainer pitch in the README and the herdr.dev gallery text (RECIPE.md).
- **Setup**: the kit version is 0.1.2, so the panel offers to update relay files copied by older versions.

## 0.1.1 (2026-11-24)

- **Panel**: a relay that was started before *Make overnight* existed now shows a greyed **Overnight n/a**
  (its tooltip says to start the relay again) instead of a Make overnight button that could do nothing.
- **README**: install straight from GitHub (`add this mod: github.com/farukEncoded/herdr-ai-relay`), which works
  before the herdr.dev gallery lists the mod; the herdr.dev line now names the real owner.
- **Setup**: the kit version is 0.1.1, so the panel offers to update relay files copied by 0.1.0.

## 0.1.0 (2026-11-24): first public release

- **Relay**: runs a project through a team of agents, each in its own Herdr tab. The built-in coding team is
  planner → executor → tester → reviewer, with fix rounds until the reviewer approves.
- **Teams**: custom teams with a job per role, `once` roles and one judge (`relay-defaults.json`).
- **Run types**: Full, Build, Review, and Queue (plan a big goal into tasks, approve them, then a mini-relay per
  task with agents chosen from each agent's strengths).
- **Start it anywhere**: the *Start AI relay* dialog (Ctrl+Alt+R), `relay` in PowerShell, or `relay` typed in Claude
  Code, Codex or Antigravity, with "me" roles for the calling agent.
- **Effort and model per role** (Recommended, agent default, or custom); the executor always runs at high effort or
  above.
- **AI Relay panel**: the project's Next list, status and recent work; live stages with agent, model, effort,
  minutes, tokens and cost; Claude and Codex plan usage; Pause, Stop and Make overnight.
- **Overnight mode**: unattended runs that skip agent permissions on purpose. They work on their own branch (never
  pushed), run until a time, a number of cycles or until done, and start with a pre-flight. A watchdog handles
  stalls and usage limits, and a morning report is written. Running relays can switch to overnight or change their
  limits.
- **Stage clean-up**: agents stop what they start, and the relay stops servers or test runs a stage left behind.
- **Resilience**: the relay waits out Herdr restarts, and an error that ends a relay is shown in the panel.
- **Codex**: stages start with `--approve-for-me`. The Windows sandbox mode is configurable (`codexWindowsSandbox`).
- **Setup screen**: detects agents and links to their official install pages, copies the engine, and adds the
  shared protocol per agent (with backups). It also adds `relay` to PATH and fills Herdr's + menu. Remove undoes
  everything.
- **Also included**: the handoff viewer (Ctrl+Alt+H), the AI commands list (Ctrl+Alt+A) and an optional floating
  relay drawer.
