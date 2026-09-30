/* ==========================================================================
   OPHIRA — application controller
   --------------------------------------------------------------------------
   Owns the context_core record, the step machine and rendering. Screens are
   pure: they receive state and return DOM.

   Autosave is on a debounce. A clinical encounter can be interrupted at any
   moment, and re-asking a patient for answers they already gave is both a
   data-quality problem and a dignity one.
   ========================================================================== */

import { emptyContextCore, CONSENT_VERSION } from "./schema.js";
import { computeFlags, validateScreen, screenComplete } from "./validate.js";
import * as API from "./api.js";
// `card` and `alert` are used by the results screen. Importing them is not
// optional bookkeeping: without it `card` is a ReferenceError that killed
// submit(), and `alert` silently resolved to window.alert -- a native
// browser dialog reading "[object Object]" instead of the result panel.
import { h, $, icon, toast, card, alert } from "./ui.js";
import * as S from "./screens.js";

/* --- step definitions ----------------------------------------------------- */

const STEPS = [
  { id: "operator",     short: "Session",     icon: "clipboard", render: S.operatorScreen },
  { id: "registration", short: "Patient",     icon: "user",      render: S.registrationScreen },
  { id: "eligibility",  short: "Eligibility", icon: "shield",    render: S.eligibilityScreen },
  { id: "consent",      short: "Consent",     icon: "shield",    render: S.consentScreen },
  { id: "diabetes",     short: "Diabetes",    icon: "activity",  render: S.diabetesScreen },
  { id: "ocular",       short: "Eye history", icon: "eye",       render: S.ocularScreen },
  { id: "symptoms",     short: "Symptoms",    icon: "alert",     render: S.symptomsScreen },
  { id: "acuity",       short: "Acuity",      icon: "eye",       render: S.acuityScreen },
  { id: "capture",      short: "Capture",     icon: "camera",    render: S.captureScreen },
  { id: "review",       short: "Review",      icon: "file",      render: S.reviewScreen },
];

/* --- state ---------------------------------------------------------------- */

const state = {
  ctx: emptyContextCore(),
  step: 0,
  errors: {},
  touched: false,       /* only show errors after an advance attempt */
  saveState: "idle",    /* idle | saving | saved | offline | error   */
  submitted: false,
  report: null,        /* null | {status:"pending"|"done"|"error", ...} */
};

let saveTimer = null;

/* --- actions passed to screens -------------------------------------------- */

const A = {
  set(path, value) {
    const parts = path.split(".");
    let node = state.ctx;
    for (let i = 0; i < parts.length - 1; i++) node = node[parts[i]];
    node[parts[parts.length - 1]] = value;
    recompute();
    render();
    scheduleSave();
  },

  /**
   * Upload one captured field and wait for the quality verdict.
   *
   * The slot is marked busy while the worker runs, so the operator cannot
   * queue two attempts at once, and a worker that never answers surfaces as
   * an explicit error rather than a silent pass.
   */
  async capture(slotId, file) {
    const prev = state.ctx.capture.slots[slotId];
    const attempt = (prev?.attempt ?? 0) + 1;

    state.ctx.capture.slots[slotId] = { ...prev, busy: true, attempt, reasons: [] };
    delete state.errors.worker;
    render();

    try {
      const up = await API.uploadImage(
        state.ctx.session.session_id, slotId, attempt, file);

      const res = await API.awaitQuality(up.job_id);

      state.ctx.capture.slots[slotId] = {
        busy: false,
        attempt,
        status: res.decision === "ACCEPT" ? "captured" : "rejected",
        decision: res.decision,
        score: res.score ?? 0,
        reasons: res.reasons ?? [],
        image_path: up.image_path,
        job_id: up.job_id,
        gate_version: res.gate_version,
        thresholds_version: res.thresholds_version,
        assessed_at: res.processed_at,
      };

      if (res.decision === "ACCEPT") {
        toast(`${slotId}: accepted (score ${Number(res.score).toFixed(2)})`, "ok");
      } else if (res.decision === "UNGRADABLE") {
        toast(`${slotId}: ungradable — routed to clinician review`, "danger", 7000);
      } else {
        toast(`${slotId}: retake needed`, "danger");
      }
    } catch (e) {
      // An image we could not assess is NOT a passing image. Leave the slot
      // un-accepted and say why.
      state.ctx.capture.slots[slotId] = {
        ...state.ctx.capture.slots[slotId], busy: false, decision: undefined,
      };
      state.errors.worker = e.message;
      state.touched = true;
      toast(e.message, "danger", 9000);
    }

    render();
    scheduleSave();
  },

  setConsent(given) {
    state.ctx.consent.given = given;
    state.ctx.consent.version = CONSENT_VERSION;
    state.ctx.consent.recorded_at = given ? new Date().toISOString() : null;
    recompute();
    render();
    scheduleSave();
  },
};

