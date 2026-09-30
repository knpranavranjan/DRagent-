/* ==========================================================================
   OPHIRA — context_core schema (v1)
   --------------------------------------------------------------------------
   THE DATA BOUNDARY (Architecture v1.0, section 01):

       questionnaire / VA / symptoms  -->  context_core  -->  DECISION ENGINE
       fundus image                   -->  preprocessing  -->  CNN

   Nothing in this file ever reaches the CNN. The network sees pixels only.
   That separation is a design commitment, not an implementation detail: it
   is what lets the image model be evaluated on public datasets that carry
   no clinical context at all.

   This file is the single source of truth for field names and allowed
   values. +ophira/+session/contextCore.m mirrors it on the MATLAB side, and
   tests/tSessionSchema.m checks the two agree.
   ========================================================================== */

export const SCHEMA_VERSION = "context_core_v1";
export const CONSENT_VERSION = "consent_v1";

/* --- enumerations --------------------------------------------------------- */

export const SEX = [
  { value: "female",       label: "Female" },
  { value: "male",         label: "Male" },
  { value: "other",        label: "Other" },
  { value: "undisclosed",  label: "Prefer not to say" },
];

export const DM_TYPE = [
  { value: "type2",        label: "Type 2" },
  { value: "type1",        label: "Type 1" },
  { value: "gestational",  label: "Gestational" },
  { value: "other",        label: "Other" },
  { value: "unknown",      label: "Not known" },
];

export const DM_TREATMENT = [
  { value: "diet",     label: "Diet / lifestyle only" },
  { value: "oral",     label: "Oral medication" },
  { value: "insulin",  label: "Insulin" },
  { value: "other",    label: "Other" },
  { value: "none",     label: "No treatment" },
];

export const OCULAR_HISTORY = [
  { value: "laser",            label: "Previous retinal laser" },
  { value: "injection",        label: "Previous eye injection" },
  { value: "vitrectomy",       label: "Previous vitrectomy" },
  { value: "cataract_surgery", label: "Cataract surgery" },
  { value: "glaucoma",         label: "Known glaucoma" },
  { value: "other",            label: "Other eye condition" },
];

/* Symptoms. `flag: true` marks a red flag that can trigger urgent
   escalation INDEPENDENTLY of any AI output (Architecture section 02:
   "Urgent symptoms can trigger urgent escalation independently of AI grade").

   PLACEHOLDER: this list and its flags require sign-off by the responsible
   ophthalmologist before any clinical use. They are a defensible starting
   point drawn from standard screening red flags, not an approved protocol. */
export const SYMPTOMS = [
  { value: "sudden_vision_loss", label: "Sudden loss of vision",        flag: true  },
  { value: "curtain_shadow",     label: "Curtain or shadow over vision", flag: true  },
  { value: "sudden_floaters",    label: "Sudden shower of floaters",     flag: true  },
  { value: "flashes",            label: "Flashing lights",               flag: true  },
  { value: "eye_pain",           label: "Significant eye pain",          flag: true  },
  { value: "blurred_vision",     label: "Gradual blurred vision",        flag: false },
  { value: "distortion",         label: "Straight lines look bent",      flag: false },
  { value: "double_vision",      label: "Double vision",                 flag: false },
  { value: "night_difficulty",   label: "Difficulty seeing at night",    flag: false },
  { value: "redness",            label: "Persistent redness",            flag: false },
];

/* Snellen 6-metre ladder plus the low-vision tail, ordered best to worst.
   `rank` is used for comparisons; never compare the display strings. */
