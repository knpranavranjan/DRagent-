# DRagent Agent Layer — Change Log

Agent version **1.0.0**. Everything here is inside `DRagent/`.
**No file outside `DRagent/` was created, modified, moved or deleted.**

---

## Created

### Python agent (`agent/`)
| File | Role |
|---|---|
| `schemas.py` | `CaseState`, `AgentAction`, `AgentEvent`, `ToolResult`, `DecisionResult`, `State`, `Event` |
| `policy.py` | the planner — reads state, returns one action with a rationale |
| `tools.py` | registry, permissions, executor; refuses anything unregistered |
| `bridge.py` | `T-*.json` tool jobs over the existing filesystem queue |
| `llm.py` | optional Ollama provider, constrained planning, narrative synthesis |
| `orchestrator.py` | the observe → plan → act → observe → replan loop |
| `__init__.py` | package surface |

### MATLAB tool layer (`+ophira/+agent/`)
| File | Role |
|---|---|
| `tools.m` | the eight tool implementations |
| `context.m` | models and rules, cached in the worker process |
| `preprocessed.m` | preprocessing cache, keyed on path + mtime + size |
| `lesions.m` | lesion-mask cache (the mask is needed twice per referred case) |

### UI
`app/agent.html`, `app/js/agent.js`, `app/css/agent.css`

### Tests
`tests/tAgentParity.m` (7), `tests/test_agent.py` (47)

### Scripts
`scripts/agent_baseline.m`, `scripts/make_demo_poor_image.m`

### Docs
`AGENT_ARCHITECTURE.md`, `AGENTIC_DEMO.md`, this file

### Sample
`samples/demo_poor_quality.png` — the sample image under-exposed and
defocused. Used to demonstrate the quality-failure branch against the
**real** gate, which scores it 0.067 and returns RECAPTURE.

---

## Modified (DRagent only)

| File | Change | Why |
|---|---|---|
| `+ophira/+worker/run.m` | drains `T-*.json` via `processTool` | one MATLAB process, models loaded once |
| `app/server/ophira_server.py` | `POST /api/agent/run`, `GET /api/agent/run/<sid>`, `GET /api/agent/info` | the UI needs to start a run and poll it |
| `+ophira/+report/clinicianReport.m` | agent summary section when a trace exists | §34 of the spec |
| `scripts/run_deploy_verify.m` | added `tAgentParity` | parity is a deployment property, not an extra |
| `run.py` | `--verify` no longer blocked by the port check | verification starts no server; the check was a launcher bug |

---

## Not changed

Model architecture · trained weights · thresholds · calibration ·
preprocessing scaling · image dimensions · CORAL decoding · triage logic ·
grading logic · DME logic · lesion segmentation · **decision rules** · XAI
implementation · report interpretation · clinical terminology · frontend
encounter workflow · session structure.

The five runtime models are byte-identical to the verified DRagent
baseline.

---

## Verification

| Suite | Result |
|---|---|
| `run.py --verify` | **88 passed, 0 failed** (was 81; +7 `tAgentParity`) |
| `tests/test_agent.py` | **47 passed, 0 failed** |
| `tests/frontend/test_deploy_e2e.py` | **20/20** |
| `tests/frontend/test_reports.py` | all passed |
| Browser walkthrough | 0 console errors |

### The regression that matters

Same image, agent off vs on:

```
agent OFF (cascade) : REFERRAL, grade 2, ref 0.959832, unc 0.523059
agent ON            : REFERRAL, grade 2, ref 0.959832, unc 0.523059
```

Route, grade, referable score and uncertainty identical — **bitwise**, at
full double precision.

---

## Bugs found and fixed while building this

1. **Lesion segmentation ran twice** per referred case — once for the
   evidence, once to draw the overlay. ~6 s of duplication, most of the
   agent's measured overhead. Fixed with `+ophira/+agent/lesions.m`.
2. **`--verify` was blocked by the port check** although it starts no
   server, so verification could not run while the app was up.
3. **The regression test silently skipped.** Quoting MATLAB source through
   the shell stripped the double quotes and the baseline never ran — the
   most important test in the suite quietly did nothing. Moved to
   `scripts/agent_baseline.m`.
4. **The parity comparison failed on rounding**, not on a real difference:
   the baseline printed 10 decimals against full double precision. Now
   `%.17g`. A test that reports a divergence that is not there is as bad as
   one that misses a divergence that is.

---

## Honest limitations

- **No LLM is installed on this machine.** The agent runs its deterministic
  planner and deterministic synthesis, and the UI reports `none reachable`
  rather than naming a provider it is not using. The LLM path is
  implemented and constrained but has **not been exercised against a live
  model**.
- **Three cascade stages are reproduced**, not shared, because they have no
  standalone entry point in `orchestrate.m`. `tAgentParity` guards the
  duplication; it does not remove it.
- **Queue latency is ~0.3 s per tool call** (~3.5 s per case), reported
  separately in the metrics rather than hidden.
