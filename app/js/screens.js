/* ==========================================================================
   OPHIRA — screen renderers
   --------------------------------------------------------------------------
   One function per step of the clinical workflow (Architecture section 02):

     Greet -> Consent -> Eligibility -> Visual acuity -> Questionnaire
           -> Explain photography -> Capture -> Review

   Each receives (ctx, errors, actions) and returns a DOM node. They hold no
   state of their own; app.js owns the record and re-renders on every change.
   ========================================================================== */

import {
  SEX, DM_TYPE, DM_TREATMENT, OCULAR_HISTORY, SYMPTOMS,
  VA_LADDER, VA_METHOD, CAPTURE_SLOTS, CONSENT_VERSION, labelFor, vaRank, VA_THRESHOLD,
} from "./schema.js";
import { summarise } from "./validate.js";
import {
  h, icon, field, textInput, select, yesNo, checkGroup, radioGroup, alert, card,
} from "./ui.js";

const boundaryNote = (text) =>
  h("div", { class: "boundary-note" }, icon("lock"), h("span", {}, text));

/* ========================================================================== */

export function operatorScreen(ctx, err, A) {
  return h("div", {},
    head("Start a screening session",
         "Identify the centre and operator. This is recorded with every session for traceability."),

    card("Session details", null,
      h("div", { class: "grid grid-2" },
        field({
          id: "centre_id", label: "Screening centre", required: true,
          help: "Facility code, for example PHC-014.",
          error: err.centre_id,
          control: textInput({
            id: "centre_id", value: ctx.session.centre_id, variant: "id",
            placeholder: "PHC-014", error: err.centre_id,
            onInput: (v) => A.set("session.centre_id", v),
          }),
        }),
        field({
          id: "operator_id", label: "Operator", required: true,
          help: "Your staff identifier.",
          error: err.operator_id,
          control: textInput({
            id: "operator_id", value: ctx.session.operator_id, variant: "id",
            placeholder: "OP-3391", error: err.operator_id,
            onInput: (v) => A.set("session.operator_id", v),
          }),
        })
      )
    ),

    alert({
      kind: "info",
      title: "Research prototype",
      text: "OPHIRA is not a clinically validated device. Every result requires clinician review. Do not use it to make a diagnosis.",
    })
  );
}

/* ========================================================================== */

export function registrationScreen(ctx, err, A) {
  return h("div", {},
    head("Patient registration",
         "Record the minimum needed to link this session to the patient's local record."),

    card("Patient", "Use the local record identifier. Do not enter names in this prototype.",
      h("div", { class: "grid grid-2" },
        field({
          id: "patient_id", label: "Patient identifier", required: true,
          help: "3–32 characters. Letters, digits and . _ - /",
          error: err.patient_id,
          control: textInput({
            id: "patient_id", value: ctx.patient.patient_id, variant: "id",
            placeholder: "P-2026-00471", error: err.patient_id,
            onInput: (v) => A.set("patient.patient_id", v),
          }),
        }),
        field({
          id: "age_years", label: "Age", required: true, error: err.age_years,
          help: "In completed years.",
          control: textInput({
            id: "age_years", value: ctx.patient.age_years ?? "", type: "number",
            mode: "numeric", variant: "num", placeholder: "54", error: err.age_years,
            onInput: (v) => A.set("patient.age_years", v === "" ? null : Number(v)),
          }),
        })
      ),
      h("div", { style: "margin-top: var(--s-5)" },
        field({
          id: "sex", label: "Sex", required: true, error: err.sex,
          control: radioGroup({
            name: "sex", value: ctx.patient.sex, options: SEX,
            onChange: (v) => A.set("patient.sex", v),
          }),
        })
      )
    ),

    boundaryNote(
      "Patient context is stored with the session and passed to the clinical decision layer. " +
      "It is never given to the image model, which sees the fundus photograph only."
    )
  );
}

/* ========================================================================== */

