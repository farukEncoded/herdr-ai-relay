// Start AI relay: a dialog that fills in every relay argument, so the relay asks nothing in
// the terminal. Opens a tab named "AI Relay" in the project's space running ai-relay.ps1
// (installed by the panel's "Set up AI relay" in ~/.agents/protocol).
// Opened by the AI Relay panel, the AI commands list and Ctrl+Alt+R (mod.open ai-relay-kit-launcher).

import { View, div, image } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { spaces, theme, run, closeOverlay, props, pickFolder, readTextFile, appHome, checking } from "herdr";
import {
  AGENTS, AGENT_KEYS, ROLES, RELAY_ICON, relayIcon, relayPs1, agentIcon, icon, pill, roleColor, activeSpace, spaceDir, findRoot,
  join, baseName, samePath, parseRelay, choiceFor, rememberChoice, isWin, parseJson, relayDefaultsPath, focusPanel, MOD,
} from "./lib.js";

// Teams: roles in order, each with its default agent and effort; once = first pass only; judge = approves or
// asks for changes (default: the last role). "coding" is built in (same as ai-relay.ps1's); relay-defaults.json
// "teams" adds or overrides teams.
const CODING = [
  { role: "planner", agent: "claude", effort: "high", once: true },
  { role: "executor", agent: "antigravity", effort: "high" },
  { role: "tester", agent: "codex", effort: "medium" },
  { role: "reviewer", agent: "claude", effort: "high", judge: true },
];
const PREFILL = "continue with the Next list in .ai/STATE.md";
function normTeam(list) {
  const t = (Array.isArray(list) ? list : []).filter((r) => r && r.role).map((r) => ({
    role: String(r.role).toLowerCase(), agent: AGENTS[r.agent] ? r.agent : "claude",
    effort: r.effort ?? "default", once: Boolean(r.once), judge: Boolean(r.judge), job: r.job ?? "" }));
  if (t.length && !t.some((r) => r.judge)) t[t.length - 1].judge = true;
  return t;
}
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const LEVELS = ["low", "medium", "high", "xhigh", "max", "default"];
const LEVEL_LABEL = { low: "Low", medium: "Med", high: "High", xhigh: "XHigh", max: "Max", default: "Default" };
// The executor always thinks at high or above (ai-relay.ps1 enforces it too).
const EXEC_LEVELS = ["high", "xhigh", "max"];
// Model short names per agent; ai-relay.ps1 ($script:modelNames) turns them into model ids.
const MODELS = {
  claude: [["default", "Default"], ["fable", "Fable"], ["opus", "Opus"], ["sonnet", "Sonnet"], ["haiku", "Haiku"]],
  codex: [["default", "Default"], ["sol", "Sol"], ["astra", "Astra"], ["terra", "Terra"], ["luna", "Luna"]],
  antigravity: [["default", "Default"], ["sonnet", "Sonnet 4.6"], ["opus", "Opus 4.6"], ["gpt-oss", "GPT-OSS"]],
};
const MODEL_DEFAULT = { claude: "Opus 5.5", codex: "GPT-6.2-Sol", antigravity: "Gemini 3.8 Flash" };
const MODEL_MODES = {
  default: { label: "Agent default", about: "Claude Opus 5.5, Codex GPT-6.2-Sol, Antigravity Gemini 3.8 Flash." },
  custom: { label: "Custom", about: "Choose per role. Antigravity's Sonnet/Opus/GPT-OSS ignore effort." },
};
const EFFORT_MODES = {
  recommended: { label: "Recommended", about: "Each role's own effort (coding: tester medium, the rest high)." },
  default: { label: "Agent default", about: "Each agent uses its own setting; the executor still runs high." },
  custom: { label: "Custom", about: "Choose per role. The executor is always high or above." },
};

