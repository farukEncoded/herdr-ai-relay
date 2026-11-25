# Starting an AI relay from inside an agent (Claude Code, Codex, Antigravity)

Use this when the user's whole message is `relay` (or `/relay`, or "start a relay"). You guide the user through
the setup in chat, then start `ai-relay.ps1`. The relay runs in its own Herdr tab, not as your child process.
You may also take one or more roles yourself ("me"): the relay then sends that stage's task to *this* session.

## 1. Read, don't change
- `~/.agents/protocol/relay-defaults.json`: the user's defaults (team, teams, maxRounds, askEachRound, timeoutMin,
  effort, model). Show these as the defaults. A team = roles in order, each with job, agent, effort; `once` = first
  pass only; `judge` = approves or asks for changes (default: the last role). "coding" (planner, executor, tester,
  reviewer) is built in. If the user wants a new team, write it into "teams" there (ask them to confirm the roles,
  order, jobs and judge first).
- The project root (the folder with `.ai/`; usually your working folder) and the `## Next` list in `.ai/STATE.md`.
- `$env:HC_TERMINAL_ID` (your Herdr terminal, e.g. `t40`). Empty = you are not inside Herdr, so "me" is not possible;
  say so if the user picks it.

## 2. Ask everything in ONE message, with defaults, so "ok" accepts them all
```
Relay setup for <project>   (reply "ok" for all defaults, or change any line, e.g. "3: executor=me, 6: custom")
0 Team:      coding (planner, executor, tester, reviewer)      other teams: <names from "teams", if any>
1 Goal:      continue with the Next list in .ai/STATE.md      (Next: <first 2-3 items>)
2 Run type:  build      full = every role | build = without the once-roles (planner) | review = the judge alone
                        | queue = big goal: planner splits it into tasks, each naming its own agents; user approves;
                          then one mini-relay per task (good when parts suit different agents, e.g. assets vs code)
3 Roles:     planner=claude  executor=antigravity  tester=opencode  reviewer=claude
             each: claude | codex | antigravity | opencode | me (this <your agent> session; not for OpenCode)
4 Fix rounds: 3, ask before each: yes
5 Effort:    recommended (each role's own effort; coding: planner high, executor high, tester medium, reviewer high)
             or: agent default | custom e.g. planner=xhigh,tester=low   (the executor is always high or above)
6 Models:    agent defaults (Claude Opus 5.5, Codex GPT-6.2-Sol, Antigravity Gemini 4 Hydrogen, OpenCode: the
             relay's picker, best free or cheap OpenRouter model per role)
             or custom: claude fable|opus|sonnet|haiku, codex sol|astra|terra|luna,
             antigravity hydrogen|flash|sonnet|opus|gpt-oss, opencode glm|deepseek|kimi|nemotron|mimo
7 Stage timeout: 120 min
8 Overnight: no      yes = unattended: no questions, ALL agent permissions skipped, its own git branch.
                     When it ends (first one wins): until <overnight.until> | until done (no time limit),
                     and with queue: <overnight.maxCycles> cycles | N cycles | no limit (0)
```
Fill the lines from relay-defaults.json (roles only for the run type's stages, in the team's order). Leave out line 0
when there is only the coding team. Wait for the answer. Ask again only if an answer is unclear. Never start the
relay before the user answered.

## 3. Build the command
- Stages by run type, in the team's order: full = every role; build = the roles without `once`; review = the judge
  alone (and then `-MaxRounds 0`). Loop = the roles without `once`. Always pass `-Team <name>`.
- Overnight = add `-Overnight -Until <08:00 | done> -MaxCycles <N | 0 = no limit>` (with queue: `-Queue -Overnight ...`).
  The relay asks exactly ONE question: the pre-flight check ("Start the overnight run? y"). An overnight queue starts
  without asking to approve the queue. Never tell the user to answer more than once.
- Queue = full's stages plus `-Queue` (or `-Tasks T-010,T-011` to queue existing task files without planning). Not
  overnight: the relay asks ONE question, to approve the queue ("y").