export function eligibilityScreen(ctx, err, A) {
  const e = ctx.eligibility;
  const pathway = ctx.flags.pathway;

  return h("div", {},
    head("Eligibility",
         "Determines whether this encounter is first-time screening or ongoing surveillance."),

    pathway === "surveillance" ? alert({
      kind: "warn",
      title: "Surveillance pathway",
      text: "This patient is already under treatment for diabetic retinopathy, so this is surveillance rather than first-time screening. Results still require clinician review.",
    }) : null,

    pathway === "ineligible" ? alert({
      kind: "warn",
      title: "Not eligible for this screening pathway",
      text: "Based on the answers given, this patient falls outside the screening protocol. Refer to the centre's standard process.",
    }) : null,

    card("Screening eligibility", null,
      h("div", { class: "grid", style: "gap: var(--s-6)" },
        field({
          id: "diabetes_confirmed", label: "Has a confirmed diagnosis of diabetes", required: true,
          error: err.diabetes_confirmed,
          control: yesNo({
            name: "diabetes_confirmed", value: e.diabetes_confirmed, error: err.diabetes_confirmed,
            onChange: (v) => A.set("eligibility.diabetes_confirmed", v),
          }),
        }),
        field({
          id: "under_dr_treatment",
          label: "Already under treatment for diabetic retinopathy", required: true,
          help: "Laser, injections or surgery for DR.",
          error: err.under_dr_treatment,
          control: yesNo({
            name: "under_dr_treatment", value: e.under_dr_treatment, error: err.under_dr_treatment,
            onChange: (v) => A.set("eligibility.under_dr_treatment", v),
          }),
        }),
        field({
          id: "previously_screened", label: "Has been screened for DR before", required: true,
          error: err.previously_screened,
          control: yesNo({
            name: "previously_screened", value: e.previously_screened, error: err.previously_screened,
            onChange: (v) => A.set("eligibility.previously_screened", v),
          }),
        }),
        e.previously_screened === true
          ? field({
              id: "months_since_last_screening", label: "Months since the last screening",
              error: err.months_since_last_screening,
              control: textInput({
                id: "months_since_last_screening",
                value: e.months_since_last_screening ?? "",
                type: "number", mode: "numeric", variant: "num", placeholder: "18",
                error: err.months_since_last_screening,
                onInput: (v) => A.set("eligibility.months_since_last_screening", v === "" ? null : Number(v)),
              }),
            })
          : null,
        field({
          id: "able_to_consent", label: "Able to give informed consent", required: true,
          error: err.able_to_consent,
          control: yesNo({
            name: "able_to_consent", value: e.able_to_consent, error: err.able_to_consent,
            onChange: (v) => A.set("eligibility.able_to_consent", v),
          }),
        })
      )
    )
  );
}

/* ========================================================================== */

export function consentScreen(ctx, err, A) {
  return h("div", {},
    head("Consent",
         "Read this to the patient in a language they understand, and record their answer."),

    card("What the patient is agreeing to", null,
      h("ul", { style: "margin:0; padding-left: var(--s-5); line-height: var(--lh-body)" },
        h("li", {}, "Photographs will be taken of the back of both eyes."),
        h("li", {}, "The photographs will be analysed by a computer system and reviewed by a clinician."),
        h("li", {}, "This is a research prototype. It does not replace an eye examination."),
        h("li", {}, "A normal result today does not guarantee that no disease is present."),
        h("li", {}, "The images and answers will be stored securely and used for this screening programme."),
        h("li", {}, "The patient may decline at any point, and their routine care will not be affected.")
      ),
      h("p", { class: "field__help", style: "margin-top: var(--s-4)" },
        `Consent text version: ${CONSENT_VERSION}`)
    ),

    card("Record the response", null,
      field({
        id: "consent_given", label: "The patient gives informed consent to proceed", required: true,
        error: err.given,
        control: yesNo({
          name: "consent_given", value: ctx.consent.given, error: err.given,
          onChange: (v) => A.setConsent(v),
        }),
      }),
      ctx.consent.given === false
        ? alert({
            kind: "warn",
            title: "Consent not given",
            text: "Screening must not proceed. Close the session and record the declination in the centre's register.",
          })
        : null,
      ctx.consent.recorded_at
        ? h("p", { class: "field__help", style: "margin-top: var(--s-3)" },
            `Recorded at ${new Date(ctx.consent.recorded_at).toLocaleString()}`)
        : null
    )
  );
}

/* ========================================================================== */