export default class AiLauncher extends View {
  init(_props, cx) {
    this.goal = InputState.new({ placeholder: "What should the agents do?" });
    this.goal.on("change", (_e, cx) => { this.error = ""; cx.notify(); });
    this.goal.on("submit", () => this.start());
    this.goal.on("focus", (_e, cx) => { this.goalFocused = true; cx.notify(); });
    this.goal.on("blur", (_e, cx) => { this.goalFocused = false; cx.notify(); });
    this.goalFocused = true;
    this.teams = { coding: normTeam(CODING) };
    this.team = "coding";
    this.mode = "full";
    this.roles = this.teamAgents();
    this.rounds = 3;
    this.ask = true;
    this.overnight = false;   // never remembered: an unattended run is chosen fresh each time
    // When the night ends: a time ("08:00") or "done", and a cycle limit (0 = none). Prefilled from relay-defaults.
    this.nightUntil = InputState.new({ placeholder: "07:00" });
    this.nightUntil.on("change", (_e, cx) => { this.error = ""; cx.notify(); });
    this.nightDone = false;
    this.nightCycles = 3;
    this.effortMode = "recommended";
    this.effort = this.recommended();
    this.modelMode = "default";
    this.models = {};
    this.error = "";
    this.space = activeSpace();
    this.root = spaceDir(this.space);
    this.setup = false;
    this.relay = null;
    this.engine = true;  // ai-relay.ps1 installed? (checked below)
    cx.timer.after(50, () => this.goal.focus());
    if (checking()) return;
    cx.spawn(async (cx) => {
      let text = null;
      try { text = await readTextFile(relayPs1()); } catch { /* not there */ }
      this.engine = text != null;
      cx.notify();
    });
    if (!this.root) return;
    cx.spawn(async (cx) => {
      const r = await findRoot(this.root, this.space?.machine);
      await this.useFolder(r.root, cx);
    });
  }

  // A project folder chosen (found or picked): load what it has and what was chosen last time.
  async useFolder(root, cx) {
    this.root = root;
    const machine = this.machine();
    let state = null, status = null;
    try { state = await readTextFile(join(root, ".ai", "STATE.md"), { on: machine }); } catch { /* gone */ }
    try { status = await readTextFile(join(root, ".ai", "relay", "status.json"), { on: machine }); } catch { /* none */ }
    this.setup = state != null;
    this.relay = parseRelay(status);
    // What was chosen last time in this project wins; else relay-defaults.json; else built-in defaults.
    let def = null;
    try { def = parseJson(await readTextFile(relayDefaultsPath())); } catch { /* none */ }
    const pairs = (s) => Object.fromEntries(String(s ?? "").split(",").map((p) => p.split("=").map((x) => x.trim())).filter((kv) => kv.length === 2 && kv[0]));
    const defEffortMode = def?.effort === "none" ? "default" : !def?.effort || def.effort === "recommended" ? "recommended" : "custom";
    const defModelMode = !def?.model || ["default", "none"].includes(def.model) ? "default" : "custom";
    const ov = def?.overnight ?? {};
    this.nightDone = String(ov.until ?? "").toLowerCase() === "done";
    this.nightUntil.set_value(this.nightDone ? "07:00" : String(ov.until ?? "07:00"));
    this.nightCycles = Number.isInteger(ov.maxCycles) ? ov.maxCycles : 3;
    const last = choiceFor(root);
    this.teams = { coding: normTeam(CODING) };
    for (const [name, list] of Object.entries(def?.teams ?? {})) { const t = normTeam(list); if (t.length) this.teams[name] = t; }
    // Old "roles" map in relay-defaults.json: still sets the coding team's agents.
    if (def?.roles) for (const r of this.teams.coding) if (AGENTS[def.roles[r.role]]) r.agent = def.roles[r.role];
    this.team = this.teams[last?.team] ? last.team : this.teams[def?.team] ? def.team : "coding";
    const modes = this.modes();
    this.mode = last?.mode && modes[last.mode] ? last.mode : !this.setup ? "full" : modes[def?.runType] ? def.runType : modes.build ? "build" : "full";
    this.roles = { ...this.teamAgents(), ...((last?.team ?? "coding") === this.team ? last?.roles ?? {} : {}) };
    this.rounds = Number.isInteger(last?.rounds) ? last.rounds : Number.isInteger(def?.maxRounds) ? def.maxRounds : 3;
    this.ask = last?.ask ?? def?.askEachRound ?? true;
    this.effortMode = EFFORT_MODES[last?.effortMode] ? last.effortMode : defEffortMode;
    this.effort = { ...this.recommended(), ...(defEffortMode === "custom" ? pairs(def.effort) : {}), ...(last?.effort ?? {}) };
    this.modelMode = MODEL_MODES[last?.modelMode] ? last.modelMode : defModelMode;
    this.models = { ...(defModelMode === "custom" ? pairs(def.model) : {}), ...(last?.models ?? {}) };
    const cur = this.goal.value().trim();
    if (!cur || cur === PREFILL) this.goal.set_value(this.setup ? PREFILL : "");
    cx.notify();
  }

