"""The planner: what the agent does next, and why.

This is deliberately deterministic and readable. An LLM may be consulted
(see `llm.py`), but only to CHOOSE AMONG the options this policy has
already declared legal — never to invent one, and never to decide a route.

WHAT MAKES THIS AGENTIC RATHER THAN A SCRIPT
--------------------------------------------
Nothing here contains a fixed sequence. Every call reads the current
evidence and returns one action. The same case can take materially
different paths:

  * a capture the gate rejects never reaches a model at all
  * a retina the triage filter clears never reaches the grader — the
    grader, maculopathy, lesion and XAI stages are all skipped
  * a case the engine routes to ROUTINE stops without lesion segmentation,
    which is ~5 s of the ~7 s cascade
  * a case the engine routes to a human comes BACK for lesions and XAI and
    is submitted to the engine a second time

The last one is the clearest demonstration: the agent calls the decision
engine, observes the route, and replans to gather explanatory evidence
that only matters because a human will now read the report.

NO MEDICAL THRESHOLD IS DEFINED HERE
------------------------------------
The policy reads thresholds out of the tool results, which read them from
`ophira.decision.rulesV1`. It compares; it does not choose. Routing is the
engine's, and this file cannot express a route.
"""
from __future__ import annotations

from typing import Any

from .schemas import AgentAction, CaseState, State

# Routes for which a clinician will open the case. Not a clinical
# threshold — it is the existing cascade's own rule for when stage 3 runs
# (see ophira.cascade.orchestrate: lesions run for REFERRAL, URGENT and
# HUMAN REVIEW, and are skipped for a routine clear).
HUMAN_WILL_SEE = {"REFERRAL", "URGENT", "HUMAN REVIEW"}


def observe(state: CaseState) -> dict[str, Any]:
    """What the agent knows, what it does not, and what it could do."""
    return {
        "state": state.state,
        "have": sorted(k for k in state.evidence if k != "context"),
        "missing": state.missing(),
        "quality_passed": state.quality_passed(),
        "triage_escalated": state.triage_escalated() if state.has("triage") else None,
        "provisional_route": (state.decision or {}).get("route"),
        "attempt": state.attempt,
        "tool_failures": state.tool_failures,
    }


