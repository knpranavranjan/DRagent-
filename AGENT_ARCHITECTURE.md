# OPHIRA Agentic Layer — Architecture

**Agent version** 1.0.0 · **Decision engine** `decision_rules_v1` · **Scope** DRagent only

---

## 1. Why the agent exists

The verified DRagent pipeline runs a fixed cascade: quality → triage →
grader → maculopathy → decision → lesions. It is correct and it is rigid.
Every case pays for every stage that its own early results have already
made pointless, and nothing records *why* a stage ran.

The agent replaces the fixed sequence with one that is chosen from the
evidence as it arrives, and writes down the reasoning. It changes **how
evidence is gathered**. It changes nothing about what the evidence means.

---

## 2. The boundary, stated first

```
AGENT                          DECISION ENGINE
observes case state            reads assembled evidence
selects the next tool          applies versioned rules
executes it                    emits ROUTINE / REFERRAL / URGENT /
observes the result                 HUMAN REVIEW / RECAPTURE
replans
assembles evidence      ---->  THE ONLY SOURCE OF A CLINICAL ROUTE
writes the narrative
```

This is enforced three ways, not asserted:

1. **Structurally.** `schemas.DecisionResult.__post_init__` raises unless
   `source == "decisionEngine"`. A route the agent invented cannot be
   represented in the type system.
2. **In the registry.** `run_decision_engine` is the only tool flagged
   `is_decision_boundary`, and it is a pass-through to
   `ophira.decision.decisionEngine`.
3. **In tests.** `tAgentParity.testDecisionEngineIsUnchangedByTheAgent`
   and `test_agent.py::test_decision_engine_boundary`.

---

## 3. Data flow

```
Browser (agent.html)
   │  POST /api/agent/run          {session_id, image_path, site}
   ▼
Python server — background thread
   │
   ▼
agent.orchestrator.AgentRun          observe → plan → act → observe → replan
   │
   ├── agent.policy          decides the next action from CaseState
   ├── agent.llm (optional)  may choose among policy-approved options
   ├── agent.tools           registry; refuses anything unregistered
   │      │
   │      ▼
   │   agent.bridge          writes T-*.json into data/sessions/jobs/pending
   │      │
   │      ▼
   │   MATLAB worker         +ophira/+worker/run.m  →  processTool
   │      │
   │      ▼
   │   ophira.agent.tools    the eight tool implementations
   │      │                  (five call existing functions unchanged)
   │      ▼
   │   the existing models   m1 m3 m4 m5 m7 — untouched
   │
   ├── agent.trace           every event, persisted
   └── agent.llm.synthesise  narrative, AFTER the route exists
   │
   ▼
data/sessions/reports/<sid>/agent_trace.json
   │
   ▼
Browser polls GET /api/agent/run/<sid>
```

---

## 4. The tools

Five call an existing function unchanged. Three had no standalone entry
point and are reproduced in `+ophira/+agent/tools.m`.

| Tool | Backed by | New code? |
|---|---|---|
| `assess_image_quality` | `ophira.quality.assess` | no |
| `run_triage` | inline in `orchestrate.m` | **reproduced** |
| `run_dr_grading` | inline in `orchestrate.m` | **reproduced** |
| `run_maculopathy` | inline in `orchestrate.m` | **reproduced** |
| `run_lesion_analysis` | `ophira.lesion.segment` | no |
| `run_xai` | `ophira.report.overlays` | no |
| `run_decision_engine` | `ophira.decision.decisionEngine` | no |

### The duplication, and what stops it hurting

Reproducing three stages means two copies of medical logic. A drifted
copy would hand a clinician numbers no validated pipeline ever produced,
while every other test stayed green — the exact failure shape this project
has hit repeatedly.

`tests/tAgentParity.m` runs **both paths on a real image** and requires
bitwise equality on grade, referable score, uncertainty and maculopathy.
`tests/test_agent.py` does the same across the whole cascade. If they ever
diverge, the agent tool is wrong and the test says so.

---

## 5. State machine

