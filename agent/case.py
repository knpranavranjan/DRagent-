"""A screening encounter: up to four captures, one agent run each.

WHY PER-IMAGE RUNS AND NOT ONE RUN OVER FOUR IMAGES
---------------------------------------------------
Each capture is graded on its own in the existing pipeline, and the session
action is the most severe across them. That is not an implementation
detail: an eye is not made safe by the other eye looking fine, and a disc
field that fails quality does not invalidate a macula field that passed.

So each capture gets its own agent run, its own evidence and its own
deterministic route. The session route is then the most severe of those,
using the SAME precedence the MATLAB worker applies in
ophira.worker.run>governing. The agent does not re-decide anything here; it
picks the worst route the engine already produced.
"""
from __future__ import annotations

import time
from pathlib import Path
from typing import Any, Callable

from .orchestrator import AgentRun
from .schemas import AGENT_VERSION, AgentEvent

# The decision engine's own precedence. RECAPTURE outranks ROUTINE because
# an unusable capture must never be reported as a clear result.
SEVERITY = ["URGENT", "HUMAN REVIEW", "REFERRAL", "RECAPTURE", "ROUTINE"]

# Slots the encounter app defines. Only the macula fields are required.
SLOTS = [
    ("od_macula", "Right eye — macula", True),
    ("od_disc",   "Right eye — disc",   False),
    ("os_macula", "Left eye — macula",  True),
    ("os_disc",   "Left eye — disc",    False),
]
SLOT_LABEL = {s: label for s, label, _ in SLOTS}


def _rank(route: str | None) -> int:
    if not route:
        return len(SEVERITY)          # no route is worse than any route
    try:
        return SEVERITY.index(route)
    except ValueError:
        return len(SEVERITY)


class AgentCase:
    """Runs the agent over every capture in an encounter."""

    def __init__(self, session_id: str, images: list[dict[str, str]],
                 sessions_root: Path, site: str = "default",
                 context: dict[str, Any] | None = None, use_llm: bool = True,
                 on_event: Callable[[AgentEvent, str], None] | None = None):
        self.session_id = session_id
        self.images = images                 # [{slot, path}]
        self.sessions_root = Path(sessions_root)
        self.site = site
        self.context = context
        self.use_llm = use_llm
        self.on_event = on_event
        self.runs: list[tuple[str, AgentRun]] = []
        self.t0 = time.time()

    def run(self) -> dict[str, Any]:
        for item in self.images:
            slot = item.get("slot", "image")
            path = item["path"]

            def _fwd(e: AgentEvent, _slot=slot):
                if self.on_event:
                    self.on_event(e, _slot)

            # "__" and not "::": the run id becomes a directory name for the
            # per-capture trace, and ":" is not legal in a Windows path.
            # Minting an illegal id and sanitising it later meant every
            # consumer had to remember to sanitise; two of them did not.
            r = AgentRun(session_id=f"{self.session_id}__{slot}",
                         image_path=path, sessions_root=self.sessions_root,
                         site=self.site, context=self.context,
                         use_llm=self.use_llm, on_event=_fwd)
            r.run()
            self.runs.append((slot, r))
        return self.summary()

    # ------------------------------------------------------------------
    def governing(self) -> tuple[str, AgentRun | None]:
        """The most severe route the engine produced across the captures."""
        best, best_run, best_rank = None, None, len(SEVERITY) + 1
        for slot, r in self.runs:
            route = (r.state.decision or {}).get("route")
            if route is None and r.state.state == "RECAPTURE_REQUIRED":
                route = "RECAPTURE"
            k = _rank(route)
            if k < best_rank:
                best, best_run, best_rank = route, r, k
        return (best or "HUMAN REVIEW"), best_run

    def summary(self) -> dict[str, Any]:
        route, gov = self.governing()
        per_image = []
        for slot, r in self.runs:
            m = r.metrics()
            per_image.append({
                "slot": slot,
                "label": SLOT_LABEL.get(slot, slot),
                "image": Path(r.state.image_path).name,
                "state": r.state.state,
                "route": (r.state.decision or {}).get("route"),
                "tools_executed": m["tools_executed"],
                "replans": m["replans"],
                "evidence_items": m["evidence_items"],
                "ms": m["total_ms"],
                "evidence": {k: v for k, v in r.state.evidence.items()
                             if k != "context"},
            })

        totals = {
            "agent_actions": sum(r.metrics()["agent_actions"] for _, r in self.runs),
            "tools_executed": sum(r.metrics()["tools_executed"] for _, r in self.runs),
            "replans": sum(r.metrics()["replans"] for _, r in self.runs),
            "tool_failures": sum(r.metrics()["tool_failures"] for _, r in self.runs),
            "evidence_items": sum(r.metrics()["evidence_items"] for _, r in self.runs),
            "tool_ms": sum(r.metrics()["tool_ms"] for _, r in self.runs),
            "llm_ms": sum(r.metrics()["llm_ms"] for _, r in self.runs),
            "total_ms": round((time.time() - self.t0) * 1000),
            "images": len(self.runs),
        }

        return {
            "session_id": self.session_id,
            "agent_version": AGENT_VERSION,
            "route": route,
            "governing_slot": next((s for s, r in self.runs if r is gov), None),
            "decision": (gov.state.decision if gov else None),
            "decision_authority": "deterministic decisionEngine",
            "agent_role": "evidence orchestration and report synthesis",
            "synthesis": {"text": _session_synthesis(gov, totals),
                          "source": gov.synthesis_source if gov else ""},
            "llm": (self.runs[0][1].llm.describe() if self.runs else {}),
            "metrics": totals,
            "per_image": per_image,
            "models": model_table(),
        }