export function diabetesScreen(ctx, err, A) {
  const d = ctx.diabetes;
  return h("div", {},
    head("Diabetes history",
         "Context for the clinical decision layer. Leave optional fields blank if unknown — do not guess."),

    card("Diabetes", null,
      field({
        id: "dm_type", label: "Type of diabetes", required: true, error: err.dm_type,
        control: radioGroup({
          name: "dm_type", value: d.dm_type, options: DM_TYPE,
          onChange: (v) => A.set("diabetes.dm_type", v),
        }),
      }),
      h("div", { class: "grid grid-2", style: "margin-top: var(--s-6)" },
        field({
          id: "duration_years", label: "Years since diagnosis", error: err.duration_years,
          help: "Optional. Leave blank if not known.",
          control: textInput({
            id: "duration_years", value: d.duration_years ?? "", type: "number",
            mode: "numeric", variant: "num", placeholder: "8", error: err.duration_years,
            onInput: (v) => A.set("diabetes.duration_years", v === "" ? null : Number(v)),
          }),
        }),
        field({
          id: "hba1c_percent", label: "Most recent HbA1c (%)", error: err.hba1c_percent,
          help: "Optional.",
          control: textInput({
            id: "hba1c_percent", value: d.hba1c_percent ?? "", type: "number",
            mode: "decimal", variant: "num", placeholder: "7.8", error: err.hba1c_percent,
            onInput: (v) => A.set("diabetes.hba1c_percent", v === "" ? null : Number(v)),
          }),
        })
      ),
      h("div", { style: "margin-top: var(--s-6)" },
        field({
          id: "treatment", label: "Current treatment", required: true, error: err.treatment,
          help: "Select all that apply.",
          control: checkGroup({
            name: "treatment", values: d.treatment, options: DM_TREATMENT,
            onChange: (v) => A.set("diabetes.treatment", v),
          }),
        })
      ),
      h("div", { class: "grid grid-2", style: "margin-top: var(--s-6)" },
        field({
          id: "hypertension", label: "Known high blood pressure",
          control: yesNo({
            name: "hypertension", value: d.hypertension,
            onChange: (v) => A.set("diabetes.hypertension", v),
          }),
        }),
        field({
          id: "smoker", label: "Current smoker",
          control: yesNo({
            name: "smoker", value: d.smoker,
            onChange: (v) => A.set("diabetes.smoker", v),
          }),
        })
      )
    )
  );
}

/* ========================================================================== */

export function ocularScreen(ctx, err, A) {
  return h("div", {},
    head("Eye history", "Previous eye treatment and known eye conditions."),

    card("Previous eye treatment or conditions",
         "Select all that apply. Leave empty if there are none.",
      checkGroup({
        name: "ocular", values: ctx.ocular_history.conditions, options: OCULAR_HISTORY,
        onChange: (v) => A.set("ocular_history.conditions", v),
      }),
      h("div", { style: "margin-top: var(--s-6)" },
        field({
          id: "ocular_notes", label: "Notes",
          help: "Optional free text — anything the reviewing clinician should know.",
          control: h("textarea", {
            class: "textarea", id: "ocular_notes",
            placeholder: "For example: cataract surgery right eye, 2023",
            onInput: (e) => A.set("ocular_history.notes", e.target.value),
          }, ctx.ocular_history.notes || ""),
        })
      )
    )
  );
}

/* ========================================================================== */

export function symptomsScreen(ctx, err, A) {
  const NONE = "none_reported";
  const options = [...SYMPTOMS, { value: NONE, label: "No symptoms reported", flag: false }];
  const urgent = ctx.flags.urgent;

  return h("div", {},
    head("Current symptoms",
         "Ask the patient directly. Some answers escalate this session immediately, regardless of what the images show."),

    urgent ? alert({
      kind: "urgent",
      title: "Urgent escalation triggered",
      text: "This session is flagged for immediate clinician attention. Continue the workflow, but do not send the patient home on a routine result.",
      items: ctx.flags.urgent_reasons.map((r) => r.text),
    }) : null,

    card("Symptoms", "Select all that apply.",
      checkGroup({
        name: "symptoms", values: ctx.symptoms.reported, options,
        flagged: true, stack: true,
        onChange: (next) => {
          /* "No symptoms" is mutually exclusive with everything else. */
          let v = next;
          if (next.includes(NONE) && !ctx.symptoms.reported.includes(NONE)) v = [NONE];
          else if (next.length > 1) v = next.filter((x) => x !== NONE);
          A.set("symptoms.reported", v);
        },
      }),
      ctx.symptoms.reported.length && !ctx.symptoms.reported.includes(NONE)
        ? h("div", { class: "grid grid-2", style: "margin-top: var(--s-6)" },
            field({
              id: "symptom_duration", label: "How long have the symptoms been present (days)",
              control: textInput({
                id: "symptom_duration", value: ctx.symptoms.duration_days ?? "",
                type: "number", mode: "numeric", variant: "num", placeholder: "14",
                onInput: (v) => A.set("symptoms.duration_days", v === "" ? null : Number(v)),
              }),
            })
          )
        : null
    ),

    boundaryNote(
      "Symptom answers reach the clinical decision engine directly. They can escalate a case " +
      "on their own, and no AI output can override them."
    )
  );
}

