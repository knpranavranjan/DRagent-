/* OPHIRA agentic screening view.
 *
 * Every rendered line comes from /api/agent/run/<sid>, which returns the
 * events the orchestrator actually emitted. No scripted sequence, no fake
 * delay, no placeholder reasoning: if a stage does not light up, the agent
 * did not run it.
 */
import { h, $, $$, icon, toast } from "./ui.js";

const API = "/api";
let poll = null;
let SLOTS = [];
let LAST = null;                 // last completed summary
let SID = null;
const picked = new Map();        // slot -> {file, path, name}

/* ------------------------------------------------------------- helpers */
async function get(p) {
  const r = await fetch(API + p);
  if (!r.ok && r.status !== 404) throw new Error(`${p} → ${r.status}`);
  return r.json();
}
async function post(p, body) {
  const r = await fetch(API + p, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || `${p} → ${r.status}`);
  return j;
}
const newSid = () => {
  const d = new Date(), p = (n) => String(n).padStart(2, "0");
  const r = Math.random().toString(16).slice(2, 8).toUpperCase();
  return `S-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-` +
         `${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}-${r}`;
};
const b64 = (file) => new Promise((res, rej) => {
  const fr = new FileReader();
  fr.onerror = () => rej(new Error("could not read file"));
  fr.onload = () => res(String(fr.result).slice(String(fr.result).indexOf(",") + 1));
  fr.readAsDataURL(file);
});
const esc = (s) => String(s ?? "").replace(/[&<>"]/g,
  (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const NODE = {
  assess_image_quality: "quality", run_triage: "triage",
  run_dr_grading: "grading", run_maculopathy: "maculopathy",
  run_decision_engine: "decision", run_lesion_analysis: "lesions",
  run_xai: "xai",
};
const LABEL = {
  assess_image_quality: "Quality gate", run_triage: "Triage",
  run_dr_grading: "DR grading", run_maculopathy: "Maculopathy",
  run_lesion_analysis: "Lesion analysis", run_xai: "XAI / Grad-CAM",
  run_decision_engine: "Decision engine",
  request_recapture: "Request recapture", finish: "Finish",
};

/* ------------------------------------------------------------- theme */
/* Same persistence key as the encounter app, so a clinic tablet set to
   dark stays dark across both pages. Explicit choice, not OS-following:
   a screening room's lighting is not the operating system's business. */
(function theme() {
  const KEY = "ophira.theme";
  let saved = null;
  try { saved = localStorage.getItem(KEY); } catch { /* private mode */ }
  if (saved) document.documentElement.dataset.theme = saved;

  const paint = () => {
    const dark = document.documentElement.dataset.theme === "dark";
    const b = $("#theme-toggle");
    b.replaceChildren(icon(dark ? "sun" : "moon"));
    b.setAttribute("aria-label",
      dark ? "Switch to light appearance" : "Switch to dark appearance");
  };
  $("#theme-toggle").addEventListener("click", () => {
    const now = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = now;
    try { localStorage.setItem(KEY, now); } catch { /* ignore */ }
    paint();
  });
  paint();
})();

/* ------------------------------------------------------------- slots */
function renderSlots() {
  const host = $("#slots");
  host.replaceChildren();
  for (const s of SLOTS) {
    const got = picked.get(s.id);
    const input = h("input", {
      type: "file", accept: "image/*", class: "sr-only",
      id: `f_${s.id}`,
      onChange: (e) => {
        const f = e.target.files?.[0];
        e.target.value = "";
        if (f) { picked.set(s.id, { file: f, name: f.name }); renderSlots(); paintRunBtn(); }
      },
    });
    host.append(h("div", {
        class: `ag-slot ${got ? "is-set" : ""} ${s.required ? "is-req" : ""}`,
        "data-slot": s.id,
      },
      h("div", { class: "ag-slot__top" },
        h("b", {}, s.label),
        s.required ? h("span", { class: "ag-req" }, "required")
                   : h("span", { class: "ag-opt" }, "optional")),
      got
        ? h("div", { class: "ag-slot__file" }, icon("check"), h("span", {}, got.name))
        : h("div", { class: "ag-slot__empty" }, "No capture loaded"),
      input,
      h("label", { class: "btn btn--ghost btn--sm", for: `f_${s.id}` },
        icon("camera"), got ? "Replace" : "Load image"),
      got ? h("button", {
        class: "ag-slot__clear", type: "button",
        "aria-label": `Remove ${s.label}`,
        onClick: () => { picked.delete(s.id); renderSlots(); paintRunBtn(); },
      }, "×") : null));
  }
}

function paintRunBtn() {
  const req = SLOTS.filter((s) => s.required).map((s) => s.id);
  const haveReq = req.every((id) => picked.has(id));
  const any = picked.size > 0;
  $("#runBtn").disabled = !any;
  $("#runNote").textContent = any
    ? (haveReq ? "" :
       "Both macula fields are normally required. The agent will run on what is loaded.")
    : "Load at least one capture.";
}

/* ------------------------------------------------------------- boot */
async function loadInfo() {
  try {
    const i = await get("/agent/info");
    SLOTS = i.slots || [];
    renderSlots(); paintRunBtn();
    renderModels(i.models || []);

    $("#vAgent").textContent = i.agent_version || "—";
    $("#vTools").textContent = (i.tools || []).length
      ? `${i.tools.length} — ${i.tools.map((t) => t.name).join(", ")}` : "—";
    const l = i.llm || {};
    $("#vLlm").textContent = l.available
      ? `${l.provider} · ${l.model} (local)`
      : "none reachable — deterministic planner and synthesis";
    if (!i.available) {
      $("#runNote").textContent = "Agent layer unavailable: " + (i.import_error || "unknown");
      $("#runBtn").disabled = true;
    }
  } catch (e) {
    $("#runNote").textContent = "Could not read agent info: " + e.message;
  }
}

function renderModels(models) {
  const b = $("#modelsBody");
  b.replaceChildren();
  for (const m of models) {
    b.append(h("tr", {},
      h("td", { class: "ag-stage" }, m.stage),
      h("td", {}, h("b", {}, m.model),
        m.file && !m.file.startsWith("—")
          ? h("code", { class: "ag-file" }, m.file) : null),
      h("td", { class: "num" }, m.params),
      h("td", { class: "num" }, m.size_mb ? `${m.size_mb} MB` : "—"),
      h("td", { class: "ag-metric" }, m.metric),
      h("td", { class: "ag-ds" }, m.dataset),
      h("td", { class: "ag-caveat" }, m.note)));
  }
}

/* ------------------------------------------------------------- render */
function setBadge(active) {
  const b = $("#agentBadge");
  b.classList.toggle("is-active", active);
  b.querySelector("b").textContent = active ? "AGENT ACTIVE" : "AGENT IDLE";
}
function lightNode(k, cls) {
  const n = document.querySelector(`.ag-node[data-k="${k}"]`);
  if (n) n.classList.add(cls);
}
function fmt(v) {
  if (Array.isArray(v)) return v.join(", ") || "none";
  if (typeof v === "number") return Number.isInteger(v) ? String(v) : v.toFixed(4);
  if (typeof v === "boolean") return v ? "yes" : "no";
  return String(v);
}

function renderTrace(events) {
  const showObs = $("#showObs").checked;
  const ol = $("#trace");
  ol.replaceChildren();
  const list = events.filter((e) => showObs || e.event !== "observation");
  if (!list.length) { ol.append(h("li", { class: "ag-empty" }, "No events yet.")); return; }

  let lastSlot = null;
  for (const e of list) {
    if (e.slot && e.slot !== lastSlot && e.slot !== "image") {
      lastSlot = e.slot;
      const lbl = (SLOTS.find((s) => s.id === e.slot) || {}).label || e.slot;
      ol.append(h("li", { class: "ag-slotmark" }, lbl));
    }
    let cls = "ag-e", title = e.event.replace(/_/g, " "), body = null;

    if (e.event === "tool_selected") {
      cls = "ag-e ag-e--select";
      title = `Agent selected ${LABEL[e.tool] || e.tool}`;
      body = h("div", { class: "ag-why" }, h("span", {}, "why"), h("p", {}, e.reason || ""));
    } else if (e.event === "tool_completed") {
      cls = "ag-e ag-e--done";
      title = `${LABEL[e.tool] || e.tool} completed`;
      const d = e.detail || {};
      if (Object.keys(d).length) {
        body = h("div", { class: "ag-res" }, Object.entries(d).map(([k, v]) =>
          h("span", { class: "ag-chip" }, h("i", {}, k.replace(/_/g, " ")),
            document.createTextNode(fmt(v)))));
      }
    } else if (e.event === "tool_failed") {
      cls = "ag-e ag-e--fail";
      title = `${LABEL[e.tool] || e.tool} FAILED`;
      body = h("p", { class: "ag-why" }, (e.detail || {}).error || "");
    } else if (e.event === "agent_replanned") {
      cls = "ag-e ag-e--replan"; title = "Agent replanned";
      body = h("div", { class: "ag-why" }, h("span", {}, "why"), h("p", {}, e.reason || ""));
    } else if (e.event === "recapture_requested") {
      cls = "ag-e ag-e--replan"; title = "AGENT ACTION — request recapture";
      body = h("div", { class: "ag-why" }, h("span", {}, "why"), h("p", {}, e.reason || ""));
    } else if (e.event === "decision_completed") {
      cls = "ag-e ag-e--engine"; title = "DETERMINISTIC DECISION ENGINE";
      body = h("div", { class: "ag-res" },
        h("span", { class: "ag-chip ag-chip--route" }, h("i", {}, "route"),
          document.createTextNode((e.detail || {}).route || "")));
    } else if (e.event === "observation") {
      cls = "ag-e ag-e--obs"; title = "Agent observed state";
      const d = e.detail || {};
      body = h("p", { class: "ag-why" },
        `have: ${(d.have || []).join(", ") || "nothing"} · missing: ${(d.missing || []).join(", ") || "nothing"}`);
    } else if (e.event === "case_completed") {
      cls = "ag-e ag-e--done"; title = "Capture complete";
    }
    ol.append(h("li", { class: cls },
      h("div", { class: "ag-line" }, h("b", {}, title),
        h("time", {}, (e.at || "").slice(11))), body));
  }
  ol.scrollTop = ol.scrollHeight;
}

function renderSummary(t) {
  if (!t) return;
  LAST = t;
  const m = t.metrics || {};
  $("#stState").textContent = "COMPLETE";
  $("#stImages").textContent = m.images ?? 0;
  $("#stTools").textContent = m.tools_executed ?? 0;
  $("#stReplans").textContent = m.replans ?? 0;
  $("#stEvidence").textContent = m.evidence_items ?? 0;
  $("#stMs").textContent = m.total_ms ? `${(m.total_ms / 1000).toFixed(1)} s` : "—";
  $("#vEngine").textContent = (t.decision || {}).rules_version || "—";

  const d = t.decision;
  if (d) {
    $("#decCard").hidden = false;
    $("#decRoute").textContent = t.route;
    $("#decRoute").className = "ag-route ag-route--" +
      String(t.route).toLowerCase().replace(/\s+/g, "-");
    $("#decSource").textContent = d.source;
    $("#decRules").textContent = d.rules_version || "—";
    const gs = SLOTS.find((s) => s.id === t.governing_slot);
    $("#decSlot").textContent = gs ? gs.label : (t.governing_slot || "—");
    const ul = $("#decReasons"); ul.replaceChildren();
    for (const r of d.reasons || []) ul.append(h("li", {}, r));
  }
  const s = t.synthesis;
  if (s && s.text) {
    $("#synCard").hidden = false;
    $("#synText").textContent = s.text;
    $("#synSrc").textContent = s.source;
  }
  $("#dlCard").hidden = false;
  renderPerImage(t.per_image || []);
}

function renderPerImage(rows) {
  if (!rows.length) return;
  $("#perImgCard").hidden = false;
  const b = $("#perImgTable").querySelector("tbody");
  b.replaceChildren();
  for (const r of rows) {
    const ev = r.evidence || {};
    const q = ev.quality, tri = ev.triage, g = ev.grading,
          mac = ev.maculopathy, les = ev.lesions;
    b.append(h("tr", {},
      h("td", {}, h("b", {}, r.label), h("code", { class: "ag-file" }, r.image)),
      h("td", {}, q ? `${q.decision} (${Number(q.quality_score).toFixed(3)})` : "—"),
      h("td", {}, tri ? (tri.escalate
          ? `escalated ${Number(tri.p_any_dr).toFixed(3)}`
          : `cleared ${Number(tri.p_any_dr).toFixed(3)}`) : "—"),
      h("td", { class: "num" }, g ? `${g.grade} — ${g.grade_label}` : "—"),
      h("td", { class: "num" }, g ? Number(g.uncertainty).toFixed(3) : "—"),
      h("td", { class: "num" }, mac && mac.available
        ? `${mac.maculopathy}${mac.referable ? " (ref)" : ""}` : "—"),
      h("td", {}, les && les.available
        ? `${(les.lesion_types || []).join(", ") || "none"}` : "—"),
      h("td", {}, h("span", {
        class: "ag-pill ag-pill--" + String(r.route || r.state).toLowerCase().replace(/[\s_]+/g, "-"),
      }, r.route || r.state)),
      h("td", { class: "num" }, String(r.tools_executed))));
  }
}

/* ------------------------------------------------------------- run */
async function start() {
  if (!picked.size) return;
  SID = newSid();
  $("#stCase").textContent = SID;
  $("#stState").textContent = "UPLOADING";
  $("#trace").replaceChildren(h("li", { class: "ag-empty" }, "Uploading captures…"));
  for (const id of ["decCard", "synCard", "dlCard", "perImgCard"]) $("#" + id).hidden = true;
  $$(".ag-node").forEach((n) => n.classList.remove("is-done", "is-active", "is-skipped"));
  $("#runBtn").disabled = true;
  setBadge(true);

  const images = [];
  try {
    for (const [slot, v] of picked) {
      const r = await post("/agent/upload", {
        session_id: SID, slot_id: slot, attempt: 1,
        filename: v.name, data_base64: await b64(v.file),
      });
      images.push({ slot, path: r.path });
    }
  } catch (e) {
    toast("Upload failed: " + e.message, "danger", 8000);
    $("#runBtn").disabled = false; setBadge(false);
    $("#stState").textContent = "FAILED";
    return;
  }

  try {
    await post("/agent/run", {
      session_id: SID, images,
      site: $("#site").value.trim() || "default",
      use_llm: $("#useLlm").checked,
      context: { flags: { urgent: false, urgent_reasons: [],
                          reduced_va: false, pathway: "screening" } },
    });
  } catch (e) {
    toast("Could not start: " + e.message, "danger", 8000);
    $("#runBtn").disabled = false; setBadge(false);
    $("#stState").textContent = "FAILED";
    return;
  }
  $("#stState").textContent = "RUNNING";
  clearInterval(poll);
  poll = setInterval(tick, 500);
}

async function tick() {
  let st;
  try { st = await get(`/agent/run/${SID}`); } catch { return; }
  const events = st.events || [];
  renderTrace(events);

  for (const e of events) {
    const k = NODE[e.tool];
    if (!k) continue;
    if (e.event === "tool_started") lightNode(k, "is-active");
    if (e.event === "tool_completed") {
      const n = document.querySelector(`.ag-node[data-k="${k}"]`);
      if (n) { n.classList.remove("is-active"); n.classList.add("is-done"); }
    }
  }
  const last = [...events].reverse().find((e) =>
    e.event === "tool_selected" || e.event === "recapture_requested");
  if (last) {
    $("#nowTool").textContent = LABEL[last.tool] || last.tool || "Request recapture";
    $("#nowWhy").textContent = last.reason || "";
  }
  $("#stTools").textContent = events.filter((e) => e.event === "tool_completed").length;
  $("#stReplans").textContent = events.filter((e) => e.event === "agent_replanned").length;

  if (st.status === "done" || st.status === "error") {
    clearInterval(poll); setBadge(false); $("#runBtn").disabled = false;
    if (st.status === "error") {
      toast("Agent run failed: " + (st.error || "unknown"), "danger", 10000);
      $("#stState").textContent = "FAILED";
    } else {
      renderSummary(st.trace);
      $("#nowTool").textContent = "Complete";
      $("#nowWhy").textContent =
        "Evidence collected and submitted. The route above came from the decision engine.";
      $$(".ag-node").forEach((n) => {
        if (!n.classList.contains("is-done")) n.classList.add("is-skipped");
      });
    }
  }
}

/* --------------------------------------------------------- report out */
function reportHtml(t) {
  const m = t.metrics || {}, d = t.decision || {};
  const rows = (t.per_image || []).map((r) => {
    const ev = r.evidence || {}, g = ev.grading, q = ev.quality,
          mac = ev.maculopathy, les = ev.lesions;
    return `<tr><td><b>${esc(r.label)}</b><br><code>${esc(r.image)}</code></td>
      <td>${q ? esc(q.decision) + " (" + Number(q.quality_score).toFixed(3) + ")" : "—"}</td>
      <td>${g ? esc(g.grade + " — " + g.grade_label) : "—"}</td>
      <td>${g ? Number(g.uncertainty).toFixed(3) : "—"}</td>
      <td>${mac && mac.available ? esc(String(mac.maculopathy)) : "—"}</td>
      <td>${les && les.available ? esc((les.lesion_types || []).join(", ") || "none") : "—"}</td>
      <td><b>${esc(r.route || r.state)}</b></td></tr>`;
  }).join("");

  const models = (t.models || []).map((x) => `<tr>
      <td>${esc(x.stage)}</td><td><b>${esc(x.model)}</b></td>
      <td class="n">${esc(x.params)}</td>
      <td class="n">${x.size_mb ? x.size_mb + " MB" : "—"}</td>
      <td>${esc(x.metric)}</td><td>${esc(x.dataset)}</td>
      <td class="cav">${esc(x.note)}</td></tr>`).join("");

  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>OPHIRA agent report — ${esc(t.session_id)}</title>
<style>
@page{size:A4 landscape;margin:12mm}
*{box-sizing:border-box}
body{margin:0;background:#fff;color:#16202c;font:12px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px 48px}
h1{font-size:19px;margin:0 0 2px}
h2{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:#5d6b7a;
   margin:22px 0 6px;border-bottom:1px solid #dde3ea;padding-bottom:4px}
.meta{color:#5d6b7a;font-size:11px;margin:0 0 14px}
.route{display:inline-block;font-size:22px;font-weight:700;padding:8px 16px;
  border:2px solid #b3541e;color:#b3541e;background:#fef3e9;border-radius:6px}
.auth{font-size:11px;color:#5d6b7a;margin:6px 0 0}
table{width:100%;border-collapse:collapse;font-size:11px;margin:6px 0}
th{text-align:left;font-size:9px;text-transform:uppercase;letter-spacing:.06em;
   color:#5d6b7a;border-bottom:1px solid #dde3ea;padding:5px 6px}
td{padding:5px 6px;border-bottom:1px solid #eef2f6;vertical-align:top}
td.n{text-align:right;font-variant-numeric:tabular-nums}
td.cav{color:#5d6b7a;max-width:300px}
code{font:10px ui-monospace,Menlo,Consolas,monospace;color:#5d6b7a}
ul{margin:4px 0;padding-left:18px}
.grid{display:grid;grid-template-columns:auto 1fr;gap:2px 14px;font-size:11px}
.grid dt{color:#5d6b7a}.grid dd{margin:0}
.note{font-size:10px;color:#5d6b7a;line-height:1.5}
footer{margin-top:24px;padding-top:10px;border-top:1px solid #dde3ea;font-size:10px;color:#5d6b7a}
@media print{main{max-width:none;padding:0}table,section{break-inside:avoid}}
</style></head><body><main>

<h1>OPHIRA — agentic screening report</h1>
<p class="meta">Session <code>${esc(t.session_id)}</code> ·
  generated ${esc(new Date().toLocaleString())} ·
  agent ${esc(t.agent_version)} · ruleset ${esc(d.rules_version || "—")}</p>

<h2>Clinical route</h2>
<div class="route">${esc(t.route)}</div>
<ul>${(d.reasons || []).map((r) => `<li>${esc(r)}</li>`).join("")}</ul>
<p class="auth"><b>Source: deterministic OPHIRA decision engine.</b>
  Rules fired: <code>${esc((d.rules_fired || []).join(", "))}</code>.
  ${d.calibrated ? "" : "<b>This site is not calibrated</b> — thresholds were fitted on a different population; measured externally that configuration detected 51% of referable disease versus 90% once recalibrated."}</p>

<h2>Result by capture</h2>
<table><thead><tr><th>Field</th><th>Quality</th><th>DR grade</th>
<th>Uncertainty</th><th>Maculopathy</th><th>Lesions</th><th>Route</th></tr></thead>
<tbody>${rows}</tbody></table>

<h2>Agentic workflow</h2>
<dl class="grid">
  <dt>Captures assessed</dt><dd>${m.images ?? 0}</dd>
  <dt>Tools executed</dt><dd>${m.tools_executed ?? 0}</dd>
  <dt>Adaptive branches</dt><dd>${m.replans ?? 0}</dd>
  <dt>Evidence items</dt><dd>${m.evidence_items ?? 0}</dd>
  <dt>Unresolved tool errors</dt><dd>${m.tool_failures ?? 0}</dd>
  <dt>Narrative source</dt><dd>${esc((t.synthesis || {}).source || "—")}</dd>
  <dt>Decision authority</dt><dd><b>OPHIRA decision engine</b></dd>
  <dt>Agent role</dt><dd>evidence orchestration and report synthesis</dd>
</dl>
<p class="note">${esc((t.synthesis || {}).text || "")}</p>
<p class="note">The agent selected which evidence to collect and in what
order. It did not grade the retina, did not set any threshold, and did not
decide the referral.</p>

<h2>Models used, and what they are measured at</h2>
<table><thead><tr><th>Stage</th><th>Model</th><th>Params</th><th>Size</th>
<th>Measured</th><th>Dataset</th><th>What it does not tell you</th></tr></thead>
<tbody>${models}</tbody></table>

<h2>Limitations</h2>
<p class="note">This system has never been validated in a prospective
clinical study; every figure above comes from retrospective public
datasets. Per-site calibration is mandatory. Model uncertainty is
calibrated on the development population only — on external data the cases
the grader misses are <i>less</i> uncertain than the ones it catches.
Grad-CAM shows model attention and does not localise lesions. A RECAPTURE
is only safe if the retake actually happens.</p>

<footer>OPHIRA is a research prototype. It is not a clinically validated
medical device and must not be used to make a diagnosis. Every result
requires clinician review.</footer>
</main></body></html>`;
}

function openReport(printIt) {
  if (!LAST) return;
  const w = window.open("", "_blank");
  if (!w) { toast("Pop-up blocked — allow pop-ups to open the report.", "warn", 7000); return; }
  w.document.write(reportHtml(LAST));
  w.document.close();
  if (printIt) w.addEventListener("load", () => setTimeout(() => w.print(), 250));
}
function download(name, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement("a");
  a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

/* ------------------------------------------------------------- wire */
$("#runBtn").addEventListener("click", start);
$("#showObs").addEventListener("change", () => {
  if (LAST || SID) tick().catch(() => {});
});
$("#demoBtn").addEventListener("click", async () => {
  // Fetch the shipped sample and load it into both required fields, so the
  // four-slot flow can be demonstrated without a camera.
  try {
    const r = await fetch("/samples/sample_fundus_referral.png");
    if (!r.ok) throw new Error("sample not served");
    const blob = await r.blob();
    const f = new File([blob], "sample_fundus_referral.png", { type: "image/png" });
    for (const s of SLOTS.filter((x) => x.required)) picked.set(s.id, { file: f, name: f.name });
    renderSlots(); paintRunBtn();
  } catch (e) {
    toast("Could not load the sample: " + e.message, "warn", 6000);
  }
});
$("#modelsToggle").addEventListener("click", (e) => {
  const w = $("#modelsWrap");
  const open = w.hasAttribute("hidden");
  if (open) w.removeAttribute("hidden"); else w.setAttribute("hidden", "");
  e.target.textContent = open ? "Hide" : "Show";
  e.target.setAttribute("aria-expanded", String(open));
});
$("#pdfBtn").addEventListener("click", () => openReport(true));
$("#htmlBtn").addEventListener("click", () =>
  download(`${LAST.session_id}_agent_report.html`, reportHtml(LAST), "text/html"));
$("#jsonBtn").addEventListener("click", () =>
  download(`${LAST.session_id}_agent_trace.json`, JSON.stringify(LAST, null, 2),
           "application/json"));

loadInfo();
