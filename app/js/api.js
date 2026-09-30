/* ==========================================================================
   OPHIRA — backend client
   --------------------------------------------------------------------------
   The backend is a local session store. It is deliberately dumb: it writes
   JSON files to disk and lists them. MATLAB reads those same files. There is
   no database and no network dependency, because the deployed device has no
   internet and must keep working when the network does not.

   OFFLINE BEHAVIOUR: every write also lands in localStorage first. If the
   server is unreachable the session survives in the browser and is flushed
   when the server returns. An interrupted encounter must never lose the
   answers the patient already gave.
   ========================================================================== */

const BASE = "/api";
const LS_PREFIX = "ophira.session.";
const LS_PENDING = "ophira.pending";

async function req(path, opts = {}) {
  const res = await fetch(BASE + path, {
    headers: { "Content-Type": "application/json" },
    ...opts,
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`${res.status} ${res.statusText}${body ? `: ${body}` : ""}`);
  }
  return res.status === 204 ? null : res.json();
}

/* --- local cache ---------------------------------------------------------- */

function cacheWrite(ctx) {
  try {
    localStorage.setItem(LS_PREFIX + ctx.session.session_id, JSON.stringify(ctx));
  } catch { /* private mode / quota: the server copy is authoritative anyway */ }
}

export function cacheRead(id) {
  try {
    const raw = localStorage.getItem(LS_PREFIX + id);
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}

export function cacheClear(id) {
  try { localStorage.removeItem(LS_PREFIX + id); } catch { /* ignore */ }
}

function markPending(id, yes) {
  try {
    const set = new Set(JSON.parse(localStorage.getItem(LS_PENDING) || "[]"));
    yes ? set.add(id) : set.delete(id);
    localStorage.setItem(LS_PENDING, JSON.stringify([...set]));
  } catch { /* ignore */ }
}

export function pendingIds() {
  try { return JSON.parse(localStorage.getItem(LS_PENDING) || "[]"); }
  catch { return []; }
}

/* --- API ------------------------------------------------------------------ */

export async function createSession(ctx) {
  const out = await req("/sessions", {
    method: "POST",
    body: JSON.stringify(ctx),
  });
  cacheWrite({ ...ctx, session: { ...ctx.session, session_id: out.session_id } });
  return out;
}

/**
 * Save a draft. Resolves to {ok, offline} rather than throwing on a network
 * failure -- the caller shows a "saved locally" state and carries on. Losing
 * the server is not a reason to interrupt an encounter with a patient.
 */
export async function saveDraft(ctx) {
  cacheWrite(ctx);
  try {
    await req(`/sessions/${encodeURIComponent(ctx.session.session_id)}`, {
      method: "PUT",
      body: JSON.stringify(ctx),
    });
    markPending(ctx.session.session_id, false);
    return { ok: true, offline: false };
  } catch {
    markPending(ctx.session.session_id, true);
    return { ok: true, offline: true };
  }
}

/** Final submit. This one DOES throw: the operator must know it failed. */
export async function submitSession(ctx) {
  cacheWrite(ctx);
  const out = await req(`/sessions/${encodeURIComponent(ctx.session.session_id)}/submit`, {
    method: "POST",
    body: JSON.stringify(ctx),
  });
  markPending(ctx.session.session_id, false);
  return out;
}

export async function listSessions() {
  return req("/sessions");
}

export async function getSession(id) {
  return req(`/sessions/${encodeURIComponent(id)}`);
}

export async function health() {
  try { return await req("/health"); }
  catch { return { ok: false }; }
}

/* --- capture + quality ---------------------------------------------------- */

/**
 * Upload one captured field. Returns {job_id, image_path}.
 * The image is stored as an immutable original; a retake gets a new attempt
 * number and a new file, so nothing is ever overwritten.
 */
export async function uploadImage(sessionId, slotId, attempt, file) {
  const b64 = await fileToBase64(file);
  return req(`/sessions/${encodeURIComponent(sessionId)}/images`, {
    method: "POST",
    body: JSON.stringify({
      slot_id: slotId,
      attempt,
      filename: file.name,
      data_base64: b64,
    }),
  });
}

export async function jobStatus(jobId) {
  return req(`/jobs/${encodeURIComponent(jobId)}`);
}

/**
 * Poll until the quality worker reports a verdict.
 *
 * Times out rather than hanging: if the MATLAB worker is not running the
 * operator must be told that plainly, not left watching a spinner. An
 * unassessed image is never treated as a passing one.
 */
export async function awaitQuality(jobId, { timeoutMs = 60000, intervalMs = 600, onTick } = {}) {
  const t0 = Date.now();
  for (;;) {
    const st = await jobStatus(jobId);
    if (st.status === "done") return st;
    if (st.status === "failed") throw new Error(st.error || "quality job failed");
    if (Date.now() - t0 > timeoutMs) {
      throw new Error(
        "No response from the analysis worker. Start it in MATLAB with " +
        "ophira.worker.run() and try again."
      );
    }
    if (onTick) onTick(Date.now() - t0);
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error("could not read file"));
    fr.onload = () => {
      const s = String(fr.result);
      resolve(s.slice(s.indexOf(",") + 1));   // strip the data: URL prefix
    };
    fr.readAsDataURL(file);
  });
}

/** Push any drafts that were written while the server was unreachable. */
export async function flushPending() {
  const ids = pendingIds();
  let sent = 0;
  for (const id of ids) {
    const ctx = cacheRead(id);
    if (!ctx) { markPending(id, false); continue; }
    try {
      await req(`/sessions/${encodeURIComponent(id)}`, {
        method: "PUT", body: JSON.stringify(ctx),
      });
      markPending(id, false);
      sent++;
    } catch { /* still offline; try again next time */ }
  }
  return sent;
}

/* ---------------------------------------------------------------------------
   Reports
   ---------------------------------------------------------------------------
   Submitting a session queues the full cascade in MATLAB. These read the
   result back. Until this existed the encounter app stopped at "record
   stored" and the documents the system generates never reached anyone.
*/

export async function reportStatus(sessionId) {
  const r = await fetch(`${BASE}/reports/${encodeURIComponent(sessionId)}`);
  if (r.status === 404) return { status: "none" };
  if (!r.ok) throw new Error(`report status failed (${r.status})`);
  return r.json();
}

/** Everything for one encounter as a single .zip download. */
export function bundleUrl(sessionId) {
  return `${BASE}/reports/${encodeURIComponent(sessionId)}/bundle.zip`;
}

/** URL for viewing or downloading a generated report. */
export function reportUrl(sessionId, which, download = false) {
  const q = download ? "?download=1" : "";
  return `${BASE}/reports/${encodeURIComponent(sessionId)}/${which}.html${q}`;
}

/**
 * Poll until MATLAB has written the reports.
 *
 * The cascade runs a lesion segmentation for referred cases, which takes
 * several seconds, so the default timeout is generous. It still times out
 * rather than hanging: if the worker is not running the operator must be
 * told plainly. A session with no report is NOT a session with no findings.
 */
export async function awaitReport(sessionId, { timeoutMs = 180000, intervalMs = 1000, onTick } = {}) {
  const t0 = Date.now();
  for (;;) {
    const st = await reportStatus(sessionId);
    if (st.status === "done") return st;
    if (st.status === "failed") throw new Error(st.error || "report generation failed");
    if (Date.now() - t0 > timeoutMs) {
      throw new Error(
        "No response from the analysis worker. Start it in MATLAB with " +
        "ophira.worker.run() — the session is saved and will be analysed when it runs."
      );
    }
    if (onTick) onTick(Date.now() - t0, st.status);
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}
