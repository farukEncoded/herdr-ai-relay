// model-scout.mjs - finds, grades and manages the OpenRouter models OpenCode uses in the relay (D-032).
//
//   node tools/model-scout.mjs              pull fresh data, score, write usage/model-scout.json (changes nothing)
//   node tools/model-scout.mjs --apply      same, then make the changes the rules allow on their own (tester role)
//   node tools/model-scout.mjs --accept tester:z-ai/glm-5.3      put a model first in a role's list (your OK)
//   node tools/model-scout.mjs --dismiss executor:moonshotai/kimi-k3.1-pro   don't propose it again for 30 days
//
// Sources (each kept with its date; one older than scout.sourceMaxAgeDays is skipped, never guessed):
//   OpenRouter API (official): prices, context, tool calling, release dates; per-provider uptime for the shortlist.
//   OpenRouter rankings data: Artificial Analysis Intelligence Index, Vals Index, coding usage share per task
//     (implementation -> executor, testing -> tester, code review -> reviewer, planning -> planner), latency.
//   Terminal-Bench (tbench.ai): accuracy per agent+model, compared only within the same agent harness.
//   SWE-bench Verified (same-agent board) and Aider polyglot: used only while their newest entry is recent enough.
//   Ours: usage/bench-results.jsonl (tools/model-bench.ps1) and usage/model-stats.jsonl (real relay stages, trials).
// Rules (relay-defaults.json "scout"): our benchmark and real results weigh most; outside data alone may move a model
// only when at least two credible sources agree. Only autoPromoteRoles change by themselves; other roles get a
// proposal you accept in the panel. Every change goes to usage/model-ledger.jsonl with its reason.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const usage = path.join(root, "usage");
const cacheDir = path.join(usage, "scout-cache");
fs.mkdirSync(cacheDir, { recursive: true });
const defaultsPath = path.join(root, "relay-defaults.json");
const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };

const readJson = (p, d = null) => { try { return JSON.parse(fs.readFileSync(p, "utf8").replace(/^﻿/, "")); } catch { return d; } };
const readLines = (p) => { try { return fs.readFileSync(p, "utf8").split(/\r?\n/).filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean); } catch { return []; } };
const appendLine = (p, o) => fs.appendFileSync(p, JSON.stringify(o) + "\n");
const now = new Date();
const daysAgo = (d) => (now - new Date(d)) / 86400000;

const defaults = readJson(defaultsPath, {});
const S = Object.assign({ autoPromoteRoles: ["tester"], minMargin: 5, sourceMaxAgeDays: 180, trialEvery: 5,
  paidBenchCapUsd: 0.25, maxPaidBenchPerWeek: 2, maxOutPricePerM: 3, minContext: 128000 }, defaults.scout ?? {});
const ROLES = ["tester", "executor", "reviewer", "planner"];
const ROLE_TASK = { tester: "software.testing_verification", executor: "software.implementation",
  reviewer: "software.code_review", planner: "software.architecture_requirements_planning" };