  // ---------- the current team ----------
  teamRoles() { return this.teams[this.team] ?? this.teams.coding; }
  teamAgents() { return Object.fromEntries(this.teamRoles().map((r) => [r.role, r.agent])); }
  recommended() { return Object.fromEntries(this.teamRoles().filter((r) => r.effort !== "default").map((r) => [r.role, r.effort])); }
  judge() { const t = this.teamRoles(); return (t.find((r) => r.judge) ?? t[t.length - 1]).role; }
  loopRoles() { return this.teamRoles().filter((r) => !r.once).map((r) => r.role); }
  // Run types for this team: full = every role; build = without the once-roles; review = the judge alone.
  modes() {
    const all = this.teamRoles().map((r) => r.role), build = this.loopRoles(), judge = this.judge();
    const once = this.teamRoles().filter((r) => r.once).map((r) => r.role);
    const m = { full: { label: "Full", about: `${all.map(cap).join(" → ")}, then fix rounds`, stages: all, loop: true } };
    if (once.length) m.build = { label: "Build", about: `${build.map(cap).join(" → ")}, then fix rounds (no ${once.join("/")})`, stages: build, loop: true };
    m.review = { label: "Review", about: `One ${judge} pass on the project as it is`, stages: [judge], loop: false };
    // Queue: the once-roles split a big goal into tasks (each names its agents); you approve; a mini-relay per task.
    if (once.length) m.queue = { label: "Queue", queue: true, stages: all, loop: true,
      about: `${once.map(cap).join("/")} splits the goal into tasks, you approve, then ${build.map(cap).join(" → ")} per task with each task's agents` };
    return m;
  }
  setTeam(name) {
    this.team = name;
    this.roles = this.teamAgents();
    this.effort = this.recommended();
    this.models = {};
    const modes = this.modes();
    if (!modes[this.mode]) this.mode = "full";
  }

  machine() {
    return this.space && samePath(spaceDir(this.space), this.root) ? this.space.machine : this.space?.machine ?? null;
  }

  // The space the relay runs in: the shown one if it's this project, else one already there.
  targetSpace() {
    const all = spaces();
    if (this.space && all.some((s) => s.id === this.space.id)) {
      const dir = spaceDir(this.space);
      if (dir && (samePath(dir, this.root) || dir.toLowerCase().startsWith(this.root.toLowerCase()))) return this.space.id;
    }
    return all.find((s) => samePath(spaceDir(s), this.root))?.id ?? null;
  }

