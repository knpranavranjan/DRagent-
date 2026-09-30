"""The tool registry. The agent's entire reach.

A planner can name anything. This is what decides whether naming it does
anything, so the registry is the security boundary, not a convenience:

  * only names registered here can execute
  * each has a declared permission, and the agent's grant is fixed
  * `run_decision_engine` is marked as the decision boundary and is the
    only tool permitted to yield a clinical route

There is no `eval`, no shell, no file-write tool, and no way to add one at
runtime — the registry is built at import and never mutated.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from .bridge import MatlabToolBridge, WorkerUnavailable
from .schemas import ToolResult


# Permissions the agent is granted. Deliberately not including
# WRITE_MODEL, MODIFY_MODEL, CHANGE_THRESHOLD, EXECUTE_SHELL or
# EXECUTE_ARBITRARY_CODE — those are not withheld by convention, they do
# not exist as tools at all.
AGENT_PERMISSIONS = frozenset({
    "READ_CASE", "READ_MODEL_OUTPUT", "CALL_QUALITY", "CALL_TRIAGE",
    "CALL_GRADING", "CALL_MACULOPATHY", "CALL_LESION", "CALL_XAI",
    "CALL_DECISION_ENGINE", "GENERATE_REPORT",
})


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    permission: str
    inputs: tuple[str, ...]
    outputs: tuple[str, ...]
    evidence_key: str = ""
    is_decision_boundary: bool = False


REGISTRY: dict[str, Tool] = {t.name: t for t in [
    Tool(
        name="assess_image_quality",
        description="Run the existing classical quality gate on a capture.",
        permission="CALL_QUALITY",
        inputs=("image_path", "attempt"),
        outputs=("status", "decision", "quality_score", "reasons"),
        evidence_key="quality",
    ),
    Tool(
        name="run_triage",
        description="Cheap filter: p(any DR) against the site-calibrated threshold.",
        permission="CALL_TRIAGE",
        inputs=("image_path",),
        outputs=("p_any_dr", "escalate", "threshold"),
        evidence_key="triage",
    ),
    Tool(
        name="run_dr_grading",
        description="CORAL ordinal grader: grade, probabilities, uncertainty, referable score.",
        permission="CALL_GRADING",
        inputs=("image_path",),
        outputs=("grade", "probabilities", "uncertainty", "referable_score"),
        evidence_key="grading",
    ),
    Tool(
        name="run_maculopathy",
        description="Maculopathy/DME head on the grader's encoder. Refers independently of DR grade.",
        permission="CALL_MACULOPATHY",
        inputs=("image_path",),
        outputs=("maculopathy", "referable"),
        evidence_key="maculopathy",
    ),
    Tool(
        name="run_lesion_analysis",
        description="Tiled U-Net lesion segmentation at native resolution. Explanation, not routing.",
        permission="CALL_LESION",
        inputs=("image_path",),
        outputs=("lesions_detected", "lesion_types", "tile_count"),
        evidence_key="lesions",
    ),
    Tool(
        name="run_xai",
        description="Grad-CAM and lesion overlays. Attention, not a lesion map.",
        permission="CALL_XAI",
        inputs=("image_path", "session_id"),
        outputs=("overlay_paths", "interpretation"),
        evidence_key="xai",
    ),
    Tool(
        name="run_decision_engine",
        description=("THE DECISION BOUNDARY. Submits assembled evidence to the "
                     "deterministic engine and returns its route verbatim."),
        permission="CALL_DECISION_ENGINE",
        inputs=("evidence",),
        outputs=("route", "rules_fired", "reasons"),
        is_decision_boundary=True,
    ),
]}

# Control actions the planner may choose that are not tool calls.
CONTROL_ACTIONS = frozenset({"request_recapture", "finish"})


class ToolExecutor:
    """Executes registered tools and refuses everything else."""

    def __init__(self, bridge: MatlabToolBridge):
        self.bridge = bridge
        self.calls = 0

    def execute(self, name: str, args: dict[str, Any]) -> ToolResult:
        tool = REGISTRY.get(name)
        if tool is None:
            # A planner asking for an unregistered name is a guardrail hit,
            # not a crash. It is recorded and the case continues under the
            # deterministic policy.
            return ToolResult(tool=name, ok=False,
                              error=f"'{name}' is not a registered tool.")
        if tool.permission not in AGENT_PERMISSIONS:
            return ToolResult(tool=name, ok=False,
                              error=f"Permission {tool.permission} is not granted.")

        self.calls += 1
        try:
            resp = self.bridge.call(name, args)
        except WorkerUnavailable as e:
            return ToolResult(tool=name, ok=False, error=str(e))

        if resp.get("status") != "ok":
            return ToolResult(tool=name, ok=False,
                              error=resp.get("error", "tool reported failure"),
                              latency_ms=resp.get("latency_ms", 0.0))

        data = resp.get("result", {}) or {}
        return ToolResult(tool=name, ok=True, data=data,
                          latency_ms=float(data.get("latency_ms",
                                                    resp.get("latency_ms", 0.0))))


def describe_registry() -> list[dict[str, Any]]:
    """For the audit screen and the LLM planner's allowed-action list."""
    return [
        {
            "name": t.name,
            "description": t.description,
            "permission": t.permission,
            "inputs": list(t.inputs),
            "outputs": list(t.outputs),
            "decision_boundary": t.is_decision_boundary,
        }
        for t in REGISTRY.values()
    ]