function recompute() {
  state.ctx.flags = computeFlags(state.ctx);
  state.ctx.eligibility.pathway = state.ctx.flags.pathway;
}

/* --- persistence ---------------------------------------------------------- */

function scheduleSave() {
  if (state.submitted) return;
  state.saveState = "saving";
  paintSaveState();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(doSave, 800);
}

async function doSave() {
  if (!state.ctx.session.session_id) return;
  const r = await API.saveDraft(state.ctx);
  state.saveState = r.offline ? "offline" : "saved";
  paintSaveState();
}

function paintSaveState() {
  const el = $("#save-state");
  if (!el) return;
  const map = {
    idle:    ["", ""],
    saving:  ["saving", "Saving…"],
    saved:   ["", "Saved"],
    offline: ["error", "Saved on this device only"],
    error:   ["error", "Save failed"],
  };
  const [dataState, text] = map[state.saveState] || map.idle;
  el.dataset.state = dataState;
  el.replaceChildren(icon(state.saveState === "saving" ? "clock" : "save"), h("span", {}, text));
}

/* --- navigation ----------------------------------------------------------- */

function currentStep() { return STEPS[state.step]; }

function goTo(index) {
  if (index < 0 || index >= STEPS.length) return;
  state.step = index;
  state.touched = false;
  state.errors = {};
  render();
  window.scrollTo({ top: 0, behavior: "instant" });
  /* Move focus to the heading so screen-reader users hear the new step. */
  requestAnimationFrame(() => $("#main h1")?.focus());
}

function next() {
  const step = currentStep();
  const errs = validateScreen(step.id, state.ctx);
  state.errors = errs;
  state.touched = true;

  if (Object.keys(errs).length > 0) {
    render();
    /* Focus the first invalid field: WCAG focus-management. */
    requestAnimationFrame(() => {
      const bad = document.querySelector('.field[data-invalid="true"] input, .field[data-invalid="true"] select, .field[data-invalid="true"] textarea');
      bad?.focus();
      bad?.scrollIntoView({ block: "center", behavior: "smooth" });
    });
    toast("Some required answers are missing.", "danger");
    return;
  }

  /* Consent declined is a hard stop, not a validation error. */
  if (step.id === "consent" && state.ctx.consent.given === false) {
    toast("Consent was declined — screening cannot proceed.", "danger", 6000);
    return;
  }

  if (state.step === STEPS.length - 1) return submit();
  goTo(state.step + 1);
}

function back() { goTo(state.step - 1); }

/* --- submit --------------------------------------------------------------- */

async function submit() {
  const missing = STEPS.filter((s) => !screenComplete(s.id, state.ctx));
  if (missing.length) {
    toast(`Incomplete: ${missing.map((m) => m.short).join(", ")}`, "danger", 6000);
    goTo(STEPS.findIndex((s) => s.id === missing[0].id));
    return;
  }

  state.ctx.session.completed_at = new Date().toISOString();
  recompute();

  try {
    const res = await API.submitSession(state.ctx);
    state.submitted = true;
    state.report = { status: "pending", images: res?.images ?? 0 };
    render();
    toast("Session submitted. Analysing…", "ok");
    pollReport(state.ctx.session.session_id);
  } catch (e) {
    toast(`Submit failed: ${e.message}`, "danger", 8000);
    state.saveState = "error";
    paintSaveState();
  }
}

/* --- rendering ------------------------------------------------------------ */

function render() {
  if (state.submitted) return renderDone();

  const step = currentStep();
  const errs = state.touched ? state.errors : {};

  /* steps */
  const steps = $("#steps");
  steps.replaceChildren(
    ...STEPS.map((s, i) => {
      const done = i < state.step && screenComplete(s.id, state.ctx);
      return h("button", {
          class: "step", type: "button",
          "aria-current": i === state.step ? "step" : null,
          "data-done": done ? "true" : null,
          disabled: i > state.step,
          onClick: () => goTo(i),
        },
        h("span", { class: "step__dot" }, done ? icon("check") : String(i + 1)),
        h("span", {}, s.short)
      );
    })
  );

  /* urgent banner in the top bar, visible on every screen once triggered */
  const chip = $("#urgent-chip");
  if (state.ctx.flags.urgent) {
    chip.hidden = false;
    chip.replaceChildren(icon("siren"), h("span", {}, "Urgent"));
  } else {
    chip.hidden = true;
  }

  /* body */
  $("#main").replaceChildren(
    h("div", { class: "wrap" },
      step.render(state.ctx, errs, A),
      h("div", { class: "actions" },
        state.step > 0
          ? h("button", { class: "btn btn--ghost", type: "button", onClick: back },
              icon("arrowL"), "Back")
          : null,
        h("div", { class: "actions__spacer" }),
        h("button", { class: "btn btn--primary", type: "button", onClick: next },
          state.step === STEPS.length - 1 ? "Submit session" : "Continue",
          icon("arrowR"))
      )
    )
  );

  const heading = $("#main h1");
  if (heading) heading.tabIndex = -1;

  paintSaveState();
}

