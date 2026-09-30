/* ==========================================================================
   OPHIRA — validation and derived clinical flags
   --------------------------------------------------------------------------
   Two jobs:

   1. Per-screen field validation, so the operator cannot advance with an
      incomplete record.

   2. computeFlags(): derives the `flags` block that the deterministic
      decision engine consumes. This is the ONLY place flags are written.

   SAFETY PROPERTY (Architecture section 02 and section 18):
   Urgent escalation is derived here, from symptoms and visual acuity ALONE.
   It does not consult, and cannot be overridden by, any AI output. A patient
   reporting sudden vision loss escalates whether the model says grade 0 or
   grade 4, and whether or not an image was ever captured.
   ========================================================================== */

import { SYMPTOMS, VA_THRESHOLD, CAPTURE_SLOTS, vaRank, labelFor } from "./schema.js";

/* --- derived flags -------------------------------------------------------- */

export function computeFlags(ctx) {
  const reasons = [];

  /* Red-flag symptoms -> urgent, independent of everything else. */
  const flagged = SYMPTOMS.filter(
    (s) => s.flag && ctx.symptoms.reported.includes(s.value)
  );
  for (const s of flagged) {
    reasons.push({ code: `symptom:${s.value}`, text: s.label });
  }

  /* Visual acuity. */
  const rOd = vaRank(ctx.visual_acuity.od.value);
  const rOs = vaRank(ctx.visual_acuity.os.value);
  const worst = Math.max(rOd, rOs);

  const reducedVa = worst >= VA_THRESHOLD.reducedRank;
  const severeVa  = worst >= VA_THRESHOLD.severeRank;

  if (severeVa) {
    const eye = rOd >= rOs ? "right" : "left";
    const val = rOd >= rOs ? ctx.visual_acuity.od.value : ctx.visual_acuity.os.value;
    reasons.push({
      code: "va:severe",
      text: `Severely reduced acuity in the ${eye} eye (${val})`,
    });
  }

  /* Pathway. A patient already under DR treatment is surveillance, not
     first-time screening (Architecture section 02, Eligibility). */
  let pathway = null;
  const e = ctx.eligibility;
  if (e.diabetes_confirmed === false) {
    pathway = "ineligible";
  } else if (e.able_to_consent === false) {
    pathway = "ineligible";
  } else if (e.under_dr_treatment === true) {
    pathway = "surveillance";
  } else if (e.diabetes_confirmed === true) {
    pathway = "screening";
  }

  return {
    urgent: reasons.length > 0,
    urgent_reasons: reasons,
    reduced_va: reducedVa,
    severe_va: severeVa,
    pathway,
    computed_at: new Date().toISOString(),
    rules_version: "context_rules_v1",
  };
}

/* --- per-screen validation ------------------------------------------------ */

const req = (v) => v !== null && v !== undefined && String(v).trim() !== "";

export const VALIDATORS = {

  operator(ctx) {
    const err = {};
    if (!req(ctx.session.centre_id))   err.centre_id   = "Enter the screening centre identifier.";
    if (!req(ctx.session.operator_id)) err.operator_id = "Enter your operator identifier.";
    return err;
  },

  registration(ctx) {
    const err = {};
    const p = ctx.patient;

    if (!req(p.patient_id)) {
      err.patient_id = "A local patient identifier is required.";
    } else if (!/^[A-Za-z0-9][A-Za-z0-9._/-]{2,31}$/.test(p.patient_id.trim())) {
      err.patient_id = "Use 3–32 characters: letters, digits, and . _ - / only.";
    }

    if (p.age_years === null || p.age_years === "") {
      err.age_years = "Age is required.";
    } else {
      const a = Number(p.age_years);
      if (!Number.isFinite(a) || a < 0 || a > 120) {
        err.age_years = "Enter an age between 0 and 120.";
      }
    }

    if (!req(p.sex)) err.sex = "Select an option.";
    return err;
  },

  eligibility(ctx) {
    const err = {};
    const e = ctx.eligibility;
    if (e.diabetes_confirmed === null) err.diabetes_confirmed = "This determines eligibility — please answer.";
    if (e.under_dr_treatment === null) err.under_dr_treatment = "This determines screening versus surveillance.";
    if (e.able_to_consent === null)    err.able_to_consent    = "Please answer.";
    if (e.previously_screened === null) err.previously_screened = "Please answer.";

    if (e.previously_screened === true &&
        e.months_since_last_screening !== null &&
        e.months_since_last_screening !== "") {
      const m = Number(e.months_since_last_screening);
      if (!Number.isFinite(m) || m < 0 || m > 600) {
        err.months_since_last_screening = "Enter a value between 0 and 600 months.";
      }
    }
    return err;
  },

  consent(ctx) {
    const err = {};
    if (ctx.consent.given !== true) {
      err.given = "Screening cannot proceed without recorded consent.";
    }
    return err;
  },

  diabetes(ctx) {
    const err = {};
    const d = ctx.diabetes;
    if (!req(d.dm_type)) err.dm_type = "Select the diabetes type, or 'Not known'.";

    if (d.duration_years !== null && d.duration_years !== "") {
      const y = Number(d.duration_years);
      if (!Number.isFinite(y) || y < 0 || y > 100) {
        err.duration_years = "Enter a duration between 0 and 100 years.";
      }
      if (Number.isFinite(y) && ctx.patient.age_years && y > Number(ctx.patient.age_years)) {
        err.duration_years = "Duration cannot exceed the patient's age.";
      }
    }

    if (d.hba1c_percent !== null && d.hba1c_percent !== "") {
      const h = Number(d.hba1c_percent);
      if (!Number.isFinite(h) || h < 3 || h > 20) {
        err.hba1c_percent = "Enter HbA1c between 3 and 20 %.";
      }
    }

    if (d.treatment.length === 0) err.treatment = "Select at least one option.";
    return err;
  },

  symptoms(ctx) {
    const err = {};
    if (ctx.symptoms.reported.length === 0) {
      err.reported = "Select at least one symptom, or 'No symptoms reported'.";
    }
    return err;
  },

  acuity(ctx) {
    const err = {};
    const v = ctx.visual_acuity;
    if (!req(v.method))   err.method = "Select the test method used.";
    if (!req(v.od.value)) err.od     = "Record the right eye, or mark it not tested.";
    if (!req(v.os.value)) err.os     = "Record the left eye, or mark it not tested.";
    return err;
  },

  /**
   * Every REQUIRED field must reach a resolved state before the encounter
   * can move on. "Resolved" deliberately includes UNGRADABLE: an image that
   * cannot be assessed is a valid outcome that routes to a clinician. What
   * is NOT allowed is leaving a required field empty or mid-retake, because
   * that would submit an encounter that silently examined only one eye.
   */
  capture(ctx) {
    const err = {};
    for (const s of CAPTURE_SLOTS.filter((x) => x.required)) {
      const st = ctx.capture.slots[s.id];
      if (!st || st.busy) {
        err[s.id] = `${s.label} has not been captured.`;
      } else if (st.decision === "RECAPTURE") {
        err[s.id] = `${s.label} failed quality — retake it, or continue retrying until the field is closed.`;
      }
    }
    return err;
  },
  review()   { return {}; },
  ocular()   { return {}; },
};

