// Make overnight: switch the relay running in a project to overnight mode, or change an overnight relay's limits.
// Part of AI Relay Kit. Opened by the AI Relay panel's "Make overnight" / "Overnight limits" button with props { folder, overnight,
// until, maxCycles, queue }. It runs `ai-relay.ps1 -MakeOvernight -Folder .. -Until .. -MaxCycles ..`, which drops
// .ai/relay/OVERNIGHT for the running relay to pick up within seconds.

import { View, div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { theme, closeOverlay, props, exec, readTextFile } from "herdr";
import { icon, relayPs1, relayDefaultsPath, parseJson } from "./lib.js";

export default class AiOvernight extends View {
  init(_props, cx) {
    const p = props() ?? {};
    this.folder = p.folder ?? null;
    this.already = Boolean(p.overnight);
    this.queue = p.queue !== false;
    this.until = InputState.new({ placeholder: "07:00" });
    this.until.on("change", (_e, cx) => { this.error = ""; cx.notify(); });
    this.done = p.until === "done";
    this.cycles = Number.isInteger(p.maxCycles) && p.maxCycles >= 0 ? p.maxCycles : 3;
    this.error = "";
    this.busy = false;
    // A time the relay already runs until, else the overnight default.
    const t = p.until && p.until !== "done" ? new Date(p.until) : null;
    if (t && !isNaN(t)) this.until.set_value(`${String(t.getHours()).padStart(2, "0")}:${String(t.getMinutes()).padStart(2, "0")}`);
    else cx.spawn(async (cx) => {
      let ov = {};
      try { ov = parseJson(await readTextFile(relayDefaultsPath()))?.overnight ?? {}; } catch { /* none */ }
      if (!this.already) {
        this.done = String(ov.until ?? "").toLowerCase() === "done";
        if (Number.isInteger(ov.maxCycles)) this.cycles = ov.maxCycles;
      }
      this.until.set_value(String(ov.until && ov.until !== "done" ? ov.until : "07:00"));
      cx.notify();
    });
  }

  async apply(cx) {
    const until = this.done ? "done" : this.until.value().trim() || "07:00";
    if (!this.done && !/^\d{1,2}(:\d{2})?\s*(am|pm)?$/i.test(until)) { this.error = "Use a time like 08:00, or pick 'Until done'."; cx.notify(); return; }
    if (!this.folder) { this.error = "No project folder."; cx.notify(); return; }
    this.busy = true; cx.notify();
    try {
      await exec("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", relayPs1(), "-MakeOvernight",
        "-Folder", this.folder, "-Until", until, "-MaxCycles", String(this.cycles)], { timeout: 60000 });
      closeOverlay(props().overlay);
    } catch (e) {
      this.busy = false; this.error = `Couldn't switch: ${String(e?.message ?? e).slice(0, 200)}`; cx.notify();
    }
  }

  segment(t, id, options, value, onPick) {
    return h_flex().p(3).gap(3).rounded(9).bg(t.background).border(1).border_color(t.border).flex_none()
      .children(options.map((o) => {
        const on = o.value === value;
        return h_flex().id(`${id}-${o.value}`).h(26).px(10).items_center().justify_center().rounded(6)
          .bg(on ? t.raised : t.background).border(1).border_color(on ? t.input : t.background)
          .text_size(12.5).text_color(on ? t.foreground : t.muted).font_medium().cursor_pointer()
          .hover((s) => s.text_color(t.foreground)).when(Boolean(o.tip), (el) => el.tooltip(o.tip))
          .on_click((_e, cx) => { onPick(o.value); cx.notify(); }).child(o.label);
      }));
  }

  button(t, id, label, primary, action, enabled = true) {
    return h_flex().id(id).h(32).px(14).items_center().rounded(8)
      .border_1().border_color(primary ? t.solid : t.input).bg(primary ? t.solid : t.raised)
      .text_color(primary ? t.solid_foreground : t.foreground).text_size(12.5).font_medium()
      .when(enabled, (el) => el.cursor_pointer().hover((s) => s.opacity(0.88)).on_click(action))
      .when(!enabled, (el) => el.opacity(0.5)).child(label);
  }

  render() {
    const t = theme();
    const row = (label, ...kids) => h_flex().pt(12).gap(10).items_center().child(div().w(76).flex_none().text_size(12).text_color(t.dim).child(label)).children(kids);
    return v_flex().id("ai-overnight").size_full().p(18).bg(t.popover).text_color(t.foreground).text_size(12.8)
      .child(h_flex().gap(9).items_center()
        .child(div().text_color(t.ansi4).child(icon("history", 18)))
        .child(div().flex_1().text_size(15).font_semibold().child(this.already ? "Overnight limits" : "Make this relay overnight"))
        .child(div().text_size(11).text_color(t.dim).child("Esc")))
      .child(div().pt(10).text_size(12).text_color(t.muted).whitespace_normal().child(this.already
        ? "Change when this overnight relay stops. It takes the new limits within seconds."
        : "From its next step: no more questions, ALL agent permissions skipped for the stages it starts, a new git branch (never pushed), the watchdog, and it keeps going on its own. The agent running right now keeps its own mode. Marks the folder trusted in Codex if needed."))
      .child(row("Run until",
        this.segment(t, "until", [{ value: false, label: "A time" }, { value: true, label: "Until done", tip: "No time limit: until the planner finds nothing worthwhile left" }], this.done, (v) => { this.done = v; }),
        ...(this.done ? [] : [Input.new(this.until).w(80).h(30).px(8).rounded(7).border_1().border_color(t.input).bg(t.background).text_size(12.5).text_color(t.foreground)])))
      .when(this.queue, (el) => el.child(row("Cycles",
        this.segment(t, "cycles", [1, 2, 3, 5, 10, 0].map((n) => ({ value: n, label: n === 0 ? "No limit" : String(n) })), this.cycles, (v) => { this.cycles = v; }))))
      .child(div().pt(10).text_size(11.5).text_color(t.dim).whitespace_normal().child(
        `Stops ${this.done ? "" : `starting new tasks after ${this.until.value().trim() || "07:00"}`}${this.done ? "" : this.queue && this.cycles ? " or " : ""}${this.queue && this.cycles ? `after ${this.cycles} cycle${this.cycles > 1 ? "s" : ""}` : ""}${this.done && !(this.queue && this.cycles) ? "when nothing worthwhile is left" : ", or earlier when nothing worthwhile is left"}.`))
      .when(Boolean(this.error), (el) => el.child(div().pt(6).text_size(12).text_color(t.blocked).child(this.error)))
      .child(div().flex_1())
      .child(h_flex().pt(14).gap(8).justify_end()
        .child(this.button(t, "cancel", "Cancel", false, () => closeOverlay(props().overlay)))
        .child(this.button(t, "apply", this.busy ? "Switching…" : this.already ? "Update limits" : "Make overnight", true, (_e, cx) => this.apply(cx), !this.busy)));
  }
}