- **One run per session** at a time; concurrency is not tested.
- **Branch D (review/uncertainty) was not separately demonstrated.** The
  path exists — an abstention routes HUMAN REVIEW through the same engine
  call — but the sample image does not produce it, and inventing a
  threshold to force one would have been exactly the fabrication the spec
  forbids.
- **No agentic behaviour is clinically validated.** The agent changes
  orchestration; the clinical claims are unchanged and remain those of the
  underlying pipeline, which has never been prospectively validated.

---

# 1.1 — Encounter UI, four capture fields, reporting

## Created
| File | Role |
|---|---|
| `agent/case.py` | `AgentCase` — one agent run per capture, session route = most severe; the model table |

## Modified
| File | Change |
|---|---|
| `app/agent.html` | rebuilt: four capture slots, dark-mode toggle, per-capture results, model table, report panel |
| `app/js/agent.js` | slot upload, theme persistence, per-capture table, self-contained PDF/HTML/JSON report |
| `app/css/agent.css` | dense clinical layout, light/dark parity, print rules, `.icon-btn` |
| `app/index.html` | **Agent view** link from the encounter app |
| `app/server/ophira_server.py` | `POST /api/agent/upload`, multi-image `/api/agent/run`, `GET /samples/<name>`, slots + model table on `/api/agent/info` |
| `tests/test_agent.py` | +15 tests (encounter precedence, model-table honesty, narrative consistency) |

## What was added, against the five asks

1. **Four capture fields** — `od_macula`, `od_disc`, `os_macula`, `os_disc`;
   the two macula fields required, matching the encounter app. Each capture
   gets its **own agent run, own evidence and own deterministic route**; the
   session route is the most severe, using the worker's own precedence. An
   eye is not made safe by the other eye looking fine.
2. **Link from the encounter app** — "Agent view" in the header.
3. **Dark mode** — uses the existing `data-theme="dark"` tokens and the same
   `ophira.theme` key, so a tablet set to dark stays dark across both pages.
   Explicit, not OS-following: a screening room's lighting is not the
   operating system's business.
4. **PDF + model table** — a self-contained A4 report with the route, its
   rules, per-capture results, workflow metrics, and every model with its
   measured figure, the dataset, and **what it does not tell you**. Also
   HTML and raw JSON trace.
5. **UI** — rebuilt dense and organised, with the `ui-ux-pro-max` density
   and accessibility guidance applied.

**21st-ai and higgsfield were not used, deliberately.** 21st generates
React/shadcn; this frontend is vanilla JS with its own tokens and no build
step, in a deployment whose point is that it runs from a 48 MB folder with
stdlib Python. Higgsfield generates imagery, which has no place near a
clinical report. The `ui-ux-pro-max` style pick ("Exaggerated Minimalism",
oversized type) was also rejected — it is tuned for fashion and portfolio
work. Its density, contrast and accessibility guidance was applied; its
Google Fonts suggestion was not, because an offline-first deployment should
not fetch a font.

## Bugs found and fixed in this round

1. **Illegal run id.** Per-capture runs were named `S-...::od_macula`; `:`
   is not legal in a Windows path, so every XAI call and every trace save
   failed. Fixed at the source (`__`, not `::`) rather than by sanitising
   at each of the places that had forgotten to.
2. **The agent retried a failing tool until the step limit.** A failed tool
   leaves its evidence missing, so the planner asked for it again every
   turn. Failed tools are now recorded and never re-selected; the agent
   continues without that evidence or stops. Once is a fault, twice is a bug.
3. **Adding `demo_poor_quality.png` silently broke three suites.** It sorts
   alphabetically first, so every "pick the sample" helper grabbed the
   image the gate *rejects*: `tAgentParity` dropped from 7 assertions to 5,
   `test_agent.py` crashed on a missing grade, and the deployment E2E
   failed. All three depended on directory order without saying so. Fixed
   with an explicit `demo_*` convention, documented in `samples/README.md`
   and enforced in all five selection sites.
4. **`.icon-btn` was undefined**, so the theme toggle rendered as a blank
   white square.
5. **The narrative contradicted its own summary table** — "executed 7 tools
   with 1 adaptive branch" beside a table reading 14 and 2, because the
   prose came from the governing capture and the metrics from the session.
   Now restated at session level, with a regression test.

## Verification after this round

```
run.py --verify              88 passed, 0 failed
tests/test_agent.py          62 passed, 0 failed
tests/frontend/test_deploy_e2e.py   20/20
tests/frontend/test_reports.py      all passed
browser walkthrough          0 console errors
  4 capture slots · 2 required badges · 8 model rows
  dark mode persists across reload
  2 captures -> 14 tools, 2 replans, REFERRAL
  report: names the engine, model table, per-capture rows, limitations, A4 print CSS
```

The agent OFF vs ON regression still holds: same route, grade, referable
score and uncertainty, bitwise.