// ---------- fetching (cached per source for 12 hours) ----------
async function get(name, url, kind = "json", maxAgeH = 12) {
  const f = path.join(cacheDir, `${name}.${kind === "json" ? "json" : "txt"}`);
  try { if ((now - fs.statSync(f).mtime) / 3600000 < maxAgeH) return { ok: true, body: fs.readFileSync(f, "utf8"), cached: true }; } catch {}
  try {
    const r = await fetch(url, { headers: { "User-Agent": "ai-relay-model-scout" }, signal: AbortSignal.timeout(60000) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const body = await r.text();
    fs.writeFileSync(f, body);
    return { ok: true, body, cached: false };
  } catch (e) {
    try { return { ok: true, body: fs.readFileSync(f, "utf8"), cached: true, stale: String(e.message ?? e) }; } catch {}
    return { ok: false, error: String(e.message ?? e) };
  }
}
// Next.js pages carry their data in self.__next_f.push([1,"..."]) chunks: join, unescape, then read JSON blocks.
function nextData(html) {
  const parts = [...html.matchAll(/self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)/g)].map((m) => { try { return JSON.parse(`"${m[1]}"`); } catch { return ""; } });
  return parts.join("");
}
function jsonAt(text, start) {   // [the JSON value starting at text[start], the index just after it]
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') inStr = true;
    else if (c === "{" || c === "[") depth++;
    else if (c === "}" || c === "]") { depth--; if (depth === 0) { try { return [JSON.parse(text.slice(start, i + 1)), i + 1]; } catch { return [null, i + 1]; } } }
  }
  return [null, text.length];
}
function queries(text) {        // react-query dehydrated state: { state: { data }, queryKey }
  const out = {};
  for (const m of text.matchAll(/"state":\{"data":/g)) {
    const [data, end] = jsonAt(text, m.index + m[0].length);
    if (!data) continue;
    const q = /"queryKey":(\[[^\]]*\])/.exec(text.slice(end, end + 2000));
    if (q) out[q[1]] = data;
  }
  return out;
}
const norm = (s) => String(s ?? "").toLowerCase().replace(/^[^:]+:\s*/, "").replace(/\(.*?\)/g, "").replace(/[^a-z0-9]/g, "");

// ---------- gather ----------
const sources = [];
const ext = {};                       // id -> { aa, vals, tbench, usage: {role: share}, latency, throughput, uptime }
const addExt = (id, k, v) => { if (!id) return; ext[id] ??= {}; ext[id][k] = v; };

const orRes = await get("openrouter-models", "https://openrouter.ai/api/v1/models");
if (!orRes.ok) { console.error("OpenRouter model list not reachable: " + orRes.error); process.exit(1); }
const models = JSON.parse(orRes.body).data;
const byId = new Map(models.map((m) => [m.id, m]));
// A model and its variants (":batch", ":free") share one canonical slug: the plain id wins the mapping.
const bySlug = new Map();
for (const m of models) {
  for (const k of [m.canonical_slug ?? m.id, m.id]) { if (!bySlug.has(k) || (bySlug.get(k).includes(":") && !m.id.includes(":"))) bySlug.set(k, m.id); }
}
const byName = new Map(); for (const m of models) { byName.set(norm(m.name), m.id); byName.set(norm(m.id.split("/")[1]), m.id); }
const idOf = (slug) => bySlug.get(slug) ?? bySlug.get(String(slug).replace(/-\d{8}$/, "")) ?? null;
sources.push({ name: "OpenRouter API", status: "ok", models: models.length, fetched: orRes.cached ? "cache" : "now" });

const rk = await get("openrouter-rankings", "https://openrouter.ai/rankings", "html");
if (rk.ok) {
  const q = queries(nextData(rk.body));
  const b = q['["rankings","benchmarks"]'];
  let n = 0;
  for (const x of b?.aaData?.intelligenceIndex ?? []) { const id = idOf(x.permaslug) ?? (x.openrouter_slug && byId.has(x.openrouter_slug) ? x.openrouter_slug : null); if (id) { addExt(id, "aa", x.score); n++; } }
  sources.push({ name: "Artificial Analysis Intelligence Index (via OpenRouter)", status: n ? "ok" : "missing", models: n });
  n = 0;
  for (const x of b?.valsIndex?.models ?? []) { const id = idOf(x.permaslug); if (id) { addExt(id, "vals", x.score); n++; } }
  sources.push({ name: `Vals Index ${b?.valsIndex?.benchmark_version ?? ""} (via OpenRouter)`.trim(), status: n ? "ok" : "missing", models: n });
  n = 0;
  for (const t of q['["rankings","taskSpend"]']?.spend?.tasks ?? []) {
    const role = Object.keys(ROLE_TASK).find((r) => ROLE_TASK[r] === t.tag);
    if (!role) continue;
    for (const x of t.models ?? []) { const id = idOf(x.model); if (id) { ext[id] ??= {}; (ext[id].usage ??= {})[role] = x.share; n++; } }
  }
  sources.push({ name: "OpenRouter coding usage per task (30 days)", status: n ? "ok" : "missing", entries: n });
  n = 0;
  for (const x of q['["rankings","performance"]'] ?? []) { const id = idOf(x.slug ?? x.id); if (id) { addExt(id, "latency", x.p50_latency); addExt(id, "throughput", x.p50_throughput); n++; } }
  sources.push({ name: "OpenRouter latency/throughput", status: n ? "ok" : "missing", models: n });
} else sources.push({ name: "OpenRouter rankings", status: "unreachable", note: rk.error });

