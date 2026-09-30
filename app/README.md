# OPHIRA — clinical encounter front end

The operator-facing workflow: registration, consent, eligibility, visual acuity,
questionnaire and capture plan. Runs as a local web app in a kiosk browser.

## Run it

```bash
python app/server/ophira_server.py
# then open http://127.0.0.1:8000/
```

Options: `--port 8080`, `--host 0.0.0.0` (allow other devices on the LAN),
`--data <dir>` (session store location).

## Why a web app and not MATLAB App Designer

The encounter UI and the MATLAB pipeline are deliberately decoupled. They meet
at one place only: a `context_core_v1` JSON file on disk.

```
browser (operator)  ->  session server  ->  data/sessions/submitted/*.json
                                                      |
                                                      v
                                          ophira.session.readSession
                                                      |
                                                      v
                                          ophira.decision.*   (MATLAB)
```

That boundary means the UI can be developed, tested and replaced without
touching MATLAB, MATLAB never needs to run a GUI on the Pi, and the deployed
device runs a browser plus generated C++ rather than a MATLAB installation.

## The data boundary

```
questionnaire / VA / symptoms  ->  context_core  ->  DECISION ENGINE
fundus image                   ->  preprocessing ->  CNN
```

Nothing collected here reaches the image model. That is a design commitment
(Architecture v1.0 section 01), and it is what allows the model to be trained
and evaluated on public datasets that carry no clinical context at all.

## Safety properties, and where they live

| Property | Enforced in |
|---|---|
| Urgent symptoms escalate independently of any AI output | `js/validate.js` — `computeFlags` |
| Severely reduced acuity contributes to urgency | `js/validate.js` — `computeFlags` |
| Consent is a hard gate on submission | `js/app.js`, **and** `server/ophira_server.py`, **and** `validateContext.m` |
| Every escalation states a reason | `validateContext.m` |
| Patient already under DR treatment is surveillance, not screening | `js/validate.js` |
| An interrupted encounter does not lose answers | `js/api.js` — localStorage + pending flush |

Consent is checked in three independent places on purpose. A client is never
the authority on what enters a clinical record.

## Offline behaviour

The Pi has no internet in deployment, and the local server can still die.
Every keystroke is debounced to localStorage first, then to the server. If the
server is unreachable the encounter continues, the save indicator says
"Saved on this device only", and drafts are flushed on the next successful
connection. Losing a server is not a reason to re-ask a patient questions they
have already answered.

No CDN is used for fonts, icons or scripts: a blocked network request would
stall first paint on a device that has no network by design.

## Files

```
index.html            shell
css/tokens.css        design tokens (colour, type, spacing, touch targets)
css/app.css           components
js/schema.js          context_core_v1 — single source of truth for fields
js/validate.js        validation + derived clinical flags
js/ui.js              DOM helpers, inline SVG icons, form primitives
js/screens.js         one renderer per workflow step
js/api.js             backend client with offline fallback
js/app.js             state machine, autosave, routing
server/ophira_server.py   static files + session store (stdlib only)
```

## Tests

```bash
node tests/frontend/test_rules.mjs      # 29 clinical rule checks, no server needed
python tests/frontend/test_api.py       # API lifecycle + safety gates (server on :8137)
```

MATLAB side: `runtests('tSession')`.

## Not yet built

- Camera acquisition. The capture screen shows the plan (one macula-centred
  field per eye required, optional disc-centred second field) but cannot
  capture. Slots are wired and ready for the acquisition module.
- Clinician review UI. Separate app, reads submitted sessions.
- Authentication. The operator identifier is typed, not verified.

## Before any clinical use

The symptom red-flag list, the visual-acuity thresholds and the consent text
in this build are **defensible placeholders, not an approved protocol**. They
require sign-off by the responsible ophthalmologist, and the thresholds must be
reconciled with `config/thresholds.json`.