export const VA_LADDER = [
  { value: "6/6",   label: "6/6",  rank: 0 },
  { value: "6/9",   label: "6/9",  rank: 1 },
  { value: "6/12",  label: "6/12", rank: 2 },
  { value: "6/18",  label: "6/18", rank: 3 },
  { value: "6/24",  label: "6/24", rank: 4 },
  { value: "6/36",  label: "6/36", rank: 5 },
  { value: "6/60",  label: "6/60", rank: 6 },
  { value: "3/60",  label: "3/60", rank: 7 },
  { value: "CF",    label: "CF",   rank: 8, help: "Counting fingers" },
  { value: "HM",    label: "HM",   rank: 9, help: "Hand movements" },
  { value: "PL",    label: "PL",   rank: 10, help: "Perception of light" },
  { value: "NPL",   label: "NPL",  rank: 11, help: "No perception of light" },
  { value: "unable",label: "N/T",  rank: -1, help: "Not tested" },
];

export const VA_METHOD = [
  { value: "snellen_6m",  label: "Snellen 6 m" },
  { value: "tumbling_e",  label: "Tumbling E" },
  { value: "logmar",      label: "LogMAR chart" },
];

/* Thresholds. PLACEHOLDERS pending clinical sign-off; mirrored in
   config/thresholds.json so the decision engine and this UI cannot drift. */
export const VA_THRESHOLD = {
  reducedRank: 3,   /* 6/18 or worse -> reduced vision, note it        */
  severeRank:  6,   /* 6/60 or worse -> severe, contributes to urgency */
};

export const CAPTURE_SLOTS = [
  { id: "od_macula", eye: "OD", field: "macula", label: "Right eye — macula", required: true  },
  { id: "od_disc",   eye: "OD", field: "disc",   label: "Right eye — disc",   required: false },
  { id: "os_macula", eye: "OS", field: "macula", label: "Left eye — macula",  required: true  },
  { id: "os_disc",   eye: "OS", field: "disc",   label: "Left eye — disc",    required: false },
];

/* --- the record ----------------------------------------------------------- */

export function emptyContextCore() {
  return {
    schema_version: SCHEMA_VERSION,

    session: {
      session_id: null,
      created_at: null,
      completed_at: null,
      centre_id: "",
      operator_id: "",
      app_version: "0.1.0",
    },

    patient: {
      patient_id: "",
      age_years: null,
      sex: "",
    },

    eligibility: {
      diabetes_confirmed: null,
      under_dr_treatment: null,     /* true -> surveillance, not screening */
      previously_screened: null,
      months_since_last_screening: null,
      able_to_consent: null,
      pathway: null,                /* derived: screening|surveillance|ineligible */
    },

    consent: {
      given: null,
      version: CONSENT_VERSION,
      recorded_at: null,
    },

    diabetes: {
      dm_type: "",
      duration_years: null,
      treatment: [],
      hba1c_percent: null,
      hypertension: null,
      smoker: null,
    },

    ocular_history: {
      conditions: [],
      notes: "",
    },

    symptoms: {
      reported: [],
      duration_days: null,
      notes: "",
    },

    visual_acuity: {
      method: "snellen_6m",
      od: { value: "", pinhole: "" },
      os: { value: "", pinhole: "" },
    },

    capture: {
      slots: {},                    /* slot_id -> {status, captured_at, file} */
    },

    /* Derived. Written by validate.js, never entered by hand. This block is
       what the deterministic decision engine reads. */
    flags: {
      urgent: false,
      urgent_reasons: [],
      reduced_va: false,
      severe_va: false,
      pathway: null,
      computed_at: null,
      rules_version: "context_rules_v1",
    },
  };
}

/* Field-name lookup for the review screen and for MATLAB-side validation. */
export function labelFor(group, value) {
  const tables = {
    sex: SEX, dm_type: DM_TYPE, treatment: DM_TREATMENT,
    conditions: OCULAR_HISTORY, symptoms: SYMPTOMS,
    va: VA_LADDER, va_method: VA_METHOD,
  };
  const t = tables[group];
  if (!t) return value;
  const hit = t.find((o) => o.value === value);
  return hit ? hit.label : value;
}

export function vaRank(value) {
  const hit = VA_LADDER.find((o) => o.value === value);
  return hit ? hit.rank : -1;
}
