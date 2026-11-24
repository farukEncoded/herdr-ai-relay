// Handoff viewer: a pane that renders a project's protocol files as markdown, live as agents
// rewrite them. Tabs: HANDOFF · STATE · the current task (newest .ai/tasks/T-*.md) · DECISIONS.
// Props: { folder?, file? }. Without a folder (Ctrl+Alt+H) it uses its space's project.
// Part of AI Relay Kit.

import { View, div } from "gpui-kit";
import { v_flex, h_flex, TextView } from "gpui-base";
import { theme, props, readTextFile, watchFolder, checking, exec } from "herdr";
import { activeSpace, spaceDir, findRoot, join, baseName, icon, isWin } from "./lib.js";
import * as fs from "fs/promises";

const TABS = [
  { id: "HANDOFF", label: "Handoff", file: () => "HANDOFF.md" },
  { id: "STATE", label: "State", file: () => "STATE.md" },
  { id: "TASK", label: "Task", file: (v) => (v.task ? join("tasks", v.task) : null) },
  { id: "DECISIONS", label: "Decisions", file: () => "DECISIONS.md" },
];

// The protocol's templates are loose ("Did:      - item", wrapped lines, deep indents):
// make them read as markdown without changing what they say.
function soften(text) {
  const out = [];
  let fence = false;
  const plainLine = (l) => l.trim() && !/^\s*(#|[-*+]\s|\d+[.)]\s|\||>|```)/.test(l);
  const lines = text.replace(/\r/g, "").split("\n");
  let base = 0; // the column a "Label:   - item" line's items start at
  for (let i = 0; i < lines.length; i++) {
    let l = lines[i];
    if (/^\s*```/.test(l)) { fence = !fence; out.push(l); continue; }
    if (fence) { out.push(l); continue; }
    const lab = /^([A-Z][\w /'-]{0,30}):(\s{2,}(?=\S)|\s+(?=[-*]\s))(.*)$/.exec(l);
    const indent = /^\s*/.exec(l)[0].length;
    if (lab) { out.push("", `**${lab[1]}:**`); base = lab[1].length + 1 + lab[2].length; l = lab[3]; }
    else if (indent >= 4) l = (base && Math.abs(indent - base) <= 1 ? "" : "   ") + l.trim();
    else {
      base = 0;
      const inline = /^([A-Z][\w /'-]{0,30}):\s+(\S.*)$/.exec(l);
      if (inline && !/^#/.test(l)) { out.push(""); l = `**${inline[1]}:** ${inline[2]}`; }
    }
    const next = lines[i + 1] ?? "";
    out.push(plainLine(l) && plainLine(next) && !/^\s{4,}/.test(next) ? `${l}  ` : l);
  }
  return out.join("\n");
}

export default class AiHandoff extends View {
  init(_props, cx) {
    const p = props() ?? {};
    this.tab = TABS.some((x) => x.id === p.file) ? p.file : (localStorage.getItem("tab") ?? "HANDOFF");
    this.text = null;
    this.task = null;
    this.version = 0;
    // Its space: the one shown when it opened (a pane mod starts when its tab is shown).
    this.space = activeSpace();
    this.machine = this.space?.machine ?? null;
    this.root = p.folder ?? null;
    if (checking()) return;
    cx.spawn(async (cx) => {
      if (!this.root) this.root = (await findRoot(spaceDir(this.space) ?? "", this.machine)).root;
      await this.load(cx);
      this.watchLoop(cx);
    });
    // Remote spaces can't be watched; local watches can be reclaimed: a slow refresh covers both.
    cx.timer.every(15000, (cx) => cx.spawn(async (cx) => this.load(cx)));
  }

  async close() { this.watch?.cancel(); }

  async newestTask() {
    const dir = join(this.root, ".ai", "tasks");
    let names = [];
    try {
      if (this.machine == null) names = await fs.readdir(dir);
      else {
        const r = await exec(isWin(dir) ? "cmd" : "ls", isWin(dir) ? ["/c", "dir", "/b", dir] : [dir], { on: this.machine });
        names = r.stdout.split(/\r?\n/);
      }
    } catch { return null; }
    const tasks = names.map((n) => n.trim()).filter((n) => /^T-\d+.*\.md$/i.test(n));
    tasks.sort((a, b) => parseInt(b.slice(2), 10) - parseInt(a.slice(2), 10));
    return tasks[0] ?? null;
  }

  async load(cx) {
    if (!this.root) return;
    this.task = await this.newestTask();
    const tab = TABS.find((x) => x.id === this.tab) ?? TABS[0];
    const file = tab.file(this);
    let text = null;
    if (file) { try { text = await readTextFile(join(this.root, ".ai", file), { on: this.machine }); } catch { /* unreachable */ } }
    const task = this.task;
    if (text === this.text && this.loaded && task === this.shownTask) return;
    if (text !== this.text) { this.text = text; this.version++; }
    this.shownTask = task;
    this.loaded = true;
    cx.notify();
  }

  watchLoop(cx) {
    if (this.machine != null || !this.root) return;
    const root = this.root;
    cx.spawn(async (cx) => {
      for (;;) {
        const w = watchFolder(join(root, ".ai"));
        this.watch = w;
        let paths;
        try { paths = await w; } catch { return; }
        if (!paths.length) return;
        await this.load(cx);
      }
    });
  }

  pick(id, cx) {
    this.tab = id;
    try { localStorage.setItem("tab", id); } catch { /* fine */ }
    this.text = null;
    cx.spawn(async (cx) => this.load(cx));
    cx.notify();
  }

  render() {
    const t = theme();
    const tabLabel = (x) => (x.id === "TASK" && this.task ? this.task.replace(/\.md$/i, "").replace(/^(T-\d+).*/, "$1") : x.label);
    const body = !this.loaded
      ? div().p(16).text_color(t.dim).child("Reading…")
      : this.text == null
        ? v_flex().p(20).gap(6)
          .child(div().text_size(13).text_color(t.foreground).child(this.tab === "TASK" ? "No task file yet" : `No ${this.tab}.md here`))
          .child(div().text_size(12).text_color(t.dim).whitespace_normal().child(`${this.root ?? "This space"} has no .ai/${this.tab === "TASK" ? "tasks/T-*.md" : `${this.tab}.md`}. Agents write it when they follow the AI protocol.`))
        : TextView.markdown(`md-${this.tab}-${this.version}`, soften(this.text)).selectable(true);
    return v_flex().id("ai-handoff").size_full().min_h(0).bg(t.background).text_color(t.foreground)
      .child(h_flex().h(36).px(10).gap(2).items_center().flex_none().border_b(1).border_color(t.border)
        .children(TABS.map((x) => {
          const on = x.id === this.tab;
          return h_flex().id(`tab-${x.id}`).h(26).px(10).items_center().rounded(6).cursor_pointer()
            .bg(on ? t.selected : t.background).text_size(12.5).text_color(on ? t.foreground : t.muted).font_medium()
            .hover((s) => s.bg(t.hover).text_color(t.foreground))
            .on_click((_e, cx) => this.pick(x.id, cx))
            .child(tabLabel(x));
        }))
        .child(div().flex_1())
        .child(h_flex().gap(6).items_center().text_size(11.5).text_color(t.dim)
          .child(icon("folder", 12)).child(div().max_w(180).truncate().child(this.root ? baseName(this.root) : ""))))
      .child(div().id("md-scroll").flex_1().min_h(0).overflow_y_scrollbar()
        .child(div().px(22).py(16).text_size(13.5).child(body)));
  }
}
