# Demonstrating the OPHIRA Agentic Layer

A live script. Every number below was measured on this build; nothing is
scripted or pre-recorded.

## Setup

```bash
cd DRagent
python run.py
```

Wait for `OK  MATLAB worker  grading live`, then open
**http://127.0.0.1:8000/agent.html**

---

## 1. Frame it (30 seconds)

> "This is OPHIRA. The medical pipeline — five trained models, a classical
> quality gate and a deterministic decision engine — is already built and
> verified. What I added is an orchestration layer on top of it. It does
> not diagnose. It decides what evidence to gather."

Point at **Runtime** at the bottom of the page: agent version, decision
engine version, LLM provider, and the seven registered tools. If no LLM is
installed it says so — it never names a provider it is not using.

---

## 2. Normal flow — watch it choose (2 minutes)

Click **Load sample image**, then **Start agent run**.

Narrate as it runs:

- badge flips to **AGENT ACTIVE**
- **Quality** lights → result ACCEPT, score 0.877
- trace shows *"Agent selected Triage"* with a **why**
- **Triage** → escalated, p = 1.0000 against threshold 0.002455
- **Grading** → grade 2, moderate NPDR
- **Maculopathy** → 2, referable
- **Decision engine** lights — pause here:

> "The agent has stopped collecting and handed the evidence over. It cannot
> produce a route. Only the engine can."

- **REFERRAL** appears
- then **AGENT REPLANNED** — the key moment:

> "It called the engine, saw REFERRAL, and *only then* decided lesion
> segmentation was worth five seconds — because a clinician will now open
> this case. On a routine clear it skips it."

- **Lesions** → MA, HE, EX over 63 tiles
- **XAI** → labelled *attention, not lesions*

**Expected:** 8 actions · 7 tools · 1 replan · 6 evidence items · REFERRAL.

---

## 3. Quality failure — the strongest proof (1 minute)

Change the image path to `samples/demo_poor_quality.png` and run again.

```
SELECT  assess_image_quality
RESULT  {"status": "FAIL", "decision": "RECAPTURE", "quality_score": 0.0667}
REPLAN  The quality gate returned RECAPTURE on attempt 1 of 3:
        The retinal field is clipped or partially out of frame.;
        Image is too dark; increase flash or check pupil dilation.
ACTION  request_recapture
```

**1 tool. No model ran.** The pipeline map shows every model stage dimmed.

> "Same code, same registry, same agent. It ran one tool instead of seven
> because the gate said the capture was unusable. That is the difference
> between an agent and a script."

---

## 4. Show it cannot cheat (1 minute)

```bash
python tests/test_agent.py
```

Point at three results:

```
[PASS] test_decision_engine_boundary: a route cannot be built by the agent
[PASS] no shell / eval / model-write tool exists
[PASS] test_agent_off_vs_on_same_decision: SAME ROUTE   REFERRAL == REFERRAL
       agent OFF (cascade) : REFERRAL, grade 2, ref 0.959832, unc 0.523059
       agent ON            : REFERRAL, grade 2, ref 0.959832, unc 0.523059
```

> "Same image, agent on and agent off: identical route, grade, referable
> score and uncertainty — bitwise. The agent changed how the evidence was
> gathered and nothing about what it means."

---

## 5. The audit trail (1 minute)

```bash
python -c "import json;t=json.load(open('data/sessions/reports/S-20260101-000010-BRANCHA/agent_trace.json'));print(json.dumps({k:t[k] for k in ('agent_version','final_state','metrics','decision_authority','agent_role')},indent=2))"
```

Then scroll the on-screen trace: every line is an event the orchestrator
emitted, with the tool's real output attached.

> "Nothing here is narrated that did not execute. The test suite asserts
> there is no completed tool without a matching invocation."

---

## 6. If someone asks "is there really an LLM?"

Answer honestly. On this machine there is not one installed, so the agent
runs its deterministic planner and writes a deterministic synthesis — and
the UI says `none reachable`. Install Ollama and pull any model and the
planner will consult it, constrained to options the policy already
approved. **The clinical output is identical either way**, which is the
design, not a limitation.

---

## Expected results table

| Scenario | Image | Tools | Replans | Outcome |
|---|---|---|---|---|
| Normal | `sample_fundus_referral.png` | 7 | 1 | REFERRAL |
| Quality failure | `demo_poor_quality.png` | 1 | 1 | RECAPTURE_REQUIRED |
| Regression | either | — | — | agent ON route == agent OFF route |