/* ========================================================================== */

export function acuityScreen(ctx, err, A) {
  const v = ctx.visual_acuity;

  const eyeBlock = (key, code, name) => {
    const eye = v[key];
    const rank = vaRank(eye.value);
    const low  = rank >= VA_THRESHOLD.reducedRank;

    return card(null, null,
      h("div", { class: "eye-head" },
        h("span", { class: "eye-badge" }, code),
        h("div", {},
          h("div", { style: "font-weight:650" }, name),
          h("div", { class: "field__help" }, code === "OD" ? "Oculus dexter" : "Oculus sinister")
        ),
        low ? h("span", {
            class: "session-chip",
            style: "margin-left:auto; color: var(--c-warn); border-color: var(--c-warn-border)"
          }, "Reduced") : null
      ),
      field({
        id: `va_${key}`, label: "Unaided acuity", required: true, error: err[key],
        control: vaLadder(`va_${key}`, eye.value, (val) => A.set(`visual_acuity.${key}.value`, val)),
      }),
      low ? h("div", { style: "margin-top: var(--s-5)" },
        field({
          id: `ph_${key}`, label: "With pinhole",
          help: "Record pinhole acuity when unaided vision is 6/18 or worse.",
          control: vaLadder(`ph_${key}`, eye.pinhole, (val) => A.set(`visual_acuity.${key}.pinhole`, val)),
        })
      ) : null
    );
  };

  return h("div", {},
    head("Visual acuity",
         "Test each eye separately, at the distance the chart specifies, with the patient's usual glasses if worn."),

    ctx.flags.severe_va ? alert({
      kind: "urgent",
      title: "Severely reduced acuity",
      text: "This contributes to urgent escalation for this session independently of the image findings.",
    }) : null,

    card("Test method", null,
      field({
        id: "va_method", label: "Method used", required: true, error: err.method,
        control: radioGroup({
          name: "va_method", value: v.method, options: VA_METHOD,
          onChange: (val) => A.set("visual_acuity.method", val),
        }),
      })
    ),

    eyeBlock("od", "OD", "Right eye"),
    eyeBlock("os", "OS", "Left eye")
  );
}

function vaLadder(name, value, onChange) {
  return h("div", { class: "va-grid", role: "radiogroup" },
    VA_LADDER.map((o) =>
      h("label", {
          class: `va-opt ${o.rank >= VA_THRESHOLD.reducedRank ? "va-opt--low" : ""}`,
          title: o.help || o.label,
        },
        h("input", {
          type: "radio", name, checked: value === o.value,
          onChange: () => onChange(o.value),
        }),
        h("span", {}, o.label),
        o.help ? h("span", { class: "sr-only" }, ` ${o.help}`) : null
      ))
  );
}

/* ========================================================================== */

export function captureScreen(ctx, err, A) {
  const slots = ctx.capture.slots;
  const required = CAPTURE_SLOTS.filter((s) => s.required);
  const accepted = required.filter((s) => slots[s.id]?.decision === "ACCEPT");
  const allRequiredDone = accepted.length === required.length;

  return h("div", {},
    head("Fundus photography",
         "Explain the procedure before starting: a bright flash, no contact with the eye, a few seconds per photograph."),

    alert({
      kind: "info",
      title: "No camera attached — loading images from file",
      text: "Acquisition hardware is not connected in this build. Select a fundus image for each field; it is stored as the immutable original and goes through the same quality gate the camera will use.",
    }),

    err.worker ? alert({ kind: "warn", title: "Analysis worker not responding", text: err.worker }) : null,

    card("Capture plan",
         "One macula-centred field per eye is required. A disc-centred field is optional. Maximum two fields per eye.",
      h("div", { class: "slots" }, CAPTURE_SLOTS.map((s) => slotCard(s, slots[s.id], A)))
    ),

    allRequiredDone
      ? alert({ kind: "ok", title: "Both required fields accepted",
                text: "The encounter can proceed to review." })
      : null,

    card("What happens to each image", null,
      h("ol", { style: "margin:0; padding-left: var(--s-5); line-height: var(--lh-body)" },
        h("li", {}, "The original is written to disk and never modified."),
        h("li", {}, "A quality gate decides ACCEPT, RECAPTURE or UNGRADABLE."),
        h("li", {}, "A failed image can be retaken. After three attempts the field becomes ungradable and goes to a clinician — it never becomes a normal result."),
        h("li", {}, "Accepted images continue to grading in a later stage of the pipeline.")
      )
    ),

    boundaryNote(
      "Quality thresholds in this build are unvalidated placeholders. They are " +
      "fitted and reported on DeepDRiD in build Step 4 before any clinical use."
    )
  );
}

