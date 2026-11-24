// AI commands: every AI-protocol action by name, with its key. Herdr's own palette
// (Ctrl+Shift+P) is rebuilt by the app and lists only app commands, so the AI actions live
// here: Ctrl+Alt+A, or the ⌘ button in the AI Relay panel. Type to filter, ↑/↓, Enter.

import { View, div, image } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { theme, run, closeOverlay, props, readTextFile, appHome, home, checking } from "herdr";
import {
  AGENTS, AGENT_KEYS, RELAY_ICON, relayIcon, agentIcon, icon, keyLabel, KEYS, activeSpace, spaceDir, findRoot, join, parseRelay,
  continueWith, setupProtocol, getReview, relayControl, openHandoff, loadRuns, baseName, samePath,
  MOD, openLauncher, focusPanel, onWindows,
} from "./lib.js";

export default class AiCommands extends View {
  init(_props, cx) {
    this.query = "";
    this.at = 0;
    this.input = InputState.new({ placeholder: "AI command…" });
    this.input.on("change", (_e, cx) => { this.query = this.input.value(); this.at = 0; cx.notify(); });
    this.input.on("submit", () => this.go(this.rows()[this.at]));
    this.input.focus();
    cx.timer.after(400, () => this.input.focus());
    this.space = activeSpace();
    this.root = spaceDir(this.space);
    this.setup = null;
    this.relay = null;
    if (checking() || !this.root) return;
    cx.spawn(async (cx) => {
      await loadRuns(appHome());
      const r = await findRoot(this.root, this.space?.machine);
      this.root = r.root;
      this.setup = r.setup;
      try { this.relay = parseRelay(await readTextFile(join(r.root, ".ai", "relay", "status.json"), { on: this.space?.machine })); } catch { /* none */ }
      cx.notify();
    });
  }

  entries() {
    const sp = this.space?.id, f = this.root, m = this.space?.machine;
    const list = AGENT_KEYS.map((k) => ({ id: k, title: `AI: Continue with ${AGENTS[k].name}`, pic: agentIcon(k, 15), key: KEYS[k], act: () => continueWith(k, sp, f) }));
    if (this.setup === false && !samePath(this.root, home())) list.unshift({ id: "setup", title: "AI: Set up protocol", pic: icon("sparkles", 15), act: () => setupProtocol(sp, f) });
    list.push(
      { id: "review", title: "AI: Get a review", pic: icon("review", 15), act: () => getReview(sp, f) },
      { id: "relay", title: "AI: Start relay…", pic: image(relayIcon()).size(16).flex_none(), key: KEYS.relay, act: () => openLauncher() },
    );
    if (this.relay?.live) {
      list.push(this.relay.state === "paused"
        ? { id: "resume", title: "AI: Resume relay", pic: icon("play", 15), act: () => relayControl(f, "resume", m) }
        : { id: "pause", title: "AI: Pause relay", pic: icon("pause", 15), act: () => relayControl(f, "pause", m) });
      list.push({ id: "stop", title: "AI: Stop relay", pic: icon("stop", 15), act: () => relayControl(f, "stop", m) });
    }
    list.push(
      { id: "handoff", title: "AI: Open handoff", pic: icon("handoff", 15), key: KEYS.handoff, act: () => openHandoff(f, "HANDOFF", sp) },
      { id: "state", title: "AI: Open project state", pic: icon("list", 15), act: () => openHandoff(f, "STATE", sp) },
      { id: "decisions", title: "AI: Open decisions", pic: icon("history", 15), act: () => openHandoff(f, "DECISIONS", sp) },
      { id: "panel", title: "AI: Focus project panel", pic: icon("activity", 15), key: KEYS.panel, act: () => focusPanel() },
    );
    if (onWindows()) list.push({ id: "kit-setup", title: "AI: Set up AI relay (install, update, remove)", pic: icon("sparkles", 15),
      act: () => { focusPanel(); run(`${MOD.panel}.setup`); } });
    return list;
  }

  rows() {
    const words = this.query.toLowerCase().split(/\s+/).filter(Boolean);
    return this.entries().filter((e) => words.every((w) => e.title.toLowerCase().includes(w)));
  }

  go(e) {
    if (!e) return;
    closeOverlay(props().overlay);
    e.act();
  }

  render() {
    const t = theme();
    const rows = this.rows();
    if (this.at >= rows.length) this.at = Math.max(0, rows.length - 1);
    return v_flex().id("ai-commands").w_full().h(46 + Math.min(10, Math.max(1, rows.length)) * 32 + 12).bg(t.popover).text_size(12.8)
      .on_key_down((e, cx) => {
        if (e.key === "down") { this.at = Math.min(rows.length - 1, this.at + 1); cx.stop_propagation(); cx.notify(); }
        else if (e.key === "up") { this.at = Math.max(0, this.at - 1); cx.stop_propagation(); cx.notify(); }
      })
      .child(h_flex().h(46).px(14).gap(10).items_center().flex_none().border_b(1).border_color(t.border)
        .child(image(relayIcon()).size(16).flex_none())
        .child(Input.new(this.input).flex_1().h(30).px(0).border_0().bg(t.popover).text_size(13.5).text_color(t.foreground))
        .child(div().text_size(11).text_color(t.dim).flex_none().child(this.root ? baseName(this.root) : "")))
      .child(v_flex().id("ai-commands-rows").flex_1().min_h(0).p(5).overflow_y_scrollbar()
        .when(rows.length === 0, (el) => el.child(div().p(10).text_color(t.dim).child("No AI command matches")))
        .children(rows.map((e, i) => {
          const k = e.key ? keyLabel(e.key) : "";
          return h_flex().id(`cmd-${e.id}`).h(32).px(10).gap(10).items_center().rounded(7).flex_none()
            .bg(i === this.at ? t.selected : t.popover).text_color(t.foreground).cursor_pointer()
            .hover((s) => s.bg(t.hover))
            .on_click(() => this.go(e))
            .child(h_flex().w(16).flex_none().justify_center().text_color(t.muted).child(e.pic))
            .child(div().flex_1().min_w(0).truncate().child(e.title))
            .when(Boolean(k), (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(k)));
        })));
  }
}