function renderDone() {
  $("#steps").replaceChildren();
  $("#main").replaceChildren(
    h("div", { class: "wrap" },
      h("div", { class: "screen-head" },
        h("h1", { tabindex: "-1" }, "Session submitted")
      ),
      h("div", { class: "card" },
        h("div", { class: "summary" },
          h("div", { class: "summary__row" },
            h("div", { class: "summary__k" }, "Session"),
            h("div", { class: "summary__v" }, state.ctx.session.session_id)),
          h("div", { class: "summary__row" },
            h("div", { class: "summary__k" }, "Patient"),
            h("div", { class: "summary__v" }, state.ctx.patient.patient_id)),
          h("div", { class: "summary__row" },
            h("div", { class: "summary__k" }, "Pathway"),
            h("div", { class: "summary__v" }, state.ctx.flags.pathway ?? "—")),
          h("div", { class: "summary__row" },
            h("div", { class: "summary__k" }, "Urgent"),
            h("div", { class: "summary__v" }, state.ctx.flags.urgent ? "YES" : "No"))
        )
      ),

      renderResult(),

      h("div", { class: "actions" },
        h("button", {
          class: "btn btn--primary", type: "button",
          onClick: () => location.reload(),
        }, icon("user"), "Start next patient")
      )
    )
  );
  requestAnimationFrame(() => $("#main h1")?.focus());
}

/* --- result and reports --------------------------------------------------- */

/* Which alert style each action gets. An action with no mapping falls back
   to "warn" rather than "ok": an unrecognised result must never be painted
   as a clear one. */
const ACTION_KIND = {
  "URGENT": "urgent",
  "REFERRAL": "warn",
  "HUMAN REVIEW": "info",
  "RECAPTURE": "warn",
  "ROUTINE": "ok",
};

const ACTION_TEXT = {
  "URGENT": "Escalate today according to the centre's protocol.",
  "REFERRAL": "Book an ophthalmology appointment and give the patient their slip.",
  "HUMAN REVIEW": "A clinician must review the images before a result is issued.",
  "RECAPTURE": "The images could not be assessed. Retake before the patient leaves.",
  "ROUTINE": "No findings needing referral. Give the patient their slip.",
};

function renderResult() {
  const r = state.report;
  const sid = state.ctx.session.session_id;

  if (!r || r.status === "pending") {
    return card("Analysis", "Running the screening cascade in MATLAB.",
      h("p", { class: "muted" },
        r?.images ? `Assessing ${r.images} image(s)…` : "Waiting for the analysis worker…"),
      h("div", { class: "progress" }, h("div", { class: "progress__bar is-indeterminate" }))
    );
  }

  if (r.status === "error") {
    /* A failed analysis is not a clear result. The session is stored and
       can be reprocessed; the operator is told exactly that. */
    return card("Analysis",
      "The session is saved. It has NOT been assessed.",
      alert({
        kind: "urgent",
        title: "Analysis did not complete",
        text: r.error || "The analysis worker did not respond.",
        items: ["Do not issue a result.", "Start the worker in MATLAB with ophira.worker.run() and reopen this session."],
      })
    );
  }

  const action = r.action || "HUMAN REVIEW";
  const kind = ACTION_KIND[action] ?? "warn";

  return card("Result", null,
    alert({
      kind,
      title: action,
      text: ACTION_TEXT[action] ?? "Refer to a clinician.",
      items: r.reasons || [],
    }),

    r.calibrated === false ? alert({
      kind: "warn",
      title: "This site is not calibrated",
      text: "Thresholds were fitted on a different population. A negative result " +
            "here is weaker than it looks — calibrate on local labelled images " +
            "before routine screening use.",
    }) : null,

    Array.isArray(r.per_image) && r.per_image.length > 1
      ? h("div", { class: "summary" },
          r.per_image.map((pi) => h("div", { class: "summary__row" },
            h("div", { class: "summary__k" }, pi.image || "image"),
            h("div", { class: "summary__v" }, pi.action))))
      : null,

    h("div", { class: "actions actions--wrap" },
      pdfBtn(sid, "clinician", "Clinician report (PDF)"),
      pdfBtn(sid, "patient", "Patient slip (PDF)"),
      // One button that cannot leave anything behind. Four separate
      // downloads is four chances to forget one.
      h("a", {
        class: "btn btn--ghost", href: API.bundleUrl(sid),
        download: `${sid}_ophira.zip`,
      }, icon("save"), "Download all (.zip)"),
      fileBtn(sid, "clinician", "Report HTML"),
      fileBtn(sid, "patient", "Slip HTML")
    ),

    // The final report itself, at the end of the page.
    //
    // Links alone put the thing the encounter exists to produce one click
    // away and out of sight. The operator should be able to read what the
    // clinic will receive without leaving the screen, and check it against
    // the patient in front of them.
    h("h3", { class: "report-h" }, "Final report"),
    h("iframe", {
      class: "report-frame",
      title: "Clinician report",
      src: API.reportUrl(sid, "clinician"),
      loading: "lazy",
    }),
    h("p", { class: "muted" },
      "Use \u201cClinician report (PDF)\u201d above to print or save this as a PDF.")
  );
}

