// "Set up AI relay": the panel's first-run screen (and its Setup view later).
// Every change happens only on a click, one step at a time, through payload/setup.ps1:
// detect agents -> copy the relay files -> per agent, add the protocol block -> 'relay' on PATH -> Herdr + menu.
// Missing agents get a link to their official install page; nothing is downloaded or run from the web.

import { div, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { setShared } from "herdr";
import { AGENTS, agentIcon, icon, pill, setupAction, openUrl, onWindows, SHARED_SETUP, RELAY_ICON } from "./lib.js";

const AGENT_TOOL = { claude: "claude", codex: "codex", antigravity: "antigravity" };
const short = (p, home) => (home && p && p.toLowerCase().startsWith(home.toLowerCase()) ? "~" + p.slice(home.length).replace(/\\/g, "/") : p);

export class Setup {
  constructor() {
    this.info = null;      // last detect result
    this.busy = "";        // the step running now
    this.msg = {};         // step -> { ok, text }
    this.confirmRemove = false;
  }

  get installed() { return Boolean(this.info?.installed); }
  get outdated() { return this.installed && this.info.installedVersion !== this.info.kitVersion; }

  // Reads what is installed; cheap enough to run on open and after each step.
  async detect(cx) {
    if (!onWindows()) { this.info = { ok: false, unsupported: true }; cx.notify(); return this.info; }
    const r = await setupAction("detect");
    this.info = r;
    cx.notify();
    return r;
  }

  // One step: run it, remember its message, detect again.
  step(cx, id, action, extra = [], done = null) {
    if (this.busy) return;
    this.busy = id;
    this.confirmRemove = false;
    cx.notify();
    cx.spawn(async (cx) => {
      const r = await setupAction(action, extra);
      this.msg[id] = r.ok ? { ok: true, text: done ? done(r) : "Done" } : { ok: false, text: r.error ?? "Failed" };
      this.busy = "";
      await this.detect(cx);
      setShared(SHARED_SETUP, Date.now());
    });
  }

  // ---------- pieces ----------
  btn(t, id, label, onClick, opts = {}) {
    const enabled = !this.busy && opts.enabled !== false;
    const primary = Boolean(opts.primary), danger = Boolean(opts.danger);
    return h_flex().id(id).h(26).px(10).gap(6).flex_none().items_center().justify_center().rounded(7)
      .border(1).border_color(primary ? t.solid : danger ? t.blocked : t.input)
      .bg(primary ? t.solid : t.raised).text_size(11.5).font_medium()
      .text_color(primary ? t.solid_foreground : danger ? t.blocked : t.foreground)
      .when(enabled, (el) => el.cursor_pointer().hover((s) => s.opacity(0.85)).on_click(onClick))
      .when(!enabled, (el) => el.opacity(0.45))
      .child(this.busy === id ? "Working…" : label);
  }
  done(t, text = "Done") { return pill(text, t.ansi2, { dot: true }); }
  note(t, id) {
    const m = this.msg[id];
    if (!m) return div().flex_none();
    return div().text_size(11).whitespace_normal().text_color(m.ok ? t.dim : t.blocked).child(String(m.text ?? ""));
  }
  card(t, n, title, body) {
    return v_flex().mx(8).mt(8).p(10).gap(7).rounded(9).bg(t.background).border(1).border_color(t.border).flex_none()
      .child(h_flex().gap(7).items_center()
        .child(h_flex().size(18).flex_none().items_center().justify_center().rounded(9).bg(t.raised)
          .text_size(10.5).font_semibold().text_color(t.muted).child(String(n)))
        .child(div().flex_1().text_size(12.5).font_medium().text_color(t.foreground).child(title)))
      .children(body);
  }

  toolRow(t, tool) {
    const pic = AGENTS[tool.key] ? agentIcon(tool.key, 14) : icon(tool.key === "git" ? "history" : "command", 13);
    return h_flex().id(`tool-${tool.key}`).h(24).gap(7).items_center().min_w(0)
      .tooltip(tool.found ? tool.path : `Not found. Official page: ${tool.url}`)
      .child(h_flex().w(16).flex_none().justify_center().text_color(t.muted).child(pic))
      .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(tool.found ? t.foreground : t.muted).child(tool.name))
      .child(tool.found ? pill("found", t.ansi2, { h: 16, size: 10 })
        : h_flex().id(`get-${tool.key}`).h(18).px(6).gap(4).items_center().rounded(5).cursor_pointer()
          .bg(t.ansi3 + "24").text_size(10.5).text_color(t.ansi3).hover((s) => s.opacity(0.8))
          .on_click(() => openUrl(tool.url)).child("missing · install page ↗"));
  }

  // ---------- the screen ----------
  render(t, cx, { onClose, home }) {
    const head = h_flex().px(16).pt(14).pb(4).gap(8).items_center().flex_none()
      .child(image(RELAY_ICON).size(16).flex_none())
      .child(div().flex_1().text_size(13).font_semibold().text_color(t.foreground).child("Set up AI relay"))
      .when(this.installed && Boolean(onClose), (el) => el.child(this.btn(t, "setup-close", "Back to project", onClose)));
    const rows = [head];
    const i = this.info;

    if (!i) { rows.push(div().px(16).pt(8).text_size(12).text_color(t.dim).child("Looking for your agents…")); return rows; }
    if (i.unsupported) {
      rows.push(v_flex().mx(8).mt(8).p(12).gap(6).rounded(9).bg(t.background).border(1).border_color(t.border)
        .child(div().text_size(12.5).font_medium().text_color(t.foreground).child("Windows only for now"))
        .child(div().text_size(12).text_color(t.muted).whitespace_normal().child(
          "The relay engine is a PowerShell script for Windows. The project panel and handoff viewer work here; starting relays doesn't yet. See the kit's README for the cross-platform plan.")));
      return rows;
    }
    if (!i.ok) {
      rows.push(v_flex().mx(8).mt(8).p(12).gap(6).rounded(9).bg(t.background).border(1).border_color(t.blocked)
        .child(div().text_size(12).text_color(t.blocked).whitespace_normal().child(`Setup check failed: ${i.error ?? "unknown error"}`))
        .child(this.btn(t, "setup-retry", "Try again", (_e, cx) => cx.spawn(async (cx) => this.detect(cx)))));
      return rows;
    }

    rows.push(div().px(16).pb(2).text_size(11.5).text_color(t.dim).whitespace_normal().child(
      "Runs a project through planner, executor, tester and reviewer, each agent in its own tab. Each step below changes your files only when you click it, and Remove undoes them."));

    // 1. Agents and tools.
    const tools = i.tools ?? [];
    const agentsFound = tools.filter((x) => AGENTS[x.key] && x.found).length;
    rows.push(this.card(t, 1, "Agents and tools on this computer", [
      v_flex().gap(1).children(tools.map((x) => this.toolRow(t, x))),
      div().text_size(11).text_color(agentsFound ? t.dim : t.ansi3).whitespace_normal().child(agentsFound
        ? "Missing ones are optional; a role whose agent is missing can go to another agent. Installed one? Check again."
        : "Install at least one agent (its official page opens in your browser), then check again."),
      h_flex().child(this.btn(t, "setup-detect", "Check again", (_e, cx) => { this.busy = "setup-detect"; cx.notify(); cx.spawn(async (cx) => { await this.detect(cx); this.busy = ""; cx.notify(); }); })),
    ]));

    // 2. Relay files.
    const filesDone = i.installed && !this.outdated;
    rows.push(this.card(t, 2, "Relay files", [
      div().text_size(11.5).text_color(t.muted).whitespace_normal().child(`Copies the relay engine, the shared protocol and your defaults to ${short(i.protocolDir, home)}.`),
      i.foreign && !i.installed ? div().text_size(11).text_color(t.ansi3).whitespace_normal()
        .child("Relay files from an earlier install are there: they are backed up first, and your relay-defaults.json is kept.") : div().flex_none(),
      h_flex().gap(8).items_center()
        .child(filesDone ? this.done(t, "Copied") : this.btn(t, "setup-install", this.outdated ? `Update to ${i.kitVersion}` : "Copy files",
          (_e, cx) => this.step(cx, "setup-install", "install", [], (r) => (r.notes?.length ? `Copied (${r.notes.join(", ")}).` : "Copied.")), { primary: true })),
      this.note(t, "setup-install"),
    ]));

    // 3. Protocol rules, asked per agent.
    const prot = i.protocol ?? {};
    rows.push(this.card(t, 3, "Shared protocol in each agent's rules", [
      div().text_size(11.5).text_color(t.muted).whitespace_normal().child(
        "Adds the protocol between AI-PROTOCOL markers so every agent keeps the project's shared memory in .ai/. A backup of the file is kept. Add it only for the agents you want."),
      v_flex().gap(4).children(Object.keys(AGENT_TOOL).map((k) => {
        const p = prot[k] ?? {};
        const found = tools.find((x) => x.key === k)?.found;
        const id = `setup-protocol-${k}`;
        return v_flex().gap(2)
          .child(h_flex().min_h(30).py(2).gap(7).items_center().min_w(0)
            .child(agentIcon(k, 14))
            .child(v_flex().flex_1().min_w(0)
              .child(div().text_size(12).text_color(found ? t.foreground : t.muted).child(AGENTS[k].name + (found ? "" : " (not installed)")))
              .child(div().truncate().text_size(10.5).text_color(t.dim).child(short(p.file, home) ?? "")))
            .child(p.managed ? this.done(t, "Added")
              : this.btn(t, id, p.hasBlock ? "Replace block" : "Add block", (_e, cx) => this.step(cx, id, "protocol", ["-Agent", k], (r) => (r.backup ? `Added. Backup: ${short(r.backup, home)}` : "Added.")),
                { enabled: i.installed })))
          .child(this.note(t, id));
      })),
    ]));

    // 4. relay on PATH.
    rows.push(this.card(t, 4, "The relay command", [
      div().text_size(11.5).text_color(t.muted).whitespace_normal().child(`Adds ${short(i.path?.dir, home)} to your user PATH, so you can type relay in PowerShell (new terminals).`),
      h_flex().gap(8).items_center().child(i.path?.onPath ? this.done(t, "On PATH")
        : this.btn(t, "setup-path", "Add to PATH", (_e, cx) => this.step(cx, "setup-path", "path", [], () => "Added. Open a new terminal to use relay."), { enabled: i.installed })),
      this.note(t, "setup-path"),
    ]));

    // 5. Herdr + menu.
    const e = i.programs?.entries ?? {};
    const names = tools.filter((x) => AGENTS[x.key] && x.found).map((x) => AGENTS[x.key].name);
    rows.push(this.card(t, 5, "Herdr + menu", [
      div().text_size(11.5).text_color(t.muted).whitespace_normal().child(
        `Adds ${[...names, "AI Relay"].join(", ")} to Herdr's + menu (programs.json). Entries you already have are kept.`),
      h_flex().gap(8).items_center().child(i.programs?.managed && e.relay ? this.done(t, "Added")
        : this.btn(t, "setup-programs", "Add to + menu", (_e, cx) => this.step(cx, "setup-programs", "programs", [], (r) => (r.keptYours?.length ? `Added; kept your ${r.keptYours.join(", ")}.` : "Added.")), { enabled: i.installed })),
      this.note(t, "setup-programs"),
    ]));

    // Done / remove.
    rows.push(h_flex().mx(8).mt(10).mb(12).gap(8).items_center().flex_none()
      .when(this.installed && Boolean(onClose), (el) => el.child(this.btn(t, "setup-finish", "Done", onClose, { primary: true })))
      .child(div().flex_1())
      .when(this.installed, (el) => el.child(this.confirmRemove
        ? this.btn(t, "setup-remove", "Click again to remove", (_e, cx) => this.step(cx, "setup-remove", "remove", [], (r) => `Removed. ${(r.notes ?? []).length} change(s) undone.`), { danger: true })
        : this.btn(t, "setup-remove-ask", "Remove…", (_e, cx) => { this.confirmRemove = true; cx.notify(); }, { danger: true }))));
    rows.push(v_flex().mx(16).mb(12).child(this.note(t, "setup-remove")));
    return rows;
  }
}