def next_action(state: CaseState) -> AgentAction:
    """One step. Reads state, returns an action with an operational reason."""

    img = {"image_path": state.image_path, "site": state.site}

    # ---- 1. nothing is known until the capture is assessed --------------
    if not state.has("quality"):
        return AgentAction(
            action="assess_image_quality",
            reason=("No evidence has been collected yet. The capture must be "
                    "assessed before any model runs on it — an image the gate "
                    "rejects is not gradable, and grading it anyway would "
                    "produce a number with nothing behind it."),
            arguments={**img, "attempt": state.attempt},
        )

    q = state.evidence["quality"]

    # ---- 2. the gate rejected it ----------------------------------------
    if q.get("status") != "PASS":
        decision = q.get("decision", "RECAPTURE")
        if decision == "RECAPTURE" and state.attempt < int(q.get("max_attempts", 3)):
            why = "; ".join(r.get("text", "") for r in q.get("reasons", [])) or \
                  "quality below the gate threshold"
            return AgentAction(
                action="request_recapture",
                reason=(f"The quality gate returned RECAPTURE on attempt "
                        f"{state.attempt} of {q.get('max_attempts', 3)}: {why}. "
                        f"No model will be run on this capture. A retake is "
                        f"the correct next step, not a graded result."),
                arguments={},
                is_replan=True,
            )
        # UNGRADABLE, or attempts exhausted. The engine, not the agent,
        # decides what that means for the patient.
        return AgentAction(
            action="run_decision_engine",
            reason=(f"The capture is {decision} and no further retake is "
                    f"available. Submitting the quality evidence to the "
                    f"decision engine — an unassessable image is routed by "
                    f"the engine, never silently treated as a clear result."),
            arguments={"evidence": state.as_engine_evidence(), "site": state.site},
        )

    # ---- 3. cheap filter before the expensive grader ---------------------
    if not state.has("triage"):
        return AgentAction(
            action="run_triage",
            reason=("The capture passed quality. Triage is the cheapest "
                    "evidence available and can rule the case out before the "
                    "512 px grader is loaded, so it runs first."),
            arguments=img,
        )

    t = state.evidence["triage"]

    # ---- 4. triage cleared it: skip the grader entirely ------------------
    if not t.get("escalate"):
        if state.decision is None:
            return AgentAction(
                action="run_decision_engine",
                reason=(f"Triage scored p(any DR) = {t.get('p_any_dr', 0):.4f} "
                        f"against the site threshold {t.get('threshold', 0):.4g} "
                        f"and cleared the image. Grading, maculopathy, lesion "
                        f"segmentation and XAI are all skipped — that is the "
                        f"filter doing its job. Submitting to the engine."),
                arguments={"evidence": state.as_engine_evidence(), "site": state.site},
                is_replan=True,
            )
        return AgentAction(action="finish",
                           reason="Route decided on a triage-cleared image.")

    # ---- 5. escalated: grade it -----------------------------------------
    if not state.has("grading"):
        return AgentAction(
            action="run_dr_grading",
            reason=(f"Triage escalated (p = {t.get('p_any_dr', 0):.4f} >= "
                    f"{t.get('threshold', 0):.4g}). A severity grade is the "
                    f"next required evidence."),
            arguments=img,
        )

    g = state.evidence["grading"]

    # ---- 6. maculopathy refers independently of the DR grade -------------
    if not state.has("maculopathy"):
        return AgentAction(
            action="run_maculopathy",
            reason=(f"Grade {g.get('grade')} recorded. Maculopathy is not "
                    f"derived from the DR grade — a threatened macula can "
                    f"refer on its own — so it is collected regardless of "
                    f"what the grade was."),
            arguments=img,
        )

    # ---- 7. provisional route, then decide whether to explain it ---------
    if state.decision is None:
        return AgentAction(
            action="run_decision_engine",
            reason=("Grade, uncertainty, referable score and maculopathy are "
                    "all collected. Submitting to the deterministic decision "
                    "engine. The route it returns determines whether "
                    "explanatory evidence is worth computing."),
            arguments={"evidence": state.as_engine_evidence(), "site": state.site},
        )

    route = state.decision.get("route", "")

    # ---- 8. a human will read this: gather explanation -------------------
    if route in HUMAN_WILL_SEE:
        if not state.has("lesions"):
            return AgentAction(
                action="run_lesion_analysis",
                reason=(f"The engine routed this {route}, so a clinician will "
                        f"open the case. Lesion segmentation costs about five "
                        f"seconds and is the evidence that shows WHERE the "
                        f"finding is. It was not worth computing until the "
                        f"route was known."),
                arguments=img,
                is_replan=True,
            )
        if not state.has("xai"):
            return AgentAction(
                action="run_xai",
                reason=("Lesion evidence collected. Generating the overlays "
                        "the clinician report displays, including Grad-CAM — "
                        "labelled as model attention, not as a lesion map."),
                arguments={**img, "session_id": state.session_id,
                           "lesion_mask_available": True},
            )
        return AgentAction(
            action="finish",
            reason=(f"Route {route} decided by the engine, with lesion and "
                    f"XAI evidence attached for the clinician."),
        )

    # ---- 9. routine clear: stop, do not spend five seconds on overlays ---
    return AgentAction(
        action="finish",
        reason=(f"The engine routed this {route}. The existing cascade does "
                f"not run lesion segmentation for a routine clear, and "
                f"neither does the agent — nobody will read the overlay."),
        is_replan=True,
    )


def state_after(action: str, state: CaseState) -> str:
    """The state label to display once `action` has been taken."""
    return {
        "assess_image_quality": State.QUALITY_CHECK.value,
        "request_recapture": State.RECAPTURE_REQUIRED.value,
        "run_triage": State.TRIAGE.value,
        "run_dr_grading": State.GRADING.value,
        "run_maculopathy": State.MACULOPATHY.value,
        "run_lesion_analysis": State.LESION_ANALYSIS.value,
        "run_xai": State.XAI.value,
        "run_decision_engine": State.DECISION.value,
        "finish": State.SYNTHESIS.value,
    }.get(action, state.state)


def allowed_actions(state: CaseState) -> list[str]:
    """Every action legal right now — the LLM planner's whole menu.

    Built from the policy's own branch conditions, so an LLM cannot widen
    it and cannot reach a tool the state does not warrant.
    """
    out: list[str] = []
    if not state.has("quality"):
        return ["assess_image_quality"]

    q = state.evidence["quality"]
    if q.get("status") != "PASS":
        if q.get("decision") == "RECAPTURE" and \
                state.attempt < int(q.get("max_attempts", 3)):
            out.append("request_recapture")
        out.append("run_decision_engine")
        return out

    if not state.has("triage"):
        return ["run_triage"]
    if not state.triage_escalated():
        return ["run_decision_engine"] if state.decision is None else ["finish"]
    if not state.has("grading"):
        return ["run_dr_grading"]
    if not state.has("maculopathy"):
        # Legal to go straight to the engine, but the policy prefers to
        # collect macular evidence first. The LLM may pick either.
        return ["run_maculopathy", "run_decision_engine"]
    if state.decision is None:
        return ["run_decision_engine"]

    route = state.decision.get("route", "")
    if route in HUMAN_WILL_SEE:
        if not state.has("lesions"):
            return ["run_lesion_analysis", "finish"]
        if not state.has("xai"):
            return ["run_xai", "finish"]
    return ["finish"]
