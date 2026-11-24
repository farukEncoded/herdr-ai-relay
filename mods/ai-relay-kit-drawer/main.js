// AI Relay drawer: floats on the right edge (peek) only while some space's project has a
// running or paused relay (.ai/relay/status.json with a fresh heartbeat). The strip shows the
// relay icon, the stage number and a pulsing dot (amber when paused); hovering slides out
// "Stage 3 · tester · Codex · 6 min · fix round 1/3" with Pause/Resume and Stop.
// Click a row: focus that stage's tab. Optional: add it to a layout's "floating" list (see the README).
// It also answers `ai-relay-kit-drawer.panel` by showing the AI Relay panel and focusing it.

import { View, div, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { spaces, theme, run, placement, readTextFile, checking, nextCommand, panes } from "herdr";
import {
  RELAY_ICON, relayIcon, AGENTS, agentIcon, icon, iconButton, roleColor, pill, relayLine, spaceDir, findRoot, join,
  parseRelay, baseName, relayControl, focusPanel,
} from "./lib.js";

export default class AiRelay extends View {
  init(_props, cx) {
    this.roots = new Map(); // folder -> project root
    this.relays = [];
    this.sig = "";
    if (checking()) return;
    cx.timer.every(5000, (cx) => this.scan(cx));
    this.scan(cx);
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        if (c === "panel") focusPanel();
        cx.notify();
      }
    });
  }

  scan(cx) {
    cx.spawn(async (cx) => {
      const found = new Map();
      for (const s of spaces()) {
        const dir = spaceDir(s);
        if (!dir) continue;
        const k = `${s.machine ?? ""}|${dir}`;
        if (!this.roots.has(k)) this.roots.set(k, (await findRoot(dir, s.machine)).root);
        const root = this.roots.get(k);
        if (found.has(`${s.machine ?? ""}|${root.toLowerCase()}`)) continue;
        let text = null;
        try { text = await readTextFile(join(root, ".ai", "relay", "status.json"), { on: s.machine }); } catch { /* offline */ }
        const r = parseRelay(text);
        if (r?.live) found.set(`${s.machine ?? ""}|${root.toLowerCase()}`, { ...r, root, machine: s.machine, space: s.id });
      }
      // A folder found without .ai may get one later: forget roots that aren't set up.
      if (this.roots.size > 64) this.roots.clear();
      this.relays = [...found.values()];
      const sig = JSON.stringify(this.relays.map((r) => [r.root, r.state, r.stage, r.role, r.agent, r.round, relayLine(r)]));
      if (sig !== this.sig) { this.sig = sig; cx.notify(); }
    });
  }

  row(t, r, i, mirrored) {
    const paused = r.state === "paused";
    const dotColor = paused ? t.ansi3 : t.accent;
    const strip = h_flex().w(54).h(46).flex_none().gap(6).items_center().justify_center()
      .child(div().size(7).rounded(4).bg(dotColor).loop("opacity", { from: 0.3, to: 1, period: paused ? 1800 : 1100 }))
      .child(image(relayIcon()).size(18).flex_none())
      .child(div().text_size(12.5).font_semibold().text_color(t.foreground).child(String(r.stage ?? "")));
    const ctl = (id, ic, label, action, danger) => iconButton(`${id}-${i}`, icon(ic, 13), label, (_e, cx) => { cx.stop_propagation(); action(); }, { size: 24, danger });
    const details = v_flex().w(300).flex_none().px(12).gap(3).justify_center()
      .child(h_flex().gap(6).items_center().min_w(0)
        .when(Boolean(AGENTS[r.agent]), (el) => el.child(agentIcon(r.agent, 14)))
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.foreground).child(relayLine(r))))
      .child(h_flex().gap(6).items_center().min_w(0)
        .when(Boolean(r.role), (el) => el.child(pill(r.role, roleColor(r.role, t))))
        .when(paused, (el) => el.child(pill("paused", t.ansi3)))
        .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(t.dim).child(baseName(r.root)))
        .child(paused
          ? ctl("resume", "play", "Resume relay", () => relayControl(r.root, "resume", r.machine))
          : ctl("pause", "pause", "Pause relay (before the next stage)", () => relayControl(r.root, "pause", r.machine)))
        .child(ctl("stop", "stop", "Stop relay (after this stage)", () => relayControl(r.root, "stop", r.machine), true)));
    return h_flex().id(`relay-${i}`).items_center().cursor_pointer().rounded(8)
      .hover((s) => s.bg(t.hover))
      .tooltip(r.goal ? `Goal: ${r.goal}` : "Go to this stage's tab")
      .on_click(() => {
        if (r.terminal && panes().some((p) => p.terminal === r.terminal)) run("pane.focus", { terminal: r.terminal });
        else if (r.space) run("space.select", { id: r.space });
      })
      .children(mirrored ? [details, strip] : [strip, details]);
  }

  render() {
    if (!this.relays.length) return div();
    const t = theme();
    const p = placement();
    const mirrored = (p?.edge ?? "right") === "right";
    const list = this.relays.map((r, i) => this.row(t, r, i, mirrored));
    return p && !p.vertical
      ? h_flex().gap(4).px(2).children(list)
      : v_flex().gap(2).children(list);
  }
}