export function validateScreen(name, ctx) {
  const fn = VALIDATORS[name];
  return fn ? fn(ctx) : {};
}

/* --- completeness --------------------------------------------------------- */

export function screenComplete(name, ctx) {
  return Object.keys(validateScreen(name, ctx)).length === 0;
}

/* --- human-readable summary of the record --------------------------------- */

export function summarise(ctx) {
  const none = (v) => (v === null || v === undefined || v === "" ? null : v);
  const list = (arr, group) =>
    arr && arr.length ? arr.map((v) => labelFor(group, v)).join(", ") : null;

  return [
    { section: "Session", rows: [
      ["Centre",   none(ctx.session.centre_id)],
      ["Operator", none(ctx.session.operator_id)],
      ["Session",  none(ctx.session.session_id)],
    ]},
    { section: "Patient", rows: [
      ["Patient ID", none(ctx.patient.patient_id)],
      ["Age",        none(ctx.patient.age_years) ? `${ctx.patient.age_years} years` : null],
      ["Sex",        ctx.patient.sex ? labelFor("sex", ctx.patient.sex) : null],
    ]},
    { section: "Eligibility", rows: [
      ["Pathway",            ctx.flags.pathway],
      ["Diabetes confirmed", yn(ctx.eligibility.diabetes_confirmed)],
      ["Under DR treatment", yn(ctx.eligibility.under_dr_treatment)],
      ["Screened before",    yn(ctx.eligibility.previously_screened)],
      ["Months since last",  none(ctx.eligibility.months_since_last_screening)],
      ["Consent recorded",   yn(ctx.consent.given)],
    ]},
    { section: "Diabetes", rows: [
      ["Type",         ctx.diabetes.dm_type ? labelFor("dm_type", ctx.diabetes.dm_type) : null],
      ["Duration",     none(ctx.diabetes.duration_years) ? `${ctx.diabetes.duration_years} years` : null],
      ["Treatment",    list(ctx.diabetes.treatment, "treatment")],
      ["HbA1c",        none(ctx.diabetes.hba1c_percent) ? `${ctx.diabetes.hba1c_percent} %` : null],
      ["Hypertension", yn(ctx.diabetes.hypertension)],
    ]},
    { section: "Ocular history", rows: [
      ["Conditions", list(ctx.ocular_history.conditions, "conditions")],
      ["Notes",      none(ctx.ocular_history.notes)],
    ]},
    { section: "Symptoms", rows: [
      ["Reported", list(ctx.symptoms.reported, "symptoms")],
      ["Duration", none(ctx.symptoms.duration_days) ? `${ctx.symptoms.duration_days} days` : null],
    ]},
    { section: "Fundus capture", rows: CAPTURE_SLOTS.map((sl) => {
      const st = ctx.capture.slots[sl.id];
      if (!st || !st.decision) return [sl.label, null];
      const extra = st.decision === "ACCEPT" ? ` (score ${Number(st.score).toFixed(2)})` : ` (attempt ${st.attempt})`;
      return [sl.label, st.decision + extra];
    })},
    { section: "Visual acuity", rows: [
      ["Method",    ctx.visual_acuity.method ? labelFor("va_method", ctx.visual_acuity.method) : null],
      ["Right (OD)", vaText(ctx.visual_acuity.od)],
      ["Left (OS)",  vaText(ctx.visual_acuity.os)],
    ]},
  ];
}

function yn(v) { return v === true ? "Yes" : v === false ? "No" : null; }

function vaText(eye) {
  if (!eye.value) return null;
  const base = labelFor("va", eye.value);
  return eye.pinhole ? `${base} (pinhole ${labelFor("va", eye.pinhole)})` : base;
}
