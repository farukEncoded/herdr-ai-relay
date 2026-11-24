// AI Relay Kit panel: the focused space's project as the shared AI protocol sees it
// (.ai/STATE.md, LOG.md, relay/status.json), live, with one-click actions, and the
// "Set up AI relay" screen (setup.js) the first time, until the relay files are installed.
// Docks on the right the first time Herdr sees it; a compact rail when it is narrow.
// Ctrl+Alt+P shows it and gives it the keyboard:
// 1/2/3 continue with Claude/Codex/Antigravity, R relay, H handoff, V review, A commands, Esc back.

import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, focused, theme, run, shared, watchFolder, appHome, home, checking, nextCommand, panes, openOverlay } from "herdr";
import {
  AGENTS, AGENT_KEYS, RELAY_ICON, relayIcon, agentIcon, icon, iconButton, pill, tip, roleColor, ago, minutes, relayLine,
  activeSpace, spaceDir, findRoot, readProject, join, baseName, samePath, loadRuns,
  continueWith, setupProtocol, getReview, relayControl, openHandoff, openLauncher, openCommands, AGENT_NAME,
  SHARED_FOCUS, focusPanel, onWindows, MOD,
} from "./lib.js";
import { Setup } from "./setup.js";

// "2026-11-25T07:00:00+01:00" -> "07:00" in local time (Herdr's toLocaleTimeString ignores hour/minute options).
const hhmm = (iso) => { const d = new Date(iso); return isNaN(d) ? "" : `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };
const kilo = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1000 ? `${Math.round(n / 1000)}k` : String(n));
// "gpt-6.2-astra" -> "astra", "claude-opus-4-6-thinking" -> "opus 4.6", "fable" -> "fable".
const shortModel = (m) => {
  const s = String(m ?? "");
  const gpt = s.match(/^gpt-[\d.]+-(\w+)/); if (gpt) return gpt[1];
  const cl = s.match(/^claude-(\w+)-(\d)-(\d)/); if (cl) return `${cl[1]} ${cl[2]}.${cl[3]}`;
  return s;
};

export default class AiProject extends View {
  init(_props, cx) {
    this.key = null;        // space id + folder we last resolved
    this.data = null;       // readProject() result
    this.statusOpen = false;
    this.width = 268;
    this.seenFocus = shared(SHARED_FOCUS) ?? 0;
    this.handle = cx.focus_handle();
    this.setup = new Setup();
    this.view = "project";  // or "setup"
    if (checking()) return;
    cx.spawn(async () => { await loadRuns(appHome()); });
    // First run: nothing installed yet -> the setup screen.
    cx.spawn(async (cx) => {
      const r = await this.setup.detect(cx);
      if (r?.ok && !r.installed) { this.view = "setup"; cx.notify(); }
    });
    // pane.go lands here ("focus"); "panel" = Ctrl+Alt+P; "setup" opens the setup screen; others are actions.
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        if (c === "focus") { this.handle.focus(); cx.timer.after(30, (cx) => cx.notify()); }
        else if (c === "panel") focusPanel();
        else if (c === "setup") this.openSetup(cx);
        else this.act(c);
        cx.notify();
      }
    });
    // Fallback refresh (remote spaces, reclaimed watches) and the relay's elapsed time / heartbeat.
    cx.timer.every(10000, (cx) => { if (this.data) this.reload(cx); });
  }

  async close() { this.watch?.cancel(); }

  // Re-read the project's files; cheap (three small reads).
  reload(cx) {
    const want = this.key, root = this.root, machine = this.machine;
    if (!root) return;
    cx.spawn(async (cx) => {
      const d = await readProject(root, machine);
      if (want !== this.key) return;
      const was = this.data?.setup;
      // Redraw only when something changed (the relay's minutes count as a change).
      const sig = JSON.stringify(d) + (d.relay?.live ? Math.floor(Date.now() / 60000) : "");
      if (sig === this.sig) return;
      this.sig = sig;
      this.data = d;
      if (d.setup !== was) this.startWatch(cx);
      cx.notify();
    });
  }

  // The space or its folder changed: find the project root again.
  resolve(cx, space, dir) {
    const key = `${space?.id}|${dir}`;
    if (key === this.key) return;
    this.key = key;
    this.data = null;
    this.sig = null;
    this.watch?.cancel();
    this.watch = null;
    if (!space || !dir || checking()) { this.root = null; return; }
    this.machine = space.machine;
    cx.spawn(async (cx) => {
      const r = await findRoot(dir, space.machine);
      if (key !== this.key) return;
      this.root = r.root;
      this.reload(cx);
    });
  }

  // Live: watch .ai while it exists (local only; the 10 s timer covers the rest).
  startWatch(cx) {
    this.watch?.cancel();
    this.watch = null;
    const root = this.root, key = this.key;
    if (!root || this.machine || !this.data?.setup) return;
    cx.spawn(async (cx) => {
      while (key === this.key) {
        const w = watchFolder(join(root, ".ai"));
        this.watch = w;
        let paths;
        try { paths = await w; } catch { return; }
        if (key !== this.key || !paths.length) return; // cancelled
        this.reload(cx);
      }
    });
  }

  openSetup(cx) {
    this.view = "setup";
    cx.spawn(async (cx) => this.setup.detect(cx));
    cx.notify();
  }
  closeSetup(cx) {
    this.view = "project";
    this.sig = null;
    if (this.root) this.reload(cx);
    cx.notify();
  }

  // ---------- actions ----------
  ctx() {
    const space = activeSpace();
    return { space: space?.id, folder: this.data?.root ?? spaceDir(space), machine: space?.machine };
  }
  act(what) {
    const { space, folder, machine } = this.ctx();
    if (!space) return;
    if (AGENTS[what]) return continueWith(what, space, folder);
    if (what === "setup") return setupProtocol(space, folder);
    if (what === "review") return getReview(space, folder);
    if (what === "relay") return openLauncher();
    if (what === "handoff") return openHandoff(folder, "HANDOFF", space);
    if (what === "commands") return openCommands();
    if (["pause", "resume", "stop", "overnight"].includes(what)) return relayControl(folder, what, machine).then(() => null);
    if (what === "goto" && this.data?.relay?.terminal) run("pane.focus", { terminal: this.data.relay.terminal });
    // The relay's own tab, where it asks its questions (fix round? queue? timeout?). Relays before 2026-11-22 21:00
    // don't record it: then the newest "AI Relay" tab in this space that still has a terminal.
    if (what === "goto-relay") {
      let term = this.data?.relay?.relayTerminal;
      if (!term) {
        const tabs = (activeSpace()?.tabs ?? []).filter((x) => /^ai relay$/i.test(x.name ?? ""));
        for (const tab of tabs.reverse()) { const p = panes().find((x) => x.tab === tab.id && x.terminal); if (p) { term = p.terminal; break; } }
      }
      if (term) run("pane.focus", { terminal: term });
    }
  }

  key_(e, cx) {
    if (e.modifiers?.control || e.modifiers?.alt || e.modifiers?.platform) return;
    const k = e.key;
    const map = { "1": "claude", "2": "codex", "3": "antigravity", r: "relay", h: "handoff", v: "review", a: "commands" };
    if (k === "escape") {
      const p = focused()?.pane;
      if (p) run("pane.focus", { pane: p });
      cx.stop_propagation();
      return;
    }
    if (map[k] && (this.data?.setup || k === "a")) { this.act(map[k]); cx.stop_propagation(); }
    else if (k === "s" && this.data && !this.data.setup) { this.act("setup"); cx.stop_propagation(); }
  }

  // ---------- pieces ----------
  chip(t) {
    const d = this.data, r = d?.relay;
    const space = activeSpace();
    const working = agents().some((a) => a.space === space?.id && a.status === "working");
    if (!d) return null;
    if (!d.setup) return { text: samePath(d.root, home()) ? "No project" : "Not set up", color: t.dim };
    if (r?.state === "paused") return { text: "Paused", color: t.ansi3, dot: true };
    if (r?.state === "running") return { text: "Relay running", color: t.accent, dot: true, pulse: true };
    if (d.active || working) return { text: "Agent active", color: t.working, dot: true, pulse: working };
    return { text: "Idle", color: t.muted, dot: true };
  }

  section(t, id, label, extra) {
    return h_flex().id(id).px(16).pt(12).pb(4).gap(6).items_center().flex_none()
      .child(div().text_size(11).font_medium().text_color(t.dim).child(label))
      .when(Boolean(extra), (el) => el.child(extra));
  }

  actions(t) {
    const w = this.width;
    const size = w < 236 ? 25 : 28;
    const btn = (k) => iconButton(`act-${k}`, agentIcon(k, 15), tip(`Continue with ${AGENTS[k].name}`, k), () => this.act(k), { size, border: true });
    const sep = div().w(1).h(16).mx(2).bg(t.border).flex_none();
    return h_flex().px(8).pt(4).gap(4).items_center().flex_none()
      .children(AGENT_KEYS.map(btn))
      .child(sep)
      .child(iconButton("act-review", icon("review", 15), "Get a review from a different agent", () => this.act("review"), { size }))
      .child(iconButton("act-relay", image(relayIcon()).size(16).flex_none(), tip("Start relay…", "relay"), () => this.act("relay"), { size }))
      .child(iconButton("act-handoff", icon("handoff", 15), tip("Open handoff", "handoff"), () => this.act("handoff"), { size }));
  }

  // One finished / running / skipped stage: "3 tester [Codex] Sol medium · 12m · 84k tok".
  stageRow(t, s, current) {
    const mark = s.state === "done" ? icon("check", 11) : s.state === "skipped" ? icon("x", 11)
      : div().size(7).rounded(4).bg(t.accent).loop("opacity", { from: 0.35, to: 1, period: 1100 });
    const mins = s.state === "running" && s.started ? Math.floor((Date.now() - Date.parse(s.started)) / 60000) : s.minutes;
    const model = s.here ? "your session" : [s.model !== "default" ? shortModel(s.model) : "", s.effort !== "default" ? s.effort : ""].filter(Boolean).join(" ");
    const use = s.usage ? [s.usage.tokens ? `${kilo(s.usage.tokens)} tok` : "", s.usage.cost ? `$${s.usage.cost.toFixed(2)}` : ""].filter(Boolean).join(" · ") : "";
    const tipText = [`Stage ${s.n} · ${s.role} · ${AGENT_NAME(s.agent)}${s.here ? " (your own session)" : ""}`, s.label,
      `model ${s.model || "default"} · effort ${s.effort || "default"}`, `${mins ?? 0} min${s.by ? ` · done by ${s.by}` : ""}`,
      use, s.verdict ? `verdict ${s.verdict}` : "", s.terminal ? `terminal ${s.terminal}` : "",
      Array.isArray(s.cleaned) && s.cleaned.length ? `cleaned up after it: ${s.cleaned.join("; ")}` : ""].filter(Boolean).join("\n");
    const cleaned = Array.isArray(s.cleaned) && s.cleaned.length > 0;
    return h_flex().id(`stage-${s.n}`).h(22).gap(6).items_center().min_w(0).rounded(5).tooltip(tipText)
      .when(Boolean(s.terminal), (el) => el.cursor_pointer().hover((st) => st.bg(t.hover))
        .on_click(() => run("pane.focus", { terminal: s.terminal })))
      .child(h_flex().w(12).flex_none().justify_center().text_color(s.state === "done" ? t.ansi2 : t.dim).child(mark))
      .child(div().w(14).flex_none().text_size(11).text_color(t.dim).child(String(s.n)))
      .child(pill(s.role ?? "?", roleColor(s.role, t), { h: 16, size: 10, px: 5 }))
      .when(Boolean(AGENTS[s.agent]), (el) => el.child(agentIcon(s.agent, 12)))
      .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(current ? t.foreground : t.muted).child(model))
      .when(s.verdict === "CHANGES_REQUESTED", (el) => el.child(div().flex_none().size(6).rounded(3).bg(t.ansi3)))
      .when(cleaned, (el) => el.child(div().flex_none().text_size(10).text_color(t.ansi3).child("⌫")))
      .child(div().flex_none().text_size(10.5).text_color(t.dim).child([use.split(" · ")[0], `${mins ?? 0}m`].filter(Boolean).join(" · ")));
  }

  // One queued task: state, id, title, and the agents its Relay: line chose.
  queueRow(t, q, i) {
    const color = q.state === "done" ? t.ansi2 : q.state === "running" ? t.accent : q.state === "pending" ? t.dim : t.ansi3;
    const mark = q.state === "done" ? icon("check", 11) : q.state === "running"
      ? div().size(7).rounded(4).bg(t.accent).loop("opacity", { from: 0.35, to: 1, period: 1100 })
      : q.state === "pending" ? div().size(6).rounded(3).border(1).border_color(t.dim) : icon("x", 11);
    const agents = String(q.agents ?? "").split(",").map((p) => p.split("=").map((x) => x.trim())).filter((kv) => kv.length === 2);
    return h_flex().id(`queue-${i}`).h(22).gap(6).items_center().min_w(0).rounded(5)
      .tooltip([`${q.id} · ${q.title}`, `state: ${q.state}${q.verdict ? ` · ${q.verdict}` : ""}${q.rounds ? ` · ${q.rounds} fix round(s)` : ""}`,
        `agents: ${q.agents}`, q.file ? `.ai/tasks/${q.file}` : ""].filter(Boolean).join("\n"))
      .child(h_flex().w(12).flex_none().justify_center().text_color(color).child(mark))
      .child(div().flex_none().text_size(11).text_color(q.state === "running" ? t.foreground : t.muted).child(String(q.id ?? "")))
      .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(t.dim).child(String(q.title ?? "").replace(q.id, "").trim()))
      .children(agents.filter(([role]) => role === "executor" || agents.length <= 2).map(([role, ag]) =>
        AGENTS[ag] ? agentIcon(ag, 12) : div().text_size(10).text_color(t.dim).child(ag)));
  }

  // Plan usage bars: Claude / Codex 5-hour and weekly, as last saved; Antigravity keeps no numbers.
  usageCard(t, u) {
    // A window the vendor didn't report (e.g. Claude omits five_hour at times): a dash, never null (null crashes child()).
    const bar = (label, w) => {
      if (!w || typeof w.used !== "number") return h_flex().gap(6).items_center().tooltip(`${label}: not reported this time`)
        .child(div().w(34).flex_none().text_size(10.5).text_color(t.dim).child(label))
        .child(div().flex_1().text_size(10.5).text_color(t.dim).child("–"));
      const pct = Math.max(0, Math.min(100, Math.round(w.used)));
      const color = pct >= 90 ? t.blocked : pct >= 70 ? t.ansi3 : t.ansi2;
      const reset = w.resets ? Date.parse(w.resets) - Date.now() : NaN;
      return h_flex().gap(6).items_center().min_w(0).tooltip(`${label}: ${pct}% used${isNaN(reset) ? "" : reset > 0 ? `, resets in ${minutes(reset)}` : ", reset since"}`)
        .child(div().w(34).flex_none().text_size(10.5).text_color(t.dim).child(label))
        .child(h_flex().flex_1().h(5).rounded(3).bg(t.border)
          .child(div().h(5).rounded(3).bg(color).flex_basis(0).flex_grow(Math.max(pct, 1)))
          .child(div().h(5).flex_basis(0).flex_grow(Math.max(100 - pct, 0.01))))
        .child(div().w(30).flex_none().text_size(10.5).text_color(pct >= 90 ? t.blocked : t.muted).child(`${pct}%`))
        .child(div().w(40).flex_none().text_size(10).text_color(t.dim).child(isNaN(reset) || reset <= 0 ? "" : `↻ ${ago(reset)}`));
    };
    const vendor = (key, data) => v_flex().gap(3)
      .child(h_flex().gap(6).items_center()
        .child(agentIcon(key, 12))
        .child(div().flex_1().text_size(11.5).text_color(t.foreground).child(AGENT_NAME(key) + (data?.plan ? ` · ${data.plan}` : "")))
        .child(div().text_size(10).text_color(t.dim).child(data?.at ? `as of ${ago(Date.now() - Date.parse(data.at))}` : "")))
      .child(data ? v_flex().gap(2).child(bar("5 h", data.fiveHour)).child(bar("week", data.week))
        : div().text_size(10.5).text_color(t.dim).child(key === "antigravity" ? "Antigravity doesn't report usage" : "No data yet (updates when a relay runs it)"));
    return v_flex().mx(8).mt(8).p(10).gap(8).rounded(9).bg(t.background).border(1).border_color(t.border).flex_none()
      .children(["claude", "codex", "antigravity"].map((k) => vendor(k, u?.[k])));
  }

  relayCard(t, r) {
    const stateText = { running: "Running", waiting: "Needs you", paused: "Paused", finished: "Finished", stopped: "Stopped", lost: "Not responding" }[r.state] ?? r.state;
    const stateColor = { running: t.accent, waiting: t.ansi3, paused: t.ansi3, finished: t.muted, stopped: t.dim, lost: t.dim }[r.state] ?? t.dim;
    const stages = Array.isArray(r.stages) ? r.stages : [];
    const queue = Array.isArray(r.queue) ? r.queue.filter(Boolean) : [];
    const done = stages.filter((s) => s.state === "done").length;
    const total = r.plannedMax ? (r.verdict === "APPROVED" || !r.live ? stages.length : r.plannedMax) : 0;
    const elapsed = r.relayStarted ? minutes((r.live ? Date.now() : Date.parse(r.updated)) - Date.parse(r.relayStarted)) : "";
    const tok = stages.reduce((a, s) => a + (s.usage?.tokens ?? 0), 0);
    const cost = stages.reduce((a, s) => a + (s.usage?.cost ?? 0), 0);
    const verdict = r.verdict === "APPROVED" ? pill("APPROVED", t.ansi2) : r.verdict ? pill("CHANGES REQUESTED", t.ansi3) : null;
    const textBtn = (id, ic, label, action, danger) => h_flex().id(id).h(24).px(8).gap(5).items_center().rounded(6)
      .border(1).border_color(t.border).text_size(11.5).text_color(t.muted).cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(danger ? t.blocked : t.foreground))
      .on_click(action).child(icon(ic, 12)).child(label);
    return v_flex().mx(8).mt(8).p(10).gap(7).rounded(9).bg(t.background).border(1).border_color(t.border).flex_none()
      .child(h_flex().gap(7).items_center()
        .child(image(relayIcon()).size(15).flex_none())
        .child(div().text_size(12.5).font_medium().text_color(t.foreground).child("Relay"))
        .child(pill(stateText, stateColor, { dot: r.live, pulse: r.state === "running" }))
        .when(Boolean(r.overnight), (el) => el.child(div().id("relay-night").tooltip([
            "Overnight: no questions, all agent permissions skipped, keeps going on its own.",
            r.nightBranch ? `Branch: ${r.nightBranch} (never pushed)` : "",
            r.until === "done" ? "No time limit: until nothing worthwhile is left" : r.until ? `No new task after ${hhmm(r.until)}` : "",
            r.maxCycles > 0 ? `Cycle ${r.cycle || 1} of ${r.maxCycles}` : r.queueMode ? "No cycle limit" : "",
            "Morning report: .ai/relay/overnight-report.md"].filter(Boolean).join("\n"))
          .child(pill(`Overnight · ${[r.until === "done" ? "until done" : r.until ? `until ${hhmm(r.until)}` : "",
            r.queueMode && r.maxCycles > 0 ? `${r.cycle || 1}/${r.maxCycles} cycles` : ""].filter(Boolean).join(" · ") || "on"}`, t.ansi4))))
        .child(div().flex_1())
        .when(r.live, (el) => el.child(r.state === "waiting" || !r.terminal
          ? iconButton("relay-goto", icon("arrow-right", 13), "Go to the AI Relay tab", () => this.act("goto-relay"), { size: 22 })
          : iconButton("relay-goto", icon("arrow-right", 13), "Go to this stage's tab", () => this.act("goto"), { size: 22 }))))
      .child(h_flex().id("relay-line").gap(6).items_center().min_w(0).tooltip(relayLine(r))
        .child(div().flex_none().text_size(12).text_color(t.foreground).child(`Stage ${r.stage}`))
        .when(Boolean(r.role), (el) => el.child(pill(r.role, roleColor(r.role, t))))
        .when(Boolean(AGENTS[r.agent]), (el) => el.child(agentIcon(r.agent, 13)))
        .when(Boolean(r.agent), (el) => el.child(div().truncate().text_size(12).text_color(t.muted).child(AGENT_NAME(r.agent)))))
      .child(h_flex().gap(6).items_center().min_w(0)
        .child(div().flex_1().min_w(0).truncate().text_size(11.5).text_color(t.dim)
          .child([r.round > 0 ? `fix round ${r.round}/${r.maxRounds}` : r.label, r.live && r.started ? ago(Date.now() - Date.parse(r.started)).replace("now", "<1m") : ""].filter(Boolean).join(" · ")))
        .when(Boolean(verdict), (el) => el.child(verdict)))
      // Why the relay stopped, when an error ended it.
      .when(Boolean(r.error), (el) => el.child(h_flex().id("relay-error").gap(6).p(6).rounded(6).bg(t.blocked + "1f")
        .cursor_pointer().on_click(() => this.act("goto-relay")).tooltip("Open the AI Relay tab for the details")
        .child(div().text_color(t.blocked).child(icon("x", 12)))
        .child(div().flex_1().min_w(0).whitespace_normal().text_size(11).text_color(t.foreground).child(`Stopped by an error: ${String(r.error).slice(0, 220)}`))))
      // The question the relay is waiting on, in its tab.
      .when(r.state === "waiting" && Boolean(r.waiting), (el) => el.child(h_flex().id("relay-waiting").gap(6).p(6).rounded(6)
        .bg(t.ansi3 + "1f").cursor_pointer().on_click(() => this.act("goto-relay")).tooltip("Open the AI Relay tab to answer")
        .child(div().text_color(t.ansi3).child(icon("activity", 12)))
        .child(div().flex_1().min_w(0).whitespace_normal().text_size(11).text_color(t.foreground).child(r.waiting))))
      // Progress and totals: "3 of up to 13 stages · 1 h 12 min · 412k tok · $1.80".
      .when(stages.length > 0, (el) => el.child(div().text_size(11).text_color(t.dim).whitespace_normal()
        .child([queue.length ? `${queue.filter((q) => q.state === "done").length} of ${queue.length} tasks done · ${done} stages`
          : `${done} of ${total ? (r.verdict === "APPROVED" || !r.live ? total : `up to ${total}`) : stages.length} stages done`,
          elapsed, tok ? `${kilo(tok)} tokens` : "", cost ? `$${cost.toFixed(2)} Claude` : ""].filter(Boolean).join(" · "))))
      // Queue mode: one row per task with its agents, then the stages of the current (or last) task.
      .when(queue.length > 0, (el) => el.child(v_flex().gap(1)
        .child(div().text_size(10.5).text_color(t.dim).child(`Queue · task ${Math.max(1, queue.findIndex((q) => q.id === r.currentTask) + 1 || queue.filter((q) => q.state !== "pending").length)} of ${queue.length}`))
        .children(queue.map((q, i) => this.queueRow(t, q, i)))))
      .when(stages.length > 0, (el) => el.child(v_flex().gap(1)
        .children((queue.length ? stages.filter((s) => s.task === (r.currentTask || stages[stages.length - 1].task)) : stages)
          .map((s) => this.stageRow(t, s, s.n === r.stage && r.live)))))
      // What this run was started with.
      .when(Boolean(r.config), (el) => el.child(div().id("relay-config").text_size(10.5).text_color(t.dim).truncate()
        .tooltip([r.config.team ? `team: ${r.config.team} (judge: ${r.config.judge})` : "", `stages: ${r.config.stages}`, `fix loop: ${r.config.loop} (max ${r.maxRounds})`, `effort: ${r.config.effort}`,
          `model: ${r.config.model}`, r.config.here ? `your session: ${r.config.here}` : "", `stage timeout: ${r.timeoutMin} min`,
          r.config.askEachRound ? "asks before each fix round" : ""].filter(Boolean).join("\n"))
        .child(`${r.config.team ? `team ${r.config.team} · ` : ""}effort ${r.config.effort} · model ${r.config.model}${r.config.here ? ` · you: ${r.config.here}` : ""}`)))
      .when(r.live, (el) => el.child(h_flex().gap(6).pt(1)
        .child(r.state === "paused"
          ? textBtn("relay-resume", "play", "Resume", () => this.act("resume"))
          : textBtn("relay-pause", "pause", "Pause", () => this.act("pause")))
        .child(textBtn("relay-stop", "stop", "Stop", () => this.act("stop"), true))
        // Switch this running relay to overnight mode, or change an overnight relay's limits: opens a small box
        // (Run until a time / until done, Cycles); the relay picks it up within seconds, also mid-question.
        // Relays started before "Make overnight" existed (their status has no 'overnight' field) never read the
        // request: show why instead of a button that does nothing.
        .child(r.overnight === undefined
          ? h_flex().id("relay-night-old").h(24).px(8).gap(5).items_center().rounded(6).border(1).border_color(t.border)
            .text_size(11.5).text_color(t.dim).opacity(0.7)
            .tooltip("This relay started before 'Make overnight' existed, so it can't switch. Start it again (or a new relay) to use overnight mode.")
            .child(icon("history", 12)).child("Overnight n/a")
          : h_flex().id("relay-night-btn").h(24).px(8).gap(5).items_center().rounded(6)
          .border(1).border_color(t.ansi4).text_size(11.5).text_color(t.ansi4).cursor_pointer().hover((s) => s.bg(t.hover))
          .on_click(() => openOverlay({ mod: MOD.overnight, kind: "dialog", width: 520, height: 400,
            props: { folder: this.data?.root, overnight: Boolean(r.overnight), until: r.until, maxCycles: r.maxCycles, queue: Boolean(r.queueMode) } }))
          .tooltip(r.overnight ? "Change when this overnight relay stops (a time, a cycle count, or until done)."
            : "Make this relay run unattended: choose until when (a time, cycles, or until done). No more questions, ALL agent permissions " +
              "skipped from the next stage on, a new git branch, the watchdog. The agent already running keeps its own mode.")
          .child(icon("history", 12)).child(r.overnight ? "Limits" : "Make overnight"))));
  }

  notSetUp(t, d) {
    const isHome = samePath(d.root, home()) || d.root === "~";
    return v_flex().mx(8).mt(10).p(12).gap(8).rounded(10).bg(t.background).border(1).border_color(t.border).flex_none()
      .child(h_flex().gap(7).items_center().text_color(t.accent).child(icon("sparkles", 15))
        .child(div().text_size(12.5).font_medium().text_color(t.foreground).child(isHome ? "No project here" : "Not set up yet")))
      .child(div().text_size(12).text_color(t.muted).whitespace_normal().child(isHome
        ? "This space is in your home folder. Open a project folder to use the AI protocol."
        : "This project isn't set up for the AI protocol. Claude adds .ai/ (state, handoff, decisions, log) so every agent shares one memory."))
      .when(!isHome, (el) => el.child(h_flex().id("setup").h(30).px(12).gap(7).items_center().justify_center().rounded(8)
        .bg(t.solid).text_color(t.solid_foreground).text_size(12.5).font_medium().cursor_pointer()
        .hover((s) => s.opacity(0.88)).tooltip("Starts Claude with: set up the protocol")
        .on_click(() => this.act("setup"))
        .child(agentIcon("claude", 14)).child("Set up protocol")));
  }

  full(t) {
    const d = this.data;
    const rows = [];
    if (!d) {
      rows.push(div().px(16).pt(8).text_size(12).text_color(t.dim).child(this.root || !activeSpace() ? (activeSpace() ? "Reading…" : "No space open") : "Reading…"));
      return rows;
    }
    if (!d.setup) { rows.push(this.notSetUp(t, d)); return rows; }
    rows.push(this.actions(t));
    // The relay files are older than this kit (it was updated): offer the update.
    if (this.setup.outdated) rows.push(h_flex().id("kit-update").mx(8).mt(8).px(10).h(28).gap(7).items_center().rounded(7)
      .bg(t.accent + "1f").cursor_pointer().on_click((_e, cx) => this.openSetup(cx))
      .child(div().text_color(t.accent).child(icon("sparkles", 13)))
      .child(div().flex_1().text_size(11.5).text_color(t.foreground).child("Relay files can be updated: open setup")));
    if (d.relay) rows.push(this.relayCard(t, d.relay));
    rows.push(this.section(t, "sec-usage", "Plan usage"));
    rows.push(this.usageCard(t, d.usage));

    // Next: the first five items of STATE's ## Next.
    rows.push(this.section(t, "sec-next", "Next"));
    const next = d.next.slice(0, 5);
    if (!next.length) rows.push(div().px(16).text_size(12).text_color(t.dim).child("Nothing listed"));
    next.forEach((text, i) => rows.push(h_flex().id(`next-${i}`).mx(8).px(8).h(24).gap(8).items_center().rounded(6).flex_none()
      .hover((s) => s.bg(t.hover)).tooltip(text)
      .child(div().w(10).flex_none().text_size(11).text_color(t.dim).child(String(i + 1)))
      .child(div().flex_1().min_w(0).truncate().text_size(12.5).text_color(i === 0 ? t.foreground : t.muted).child(text))));

    // Status: two lines until opened.
    if (d.status.length) {
      const open = this.statusOpen;
      rows.push(this.section(t, "sec-status", "Status",
        div().id("status-toggle").text_color(t.dim).cursor_pointer().hover((s) => s.text_color(t.foreground))
          .on_click((_e, cx) => { this.statusOpen = !open; cx.notify(); })
          .child(icon(open ? "chevron-down" : "chevron-right", 11))));
      const shown = open ? d.status : d.status.slice(0, 2);
      shown.forEach((text, i) => rows.push(div().id(`status-${i}`).mx(16).py(1).text_size(12).text_color(t.muted)
        .when(!open, (el) => el.truncate().tooltip(text)).when(open, (el) => el.whitespace_normal())
        .child(text)));
      if (!open && d.status.length > 2) rows.push(div().id("status-more").mx(16).text_size(11).text_color(t.dim).cursor_pointer()
        .hover((s) => s.text_color(t.foreground)).on_click((_e, cx) => { this.statusOpen = true; cx.notify(); })
        .child(`+${d.status.length - 2} more`));
    }

    // Recent: the last four LOG lines.
    rows.push(this.section(t, "sec-recent", "Recent"));
    if (!d.log.length) rows.push(div().px(16).text_size(12).text_color(t.dim).child("No sessions logged yet"));
    const now = Date.now();
    d.log.forEach((l, i) => rows.push(h_flex().id(`log-${i}`).mx(8).px(8).h(26).gap(7).items_center().rounded(6).flex_none()
      .hover((s) => s.bg(t.hover)).tooltip(`${l.sig} · ${l.role} · ${l.task}\n${l.summary}`)
      .child(l.tool ? agentIcon(l.tool, 14) : div().size(14).flex_none().rounded(4).bg(t.border))
      .child(div().flex_none().text_size(11).text_color(roleColor(l.role, t)).child(l.role))
      .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.muted).child(l.summary))
      .child(div().flex_none().text_size(11).text_color(t.dim).child(l.at ? ago(now - l.at) : ""))));
    if (d.blockers.length && !/^none\b/i.test(d.blockers[0])) {
      rows.push(this.section(t, "sec-block", "Blockers"));
      d.blockers.slice(0, 3).forEach((text, i) => rows.push(div().id(`block-${i}`).mx(16).py(1).truncate().tooltip(text)
        .text_size(12).text_color(t.blocked).child(text)));
    }
    rows.push(div().h(10).flex_none());
    return rows;
  }

  rail(t, chip) {
    const d = this.data;
    const btn = (id, content, label, what) => iconButton(id, content, label, () => this.act(what), { size: 28 });
    return v_flex().items_center().gap(4).py(8)
      .child(div().id("rail-chip").size(28).flex().items_center().justify_center()
        .tooltip(`${baseName(d?.root ?? "") || "AI Project"} · ${chip?.text ?? "…"}`)
        .child(div().size(8).rounded(4).bg(chip?.color ?? t.dim).when(Boolean(chip?.pulse), (el) => el.loop("opacity", { from: 0.35, to: 1, period: 1100 }))))
      .when(Boolean(d?.setup), (el) => el
        .children(AGENT_KEYS.map((k) => btn(`rail-${k}`, agentIcon(k, 15), tip(`Continue with ${AGENTS[k].name}`, k), k)))
        .child(btn("rail-relay", image(relayIcon()).size(16).flex_none(), tip("Start relay…", "relay"), "relay"))
        .child(btn("rail-handoff", icon("handoff", 15), tip("Open handoff", "handoff"), "handoff"))
        .when(Boolean(d.relay?.live), (el) => el.child(d.relay.state === "paused"
          ? btn("rail-resume", icon("play", 14), "Resume relay", "resume")
          : btn("rail-pause", icon("pause", 14), "Pause relay", "pause"))))
      .when(Boolean(d && !d.setup), (el) => el.child(btn("rail-setup", icon("sparkles", 15), "Set up protocol", "setup")));
  }

  render(cx) {
    const t = theme();
    const space = activeSpace();
    this.resolve(cx, space, spaceDir(space));
    const ask = shared(SHARED_FOCUS) ?? 0;
    if (ask !== this.seenFocus) { this.seenFocus = ask; cx.timer.after(60, (cx) => { this.handle.focus(); cx.notify(); }); }
    const focusedNow = this.handle.is_focused();
    const chip = this.chip(t);
    const narrow = this.width < 160;
    const root = v_flex().id("ai-project").size_full().min_h(0).bg(t.chrome).border_t(1).border_color(focusedNow ? t.accent : t.border)
      .text_size(13).track_focus(this.handle).on_key_down((e, cx) => this.key_(e, cx))
      .on_size_change((size, cx) => { if (Math.abs(size.width - this.width) > 1) { this.width = size.width; cx.notify(); } });
    if (this.view === "setup") return root.child(v_flex().id("setup-body").flex_1().min_h(0).overflow_y_scrollbar()
      .children(this.setup.render(t, cx, { home: home(), onClose: (_e, cx) => this.closeSetup(cx) })));
    if (narrow) return root.child(this.rail(t, chip));
    const name = this.data?.setup ? baseName(this.data.root) : space?.name ?? "";
    return root
      .child(h_flex().px(16).pt(14).pb(5).h(41).gap(8).items_center().flex_none()
        .child(div().text_size(11.5).font_medium().text_color(t.dim).flex_none().child("Project"))
        .child(div().flex_1().min_w(0).truncate().text_size(12).font_medium().text_color(t.foreground).child(name))
        .when(Boolean(chip), (el) => el.child(pill(chip.text, chip.color, { dot: chip.dot, pulse: chip.pulse })))
        .child(iconButton("ai-commands", icon("command", 13), tip("AI commands", "commands"), () => this.act("commands"), { size: 22 }))
        .when(onWindows(), (el) => el.child(iconButton("ai-setup", icon("sparkles", 13), "Set up AI relay (install, update, remove)", (_e, cx) => this.openSetup(cx), { size: 22 }))))
      .child(v_flex().id("ai-body").flex_1().min_h(0).overflow_y_scrollbar().children(this.full(t)))
      .when(focusedNow, (el) => el.child(div().flex_none().px(16).py(5).border_t(1).border_color(t.border).text_size(10.5).text_color(t.dim)
        .child("1 2 3 continue · R relay · H handoff · Esc")));
  }
}