  start() {
    const goal = this.goal.value().replace(/[\r\n]+/g, " ").replace(/"/g, "'").replace(/\\/g, "/").trim();
    if (!this.engine) { this.error = "Set up AI relay first (the AI Relay panel)."; return; }
    if (!this.root) { this.error = "Choose a project folder first."; return; }
    if (!goal) { this.error = "Write a goal for this run."; this.goal.focus(); return; }
    const m = this.modes()[this.mode] ?? this.modes().full;
    const pairs = (roles) => roles.map((r) => `${r}=${this.roles[r]}`).join(",");
    const loop = pairs(this.loopRoles());
    const rounds = m.loop ? this.rounds : 0;
    // Herdr drops backslashes inside spaced arguments: the folder goes with forward slashes.
    const folderArg = isWin(this.root) ? this.root.replace(/\\/g, "/") : this.root;
    const argv = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", relayPs1().replace(/\\/g, "/"),
      "-Folder", folderArg, "-Goal", goal, "-Stages", pairs(m.stages), "-Loop", loop, "-MaxRounds", String(rounds)];
    if (rounds > 0 && this.ask) argv.push("-AskEachRound");
    argv.push("-Effort", this.effortArg(m), "-Model", this.modelArg(m), "-Team", this.team);
    if (m.queue) argv.push("-Queue");
    // Overnight: unattended (no questions, all agent permissions skipped, own git branch); the relay still shows a
    // pre-flight check in its tab first and waits for "y" there.
    if (this.overnight) {
      const until = this.nightDone ? "done" : this.nightUntil.value().trim() || "07:00";
      if (!this.nightDone && !/^\d{1,2}(:\d{2})?\s*(am|pm)?$/i.test(until)) { this.error = "Overnight 'until' must be a time like 08:00 (or pick 'Until done')."; return; }
      argv.push("-Overnight", "-Until", until, "-MaxCycles", String(this.nightCycles));
    }
    rememberChoice(this.root, { team: this.team, mode: this.mode, roles: this.roles, rounds: this.rounds, ask: this.ask,
      effortMode: this.effortMode, effort: this.effort, modelMode: this.modelMode, models: this.models });
    const space = this.targetSpace();
    closeOverlay(props().overlay);
    if (space) run("tab.new", { space, name: "AI Relay", folder: this.root, argv });
    else run("space.new", { name: baseName(this.root), folder: this.root, tab: "AI Relay", argv });
  }

  // The relay's -Effort value: "recommended", "none" (agent defaults) or role=level pairs.
  effortArg(m) {
    if (this.effortMode === "recommended") return "recommended";
    if (this.effortMode === "default") return "none";
    const roles = this.usedRoles(m);
    return roles.map((r) => `${r}=${this.effort[r] ?? "default"}`).join(",");
  }

  // Roles this run can use: its stages, plus the fix-loop roles when it loops.
  usedRoles(m) { return this.teamRoles().map((r) => r.role).filter((r) => m.stages.includes(r) || (m.loop && this.loopRoles().includes(r))); }

  effortText(m) {
    const e = this.effortMode === "recommended" ? this.recommended() : this.effortMode === "custom" ? this.effort : {};
    return m.stages
      .map((r) => `${r} ${r === "executor" ? this.execLevel(e[r]) : e[r] ?? "default"}`).join(", ");
  }

  execLevel(l) { return EXEC_LEVELS.includes(l) ? l : "high"; }

  // A role's model if it still belongs to the role's agent (the agent may have been changed since).
  modelFor(role) {
    const name = this.models[role] ?? "default";
    return MODELS[this.roles[role]].some(([v]) => v === name) ? name : "default";
  }

  modelArg(m) {
    if (this.modelMode === "default") return "default";
    const pairs = this.usedRoles(m)
      .map((r) => [r, this.modelFor(r)]).filter(([, v]) => v !== "default");
    return pairs.length ? pairs.map(([r, v]) => `${r}=${v}`).join(",") : "default";
  }

  modelText(m) {
    return m.stages.map((r) => {
      const v = this.modelMode === "custom" ? this.modelFor(r) : "default";
      const name = v === "default" ? MODEL_DEFAULT[this.roles[r]] : MODELS[this.roles[r]].find(([x]) => x === v)[1];
      return `${r} ${name}`;
    }).join(", ");
  }

  effortRow(t, role) {
    const exec = role === "executor";
    const levels = exec ? EXEC_LEVELS : LEVELS;
    const value = exec ? this.execLevel(this.effort[role]) : this.effort[role] ?? "default";
    return h_flex().h(34).gap(10).items_center()
      .child(h_flex().w(84).flex_none().child(pill(role, roleColor(role, t), { h: 20, size: 11.5, px: 8 })))
      .child(div().flex_1().child(this.segment(t, `effort-${role}`, levels.map((l) => ({ value: l, label: LEVEL_LABEL[l] })),
        value, (v) => { this.effort[role] = v; }, { grow: true, px: 6 })));
  }

