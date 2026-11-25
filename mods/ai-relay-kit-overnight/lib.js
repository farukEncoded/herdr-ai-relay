// Shared helpers for the AI Relay Kit mods (ai-relay-kit = the panel, -launcher, -commands,
// -handoff, -drawer, -overnight). Mods can't import across folders, so this file is copied into each of
// them. EDIT ONLY mods/ai-relay-kit/lib.js, then run tools/sync-lib.ps1 (in the kit's repo).
// Nothing here is tied to one machine: paths come from home() / appHome() at run time.

import { svg, image, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, panes, agents, focused, keys, layout, readTextFile, exec, run, home, appHome, theme, shared, setShared, settings, window as win } from "herdr";

// The kit's mods. Renamed on a clash? Change the names here, then run tools/sync-lib.ps1.
export const MOD = {
  panel: "ai-relay-kit", launcher: "ai-relay-kit-launcher", commands: "ai-relay-kit-commands",
  handoff: "ai-relay-kit-handoff", drawer: "ai-relay-kit-drawer", overnight: "ai-relay-kit-overnight",
};
export const ICONS = `mods/${MOD.panel}/icons`;
// Shared-state keys (prefixed so they never meet another mod's).
export const SHARED_FOCUS = "ai-relay-kit.panel.focus";
export const SHARED_SETUP = "ai-relay-kit.setup.changed";

// Where things live on this machine, from the home folder at run time.
export const protocolDir = () => join(home(), ".agents", "protocol");
export const relayPs1 = () => join(protocolDir(), "ai-relay.ps1");
export const planUsagePath = () => join(protocolDir(), "usage", "plan.json");
export const relayDefaultsPath = () => join(protocolDir(), "relay-defaults.json");
// The setup script ships inside the panel mod's folder (payload/), so it runs before anything is installed.
export const setupPs1 = () => join(appHome(), "mods", MOD.panel, "payload", "setup.ps1");

// The three protocol agents. `run` is a fallback; programs.json's `run` wins (loadRuns).
export const AGENTS = {
  claude: { key: "claude", name: "Claude", icon: "icons/claude.svg", run: ["claude"], n: 1 },
  codex: { key: "codex", name: "Codex", icon: "icons/codex.svg", run: ["codex", "--no-daemon"], n: 2 },
  antigravity: { key: "antigravity", name: "Antigravity", icon: "icons/antigravity.svg", run: ["agy"], n: 3 },
};
export const AGENT_KEYS = ["claude", "codex", "antigravity"];
export const RELAY_ICON = `${ICONS}/relay.svg`;
// relay.svg's arrows are near-white: on a light theme use the copy with dark arrows.
export const relayIcon = () => (settings()?.dark === false ? `${ICONS}/relay-light.svg` : RELAY_ICON);

// Four calm, distinct hues, from the theme's terminal palette so they follow light and dark.
export const ROLES = ["planner", "executor", "tester", "reviewer"];
export const ROLE_COLOR = { planner: "ansi4", executor: "ansi6", tester: "ansi3", reviewer: "ansi5" };
export const roleColor = (role, t = theme()) => t[ROLE_COLOR[role]] ?? t.muted;

// Reads programs.json once per copy so a changed `run` there is used here too.
export async function loadRuns(appHome) {
  try {
    const j = JSON.parse((await readTextFile(join(appHome, "programs.json"))) ?? "{}");
    for (const k of AGENT_KEYS) {
      const r = j?.programs?.[k]?.run;
      if (Array.isArray(r) && r.length) AGENTS[k].run = r;
    }
  } catch { /* keep the defaults */ }
}

// ---------- look ----------

// Never null: .child(null) makes the whole mod fail to render, so an unknown agent gets an empty box.
export const agentIcon = (key, size = 14) => (AGENTS[key] ? image(AGENTS[key].icon).size(size).flex_none() : div().size(size).flex_none());
export const icon = (name, size = 14) => svg(`${ICONS}/${name}.svg`).size(size).flex_none();

