"""Optional LLM: constrained planning and narrative synthesis.

THE MEDICAL PIPELINE DOES NOT DEPEND ON THIS FILE.
--------------------------------------------------
If no LLM is reachable, `available()` returns False and the agent runs on
`policy.py` alone with a deterministic synthesis. Every route, every grade
and every number is identical either way — the LLM never produces one.

WHAT IT IS ALLOWED TO DO
------------------------
1. CHOOSE among actions the policy has already declared legal. It cannot
   add one, and a reply naming anything else is discarded and recorded.
2. WRITE the narrative paragraph, after the deterministic route exists,
   with that route handed to it as fixed text.

WHAT IT CANNOT DO
-----------------
Produce a route, a grade, a probability or a threshold. Reach a tool.
Execute anything. It sees structured evidence, never a patient image, and
by default talks only to localhost.

PRIVACY
-------
Default provider is Ollama on 127.0.0.1. No image bytes, no patient
identifiers and no free-text clinical notes are sent — only the numeric
evidence summary built in `_evidence_digest`.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any

OLLAMA_HOST = os.environ.get("OPHIRA_LLM_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("OPHIRA_LLM_MODEL", "")
TIMEOUT = float(os.environ.get("OPHIRA_LLM_TIMEOUT", "25"))


class LLMProvider:
    """Base class. A second provider only needs these three methods."""
    name = "none"
    model = ""

    def available(self) -> bool:
        return False

    def complete(self, prompt: str, system: str = "") -> str:
        raise NotImplementedError

    def describe(self) -> dict[str, Any]:
        return {"provider": self.name, "model": self.model,
                "available": self.available(), "local": True}


class NullProvider(LLMProvider):
    """No LLM. The agent still plans, still branches, still traces."""
    name = "none"


class OllamaProvider(LLMProvider):
    name = "ollama"

    def __init__(self, host: str = OLLAMA_HOST, model: str = OLLAMA_MODEL):
        self.host = host.rstrip("/")
        self.model = model
        self._checked: bool | None = None

    def _models(self) -> list[str]:
        try:
            with urllib.request.urlopen(f"{self.host}/api/tags", timeout=3) as r:
                return [m.get("name", "") for m in json.load(r).get("models", [])]
        except (urllib.error.URLError, OSError, json.JSONDecodeError, TimeoutError):
            return []

    def available(self) -> bool:
        if self._checked is not None:
            return self._checked
        models = self._models()
        if not models:
            self._checked = False
            return False
        if not self.model:
            # Never advertise a model that is not actually installed.
            self.model = models[0]
        self._checked = self.model in models
        return self._checked

    def complete(self, prompt: str, system: str = "") -> str:
        body = json.dumps({
            "model": self.model,
            "prompt": prompt,
            "system": system,
            "stream": False,
            "options": {"temperature": 0.1},
        }).encode()
        req = urllib.request.Request(
            f"{self.host}/api/generate", data=body,
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r).get("response", "")


def get_provider() -> LLMProvider:
    if os.environ.get("OPHIRA_LLM", "auto").lower() in ("0", "off", "none"):
        return NullProvider()
    p = OllamaProvider()
    return p if p.available() else NullProvider()


# --------------------------------------------------------------------------
# constrained planning
# --------------------------------------------------------------------------

PLANNER_SYSTEM = (
    "You select the next step in a diabetic retinopathy screening workflow.\n"
    "You choose ONLY from the allowed_actions list you are given.\n"
    "You never decide whether a patient has disease, never assign a grade, "
    "and never decide a referral. A separate deterministic engine does that.\n"
    "Reply with JSON only: {\"action\": \"<one of allowed_actions>\", "
    "\"reason\": \"<one sentence on what evidence is still missing>\"}"
)


def plan(provider: LLMProvider, observation: dict[str, Any],
         allowed: list[str], fallback_reason: str) -> tuple[str, str, bool]:
    """Returns (action, reason, used_llm). Falls back silently and safely."""
    if not provider.available() or len(allowed) <= 1:
        return "", "", False
    try:
        prompt = json.dumps({"observation": observation,
                             "allowed_actions": allowed}, indent=2)
        raw = provider.complete(prompt, PLANNER_SYSTEM).strip()
        start, end = raw.find("{"), raw.rfind("}")
        if start < 0 or end <= start:
            return "", "", False
        obj = json.loads(raw[start:end + 1])
        action = str(obj.get("action", "")).strip()
        if action not in allowed:
            # Guardrail hit. Recorded by the orchestrator; policy decides.
            return "", "", False
        reason = str(obj.get("reason", "")).strip() or fallback_reason
        return action, reason, True
    except (urllib.error.URLError, OSError, json.JSONDecodeError,
            ValueError, TimeoutError):
        return "", "", False


# --------------------------------------------------------------------------
# narrative synthesis
# --------------------------------------------------------------------------

SYNTH_SYSTEM = (
    "You write one short paragraph for a clinician summarising how evidence "
    "was collected in a retinal screening case.\n"
    "The clinical route is already decided and is given to you as fixed "
    "text. Restate it exactly. Never change it, soften it, or add a "
    "diagnosis. Never invent a finding that is not in the evidence. "
    "Do not use the word 'diagnosis'. Plain prose, no headings, under 90 words."
)


def _evidence_digest(state) -> dict[str, Any]:
    """Only numbers and labels. No image, no identifiers, no free text."""
    ev = state.evidence
    d: dict[str, Any] = {}
    if "quality" in ev:
        d["image_quality"] = ev["quality"].get("decision")
        d["quality_score"] = round(float(ev["quality"].get("quality_score", 0)), 3)
    if "triage" in ev:
        d["triage_escalated"] = bool(ev["triage"].get("escalate"))
    if "grading" in ev:
        d["dr_grade"] = ev["grading"].get("grade")
        d["dr_grade_label"] = ev["grading"].get("grade_label")
        d["uncertainty"] = round(float(ev["grading"].get("uncertainty", 0)), 3)
    if "maculopathy" in ev and ev["maculopathy"].get("available"):
        d["maculopathy"] = ev["maculopathy"].get("maculopathy")
    if "lesions" in ev and ev["lesions"].get("available"):
        d["lesion_types_found"] = ev["lesions"].get("lesion_types", [])
        d["lesion_tiles"] = ev["lesions"].get("tile_count")
    d["tools_executed"] = len([a for a in state.actions if a.get("executed")])
    d["replans"] = state.replans
    return d


def deterministic_synthesis(state) -> str:
    """Used whenever no LLM is available. Never fabricates."""
    d = _evidence_digest(state)
    route = (state.decision or {}).get("route", "not decided")
    bits = [f"Image quality {d.get('image_quality', 'not assessed')}."]
    if "dr_grade" in d:
        bits.append(f"DR grade {d['dr_grade']} ({d.get('dr_grade_label','')}), "
                    f"model uncertainty {d.get('uncertainty')}.")
    elif d.get("triage_escalated") is False:
        bits.append("Triage cleared the image, so grading was not run.")
    if "maculopathy" in d:
        bits.append(f"Maculopathy risk {d['maculopathy']}.")
    if d.get("lesion_types_found"):
        bits.append("Lesion evidence collected for "
                    + ", ".join(d["lesion_types_found"]) + ".")
    bits.append(f"The deterministic decision engine routed this case {route}.")
    bits.append(f"The agent executed {d.get('tools_executed', 0)} tools with "
                f"{d.get('replans', 0)} adaptive branch(es); it orchestrated "
                f"evidence collection and did not make the clinical decision.")
    return " ".join(bits)


def synthesise(provider: LLMProvider, state) -> tuple[str, str]:
    """Returns (text, source) where source is 'llm' or 'deterministic'."""
    route = (state.decision or {}).get("route", "")
    if not provider.available() or not route:
        return deterministic_synthesis(state), "deterministic"
    try:
        prompt = json.dumps({
            "fixed_clinical_route": route,
            "route_reasons": (state.decision or {}).get("reasons", []),
            "evidence": _evidence_digest(state),
        }, indent=2)
        text = provider.complete(prompt, SYNTH_SYSTEM).strip()
        # A synthesis that drops or contradicts the route is discarded.
        if not text or route.lower() not in text.lower():
            return deterministic_synthesis(state), "deterministic"
        return text, "llm"
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return deterministic_synthesis(state), "deterministic"