/* Opens the report with ?print=1, which triggers the browser's print dialog
   on load. "Save as PDF" is a destination in that dialog on every current
   browser, so this produces a real PDF from the SAME html and css the
   clinic reads on screen -- no second renderer to drift out of sync. */
function pdfBtn(sid, which, label) {
  return h("a", {
    class: "btn btn--primary",
    href: API.reportUrl(sid, which) + "?print=1",
    target: "_blank", rel: "noopener",
  }, icon("file"), label);
}

function fileBtn(sid, which, label) {
  return h("a", {
    class: "btn btn--ghost",
    href: API.reportUrl(sid, which, true),
    download: `${sid}_${which}.html`,
  }, icon("save"), label);
}

async function pollReport(sid) {
  try {
    const st = await API.awaitReport(sid, {
      onTick: () => { /* keep the indeterminate bar; nothing to update */ },
    });
    state.report = { status: "done", ...st };
    render();
    // Only URGENT gets a toast. The toast bar is fixed to the bottom of the
    // viewport and sits directly over the report buttons, so a "Result:
    // REFERRAL" toast covered the very links it was announcing while adding
    // nothing the panel above did not already say. An urgent escalation is
    // worth obscuring a button for; a routine result is not.
    if (st.action === "URGENT") {
      toast("URGENT — escalate today.", "danger", 10000);
    }
  } catch (e) {
    state.report = { status: "error", error: e.message };
    render();
    toast(`Analysis failed: ${e.message}`, "danger", 10000);
  }
}

/* --- boot ----------------------------------------------------------------- */

async function boot() {
  /* theme toggle, persisted per device */
  const savedTheme = (() => { try { return localStorage.getItem("ophira.theme"); } catch { return null; } })();
  if (savedTheme) document.documentElement.dataset.theme = savedTheme;

  $("#theme-toggle").addEventListener("click", () => {
    const now = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = now;
    try { localStorage.setItem("ophira.theme", now); } catch { /* ignore */ }
    paintTheme();
  });
  paintTheme();

  state.ctx.session.created_at = new Date().toISOString();
  recompute();

  try {
    const out = await API.createSession(state.ctx);
    state.ctx.session.session_id = out.session_id;
    $("#session-id").textContent = out.session_id;
  } catch {
    /* Server down at boot: generate a local id and keep going. The encounter
       matters more than the server. flushPending() reconciles later. */
    const local = `LOCAL-${Date.now().toString(36).toUpperCase()}`;
    state.ctx.session.session_id = local;
    $("#session-id").textContent = local;
    toast("Server unreachable — working offline on this device.", "danger", 6000);
  }

  const sent = await API.flushPending();
  if (sent > 0) toast(`${sent} offline session(s) synchronised.`, "ok");

  render();
}

function paintTheme() {
  const dark = document.documentElement.dataset.theme === "dark";
  const btn = $("#theme-toggle");
  btn.replaceChildren(icon(dark ? "sun" : "moon"));
  btn.setAttribute("aria-label", dark ? "Switch to light theme" : "Switch to dark theme");
}

/* Warn before losing an in-progress encounter. */
window.addEventListener("beforeunload", (e) => {
  if (!state.submitted && state.ctx.patient.patient_id) {
    e.preventDefault();
    e.returnValue = "";
  }
});

boot();