function slotCard(slot, st, A) {
  const state = st?.decision ?? (st?.busy ? "BUSY" : "EMPTY");

  const tone = {
    ACCEPT:     "done",
    RECAPTURE:  "retake",
    UNGRADABLE: "fatal",
    BUSY:       "busy",
    EMPTY:      "empty",
  }[state];

  const attempt = st?.attempt ?? 0;
  const maxAttempts = 3;
  const exhausted = state === "UNGRADABLE";

  const pick = h("input", {
    type: "file", accept: "image/*", class: "sr-only",
    id: `file_${slot.id}`,
    onChange: (e) => {
      const f = e.target.files?.[0];
      e.target.value = "";
      if (f) A.capture(slot.id, f);
    },
  });

  const label = state === "EMPTY" ? "Select image"
              : exhausted        ? "Field closed"
              : state === "BUSY" ? "Analysing…"
              : "Retake";

  return h("div", { class: "slot", "data-state": tone },
    icon(state === "ACCEPT" ? "check"
       : state === "UNGRADABLE" ? "alert"
       : state === "BUSY" ? "clock" : "camera"),

    h("div", { class: "slot__name" }, slot.label),

    h("div", { class: "slot__state" },
      state === "EMPTY"  ? (slot.required ? "Required" : "Optional")
    : state === "BUSY"   ? "Running quality gate…"
    : state === "ACCEPT" ? `Accepted · score ${st.score.toFixed(2)}`
    : `${state} · attempt ${attempt} of ${maxAttempts}`),

    st?.reasons?.length
      ? h("ul", { class: "slot__reasons" },
          st.reasons.map((r) => h("li", { "data-sev": r.severity }, r.text)))
      : null,

    pick,
    h("label", {
        class: `btn btn--sm ${state === "ACCEPT" ? "btn--ghost" : "btn--primary"}`,
        for: `file_${slot.id}`,
        "aria-disabled": (st?.busy || exhausted) ? "true" : null,
        style: (st?.busy || exhausted) ? "opacity:.45; pointer-events:none" : "cursor:pointer",
      },
      icon(state === "ACCEPT" ? "camera" : "file"), label)
  );
}

/* ========================================================================== */

export function reviewScreen(ctx, err, A) {
  const sections = summarise(ctx);

  return h("div", {},
    head("Review and submit",
         "Check the record with the patient before submitting. It cannot be edited after submission."),

    ctx.flags.urgent ? alert({
      kind: "urgent",
      title: "This session is flagged urgent",
      text: "Escalate according to the centre's protocol. Do not issue a routine result.",
      items: ctx.flags.urgent_reasons.map((r) => r.text),
    }) : null,

    ctx.flags.pathway === "surveillance"
      ? alert({ kind: "warn", title: "Surveillance pathway",
                text: "Patient is already under DR treatment." })
      : null,

    ...sections.map((s) =>
      card(s.section, null,
        h("div", { class: "summary" },
          s.rows.map(([k, val]) =>
            h("div", { class: "summary__row" },
              h("div", { class: "summary__k" }, k),
              h("div", { class: `summary__v ${val ? "" : "summary__v--empty"}` },
                val ?? "not recorded")
            ))
        )
      )),

    boundaryNote(
      "On submission this record is written as context_core_v1 and read by the MATLAB " +
      "decision engine. The image model does not receive any of it."
    )
  );
}

/* ========================================================================== */

function head(title, sub) {
  return h("div", { class: "screen-head" },
    h("h1", {}, title),
    sub ? h("p", {}, sub) : null
  );
}