  modelRow(t, role) {
    const agent = this.roles[role];
    return h_flex().h(34).gap(10).items_center()
      .child(h_flex().w(84).flex_none().child(pill(role, roleColor(role, t), { h: 20, size: 11.5, px: 8 })))
      .child(div().flex_none().child(agentIcon(agent, 14)))
      .child(div().flex_1().child(this.segment(t, `model-${role}`,
        MODELS[agent].map(([v, label]) => ({ value: v, label, tip: v === "default" ? `${MODEL_DEFAULT[agent]} (the agent's own setting)` : undefined })),
        this.modelFor(role), (v) => { this.models[role] = v; }, { grow: true, px: 6 })));
  }

  // ---------- pieces ----------
  label(t, text) { return div().pt(14).pb(6).text_size(11.5).font_medium().text_color(t.dim).child(text); }

  segment(t, id, options, value, onPick, opts = {}) {
    return h_flex().p(3).gap(3).rounded(9).bg(t.background).border(1).border_color(t.border).flex_none()
      .children(options.map((o) => {
        const on = o.value === value;
        return h_flex().id(`${id}-${o.value}`).h(26).px(opts.px ?? 14).gap(6).items_center().justify_center().rounded(6)
          .when(Boolean(opts.grow), (el) => el.flex_1())
          .bg(on ? t.raised : t.background).border(1).border_color(on ? t.input : t.background)
          .text_size(12.5).text_color(on ? t.foreground : t.muted).font_medium().cursor_pointer()
          .hover((s) => s.text_color(t.foreground))
          .when(Boolean(o.tip), (el) => el.tooltip(o.tip))
          .on_click((_e, cx) => { onPick(o.value); cx.notify(); })
          .when(Boolean(o.icon), (el) => el.child(o.icon)).child(o.label);
      }));
  }

  roleRow(t, role) {
    return h_flex().h(36).gap(10).items_center()
      .child(h_flex().w(84).flex_none().child(pill(role, roleColor(role, t), { h: 20, size: 11.5, px: 8 })))
      .child(div().flex_1().child(this.segment(t, `role-${role}`, AGENT_KEYS.map((k) => ({ value: k, label: AGENTS[k].name, icon: agentIcon(k, 14) })),
        this.roles[role], (v) => { this.roles[role] = v; }, { grow: true, px: 8 })));
  }

  button(t, id, content, primary, action, enabled = true) {
    return h_flex().id(id).h(32).px(14).gap(7).items_center().rounded(8)
      .border_1().border_color(primary ? t.solid : t.input).bg(primary ? t.solid : t.raised)
      .text_color(primary ? t.solid_foreground : t.foreground).text_size(12.5).font_medium()
      .when(enabled, (el) => el.cursor_pointer().hover((s) => s.opacity(0.88)).on_click(action))
      .when(!enabled, (el) => el.opacity(0.5))
      .children(content);
  }

