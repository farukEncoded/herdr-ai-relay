# Changelog

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
