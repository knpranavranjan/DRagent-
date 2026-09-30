"""The agent loop: observe -> plan -> act -> observe -> replan.

Every visible line in the UI trace comes from here, and every one of them
corresponds to a real tool invocation with a real result. Nothing is
narrated that did not happen.
"""
from __future__ import annotations

import json
import re
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any, Callable

from . import llm as llm_mod
from . import policy
from .bridge import MatlabToolBridge
from .schemas import (AGENT_VERSION, AgentAction, AgentEvent, CaseState,
                      DecisionResult, Event, State)
from .tools import CONTROL_ACTIONS, REGISTRY, ToolExecutor, describe_registry

MAX_STEPS = 24          # a loop that cannot terminate is a bug, not patience


class AgentRun:
    def __init__(self, session_id: str, image_path: str, sessions_root: Path,
                 site: str = "default", attempt: int = 1,
                 context: dict[str, Any] | None = None,
                 use_llm: bool = True,
                 on_event: Callable[[AgentEvent], None] | None = None):
        self.state = CaseState(session_id=session_id, image_path=image_path,
                               site=site, attempt=attempt)
        if context:
            self.state.evidence["context"] = context
        self.sessions_root = Path(sessions_root)
        self.bridge = MatlabToolBridge(self.sessions_root)
        self.executor = ToolExecutor(self.bridge)
        self.llm = llm_mod.get_provider() if use_llm else llm_mod.NullProvider()
        self.events: list[AgentEvent] = []
        self.on_event = on_event
        self.synthesis = ""
        self.synthesis_source = ""
        self.llm_ms = 0.0
        self.tool_ms = 0.0
        # Tools that failed. A failing tool leaves its evidence missing, so
        # the planner would ask for it again on the next turn and the loop
        # would spin until MAX_STEPS. Once is a fault; twice is a bug.
        self.failed_tools: set[str] = set()
        self.t0 = time.time()

    # ---- trace ----------------------------------------------------------
    def _emit(self, event: str, **kw) -> None:
        e = AgentEvent(event=event, **kw)
        self.events.append(e)
        if self.on_event:
            try:
                self.on_event(e)
            except Exception:
                pass    # a broken listener must not stop a clinical case

    # ---- the loop -------------------------------------------------------
    def run(self) -> CaseState:
        self._emit(Event.CASE_INITIALIZED.value,
                   detail={"session_id": self.state.session_id,
                           "agent_version": AGENT_VERSION,
                           "llm": self.llm.describe()})
        self.state.state = State.IMAGE_RECEIVED.value
        self._emit(Event.IMAGE_RECEIVED.value,
                   detail={"image": Path(self.state.image_path).name,
                           "attempt": self.state.attempt})

        for _ in range(MAX_STEPS):
            observation = policy.observe(self.state)
            self._emit(Event.OBSERVATION.value, detail=observation)

            action = self._plan(observation)

            if action.is_replan:
                self.state.replans += 1
                self._emit(Event.AGENT_REPLANNED.value, reason=action.reason,
                           detail={"next": action.action})

            self._emit(Event.TOOL_SELECTED.value, tool=action.action,
                       reason=action.reason,
                       detail={"planner": action.planner})
            self.state.actions.append({**asdict(action), "executed": False})

            if action.action == "finish":
                break
            if action.action == "request_recapture":
                self.state.state = State.RECAPTURE_REQUIRED.value
                self._emit(Event.RECAPTURE_REQUESTED.value, reason=action.reason)
                break

            if not self._act(action):
                break

            self.state.state = policy.state_after(action.action, self.state)
        else:
            self._emit(Event.ERROR.value,
                       detail={"error": f"step limit {MAX_STEPS} reached"})
            self.state.state = State.FAILED.value

        self._synthesise()
        self.state.completed_at = time.strftime("%Y-%m-%dT%H:%M:%S")
        if self.state.state not in (State.FAILED.value,
                                    State.RECAPTURE_REQUIRED.value):
            self.state.state = State.COMPLETE.value
        self._emit(Event.CASE_COMPLETED.value, detail=self.metrics())
        return self.state

    # ---- plan -----------------------------------------------------------
    def _plan(self, observation: dict[str, Any]) -> AgentAction:
        action = policy.next_action(self.state)
        allowed = policy.allowed_actions(self.state)

        # Never re-select a tool that already failed this case. Prefer any
        # other legal action; if the only options have failed, stop rather
        # than loop. Retrying a broken tool does not make its evidence
        # appear, and a clinician waiting on a spinner learns nothing.
        if action.action in self.failed_tools:
            alt = [a for a in allowed if a not in self.failed_tools]
            fallback = "finish" if self.state.decision is not None else ""
            nxt = alt[0] if alt else fallback
            if nxt:
                self._emit(Event.AGENT_REPLANNED.value,
                           reason=(f"{action.action} already failed for this "
                                   f"capture; it is not retried. Continuing "
                                   f"with {nxt}."),
                           detail={"skipped": action.action})
                rebuilt = policy.next_action(self.state)
                action = AgentAction(
                    action=nxt,
                    reason=(f"{action.action} failed earlier in this case, so "
                            f"the evidence it would have supplied is "
                            f"unavailable. Proceeding without it."),
                    arguments=rebuilt.arguments, planner="policy",
                    is_replan=True)
            else:
                action = AgentAction(
                    action="finish",
                    reason=(f"{action.action} failed and no other evidence "
                            f"can be collected. Stopping rather than "
                            f"retrying a tool that does not work."),
                    is_replan=True)
            allowed = [action.action]

        # The LLM may pick among options the policy already permits. It
        # cannot widen the list, and a reply naming anything else is
        # discarded and recorded rather than followed.
        if self.llm.available() and len(allowed) > 1:
            t = time.time()
            choice, reason, used = llm_mod.plan(self.llm, observation, allowed,
                                                action.reason)
            self.llm_ms += (time.time() - t) * 1000
            if used and choice != action.action:
                self._emit(Event.AGENT_REPLANNED.value,
                           reason=f"LLM planner selected {choice} over "
                                  f"{action.action} among {allowed}.",
                           detail={"planner": "llm"})
                rebuilt = policy.next_action(self.state)
                action = AgentAction(action=choice, reason=reason,
                                     arguments=rebuilt.arguments,
                                     planner="llm",
                                     is_replan=rebuilt.is_replan)
            elif used:
                action.planner = "llm"
                action.reason = reason
        return action

    # ---- act ------------------------------------------------------------
    def _act(self, action: AgentAction) -> bool:
        self._emit(Event.TOOL_STARTED.value, tool=action.action)
        result = self.executor.execute(action.action, action.arguments)
        self.tool_ms += result.latency_ms
        self.state.actions[-1]["executed"] = True

        if not result.ok:
            self.state.tool_failures += 1
            self.failed_tools.add(action.action)
            self._emit(Event.TOOL_FAILED.value, tool=action.action,
                       detail={"error": result.error})
            # A failed tool never becomes a finding. If the engine has not
            # run, the case stops here rather than being routed on evidence
            # that does not exist.
            if self.state.decision is None:
                self.state.state = State.FAILED.value
                self._emit(Event.ERROR.value,
                           detail={"error": result.error,
                                   "note": "No clinical route was produced."})
                return False
            return True

        self._emit(Event.TOOL_COMPLETED.value, tool=action.action,
                   detail=_summarise(action.action, result.data))

        tool = REGISTRY[action.action]
        if tool.is_decision_boundary:
            self._record_decision(result.data)
        elif tool.evidence_key:
            self.state.evidence[tool.evidence_key] = result.data
            self._emit(Event.EVIDENCE_ADDED.value, tool=action.action,
                       detail={"key": tool.evidence_key})
        return True

    def _record_decision(self, data: dict[str, Any]) -> None:
        """The boundary. Constructed only from the engine's own output."""
        self._emit(Event.DECISION_SUBMITTED.value,
                   detail={"evidence_keys": sorted(
                       k for k in self.state.evidence if k != "context")})
        d = DecisionResult(
            route=data["route"],
            source=data["source"],                 # raises unless decisionEngine
            rules_fired=list(data.get("rules_fired", [])),
            reasons=list(data.get("reasons", [])),
            rules_version=data.get("rules_version", ""),
            site=data.get("site", ""),
            calibrated=bool(data.get("calibrated", False)),
        )
        self.state.decision = asdict(d)
        self._emit(Event.DECISION_COMPLETED.value,
                   source="decision_engine",
                   detail={"route": d.route, "rules_fired": d.rules_fired,
                           "authority": "DETERMINISTIC DECISION ENGINE"})

    # ---- synthesis ------------------------------------------------------
    def _synthesise(self) -> None:
        self._emit(Event.SYNTHESIS_STARTED.value)
        t = time.time()
        text, src = llm_mod.synthesise(self.llm, self.state)
        if src == "llm":
            self.llm_ms += (time.time() - t) * 1000
        self.synthesis, self.synthesis_source = text, src
        self._emit(Event.SYNTHESIS_COMPLETED.value,
                   detail={"source": src, "chars": len(text)})

    # ---- output ---------------------------------------------------------
    def metrics(self) -> dict[str, Any]:
        executed = [a for a in self.state.actions if a.get("executed")]
        total = (time.time() - self.t0) * 1000
        return {
            "agent_actions": len(self.state.actions),
            "tools_executed": len(executed),
            "replans": self.state.replans,
            "tool_failures": self.state.tool_failures,
            "evidence_items": len([k for k in self.state.evidence
                                   if k != "context"]),
            "total_ms": round(total),
            "tool_ms": round(self.tool_ms),
            "llm_ms": round(self.llm_ms),
            "queue_overhead_ms": round(self.bridge.queue_wait_ms - self.tool_ms)
            if self.bridge.queue_wait_ms > self.tool_ms else 0,
        }

    def trace(self) -> dict[str, Any]:
        return {
            "session_id": self.state.session_id,
            "agent_version": AGENT_VERSION,
            "decision_engine_version": (self.state.decision or {}).get(
                "rules_version", ""),
            "llm": self.llm.describe(),
            "started_at": self.state.started_at,
            "completed_at": self.state.completed_at,
            "final_state": self.state.state,
            "metrics": self.metrics(),
            "decision": self.state.decision,
            "decision_authority": "deterministic decisionEngine",
            "agent_role": "evidence orchestration and report synthesis",
            "synthesis": {"text": self.synthesis,
                          "source": self.synthesis_source},
            "evidence": {k: v for k, v in self.state.evidence.items()
                         if k != "context"},
            "registry": describe_registry(),
            "events": [asdict(e) for e in self.events],
            "actions": self.state.actions,
        }

    def save_trace(self) -> Path:
        # Defensive: a run id becomes a directory name, so anything a path
        # cannot carry is replaced rather than trusted.
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", self.state.session_id)
        d = self.sessions_root / "reports" / safe
        d.mkdir(parents=True, exist_ok=True)
        p = d / "agent_trace.json"
        tmp = p.with_suffix(".json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.trace(), f, indent=2)
        tmp.replace(p)
        return p


def _summarise(tool: str, data: dict[str, Any]) -> dict[str, Any]:
    """The one-line result the trace shows. Real values, not prose."""
    keep = {
        "assess_image_quality": ("status", "decision", "quality_score"),
        "run_triage": ("p_any_dr", "threshold", "escalate", "result"),
        "run_dr_grading": ("grade", "grade_label", "uncertainty",
                           "referable_score"),
        "run_maculopathy": ("maculopathy", "referable"),
        "run_lesion_analysis": ("lesions_detected", "lesion_types",
                                "tile_count"),
        "run_xai": ("xai_type", "interpretation"),
        "run_decision_engine": ("route", "rules_fired"),
    }.get(tool, ())
    return {k: data[k] for k in keep if k in data}