- A role given to "me" is written `role=here`, plus `-HereTerminal $env:HC_TERMINAL_ID -HereAgent <claude|codex|antigravity>`
  (what you are). Model and effort of "here" roles stay as this session has them.
- Never put double quotes inside -Goal (use ' instead).
- Plan quota is handled by the relay itself (relay-defaults.json `fallback`, D-027): a limit that resets within
  `waitMinutes` is waited out; otherwise Antigravity switches model inside its session (Gemini -> its Claude models),
  and a Claude or Codex stage is handed to another agent. Near a limit the tester (and the reviewer in fix rounds)
  starts one effort step lower; the executor never does. Don't promise the user anything beyond that.
- OpenCode (D-028) runs OpenRouter models: free ones first where relay-defaults.json `opencode.freeModelProjects`
  allows, paid ones within the key's budget. Its cost is measured exactly; `tools/model-report.ps1` shows how every
  agent and model does (usage/model-report.html). OpenCode can't be a "me" role.
- Quota planner (D-029): frontier agents first (codex > claude > antigravity, then opencode); relay stages use Claude
  only up to 75 % of its 5-hour limit (the reviewer up to 90 %), keeping the rest for the user's own Claude chats; an
  agent that probably can't finish a stage is skipped up front; no quota wait lasts over 30 min; when everything is
  out, free OpenRouter models carry on (flagged). Paid OpenRouter spend is paced weekly.
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "{{PROTOCOL_DIR}}\ai-relay.ps1" -Folder "<project root>" `
  -Goal "<goal>" -Stages "executor=here,tester=codex,reviewer=claude" -Loop "executor=here,tester=codex,reviewer=claude" `
  -MaxRounds 3 -AskEachRound -TimeoutMin 120 -Effort recommended -Model default -Team coding `
  -HereTerminal $env:HC_TERMINAL_ID -HereAgent antigravity
```
Leave out -AskEachRound when the user said no; leave out -HereTerminal/-HereAgent when nobody is "me".

## Switching a relay that is already running to overnight (or changing its overnight limits)
When the user asks e.g. "make the running relay overnight until 9, 5 cycles" or "let it run until done", don't start
a new relay. Run (once, in the foreground; Codex: request approval to run it outside the sandbox):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "{{PROTOCOL_DIR}}\ai-relay.ps1" -MakeOvernight `
  -Folder "<project root>" -Until 09:00 -MaxCycles 5        # or -Until done; -MaxCycles 0 = no cycle limit
```
Leave out -Until / -MaxCycles the user didn't mention (then the overnight defaults apply). The running relay switches
within seconds (also while it waits for an answer); on an overnight relay this only changes the limits. Tell the user
the agent already running keeps its own permission mode; the next stages skip all permissions.

## 4. Run it once, in the foreground
It notices it was started by an agent, opens Herdr tab 'AI Relay' in the project's space, prints its terminal and
exits within seconds (D-005). Don't run it in the background, don't wait on or poll it, don't run it twice.
It refuses when a relay already runs for this project: tell the user, don't retry. It prints "Where: space ..., tab
'AI Relay'" and how many answers it needs: repeat those two lines to the user word for word, don't guess them.
Use the full script path above (`$HOME` doesn't expand in every agent's shell); AI Relay Kit's setup wrote it in. Codex: its sandbox blocks the relay
(it writes outside the project and talks to Herdr), so request approval to run it outside the sandbox right away.

## 5. Tell the user, then stop
One short message: where the relay is (space and tab, as the script printed), what the user must answer there (none
or one "y", as the script printed), the stages, who does what, and that the AI Project panel shows progress, models,
effort, tokens and plan usage. If you have a role: end your turn now. The relay pastes your role's task into this
session when your stage comes. That message is your task: follow it exactly (protocol steps, commit, then the
`.ai/relay/stage-N.done` file) and stop. Don't start on your role before that message arrives.