// Which tool a protocol signature names: "codex-app/gpt-6" -> codex.
export function toolOf(sig) {
  const s = (sig ?? "").toLowerCase().trim();
  if (s.startsWith("claude")) return "claude";
  if (s.startsWith("codex") || s.startsWith("chatgpt")) return "codex";
  if (s.startsWith("antigravity") || s.startsWith("agy") || s.startsWith("gemini")) return "antigravity";
  return null;
}
// An agent's key from a word ("Codex", "agy", "claude-code").
export function agentKeyOf(word) {
  const s = (word ?? "").toLowerCase();
  if (s.includes("claude")) return "claude";
  if (s.includes("codex")) return "codex";
  if (s.includes("antigravity") || s === "agy" || s.includes("gemini")) return "antigravity";
  return null;
}

export function ago(ms) {
  const m = Math.floor(Math.max(0, ms) / 60000);
  if (m < 1) return "now";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}
export function minutes(ms) {
  const m = Math.floor(Math.max(0, ms) / 60000);
  if (m < 60) return `${m} min`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}

// "ctrl-alt-1" -> "Ctrl+Alt+1", only if that key is still bound (people rebind).
export function keyLabel(stroke) {
  if (!keys().some((k) => k.section === "global" && k.keys === stroke)) return "";
  const mac = win()?.platform === "macos";
  return stroke.split("-").map((p) => (p.length === 1 ? p.toUpperCase() : p[0].toUpperCase() + p.slice(1))).join(mac ? "" : "+");
}
export const KEYS = {
  claude: "ctrl-alt-1", codex: "ctrl-alt-2", antigravity: "ctrl-alt-3",
  relay: "ctrl-alt-r", handoff: "ctrl-alt-h", panel: "ctrl-alt-p", commands: "ctrl-alt-a",
};
export const tip = (text, k) => { const l = k ? keyLabel(KEYS[k] ?? k) : ""; return l ? `${text}  (${l})` : text; };

// A small icon button with a tooltip; `danger` tints it on hover.
export function iconButton(id, content, tooltip, action, opts = {}) {
  const t = theme();
  const size = opts.size ?? 28;
  return h_flex().id(id).size(size).flex_none().items_center().justify_center().rounded(7)
    .text_color(opts.color ?? t.muted).cursor_pointer()
    .when(Boolean(opts.border), (el) => el.border(1).border_color(t.border))
    .hover((s) => s.bg(t.hover).text_color(opts.danger ? t.blocked : t.foreground))
    .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
    .tooltip(tooltip).on_click(action).child(content ?? div());
}

// A pill: colored text on a faint wash of the same color.
export function pill(text, color, opts = {}) {
  return h_flex().flex_none().h(opts.h ?? 18).px(opts.px ?? 6).gap(4).items_center().rounded(opts.r ?? 5)
    .bg(color + "24").text_size(opts.size ?? 10.5).font_medium().text_color(color)
    .when(Boolean(opts.dot), (el) => el.child(div().size(6).rounded(3).bg(color).when(Boolean(opts.pulse), (d) => d.loop("opacity", { from: 0.35, to: 1, period: 1100 }))))
    .child(String(text ?? ""));
}

// ---------- paths ----------

