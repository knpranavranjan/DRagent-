"""OPHIRA agentic orchestration layer.

The agent observes case state, selects tools, executes them against the
existing MATLAB pipeline, observes the results and replans. It does not
make the clinical decision: that stays with ophira.decision.decisionEngine,
and `schemas.DecisionResult` refuses to be constructed from anything else.
"""
from .schemas import AGENT_VERSION, CaseState, State, Event   # noqa: F401
from .orchestrator import AgentRun                            # noqa: F401
from .tools import REGISTRY, describe_registry                # noqa: F401

__all__ = ["AGENT_VERSION", "AgentRun", "CaseState", "State", "Event",
           "REGISTRY", "describe_registry"]