def _session_synthesis(gov, totals: dict[str, Any]) -> str:
    """The governing capture's narrative, with SESSION-level counts.

    The per-run synthesis ends with "the agent executed N tools with M
    adaptive branches" — counts for ONE capture. Printed next to a summary
    table showing the totals for the whole encounter, that read as a
    contradiction: 7 tools in the prose, 14 in the table. The clinical
    description stays; the counts are restated for the session it is
    actually describing.
    """
    if gov is None:
        return ""
    text = gov.synthesis or ""
    marker = "The agent executed"
    i = text.find(marker)
    if i >= 0:
        text = text[:i].rstrip()
    tail = (f" Across {totals['images']} capture(s) the agent executed "
            f"{totals['tools_executed']} tools with {totals['replans']} "
            f"adaptive branch(es); it orchestrated evidence collection and "
            f"did not make the clinical decision.")
    return (text + tail).strip()


def model_table() -> list[dict[str, Any]]:
    """What ran, and how well it is known to perform.

    Every number here is a MEASURED result from this project's own
    evaluation, with the dataset it was measured on named. Nothing is a
    vendor claim and nothing is rounded up. Where a model is weak, the
    table says so in the same voice it uses for the strong ones — a
    reviewer who only sees the good numbers has been misled.
    """
    return [
        {
            "stage": "0 — quality",
            "model": "quality_gate_v1 (classical features)",
            "file": "— no model file",
            "params": "—",
            "size_mb": 0,
            "metric": "AUC 0.79",
            "dataset": "DeepDRiD held-out",
            "note": "Weakest component. Rejected 19 of 71 referable images "
                    "externally — a RECAPTURE is only safe if the retake happens.",
        },
        {
            "stage": "1 — triage",
            "model": "MobileNetV2 binary filter",
            "file": "m3_triage.mat",
            "params": "~2.2 M",
            "size_mb": 10.3,
            "metric": "sens(ref) 1.000 @ 53% escalation",
            "dataset": "APTOS frozen test",
            "note": "Site-calibrated threshold from rulesV1. The value baked "
                    "into the model file scored 0.493 externally and is not used.",
        },
        {
            "stage": "2 — DR grading",
            "model": "EfficientNet-B0 + CORAL ordinal head",
            "file": "m1_teacher_aptos.mat",
            "params": "~5.3 M",
            "size_mb": 17.8,
            "metric": "QWK 0.895 ± 0.008 (3 seeds)",
            "dataset": "APTOS frozen test",
            "note": "External QWK 0.75. Referable sens 0.981 / spec 0.894 "
                    "in-domain; 0.931 / 0.843 externally once calibrated.",
        },
        {
            "stage": "2b — maculopathy",
            "model": "MLP head on the frozen M1 encoder",
            "file": "m4_maculopathy.mat",
            "params": "~0.33 M",
            "size_mb": 1.3,
            "metric": "AUC 0.932 (referable)",
            "dataset": "IDRiD test",
            "note": "The IDRiD label is DEFINED by exudate proximity to the "
                    "fovea, so this is coupled to the exudate findings, not "
                    "independent of them. External precision 0.209.",
        },
        {
            "stage": "3 — lesions",
            "model": "U-Net, MobileNetV2 encoder, tiled at native resolution",
            "file": "m5_lesion_unet.mat",
            "params": "~2.0 M",
            "size_mb": 7.8,
            "metric": "Dice EX 0.613 · MA 0.424 · HE 0.404 · SE 0.095",
            "dataset": "IDRiD segmentation test",
            "note": "Explanation only — no routing rule reads it. SE "
                    "localisation is unreliable; absence of a marking is not "
                    "evidence of a healthy retina.",
        },
        {
            "stage": "— calibration",
            "model": "Temperature scaling",
            "file": "m7_calibration.mat",
            "params": "1 scalar",
            "size_mb": 0.02,
            "metric": "T = 1.2200",
            "dataset": "APTOS calibration split",
            "note": "Fitted on APTOS only. Per-site temperature was tested "
                    "and rejected: it minimises ECE but destroys the "
                    "threshold and the uncertainty ranking.",
        },
        {
            "stage": "XAI",
            "model": "Grad-CAM on the M1 final feature map",
            "file": "— derived from m1",
            "params": "—",
            "size_mb": 0,
            "metric": "IoU 0.052 · mass lift 2.2×",
            "dataset": "IDRiD vs expert masks",
            "note": "Does NOT localise lesions. The supervised lesion branch "
                    "reaches 5.3× on the same metric. Shown as model "
                    "attention, never as a map of disease.",
        },
        {
            "stage": "9 — decision",
            "model": "decision_rules_v1 (deterministic, not a model)",
            "file": "— versioned rules",
            "params": "—",
            "size_mb": 0,
            "metric": "21 scenario tests",
            "dataset": "— cannot be validated on public data",
            "note": "No public dataset pairs fundus images with symptoms, "
                    "visual acuity and grade. THE ONLY SOURCE OF A CLINICAL "
                    "ROUTE.",
        },
    ]
