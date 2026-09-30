"""Typed contracts for the OPHIRA agent layer.

Plain dataclasses and stdlib only — the deployment has no third-party
Python dependency and adding one for the agent would change that.

THE ONE STRUCTURAL RULE HERE
----------------------------
`DecisionResult` records `source`. It is set from the MATLAB tool's own
`source` field, which is always "decisionEngine". Nothing in this package
constructs a DecisionResult from anything else, so a route that did not
come from the deterministic engine cannot be represented.
"""
from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Any

AGENT_VERSION = "1.0.0"


class State(str, Enum):
    """Where the case is. Explicit, not hidden inside a prompt."""
    INITIALIZED = "INITIALIZED"
    IMAGE_RECEIVED = "IMAGE_RECEIVED"
    QUALITY_CHECK = "QUALITY_CHECK"
    QUALITY_FAILED = "QUALITY_FAILED"
    RECAPTURE_REQUIRED = "RECAPTURE_REQUIRED"
    QUALITY_PASSED = "QUALITY_PASSED"
    TRIAGE = "TRIAGE"
    GRADING = "GRADING"
    MACULOPATHY = "MACULOPATHY"
    EVIDENCE_REVIEW = "EVIDENCE_REVIEW"
    LESION_ANALYSIS = "LESION_ANALYSIS"
    XAI = "XAI"
    DECISION = "DECISION"
    SYNTHESIS = "SYNTHESIS"
    COMPLETE = "COMPLETE"
    FAILED = "FAILED"


class Event(str, Enum):
    CASE_INITIALIZED = "case_initialized"
    IMAGE_RECEIVED = "image_received"
    OBSERVATION = "observation"
    TOOL_SELECTED = "tool_selected"
    TOOL_STARTED = "tool_started"
    TOOL_COMPLETED = "tool_completed"
    TOOL_FAILED = "tool_failed"
    EVIDENCE_ADDED = "evidence_added"
    AGENT_REPLANNED = "agent_replanned"
    RECAPTURE_REQUESTED = "recapture_requested"
    DECISION_SUBMITTED = "decision_submitted"
    DECISION_COMPLETED = "decision_completed"
    SYNTHESIS_STARTED = "synthesis_started"
    SYNTHESIS_COMPLETED = "synthesis_completed"
    CASE_COMPLETED = "case_completed"
    ERROR = "error"


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime())


@dataclass
class ToolRequest:
    tool: str
    args: dict[str, Any] = field(default_factory=dict)
    request_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])


@dataclass
class ToolResult:
    tool: str
    ok: bool
    data: dict[str, Any] = field(default_factory=dict)
    error: str = ""
    latency_ms: float = 0.0
    at: str = field(default_factory=_now)


@dataclass
class AgentAction:
    """One decision by the planner: which tool, and why.

    `reason` is an operational rationale shown to the operator — what
    evidence is missing and what the tool will supply. It is deliberately
    NOT model chain-of-thought.
    """
    action: str                      # a registered tool name, or a control action
    reason: str
    arguments: dict[str, Any] = field(default_factory=dict)
    planner: str = "policy"          # "policy" | "llm"
    is_replan: bool = False
    at: str = field(default_factory=_now)


@dataclass
class AgentEvent:
    event: str
    at: str = field(default_factory=_now)
    tool: str = ""
    reason: str = ""
    detail: dict[str, Any] = field(default_factory=dict)
    source: str = "agent"


@dataclass
class DecisionResult:
    """The deterministic engine's output. Never constructed elsewhere."""
    route: str
    source: str
    rules_fired: list[str] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)
    rules_version: str = ""
    site: str = ""
    calibrated: bool = False
    at: str = field(default_factory=_now)

    def __post_init__(self):
        if self.source != "decisionEngine":
            raise ValueError(
                "A clinical route may only come from the deterministic "
                f"decision engine. Got source={self.source!r}."
            )


@dataclass
class CaseState:
    """Everything the agent knows. Serialisable, inspectable, persisted."""
    session_id: str
    image_path: str = ""
    site: str = "default"
    attempt: int = 1
    state: str = State.INITIALIZED.value

    # evidence, keyed by the tool that produced it
    evidence: dict[str, Any] = field(default_factory=dict)

    # the deterministic result, once the engine has run
    decision: dict[str, Any] | None = None

    # bookkeeping
    actions: list[dict[str, Any]] = field(default_factory=list)
    replans: int = 0
    tool_failures: int = 0
    started_at: str = field(default_factory=_now)
    completed_at: str = ""

    # --- what the planner reads ------------------------------------------
    def has(self, key: str) -> bool:
        return key in self.evidence and self.evidence[key] is not None

    def missing(self) -> list[str]:
        """Evidence a complete case would carry but this one does not."""
        want = ["quality", "triage", "grading", "maculopathy", "lesions", "xai"]
        return [w for w in want if not self.has(w)]

    def quality_passed(self) -> bool:
        return self.has("quality") and self.evidence["quality"].get("status") == "PASS"

    def triage_escalated(self) -> bool:
        return self.has("triage") and bool(self.evidence["triage"].get("escalate"))

    def as_engine_evidence(self) -> dict[str, Any]:
        """Assemble the struct ophira.decision.decisionEngine expects.

        Only fields the engine already reads. The agent adds nothing to
        this and interprets nothing in it.
        """
        ev: dict[str, Any] = {}

        if self.has("quality"):
            ev["quality"] = {"decision": self.evidence["quality"]["decision"]}

        if self.has("grading"):
            g = self.evidence["grading"]
            ev["dr_grade"] = g["grade"]
            ev["dr_probs"] = g["probabilities"]
            ev["uncertainty"] = g["uncertainty"]
            ev["referable_score"] = g["referable_score"]
        elif self.has("triage") and not self.triage_escalated():
            # Cleared by the filter. These are the cascade's own values for
            # that branch, not an agent invention: grade 0, and a binary
            # uncertainty that peaks at p = 0.5.
            t = self.evidence["triage"]
            ev["dr_grade"] = 0
            ev["uncertainty"] = t["uncertainty"]

        if self.has("maculopathy") and self.evidence["maculopathy"].get("available"):
            ev["maculopathy"] = self.evidence["maculopathy"]["maculopathy"]

        if self.has("context"):
            ev["context"] = self.evidence["context"]

        return ev

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
