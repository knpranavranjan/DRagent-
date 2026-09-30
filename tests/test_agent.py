"""Agent layer tests.

    python run.py                      # terminal 1 (server + MATLAB worker)
    python tests/test_agent.py

The tool tests need the MATLAB worker, because the point is that the agent
drives the REAL pipeline. Tests that do not need it run either way and say
which ones were skipped.

THE TEST THAT MATTERS MOST is test_agent_off_vs_on_same_decision: for the
same image, the route with the agent must equal the route without it. The
agent is allowed to change HOW evidence is gathered and nothing else.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from agent import AGENT_VERSION, AgentRun, REGISTRY, describe_registry   # noqa: E402
from agent.bridge import MatlabToolBridge, WorkerUnavailable             # noqa: E402
from agent.case import (SLOTS, SEVERITY, model_table, _rank,             # noqa: E402
                        _session_synthesis)
from agent.llm import NullProvider, deterministic_synthesis, synthesise  # noqa: E402
from agent.policy import allowed_actions, next_action, observe           # noqa: E402
from agent.schemas import CaseState, DecisionResult, State               # noqa: E402
from agent.tools import AGENT_PERMISSIONS, ToolExecutor                  # noqa: E402

SESSIONS = ROOT / "data" / "sessions"
MATLAB = r"C:\Program Files\MATLAB\R2026a\bin\matlab.exe"

passed = failed = skipped = 0


def check(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f"  {extra}" if extra else ""))


def skip(name, why):
    global skipped
    skipped += 1
    print(f"  [SKIP] {name} — {why}")


def sample() -> Path | None:
    """A capture intended for VERIFICATION, not for demonstration.

    Files named demo_* are deliberately degraded inputs used to show
    branch behaviour; one of them is rejected by the quality gate on
    purpose. Picking "the first image in samples/" grabbed it as soon as it
    existed, because it sorts first — and three suites started skipping
    their real assertions without failing. Selection is now explicit.
    """
    d = ROOT / "samples"
    if not d.is_dir():
        return None
    for f in sorted(d.iterdir()):
        if f.name.startswith("demo_"):
            continue
        if f.suffix.lower() in (".png", ".jpg", ".jpeg", ".tif", ".tiff"):
            return f
    return None


def worker_running() -> bool:
    try:
        MatlabToolBridge(SESSIONS, timeout=25).call(
            "run_decision_engine", {"evidence": {}, "site": "default"})
        return True
    except WorkerUnavailable:
        return False
    except Exception:
        return True


print("=== OPHIRA agent tests ===")
print(f"  agent version {AGENT_VERSION}")

# ==========================================================================
print("\n--- 1. registry and permissions ---")

check("test_tool_registry: all expected tools registered",
      set(REGISTRY) == {"assess_image_quality", "run_triage", "run_dr_grading",
                        "run_maculopathy", "run_lesion_analysis", "run_xai",
                        "run_decision_engine"},
      f"{len(REGISTRY)} tools")

check("exactly one tool is the decision boundary",
      sum(1 for t in REGISTRY.values() if t.is_decision_boundary) == 1)

# The guardrail is structural: dangerous capabilities are not tools that
# are withheld, they do not exist in the registry at all.
check("no shell / eval / model-write tool exists",
      not any(k in REGISTRY for k in
              ("run_shell", "eval", "execute", "write_model", "set_threshold")))

check("agent is NOT granted write or execute permissions",
      not (AGENT_PERMISSIONS & {"WRITE_MODEL", "MODIFY_MODEL",
                                "CHANGE_THRESHOLD", "EXECUTE_SHELL",
                                "EXECUTE_ARBITRARY_CODE"}))

check("describe_registry exposes every tool",
      len(describe_registry()) == len(REGISTRY))

# ==========================================================================
print("\n--- 2. the decision boundary is structural ---")

ok = False
try:
    DecisionResult(route="REFERRAL", source="agent")
except ValueError:
    ok = True
check("test_decision_engine_boundary: a route cannot be built by the agent", ok,
      "DecisionResult rejects any source but decisionEngine")

d = DecisionResult(route="REFERRAL", source="decisionEngine")
check("a route from the engine is accepted", d.route == "REFERRAL")

# ==========================================================================
print("\n--- 3. planner: state drives the action ---")

st = CaseState(session_id="T1", image_path="x.png")
check("test_agent_initialization: fresh case has no evidence",
      st.evidence == {} and st.state == State.INITIALIZED.value)
check("first action is always quality",
      next_action(st).action == "assess_image_quality")
check("nothing else is legal before quality",
      allowed_actions(st) == ["assess_image_quality"])

# quality PASS -> triage
st.evidence["quality"] = {"status": "PASS", "decision": "ACCEPT",
                          "quality_score": 0.9, "max_attempts": 3}
check("after a PASS the agent goes to triage",
      next_action(st).action == "run_triage")

# --- test_replanning: triage clears -> grader is SKIPPED -----------------
cleared = CaseState(session_id="T2", image_path="x.png")
cleared.evidence["quality"] = {"status": "PASS", "decision": "ACCEPT",
                               "quality_score": 0.9, "max_attempts": 3}
cleared.evidence["triage"] = {"escalate": False, "p_any_dr": 0.0001,
                              "threshold": 0.0024, "uncertainty": 0.0002}
a = next_action(cleared)
check("test_replanning: a cleared image skips the grader entirely",
      a.action == "run_decision_engine" and a.is_replan,
      "grading, maculopathy, lesions and XAI are all skipped")

# --- quality FAIL -> recapture ------------------------------------------
badq = CaseState(session_id="T3", image_path="x.png", attempt=1)
badq.evidence["quality"] = {"status": "FAIL", "decision": "RECAPTURE",
                            "quality_score": 0.2, "max_attempts": 3,
                            "reasons": [{"text": "too dark"}]}
a = next_action(badq)
check("test_quality_failure: a rejected capture requests recapture",
      a.action == "request_recapture" and a.is_replan)
check("no model runs on a rejected capture",
      "run_triage" not in allowed_actions(badq) and
      "run_dr_grading" not in allowed_actions(badq))

# attempts exhausted -> the ENGINE decides, not the agent
badq.attempt = 3
a = next_action(badq)
check("with attempts exhausted the engine decides, not the agent",
      a.action == "run_decision_engine")

# --- adaptive branch on the engine's own route ---------------------------
ref = CaseState(session_id="T4", image_path="x.png")
ref.evidence["quality"] = {"status": "PASS", "decision": "ACCEPT",
                           "quality_score": 0.9, "max_attempts": 3}
ref.evidence["triage"] = {"escalate": True, "p_any_dr": 0.99, "threshold": 0.002}
ref.evidence["grading"] = {"grade": 2, "probabilities": [0, 0, 1, 0, 0],
                           "uncertainty": 0.3, "referable_score": 0.9}
ref.evidence["maculopathy"] = {"available": True, "maculopathy": 2}
ref.decision = {"route": "REFERRAL"}
check("a referred case comes back for lesion evidence",
      next_action(ref).action == "run_lesion_analysis")

routine = CaseState(session_id="T5", image_path="x.png")
routine.evidence.update(ref.evidence)
routine.decision = {"route": "ROUTINE"}
a = next_action(routine)
check("a routine clear stops without lesion segmentation",
      a.action == "finish" and a.is_replan,
      "the ~5 s lesion stage is skipped, as in the baseline cascade")

# ==========================================================================
print("\n--- 4. evidence assembly is faithful ---")

ev = ref.as_engine_evidence()
check("engine evidence carries the grader's own numbers",
      ev["dr_grade"] == 2 and ev["referable_score"] == 0.9 and
      ev["uncertainty"] == 0.3)
check("engine evidence carries maculopathy", ev["maculopathy"] == 2)
check("the agent adds no field the engine does not read",
      set(ev) <= {"quality", "dr_grade", "dr_probs", "uncertainty",
                  "referable_score", "maculopathy", "context"},
      sorted(ev))

cl = cleared.as_engine_evidence()
check("a cleared image reports grade 0 with the cascade's own uncertainty",
      cl["dr_grade"] == 0 and cl["uncertainty"] == 0.0002)

# ==========================================================================
print("\n--- 5. LLM is optional ---")

null = NullProvider()
check("test_llm_unavailable: NullProvider reports unavailable",
      not null.available())
s5 = CaseState(session_id="T6", image_path="x.png")
s5.evidence["quality"] = {"decision": "ACCEPT", "quality_score": 0.9}
s5.decision = {"route": "ROUTINE"}
text, src = synthesise(null, s5)
check("synthesis falls back to deterministic prose",
      src == "deterministic" and "ROUTINE" in text)
check("deterministic synthesis names the engine as the decider",
      "decision engine" in deterministic_synthesis(s5).lower())

# ==========================================================================
print("\n--- 6. invalid tool requests are refused ---")


class _NoBridge(MatlabToolBridge):
    def call(self, tool, args, timeout=None):
        raise AssertionError("an unregistered tool must never reach the bridge")


ex = ToolExecutor(_NoBridge(SESSIONS))
r = ex.execute("rm_rf", {})
check("test_invalid_tool_request: unregistered name is refused",
      not r.ok and "not a registered tool" in r.error)
r = ex.execute("run_shell", {"cmd": "dir"})
check("a shell-looking tool is refused", not r.ok)
check("no refused call reached the bridge", ex.calls == 0)

# ==========================================================================
print("\n--- 6b. encounter: four fields, most-severe wins ---")

check("four capture slots are defined",
      [s_[0] for s_ in SLOTS] == ["od_macula", "od_disc", "os_macula", "os_disc"])
check("both macula fields are required, disc fields are not",
      [s_[2] for s_ in SLOTS] == [True, False, True, False])

# The session route is the MOST SEVERE across captures. An eye is not made
# safe by the other eye looking fine, so a REFERRAL on one field must not
# be softened by a ROUTINE on another.
check("severity order matches the decision engine's precedence",
      SEVERITY == ["URGENT", "HUMAN REVIEW", "REFERRAL", "RECAPTURE", "ROUTINE"])
check("URGENT outranks REFERRAL", _rank("URGENT") < _rank("REFERRAL"))
check("RECAPTURE outranks ROUTINE", _rank("RECAPTURE") < _rank("ROUTINE"),
      "an unusable capture must never be reported as a clear result")
check("a missing route is worse than any route",
      _rank(None) > _rank("ROUTINE"))

# The session narrative must not contradict the session summary table.
# The per-capture synthesis ends with counts for ONE capture; printed
# beside totals for the whole encounter that read as 7 vs 14.
class _Gov:
    synthesis = ("Image quality ACCEPT. DR grade 2. The agent executed 7 "
                 "tools with 1 adaptive branch(es); it orchestrated "
                 "evidence collection and did not make the clinical decision.")
    synthesis_source = "deterministic"

_txt = _session_synthesis(_Gov(), {"images": 2, "tools_executed": 14,
                                   "replans": 2})
check("session narrative reports SESSION counts, not one capture's",
      "14 tools" in _txt and "2 adaptive" in _txt and "7 tools" not in _txt,
      "prose said 7 while the summary table said 14")
check("the narrative still names the engine as the decider",
      "did not make the clinical decision" in _txt)

print("\n--- 6c. model table is honest ---")

mt = model_table()
check("every pipeline stage is listed", len(mt) >= 8, f"{len(mt)} rows")
need = {"stage", "model", "params", "size_mb", "metric", "dataset", "note"}
check("every row carries its dataset and its caveat",
      all(need <= set(r) for r in mt))
check("no row has an empty caveat",
      all(str(r["note"]).strip() for r in mt),
      "a measured number without its limits is a misleading number")
check("every row names the dataset it was measured on",
      all(str(r["dataset"]).strip() for r in mt))

# The two claims a reviewer is most likely to over-read.
gradcam = next(r for r in mt if "Grad-CAM" in r["model"])
check("the Grad-CAM row says it does not localise lesions",
      "does not localise" in gradcam["note"].lower() or
      "not localise" in gradcam["note"].lower())
dec = next(r for r in mt if "decision_rules" in r["model"])
check("the decision row names itself the only source of a route",
      "only source of a clinical route" in dec["note"].lower())
gate = next(r for r in mt if "quality" in r["stage"])
check("the weakest component says so",
      "weakest" in gate["note"].lower())

print("\n--- 7. live pipeline (needs the MATLAB worker) ---")

img = sample()
if img is None:
    skip("all live tests", "no image in samples/")
elif not worker_running():
    skip("all live tests", "MATLAB worker not running — start with python run.py")
else:
    ctx = {"flags": {"urgent": False, "urgent_reasons": [],
                     "reduced_va": False, "pathway": "screening"}}

    t0 = time.time()
    run = AgentRun(session_id="S-20260101-000001-AGTST", image_path=str(img),
                   sessions_root=SESSIONS, context=ctx, use_llm=False)
    state = run.run()
    agent_ms = (time.time() - t0) * 1000
    m = run.metrics()

    check("test_agent_trace: the case completed",
          state.state == State.COMPLETE.value, state.state)
    check("a route was produced", bool((state.decision or {}).get("route")),
          (state.decision or {}).get("route"))
    check("the route came from the deterministic engine",
          (state.decision or {}).get("source") == "decisionEngine")
    check("tools actually executed", m["tools_executed"] >= 5,
          f"{m['tools_executed']} tools")
    check("the agent replanned at least once", m["replans"] >= 1,
          f"{m['replans']} replan(s)")
    check("evidence was collected", m["evidence_items"] >= 4,
          f"{m['evidence_items']} items")

    kinds = {e.event for e in run.events}
    for needed in ("tool_selected", "tool_completed", "decision_completed",
                   "agent_replanned", "observation"):
        check(f"trace records {needed}", needed in kinds)

    # every tool_completed must have a matching tool_started
    started = [e.tool for e in run.events if e.event == "tool_started"]
    done = [e.tool for e in run.events if e.event == "tool_completed"]
    check("no result is reported without an invocation",
          all(t in started for t in done), f"{len(done)} results, {len(started)} calls")

    p = run.save_trace()
    check("test_agent_state_persistence: trace written", p.is_file())
    with open(p, encoding="utf-8") as f:
        tr = json.load(f)
    check("persisted trace has events and a decision",
          len(tr.get("events", [])) > 5 and tr.get("decision"))
    check("persisted trace names the decision authority",
          tr.get("decision_authority") == "deterministic decisionEngine")

    # ---------------------------------------------------------------------
    print("\n--- 8. THE REGRESSION: agent OFF vs ON ---")
    if not os.path.isfile(MATLAB):
        skip("test_agent_off_vs_on_same_decision", "MATLAB not found")
    else:
        # Run the baseline from a SCRIPT FILE, not an inline -batch string.
        # Quoting MATLAB source through the shell stripped the double
        # quotes and the run failed silently, which showed up as a skipped
        # test -- the most important test in the file quietly not running.
        out = subprocess.run(
            [MATLAB, "-batch", "startup_ophira; agent_baseline"],
            cwd=str(ROOT), capture_output=True, text=True, timeout=900)
        line = next((l for l in (out.stdout or "").splitlines()
                     if l.startswith("BASELINE=")), "")
        check("the baseline cascade ran", bool(line),
              (out.stdout or out.stderr or "")[-200:] if not line else "")

        if line:
            parts = line.split("=", 1)[1].split("|")
            base_route, base_grade = parts[0], parts[1]
            base_ref, base_unc, base_ms = parts[2], parts[3], parts[4]

            agent_route = (state.decision or {}).get("route")
            g = state.evidence.get("grading") or {}
            agent_grade = g.get("grade")
            agent_ref = g.get("referable_score")
            agent_unc = g.get("uncertainty")

            print(f"      agent OFF (cascade) : {base_route}, grade {base_grade}, "
                  f"ref {float(base_ref):.6f}, unc {float(base_unc):.6f}, "
                  f"{float(base_ms):.0f} ms")
            print(f"      agent ON            : {agent_route}, grade {agent_grade}, "
                  f"ref {float(agent_ref):.6f}, unc {float(agent_unc):.6f}, "
                  f"{agent_ms:.0f} ms")

            check("test_agent_off_vs_on_same_decision: SAME ROUTE",
                  agent_route == base_route, f"{base_route} == {agent_route}")
            check("SAME GRADE", str(agent_grade) == base_grade,
                  f"{base_grade} == {agent_grade}")
            # Bitwise on the two numbers a referral and an abstention turn on.
            check("SAME REFERABLE SCORE (bitwise)",
                  abs(float(agent_ref) - float(base_ref)) == 0.0)
            check("SAME UNCERTAINTY (bitwise)",
                  abs(float(agent_unc) - float(base_unc)) == 0.0)

            print(f"\n      PERFORMANCE")
            print(f"        baseline cascade   : {float(base_ms):.0f} ms")
            print(f"        agent total        : {m['total_ms']} ms")
            print(f"        of which tools     : {m['tool_ms']} ms")
            print(f"        of which queue     : {m['queue_overhead_ms']} ms")
            print(f"        of which LLM       : {m['llm_ms']} ms")
            print(f"        agent overhead     : "
                  f"{m['total_ms'] - float(base_ms):.0f} ms")

print(f"\n{passed} passed, {failed} failed"
      + (f", {skipped} skipped" if skipped else ""))
sys.exit(1 if failed else 0)
