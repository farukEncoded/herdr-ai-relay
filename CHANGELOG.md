# Changelog

## Unreleased

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