```
INITIALIZED → IMAGE_RECEIVED → QUALITY_CHECK
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
             QUALITY_FAILED                  QUALITY_PASSED
                    │                               │
         attempts left? ──yes──► RECAPTURE_REQUIRED │
                    │ no                            ▼
                    └──────────────►             TRIAGE
                                                    │
                          cleared ◄─────────────────┤
                            │                       │ escalated
                            │                       ▼
                            │                    GRADING
                            │                       ▼
                            │                  MACULOPATHY
                            │                       │
                            └───────┬───────────────┘
                                    ▼
                                 DECISION            ← the engine
                                    │
                    ┌───────────────┴───────────────┐
         human will see it                    routine clear
                    ▼                               │
            LESION_ANALYSIS                         │
                    ▼                               │
                   XAI                              │
                    └───────────────┬───────────────┘
                                    ▼
                               SYNTHESIS → COMPLETE
```

`State` is an enum in `schemas.py`, carried on `CaseState.state`, and shown
in the UI. It is not implied by a prompt.

---

## 6. Adaptive behaviour — the three real branches

Measured, not designed on paper:

| Input | Tools run | Evidence | Outcome |
|---|---|---|---|
| gate-accepted referable image | **7** | 6 | REFERRAL |
| gate-rejected capture | **1** | 1 | RECAPTURE_REQUIRED — **no model ran** |
| triage-cleared retina | **2** | 2 | grader, maculopathy, lesions, XAI all skipped |

The replan on the first row is the clearest one: the agent calls the
decision engine, observes `REFERRAL`, and only then decides lesion
segmentation is worth its five seconds — because a clinician will now open
the case. On a ROUTINE clear it stops instead, which is what the baseline
cascade does too.

---

## 7. LLM

**Optional. The medical pipeline does not depend on it.**

| | |
|---|---|
| provider | Ollama, `http://127.0.0.1:11434`, local only |
| model | whatever is installed; never advertised unless reachable |
| planning | may choose **among options the policy already declared legal**; a reply naming anything else is discarded and recorded |
| synthesis | writes the narrative paragraph **after** the route exists, with the route given as fixed text; a draft that drops or contradicts it is discarded |
| never | produces a route, a grade, a probability or a threshold; reaches a tool; executes anything |
| privacy | sees `_evidence_digest` only — numbers and labels. No image bytes, no patient identifiers, no free text |

With no LLM installed (the current state of this machine) the agent runs on
`policy.py` and deterministic synthesis, and every number is identical.

---

## 8. Guardrails

| Risk | Control |
|---|---|
| agent invents a route | `DecisionResult` refuses any other source |
| agent reaches an unvetted function | registry lookup; `ophira.agent.tools` errors on an unknown name |
| shell / eval / arbitrary code | **no such tool exists** — not withheld, absent |
| agent modifies a model or threshold | no write tool; `AGENT_PERMISSIONS` omits `WRITE_MODEL`, `CHANGE_THRESHOLD`, `EXECUTE_SHELL` |
| agent bypasses the quality gate | the policy's first action is always quality, and nothing else is legal until it returns |
| tool failure becomes a finding | a failed tool is recorded as failed; if the engine has not run, the case ends `FAILED` with no route |
| MATLAB unavailable | `WorkerUnavailable` — the run fails loudly, no result is fabricated |
| LLM unavailable | deterministic planner and synthesis; identical output |
| runaway loop | `MAX_STEPS = 24`, then `FAILED` |

---

## 9. Trace

Every event is `schemas.AgentEvent` and every visible UI line comes from
one. `data/sessions/reports/<sid>/agent_trace.json` holds events, actions,
evidence, metrics, the registry as it was, the decision and its authority.

`test_agent.py` asserts that **no `tool_completed` exists without a
matching `tool_started`** — a result cannot be narrated that was not
computed.

---

## 10. What the agent is not

It is not a chatbot: there is no chat window, and the main interface
remains the clinical dashboard. It is not a classifier: it calls the
classifiers. It is not a decision-maker: it hands evidence to the engine
and reports what the engine said.