export const isWin = (p) => /^[A-Za-z]:[\\/]/.test(p ?? "") || (p ?? "").includes("\\");
export const sepOf = (p) => (isWin(p) ? "\\" : "/");
export const join = (dir, ...parts) => [dir.replace(/[\\/]+$/, ""), ...parts].join(sepOf(dir));
export function parent(p) {
  const s = p.replace(/[\\/]+$/, "");
  const i = Math.max(s.lastIndexOf("\\"), s.lastIndexOf("/"));
  if (i <= 0) return null;
  const up = s.slice(0, i);
  return /^[A-Za-z]:$/.test(up) ? null : up; // stop above a drive root
}
export const baseName = (p) => (p ?? "").replace(/[\\/]+$/, "").split(/[\\/]/).pop() || p;
const same = (a, b) => (a ?? "").replace(/[\\/]+$/, "").replace(/\//g, "\\").toLowerCase() === (b ?? "").replace(/[\\/]+$/, "").replace(/\//g, "\\").toLowerCase();
export const samePath = same;

// Where a space is: the live folder of the tab it shows (then the other tabs in order), else its saved folder.
// Following the shown tab means a space that ever holds two projects shows the one you look at.
export function spaceDir(space) {
  if (!space) return null;
  const all = panes();
  const tabs = [...space.tabs].sort((a, b) => Number(Boolean(b.active)) - Number(Boolean(a.active)));
  for (const tab of tabs) {
    const p = all.find((x) => x.tab === tab.id && x.terminal && x.cwd);
    if (p) return p.cwd;
  }
  return space.folder || null;
}
export const activeSpace = () => spaces().find((s) => s.active) ?? null;

// Does this space belong to the project at root? Yes when at least one of its terminals works in root and none in
// another project (a parent folder such as home is neutral). Same rule as ai-relay.ps1 Get-ProjectSpace:
// a space's saved folder can belong to another project, so only live terminal folders count.
export function spaceHolds(space, root) {
  if (!space || !root) return false;
  const norm = (s) => String(s).replace(/\//g, "\\").replace(/\\+$/, "").toLowerCase();
  const r = norm(root);
  const tabIds = new Set(space.tabs.map((t) => t.id));
  let own = 0;
  for (const p of panes()) {
    if (!tabIds.has(p.tab) || !p.terminal || !p.cwd) continue;
    const c = norm(p.cwd);
    if (c === r || c.startsWith(r + "\\")) own++;
    else if (!r.startsWith(c + "\\")) return false;
  }
  return own > 0;
}

// The project root for a folder: the nearest folder upward with .ai/STATE.md
// (so a terminal cd'd into src/ still finds it), never the home folder itself.
export async function findRoot(dir, machine) {
  const h = home();
  let d = dir;
  for (let i = 0; d && i < 8; i++) {
    if (machine == null && same(d, h)) break;
    try { if ((await readTextFile(join(d, ".ai", "STATE.md"), { on: machine })) != null) return { root: d, setup: true }; } catch { /* unreachable */ }
    d = parent(d);
  }
  return { root: dir, setup: false };
}

// ---------- reading the protocol files ----------

const plain = (s) => s.replace(/\*\*|__|`/g, "").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").trim();

export function parseState(text) {
  const out = { updated: "", active: "", sections: {} };
  if (!text) return out;
  let cur = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trimEnd();
    const h = /^##\s+(.+?)\s*(\(.*\))?\s*$/.exec(line);
    if (h) { cur = h[1].split("/")[0].trim().toLowerCase(); out.sections[cur] = []; continue; }
    if (!cur) {
      const u = /^Updated:\s*(.+)$/i.exec(line); if (u) out.updated = u[1].trim();
      const a = /^Active:\s*(.+)$/i.exec(line); if (a) out.active = a[1].trim();
      continue;
    }
    if (line.trim()) out.sections[cur].push(line);
  }
  return out;
}

// A section's list items: "1. foo", "- foo"; wrapped lines join their item.
export function items(lines = []) {
  const res = [];
  for (const l of lines) {
    const m = /^\s*(?:[-*+]|\d+[.)])\s+(.*)$/.exec(l);
    if (m && !/^\s{4,}/.test(l)) res.push(plain(m[1]));
    else if (res.length) res[res.length - 1] += " " + plain(l);
    else res.push(plain(l));
  }
  return res.filter(Boolean);
}

export const activeAgent = (active) => (active && !/^none\b/i.test(active) ? active : "");

// LOG lines: "YYYY-MM-DD HH:MM | signature | role | task | summary".
export function parseLog(text, n = 4) {
  if (!text) return [];
  const rows = [];
  for (const line of text.split(/\r?\n/)) {
    const p = line.split("|").map((s) => s.trim());
    if (p.length < 5 || !/^\d{4}-\d{2}-\d{2}/.test(p[0])) continue;
    const [d, tm] = p[0].split(/\s+/);
    const at = new Date(`${d}T${(tm ?? "00:00").padStart(5, "0")}:00`).getTime();
    rows.push({ at: isNaN(at) ? 0 : at, sig: p[1], tool: toolOf(p[1]), role: p[2], task: p[3], summary: p.slice(4).join(" | ") });
  }
  return rows.slice(-n).reverse();
}

// The relay's live status, or null. `live`: running or paused and its heartbeat is fresh.
export function parseRelay(text) {
  if (!text) return null;
  try {
    const s = JSON.parse(text.replace(/^\uFEFF/, ""));
    const updated = Date.parse(s.updated);
    const stale = !isNaN(updated) && Date.now() - updated > 60000;
    // "waiting": the relay is asking you something in its tab (no heartbeat while it waits).
    const state = (s.state === "running" || s.state === "paused") && stale ? "lost" : s.state;
    return { ...s, state, live: state === "running" || state === "paused" || state === "waiting" };
  } catch { return null; }
}

export const AGENT_NAME = (k) => AGENTS[k]?.name ?? (k ? k[0].toUpperCase() + k.slice(1) : "");

// "Stage 3 · tester · Codex · 6 min · fix round 1/3"
export function relayLine(r) {
  const parts = [`Stage ${r.stage}`];
  if (r.role) parts.push(r.role);
  if (r.agent) parts.push(AGENT_NAME(r.agent));
  if (r.live && r.started) parts.push(minutes(Date.now() - Date.parse(r.started)));
  if (r.round > 0) parts.push(`fix round ${r.round}/${r.maxRounds}`);
  else if (r.label) parts.push(r.label);
  return parts.join(" · ");
}

// Everything the panel shows about one project, read fresh.
export async function readProject(root, machine) {
  const rd = async (...p) => { try { return await readTextFile(join(root, ".ai", ...p), { on: machine }); } catch { return null; } };
  const [state, log, relay, plan] = await Promise.all([rd("STATE.md"), rd("LOG.md"), rd("relay", "status.json"),
    (async () => { try { return await readTextFile(planUsagePath()); } catch { return null; } })()]);
  if (state == null) return { root, setup: false };
  const st = parseState(state);
  return {
    root, setup: true, updated: st.updated, active: activeAgent(st.active),
    next: items(st.sections["next"]), status: items(st.sections["status"]),
    blockers: items(st.sections["blockers"]),
    log: parseLog(log, 4), relay: parseRelay(relay), usage: parseJson(plan),
  };
}

// Plan usage (Claude, Codex) is saved by ai-relay.ps1 in planUsagePath(); Antigravity keeps none.
// The relay's defaults (roles, effort, models, rounds) are in relayDefaultsPath(), shared by the
// relay, the launcher and the agents.
export function parseJson(text) { try { return text ? JSON.parse(text.replace(/^\uFEFF/, "")) : null; } catch { return null; } }

// ---------- actions ----------

const spaceOf = (id) => spaces().find((s) => s.id === id) ?? activeSpace();

export function startAgent(key, { space, folder, name, message }) {
  const a = AGENTS[key];
  if (!a) return;
  const args = { name: name ?? `${a.name} · continue`, space, folder: folder ?? undefined };
  // Antigravity rejects Herdr's task argument: its first message goes in argv after -i.
  if (key === "antigravity") run("tab.new", { ...args, argv: [...a.run, "-i", message] });
  else run("tab.new", { ...args, argv: a.run, task: message });
}
export const continueWith = (key, space, folder) => startAgent(key, { space, folder, message: "continue" });
export const setupProtocol = (space, folder) => startAgent("claude", { space, folder, name: "Claude · set up", message: "set up the protocol" });

// A review from a different agent than the one in the focused pane; else Claude asks one.
export async function getReview(space, folder) {
  const f = focused();
  const a = f?.terminal ? agents().find((x) => x.address === f.terminal) : null;
  const mine = a ? agentKeyOf(a.program?.key ?? a.app) : null;
  if (a && mine) {
    const other = mine === "claude" ? "codex" : "claude";
    await exec("hc", ["send", a.address, `get a review from ${other} and report back`]).catch(() => null);
    return;
  }
  startAgent("claude", { space, folder, name: "Claude · review", message: "get a review from codex and report back" });
}

// Relay controls: mods only write under the app folder, so the control files go through cmd.
export async function relayControl(root, what, machine) {
  const dir = join(root, ".ai", "relay");
  const win = isWin(root);
  const touch = (f) => (win ? exec("cmd", ["/c", "type", "nul", ">", join(dir, f)], { on: machine }) : exec("sh", ["-c", `touch "${join(dir, f)}"`], { on: machine }));
  const rm = (f) => (win ? exec("cmd", ["/c", "del", "/q", join(dir, f)], { on: machine }) : exec("sh", ["-c", `rm -f "${join(dir, f)}"`], { on: machine }));
  try {
    if (what === "pause") await touch("PAUSE");
    else if (what === "resume") await rm("PAUSE");
    else if (what === "stop") await touch("STOP");
    else if (what === "overnight") await touch("OVERNIGHT");   // switch the running relay to overnight mode
  } catch { /* the relay folder is gone */ }
}

// The handoff viewer, split to the right of the focused pane (or as its own tab).
export function openHandoff(root, file = "HANDOFF", space) {
  const f = focused();
  const props = { folder: root, file };
  const tab = spaceOf(space)?.tabs.find((x) => x.active);
  const pane = f?.pane ?? panes().find((p) => p.tab === tab?.id && p.focused)?.pane ?? panes().find((p) => p.tab === tab?.id)?.pane;
  if (pane) run("pane.split", { direction: "right", pane, mod: MOD.handoff, props });
  else run("tab.new", { space, name: "Handoff", mod: MOD.handoff, props });
}

export const openLauncher = () => run("mod.open", { name: MOD.launcher });
export const openCommands = () => run("mod.open", { name: MOD.commands });

// Remembered launcher choices per project.
export const CHOICES = "ai-relay-kit.choices";
export const choiceFor = (root) => (shared(CHOICES) ?? {})[(root ?? "").toLowerCase()] ?? null;
export const rememberChoice = (root, c) => setShared(CHOICES, { ...(shared(CHOICES) ?? {}), [(root ?? "").toLowerCase()]: c });

// Find layout nodes (the sidebar decides the compact rail).
export function findNode(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) { const f = findNode(child, id); if (f) return f; }
  return null;
}
// The block that shows a given mod, wherever the layout put it.
export function findModNode(node, mod) {
  if (node?.content?.mod === mod) return node;
  for (const child of node?.children ?? []) { const f = findModNode(child, mod); if (f) return f; }
  return null;
}

// Show the panel (unhide its block, and the sidebar if the panel sits in it) and give it the keyboard.
export function focusPanel() {
  const root = layout();
  const node = findModNode(root, MOD.panel);
  const sidebar = findNode(root, "sidebar");
  if (node && sidebar && findModNode(sidebar, MOD.panel)) {
    if (sidebar.hidden) run("layout.show", { id: "sidebar" });
    if ((sidebar.size?.px ?? 999) < 160) run("layout.resize", { id: "sidebar", px: shared("sidebar.width") ?? 268 });
  }
  if (node?.hidden && node.id) run("layout.show", { id: node.id });
  setShared(SHARED_FOCUS, Date.now());
}

// ---------- setup (Windows only for now: payload/setup.ps1) ----------

export const onWindows = () => (win()?.platform ? win().platform === "windows" : isWin(home()));

// Runs one setup.ps1 action; resolves with its JSON result ({ ok, error?, ... }).
export async function setupAction(action, extra = []) {
  const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", setupPs1(), "-Action", action, ...extra, "-HerdrHome", appHome()];
  try {
    const r = await exec("powershell", args, { timeout: 120000 });
    const line = (r.stdout ?? "").trim().split(/\r?\n/).filter((l) => l.trim().startsWith("{")).pop();
    const j = line ? JSON.parse(line) : null;
    return j ?? { ok: false, error: (r.stderr || r.stdout || "no output").trim().slice(0, 300) };
  } catch (e) {
    return { ok: false, error: String(e?.message ?? e) };
  }
}

// Opens an official install page in the default browser (nothing is downloaded or run).
export function openUrl(url) {
  if (!/^https:\/\//.test(url)) return;
  exec("rundll32", ["url.dll,FileProtocolHandler", url]).catch(() => null);
}