  render() {
    const t = theme();
    const modes = this.modes();
    const m = modes[this.mode] ?? modes.full;
    const running = this.relay?.live;
    const rounds = m.loop ? this.rounds : 0;
    const chain = [...m.stages.map((r) => `${r} ${AGENTS[this.roles[r]].name}`)].join(" → ");
    const summary = (rounds ? `${chain}, then up to ${rounds} fix round${rounds > 1 ? "s" : ""}${this.ask ? ", asking each time" : ""}` : chain)
      + `. Models: ${this.modelText(m)}. Effort: ${this.effortText(m)}.`;
    // Header and buttons stay put; the form between them scrolls when Custom rows make it tall.
    return v_flex().id("ai-launcher").size_full().min_h(0).p(18).bg(t.popover).text_color(t.foreground).text_size(12.8)
      .child(h_flex().flex_none().gap(9).items_center()
        .child(image(relayIcon()).size(20).flex_none())
        .child(div().flex_1().text_size(15).font_semibold().child("Start AI relay"))
        .child(div().text_size(11).text_color(t.dim).child("Esc")))

      .child(v_flex().id("launcher-body").flex_1().min_h(0).pr(6).overflow_y_scrollbar()
      .child(this.label(t, "Project"))
      .child(h_flex().h(36).px(10).gap(8).items_center().rounded(9).bg(t.background).border(1).border_color(t.input)
        .child(div().text_color(t.dim).child(icon("folder", 14)))
        .child(div().flex_1().min_w(0).truncate().text_size(12.5).child(this.root ?? "No folder"))
        .when(Boolean(this.root), (el) => el.child(pill(this.setup ? "set up" : "new", this.setup ? t.ansi2 : t.muted)))
        .child(h_flex().id("pick").h(24).px(8).items_center().rounded(6).text_size(12).text_color(t.muted).cursor_pointer()
          .hover((s) => s.bg(t.hover).text_color(t.foreground)).tooltip("Choose another project folder")
          .on_click((_e, cx) => cx.spawn(async (cx) => {
            const f = await pickFolder({ prompt: "Use this folder" });
            if (f) await this.useFolder(f, cx);
          }))
          .child("Change…")))
      .when(Boolean(running), (el) => el.child(h_flex().pt(6).gap(6).items_center().text_size(11.5).text_color(t.ansi3)
        .child(icon("activity", 12)).child("A relay is already running in this project. Stop it first (AI Relay panel).")))
      .when(!this.engine, (el) => el.child(h_flex().id("need-setup").mt(8).p(8).gap(6).items_center().rounded(7).cursor_pointer()
        .bg(t.ansi3 + "1f").text_size(11.5).text_color(t.foreground)
        .on_click(() => { closeOverlay(props().overlay); focusPanel(); run(`${MOD.panel}.setup`); })
        .child(div().text_color(t.ansi3).child(icon("sparkles", 12)))
        .child(div().flex_1().whitespace_normal().child("The relay isn't set up on this computer yet. Click to open Set up AI relay."))))

      .child(this.label(t, "Goal"))
      .child(Input.new(this.goal).h(36).px(10).rounded(9).border_1().border_color(this.goalFocused ? t.accent : t.input).bg(t.background).text_size(12.8).text_color(t.foreground))

      .when(Object.keys(this.teams).length > 1, (el) => el
        .child(this.label(t, "Team"))
        .child(h_flex().gap(12).items_center()
          .child(this.segment(t, "team", Object.keys(this.teams).map((k) => ({ value: k, label: cap(k), tip: this.teams[k].map((r) => r.role).join(" → ") })),
            this.team, (v) => { if (v !== this.team) this.setTeam(v); }))
          .child(div().flex_1().min_w(0).text_size(11.5).text_color(t.dim).whitespace_normal()
            .child(`${this.judge()} approves or asks for changes`))))

      .child(this.label(t, "Run type"))
      .child(h_flex().gap(12).items_center()
        .child(this.segment(t, "mode", Object.entries(modes).map(([value, x]) => ({ value, label: x.label, tip: x.about })), this.mode, (v) => { this.mode = v; }))
        .child(div().flex_1().min_w(0).text_size(11.5).text_color(t.dim).whitespace_normal().child(m.about)))

      .child(this.label(t, "Who does what"))
      .child(v_flex().gap(2).children(m.stages.map((r) => this.roleRow(t, r))))

      .when(m.loop, (el) => el
        .child(this.label(t, `Fix rounds if the ${this.judge()} asks for changes`))
        .child(h_flex().gap(14).items_center()
          .child(this.segment(t, "rounds", [0, 1, 2, 3, 4, 5].map((n) => ({ value: n, label: String(n) })), this.rounds, (v) => { this.rounds = v; }, { px: 11 }))
          .child(h_flex().id("ask").gap(8).items_center().cursor_pointer()
            .when(this.rounds === 0, (el) => el.opacity(0.45))
            .on_click((_e, cx) => { this.ask = !this.ask; cx.notify(); })
            .child(h_flex().size(16).flex_none().items_center().justify_center().rounded(4).border(1)
              .border_color(this.ask ? t.accent : t.input).bg(this.ask ? t.accent : t.background).text_color(t.accent_foreground ?? t.background)
              .when(this.ask, (el) => el.child(icon("check", 11))))
            .child(div().text_size(12.5).text_color(t.foreground).child("Ask me before each fix round")))))

      .child(this.label(t, "Effort (how hard each agent thinks)"))
      .child(h_flex().gap(12).items_center()
        .child(this.segment(t, "effort-mode", Object.entries(EFFORT_MODES).map(([value, x]) => ({ value, label: x.label, tip: x.about })), this.effortMode, (v) => { this.effortMode = v; }))
        .child(div().flex_1().min_w(0).text_size(11.5).text_color(t.dim).whitespace_normal().child(EFFORT_MODES[this.effortMode].about)))
      .when(this.effortMode === "custom", (el) => el
        .child(v_flex().pt(6).gap(2).children(m.stages.map((r) => this.effortRow(t, r)))))

      .child(this.label(t, "Model"))
      .child(h_flex().gap(12).items_center()
        .child(this.segment(t, "model-mode", Object.entries(MODEL_MODES).map(([value, x]) => ({ value, label: x.label, tip: x.about })), this.modelMode, (v) => { this.modelMode = v; }))
        .child(div().flex_1().min_w(0).text_size(11.5).text_color(t.dim).whitespace_normal().child(MODEL_MODES[this.modelMode].about)))
      .when(this.modelMode === "custom", (el) => el
        .child(v_flex().pt(6).gap(2).children(m.stages.map((r) => this.modelRow(t, r)))))

      .child(this.label(t, "Overnight"))
      .child(h_flex().id("overnight").gap(8).items_center().cursor_pointer()
        .on_click((_e, cx) => { this.overnight = !this.overnight; cx.notify(); })
        .child(h_flex().size(16).flex_none().items_center().justify_center().rounded(4).border(1)
          .border_color(this.overnight ? t.ansi3 : t.input).bg(this.overnight ? t.ansi3 : t.background).text_color(t.background)
          .when(this.overnight, (el) => el.child(icon("check", 11))))
        .child(div().text_size(12.5).text_color(t.foreground).child("Run unattended (overnight)")))
      .when(this.overnight, (el) => el
        .child(div().pt(4).text_size(11.5).text_color(t.ansi3).whitespace_normal()
          .child("No questions, ALL agent permissions skipped, work goes on a new git branch (never pushed). Use Queue to keep planning and running tasks. The AI Relay tab asks you to confirm a pre-flight check first; you can watch or step in any time."))
        // When the night ends (whichever comes first).
        .child(h_flex().pt(8).gap(10).items_center()
          .child(div().w(70).flex_none().text_size(12).text_color(t.dim).child("Run until"))
          .child(this.segment(t, "night-until", [{ value: false, label: "A time" }, { value: true, label: "Until done", tip: "No time limit: until the planner finds nothing worthwhile left" }],
            this.nightDone, (v) => { this.nightDone = v; }))
          .when(!this.nightDone, (row) => row.child(Input.new(this.nightUntil).w(80).h(30).px(8).rounded(7).border_1().border_color(t.input).bg(t.background).text_size(12.5).text_color(t.foreground))))
        .when(m.queue, (e2) => e2.child(h_flex().pt(6).gap(10).items_center()
          .child(div().w(70).flex_none().text_size(12).text_color(t.dim).child("Cycles"))
          .child(this.segment(t, "night-cycles", [1, 2, 3, 5, 10, 0].map((n) => ({ value: n, label: n === 0 ? "No limit" : String(n) })),
            this.nightCycles, (v) => { this.nightCycles = v; }, { px: 10 }))))))

      .child(div().flex_none().h(1).mt(12).bg(t.border))
      .child(div().flex_none().pt(10).text_size(11.5).text_color(t.dim).whitespace_normal().child(summary))
      .when(Boolean(this.error), (el) => el.child(div().pt(6).text_size(12).text_color(t.blocked).child(this.error)))
      .child(h_flex().flex_none().pt(14).gap(8).justify_end()
        .child(this.button(t, "cancel", ["Cancel"], false, () => closeOverlay(props().overlay)))
        .child(this.button(t, "start", [icon("play", 13), "Start relay"], true, (_e, cx) => { this.start(); cx.notify(); }, !running && Boolean(this.root) && this.engine)));
  }
}