const tb = await get("tbench", "https://www.tbench.ai/leaderboard", "html");
if (tb.ok) {
  const t = nextData(tb.body);
  const rows = [...t.matchAll(/"agent_display":\{"url":"[^"]*","label":"([^"]+)"\}[\s\S]{0,400}?"model_display":\{"url":"[^"]*","label":"([^"]+)"\}[\s\S]{0,800}?"accuracy":([\d.]+)/g)]
    .map((m) => ({ agent: m[1], model: m[2], acc: +m[3] }));
  // Only harnesses that ran many models (a fairer comparison); accuracy relative to the best result overall.
  const perAgent = {}; for (const r of rows) perAgent[r.agent] = (perAgent[r.agent] ?? 0) + 1;
  const top = Math.max(...rows.map((r) => r.acc), 1);
  let n = 0;
  for (const r of rows) {
    if (perAgent[r.agent] < 8) continue;
    const id = byName.get(norm(r.model));
    if (!id) continue;
    const rel = 100 * r.acc / top;
    if (ext[id]?.tbench == null || rel > ext[id].tbench) { addExt(id, "tbench", Math.round(rel * 10) / 10); addExt(id, "tbenchRaw", `${r.acc} % (${r.agent})`); n++; }
  }
  sources.push({ name: "Terminal-Bench (same-harness relative)", status: n ? "ok" : "missing", rows: rows.length, matched: n });
} else sources.push({ name: "Terminal-Bench", status: "unreachable", note: tb.error });

// Stale-checked sources: used only while their newest entry is within sourceMaxAgeDays.
const swe = await get("swebench", "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json", "json", 72);
if (swe.ok) {
  try {
    const v = (JSON.parse(swe.body).leaderboards ?? []).find((b) => b.name === "Verified")?.results ?? [];
    const mini = v.filter((r) => /mini-swe-agent/i.test(r.agent ?? ""));
    const newest = mini.map((r) => r.date).sort().pop();
    if (newest && daysAgo(newest) <= S.sourceMaxAgeDays) {
      let n = 0; for (const r of mini) { const id = byName.get(norm(r.model_display)); if (id) { addExt(id, "swe", r.resolved); n++; } }
      sources.push({ name: "SWE-bench Verified (mini-SWE-agent)", status: "ok", newest, matched: n });
    } else sources.push({ name: "SWE-bench Verified (mini-SWE-agent)", status: "skipped", newest, note: `older than ${S.sourceMaxAgeDays} days` });
  } catch (e) { sources.push({ name: "SWE-bench Verified", status: "unreadable", note: String(e.message) }); }
}
const aider = await get("aider", "https://raw.githubusercontent.com/Aider-AI/aider/main/aider/website/_data/polyglot_leaderboard.yml", "txt", 72);
if (aider.ok) {
  const newest = [...aider.body.matchAll(/^\s*date:\s*(\d{4}-\d\d-\d\d)/gm)].map((m) => m[1]).sort().pop();
  if (newest && daysAgo(newest) <= S.sourceMaxAgeDays) {
    let n = 0;
    for (const e of aider.body.split(/\n- /)) {
      const name = /\n\s*model:\s*(.+)/.exec(e)?.[1]; const pr = /pass_rate_2:\s*([\d.]+)/.exec(e)?.[1];
      const id = name && byName.get(norm(name)); if (id && pr) { addExt(id, "aider", +pr); n++; }
    }
    sources.push({ name: "Aider polyglot", status: "ok", newest, matched: n });
  } else sources.push({ name: "Aider polyglot", status: "skipped", newest, note: `older than ${S.sourceMaxAgeDays} days` });
}

// ---------- our own evidence ----------
const bench = readLines(path.join(usage, "bench-results.jsonl"));
const stats = readLines(path.join(usage, "model-stats.jsonl")).filter((r) => r.agent === "opencode" && r.model);
const verdictOf = {}; for (const r of readLines(path.join(usage, "model-stats.jsonl"))) if (r.judge && r.verdict) verdictOf[`${r.relay}|${r.task}|${r.round}`] = r.verdict;
const baseId = (id) => String(id).replace(/:free$/, "");
function ours(id, role) {
  const b = bench.filter((x) => baseId(x.model) === baseId(id) && x.role === role);
  const benchScore = b.length ? 100 * b.reduce((s, x) => s + x.score, 0) / b.reduce((s, x) => s + x.max, 0) : null;
  const real = stats.filter((x) => baseId(x.model) === baseId(id) && x.role === role);
  const judged = real.filter((x) => verdictOf[`${x.relay}|${x.task}|${x.round}`]);
  const pass = judged.length ? 100 * judged.filter((x) => verdictOf[`${x.relay}|${x.task}|${x.round}`] === "APPROVED").length / judged.length : null;
  const comp = real.filter((x) => x.compliant != null);
  const protocol = comp.length ? 100 * comp.filter((x) => x.compliant).length / comp.length : null;
  const toks = real.map((x) => x.tokens).filter(Boolean).sort((a, b) => a - b);
  return { benchScore, benchRuns: b.length, realRuns: real.length, pass, judged: judged.length, protocol,
           tokens: toks.length ? toks[Math.floor(toks.length / 2)] : null };
}

// ---------- scoring ----------
const maxOf = (k) => Math.max(...Object.values(ext).map((e) => e[k]).filter((v) => typeof v === "number"), 0);
const MAX = { aa: maxOf("aa"), vals: maxOf("vals"), swe: maxOf("swe"), aider: maxOf("aider") };
const usageMax = {}; for (const r of ROLES) usageMax[r] = Math.max(...Object.values(ext).map((e) => e.usage?.[r] ?? 0), 0);
const price = (m) => ({ in: +m.pricing.prompt * 1e6, out: +m.pricing.completion * 1e6 });
const isFree = (id) => /:free$/.test(id) || (byId.get(id) && price(byId.get(id)).in === 0 && price(byId.get(id)).out === 0);
const eligible = models.filter((m) => (m.supported_parameters ?? []).includes("tools") && (m.context_length ?? 0) >= S.minContext &&
  !/content-safety|guard|embed|vision-only|image|audio|tts|whisper/i.test(m.id) && !/:batch$/.test(m.id) && m.id !== "openrouter/auto" &&
  (isFree(m.id) || price(m).out <= S.maxOutPricePerM));

function score(id, role) {
  const e = ext[baseId(id)] ?? ext[id] ?? {};
  const parts = [], used = [];
  if (e.aa != null) { parts.push([100 * e.aa / MAX.aa, 0.35]); used.push(`Artificial Analysis ${e.aa}`); }
  if (e.vals != null) { parts.push([100 * e.vals / MAX.vals, 0.25]); used.push(`Vals ${e.vals}`); }
  if (e.tbench != null) { parts.push([e.tbench, 0.25]); used.push(`Terminal-Bench ${e.tbenchRaw}`); }
  if (e.swe != null) { parts.push([100 * e.swe / MAX.swe, 0.2]); used.push(`SWE-bench ${e.swe}`); }
  if (e.aider != null) { parts.push([100 * e.aider / MAX.aider, 0.15]); used.push(`Aider ${e.aider}`); }
  const credible = used.length;
  if (e.usage?.[role] && usageMax[role]) { parts.push([100 * e.usage[role] / usageMax[role], 0.1]); used.push(`OpenRouter ${role} usage ${(100 * e.usage[role]).toFixed(1)} %`); }
  const wsum = parts.reduce((s, p) => s + p[1], 0);
  const outside = wsum ? parts.reduce((s, p) => s + p[0] * p[1], 0) / wsum : null;
  const o = ours(id, role);
  const mine = [];
  if (o.benchScore != null) mine.push([o.benchScore, 0.6]);
  if (o.pass != null && o.judged >= 3) mine.push([o.pass, 0.3]);
  if (o.protocol != null && o.realRuns >= 3) mine.push([o.protocol, 0.1]);
  const msum = mine.reduce((s, p) => s + p[1], 0);
  const measured = msum ? mine.reduce((s, p) => s + p[0] * p[1], 0) / msum : null;
  // Our own measurements weigh most; outside data fills in where we have none.
  const quality = measured != null && outside != null ? 0.65 * measured + 0.35 * outside : measured ?? outside;
  const m = byId.get(id);
  const tokens = o.tokens ?? 400000;
  const cost = m ? (tokens * 0.97 * price(m).in + tokens * 0.03 * price(m).out) / 1e6 : null;
  return { id, quality: quality == null ? null : Math.round(quality * 10) / 10, outside: outside == null ? null : Math.round(outside * 10) / 10,
    measured: measured == null ? null : Math.round(measured * 10) / 10, credible, evidence: used, bench: o.benchScore, benchRuns: o.benchRuns,
    real: o.realRuns, pass: o.pass, protocol: o.protocol, free: isFree(id), costPerStage: cost == null ? null : Math.round(cost * 10000) / 10000,
    uptime: e.uptime ?? null };
}

const chains = defaults.opencode?.models ?? {};
const ledgerPath = path.join(usage, "model-ledger.jsonl");
const ledger = readLines(ledgerPath);
const dismissed = (role, id) => ledger.some((l) => l.action === "dismiss" && l.role === role && baseId(l.model) === baseId(id) && daysAgo(l.at) < 30);
const out = { at: now.toISOString(), settings: S, sources, roles: {}, benchQueue: [], proposals: [], applied: [] };

// Per-provider uptime for the shortlist only (one request per model).
async function uptime(id) {
  const m = byId.get(id); if (!m) return null;
  const r = await get(`ep-${id.replace(/[^a-z0-9]/gi, "_")}`, `https://openrouter.ai/api/v1/models/${baseId(id)}/endpoints`, "json", 24);
  if (!r.ok) return null;
  try { const eps = JSON.parse(r.body).data.endpoints ?? []; const u = eps.map((x) => x.uptime_last_1d).filter((v) => typeof v === "number"); return u.length ? Math.max(...u) : null; } catch { return null; }
}

const paidBenchThisWeek = bench.filter((b) => b.paid && daysAgo(b.at) < 7).length;
for (const role of ROLES) {
  const chain = (chains[role] ?? []).map(String);
  const ids = new Set([...chain, ...eligible.map((m) => m.id)]);
  let board = [...ids].map((id) => score(id, role)).filter((x) => x.quality != null || chain.includes(x.id));
  board.sort((a, b) => (b.quality ?? -1) - (a.quality ?? -1) || (a.costPerStage ?? 9) - (b.costPerStage ?? 9));
  for (const x of board.slice(0, 8)) x.uptime = await uptime(x.id);
  const first = chain[0] ? board.find((x) => x.id === chain[0]) ?? score(chain[0], role) : null;
  const r = { incumbent: first, leaderboard: board.slice(0, 10), trial: null };
  // Like with like (D-032): when the current first choice has our own measurements, a challenger must beat those
  // with its own measurements; outside data only decides between models nobody here has measured yet.
  const incMeasured = first && first.measured != null;
  const goodEnough = incMeasured && first.measured >= (S.goodEnough ?? 85);
  const ok = (x) => x.id !== chain[0] && baseId(x.id) !== baseId(chain[0] ?? "") && !dismissed(role, x.id) && (x.uptime == null || x.uptime >= 95);
  // Measured against measured only: an unmeasured first choice gets measured first (queued below). Our tasks are
  // small, so capable models tie near the top; on a tie the combined score (with credible outside data) and the
  // cost decide, so one easy benchmark never outweighs strong evidence that a model is weaker.
  const tie = (x) => Math.abs(x.measured - first.measured) <= 2;
  const cheaper = (x) => (x.costPerStage ?? 9) < (first.costPerStage ?? 9) * 0.5;
  const measuredWinners = board.filter((x) => ok(x) && x.measured != null && incMeasured && (
    x.measured >= first.measured + S.minMargin ||
    (tie(x) && x.quality != null && first.quality != null && (x.quality >= first.quality + S.minMargin || (cheaper(x) && x.quality >= first.quality - 2)))));
  const outsideWinners = board.filter((x) => ok(x) && x.measured == null && x.credible >= 2 && x.outside != null &&
    (first?.outside == null || x.outside >= first.outside + S.minMargin));
  const best = measuredWinners[0];
  const fmt = (x) => `${x.id} (${x.measured != null ? `measured ${x.measured}` : `outside ${x.outside}`}${x.free ? ", free" : `, ~$${x.costPerStage}/stage`})`;
  if (best) {
    out.proposals.push({ role, model: best.id, from: chain[0] ?? null, basis: "measured", auto: S.autoPromoteRoles.includes(role),
      reason: `${fmt(best)} beats ${first ? fmt(first) : "the empty list"} for ${role}` });
  } else if (!incMeasured && outsideWinners[0]) {
    // Nobody measured here: two or more credible sources may propose (never auto).
    const c = outsideWinners[0];
    out.proposals.push({ role, model: c.id, from: chain[0] ?? null, basis: "credible outside data", auto: false,
      reason: `${fmt(c)} beats ${first ? fmt(first) : "the empty list"} for ${role} by ${c.evidence.slice(0, 3).join(", ")}` });
  }
  // What to measure next: the best unmeasured challengers. Free always; paid only when it's worth it: the current
  // first choice isn't measured as good enough, or it isn't free, and credible data says the challenger is better.
  // A fair comparison needs the current first choice measured too (when it costs no more than the cap).
  if (first && !incMeasured && !out.benchQueue.some((q) => q.model === first.id && q.role === role) &&
      (first.free || (first.costPerStage ?? 9) <= S.paidBenchCapUsd)) {
    out.benchQueue.push({ role, model: first.id, paid: !first.free, estUsd: first.free ? 0 : first.costPerStage, reason: "current first choice, not measured yet", incumbent: true });
  }
  for (const c of outsideWinners.slice(0, 1)) {   // the single best unmeasured challenger per role
    if (out.benchQueue.some((q) => q.model === c.id && q.role === role)) continue;
    if (c.free) { out.benchQueue.push({ role, model: c.id, paid: false, estUsd: 0, reason: `credible data: ${c.evidence.slice(0, 2).join(", ")}` }); continue; }
    const worth = !goodEnough || (first && !first.free);
    const fits = c.costPerStage != null && c.costPerStage <= S.paidBenchCapUsd && paidBenchThisWeek < S.maxPaidBenchPerWeek;
    if (worth && fits) out.benchQueue.push({ role, model: c.id, paid: true, estUsd: c.costPerStage, reason: `credible data: ${c.evidence.slice(0, 2).join(", ")}` });
    else if (!worth) r.skippedPaid = (r.skippedPaid ?? []).concat(`${c.id}: current first is free and measured ${first.measured}`);
  }
  // Trial candidate for real tester stages: the best free model not first, ideally one under evaluation.
  if (role === "tester") {
    const t = board.find((x) => x.free && x.id !== chain[0] && !dismissed(role, x.id) && (x.uptime == null || x.uptime >= 95));
    r.trial = t ? t.id : null;
  }
  out.roles[role] = r;
}

// Free models the shortlist doesn't cover yet but outside data likes: benchmark them for the tester role (free = no cost).
for (const x of out.roles.tester.leaderboard.filter((x) => x.free && x.bench == null).slice(0, 2)) {
  if (!out.benchQueue.some((q) => q.model === x.id && q.role === "tester")) out.benchQueue.push({ role: "tester", model: x.id, paid: false, estUsd: 0, reason: "free model without our measurement" });
}

// Paid benchmarks: one model measured once covers several roles' tasks, so group by model; then keep only what
// this week's paid allowance (maxPaidBenchPerWeek, counted in models) still permits, best outside score first.
{
  const paid = out.benchQueue.filter((q) => q.paid);
  const models = [...new Set(paid.map((q) => q.model))];
  const allowed = new Set(models.slice(0, Math.max(0, S.maxPaidBenchPerWeek - paidBenchThisWeek)));
  out.benchQueue = out.benchQueue.filter((q) => !q.paid || allowed.has(q.model));
  out.benchPaidHeld = models.filter((m) => !allowed.has(m));
}

// ---------- changes ----------
function putFirst(role, id, by, reason) {
  const raw = fs.readFileSync(defaultsPath, "utf8");
  const j = JSON.parse(raw.replace(/^﻿/, ""));
  const list = (j.opencode?.models?.[role] ?? []).filter((x) => baseId(x) !== baseId(id));
  list.unshift(id);
  j.opencode.models[role] = list;
  fs.copyFileSync(defaultsPath, defaultsPath + ".bak");
  // Rewrite only this role's line, so the rest of the file keeps its layout and comments.
  const re = new RegExp(`("${role}"\\s*:\\s*)\\[[^\\]]*\\]`);
  const next = raw.replace(re, `$1${JSON.stringify(list).replace(/,/g, ", ")}`);
  fs.writeFileSync(defaultsPath, next === raw ? JSON.stringify(j, null, 2) : next);
  const entry = { at: now.toISOString(), action: "promote", role, model: id, by, reason };
  appendLine(ledgerPath, entry);
  out.applied.push(entry);
}
const acc = opt("--accept"), dis = opt("--dismiss");
if (acc || dis) {
  const [role, ...rest] = String(acc ?? dis).split(":"); const id = rest.join(":");
  if (!ROLES.includes(role) || !id) { console.error("Use role:model-id, e.g. tester:deepseek/deepseek-v4.1-flash"); process.exit(1); }
  if (acc) { const p = out.proposals.find((x) => x.role === role && x.model === id); putFirst(role, id, "user", p?.reason ?? "accepted in the panel"); }
  else { appendLine(ledgerPath, { at: now.toISOString(), action: "dismiss", role, model: id, by: "user" }); out.dismissedNow = `${role}:${id}`; }
  out.proposals = out.proposals.filter((x) => !(x.role === role && x.model === id));
}
if (flag("--apply")) {
  for (const p of out.proposals.filter((x) => x.auto && x.basis === "measured")) putFirst(p.role, p.model, "scout", p.reason);
  out.proposals = out.proposals.filter((x) => !(x.auto && x.basis === "measured"));
}
fs.writeFileSync(path.join(usage, "model-scout.json"), JSON.stringify(out, null, 2));

// ---------- summary ----------
console.log(`Model scout ${now.toISOString().slice(0, 16)}: ${eligible.length} eligible OpenRouter models`);
for (const s of sources) console.log(`  source ${s.status.padEnd(11)} ${s.name}${s.newest ? ` (newest ${s.newest})` : ""}${s.note ? ` - ${s.note}` : ""}`);
for (const role of ROLES) {
  const r = out.roles[role];
  console.log(`  ${role}: first ${r.incumbent?.id ?? "-"} (${r.incumbent?.quality ?? "no score"})  top: ` +
    r.leaderboard.slice(0, 3).map((x) => `${x.id} ${x.quality ?? "-"}${x.free ? " free" : ` $${x.costPerStage}`}`).join(" | ") + (r.trial ? `  trial: ${r.trial}` : ""));
}
for (const p of out.proposals) console.log(`  proposal${p.auto ? " (auto once measured)" : ""}: ${p.reason}`);
for (const q of out.benchQueue) console.log(`  to benchmark: ${q.role} ${q.model}${q.paid ? ` (paid ~$${q.estUsd})` : " (free)"}`);
for (const a of out.applied) console.log(`  APPLIED: ${a.role} first = ${a.model} (${a.by})`);
