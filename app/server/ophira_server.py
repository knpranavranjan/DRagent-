#!/usr/bin/env python3
"""
OPHIRA session server
=====================

A deliberately small local server: it serves the operator UI and stores each
screening encounter as a JSON file on disk. MATLAB reads those same files.

Why not a database
------------------
The deployed device is offline, single-operator, and must keep working when
everything around it does not. Files on disk survive a power cut, can be
copied with `cp`, can be read by MATLAB with `jsondecode`, and can be
inspected by a human during a failure. A database would add a daemon, a
schema migration path and a new failure mode, and buy nothing at this scale.

Standard library only -- no pip install. Python 3.8+ ships with Raspberry Pi
OS, so this runs unchanged on the development PC and on the Pi.

Usage
-----
    python app/server/ophira_server.py
    python app/server/ophira_server.py --port 8080 --data data/sessions

Layout
------
    data/sessions/drafts/<session_id>.json       in progress
    data/sessions/submitted/<session_id>.json    completed, read by MATLAB
"""

import argparse
import base64
import binascii
import json
import os
import re
import secrets
import shutil
import sys
import threading
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

from pathlib import Path
from urllib.parse import urlparse, parse_qs

# Dashboard telemetry. Imported after Path is available, and with this
# file's own directory pinned on sys.path so the server works regardless of
# the directory it was launched from.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import training_status
except ImportError:
    training_status = None

SCHEMA_VERSION = "context_core_v1"
MAX_BODY = 64 * 1024 * 1024         # fundus images are large; base64 adds 33%
SESSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{3,63}$")
SLOT_RE = re.compile(r"^[a-z]{2}_[a-z]+$")
ALLOWED_EXT = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp"}

_write_lock = threading.Lock()

# The agent layer is OPTIONAL. If it fails to import, the encounter app and
# the whole deterministic pipeline still run exactly as verified -- only the
# agentic endpoints go away. A screening system must not be taken down by an
# orchestration layer that sits above it.
_AGENT_IMPORT_ERROR = ""
try:
    _ROOT = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(_ROOT))
    from agent import AgentRun, AGENT_VERSION, describe_registry
    from agent.case import AgentCase, SLOTS, model_table
    AGENT_AVAILABLE = True
except Exception as _e:                                   # pragma: no cover
    AGENT_AVAILABLE = False
    AGENT_VERSION = "unavailable"
    _AGENT_IMPORT_ERROR = f"{type(_e).__name__}: {_e}"

# One agent run at a time per session, tracked so the UI can poll it.
_AGENT_RUNS: dict = {}
_AGENT_LOCK = threading.Lock()


# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------

class Store:
    def __init__(self, root: Path):
        self.root = root
        self.drafts = root / "drafts"
        self.submitted = root / "submitted"
        self.images = root / "images"
        self.jobs_pending = root / "jobs" / "pending"
        self.jobs_done = root / "jobs" / "done"
        self.reports = root / "reports"
        for d in (self.drafts, self.submitted, self.images,
                  self.jobs_pending, self.jobs_done, self.reports):
            d.mkdir(parents=True, exist_ok=True)

    # --- images and quality jobs ---------------------------------------

    def save_image(self, sid: str, slot: str, attempt: int, ext: str, blob: bytes) -> Path:
        """Store an ORIGINAL capture. Originals are immutable: a new attempt
        gets a new file, nothing is ever overwritten (Architecture v1.0
        section 06 -- original data immutable, derivatives versioned)."""
        if not SESSION_RE.match(sid):
            raise ValueError(f"invalid session id: {sid!r}")
        if not SLOT_RE.match(slot):
            raise ValueError(f"invalid slot id: {slot!r}")
        if ext.lower() not in ALLOWED_EXT:
            raise ValueError(f"unsupported image type: {ext!r}")

        d = self.images / sid
        d.mkdir(parents=True, exist_ok=True)
        path = d / f"{slot}_a{attempt:02d}{ext.lower()}"
        if path.exists():
            raise ValueError(f"original already exists, refusing to overwrite: {path.name}")
        with _write_lock:
            tmp = path.with_suffix(path.suffix + ".tmp")
            with open(tmp, "wb") as f:
                f.write(blob)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        return path

    def enqueue_quality(self, sid: str, slot: str, attempt: int, img: Path) -> str:
        job_id = f"Q-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(3).upper()}"
        job = {
            "job_id": job_id,
            "kind": "quality",
            "session_id": sid,
            "slot_id": slot,
            "attempt": attempt,
            "image_path": str(img),
            "queued_at": datetime.now(timezone.utc).isoformat(),
        }
        tmp = self.jobs_pending / f"{job_id}.json.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(job, f, indent=2)
        os.replace(tmp, self.jobs_pending / f"{job_id}.json")
        return job_id

    def enqueue_report(self, sid: str, images: list) -> str:
        """Queue the full cascade + report generation for a submitted session.

        Same file-queue contract as the quality jobs: the browser cannot call
        MATLAB, and MATLAB cannot serve HTTP. A directory of JSON files is
        something both sides already understand, and if the worker is down
        the job waits rather than erroring."""
        job_id = f"R-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(3).upper()}"
        job = {
            "job_id": job_id,
            "kind": "report",
            "session_id": sid,
            "images": [str(i) for i in images],
            "queued_at": datetime.now(timezone.utc).isoformat(),
        }
        tmp = self.jobs_pending / f"{job_id}.json.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(job, f, indent=2)
        os.replace(tmp, self.jobs_pending / f"{job_id}.json")
        return job_id

    def accepted_images(self, sid: str) -> list:
        """Originals for this session, latest attempt per slot.

        The quality verdict lives in the done-queue, so the newest attempt of
        each slot is the one the operator kept -- an earlier attempt only
        exists because it was rejected and retaken."""
        d = self.images / sid
        if not d.is_dir():
            return []
        best = {}
        for f in sorted(d.glob("*")):
            if f.suffix.lower() not in ALLOWED_EXT:
                continue
            slot = f.stem.rsplit("_a", 1)[0]
            best[slot] = f          # sorted, so the last wins
        return [best[k] for k in sorted(best)]

    def report_status(self, sid: str):
        if not SESSION_RE.match(sid):
            raise ValueError(f"invalid session id: {sid!r}")
        d = self.reports / sid
        meta = d / "report.json"
        if meta.is_file():
            try:
                with open(meta, encoding="utf-8") as f:
                    body = json.load(f)
                # The worker's own record carries a `status` of "ok"/"error"
                # describing whether GENERATION succeeded. The polling contract
                # uses `status` for whether the report EXISTS yet. Spreading the
                # file last overwrote "done" with "ok" and the browser polled
                # forever. Keep them separate.
                gen = body.pop("status", "ok")
                return {**body, "generation": gen,
                        "status": "failed" if gen == "error" else "done"}
            except (json.JSONDecodeError, OSError) as e:
                return {"status": "failed", "error": f"report unreadable: {e}"}
        for j in self.jobs_pending.glob("R-*.json"):
            try:
                with open(j, encoding="utf-8") as f:
                    if json.load(f).get("session_id") == sid:
                        return {"status": "pending", "session_id": sid}
            except (json.JSONDecodeError, OSError):
                continue
        return None

    def report_bundle(self, sid: str):
        """Everything the clinic needs for one encounter, as one .zip.

        Four separate download buttons is four chances to forget one. The
        documents embed their images as data URIs, so each file in here
        still opens correctly on its own after it is emailed on.
        """
        import io as _io
        import zipfile

        if not SESSION_RE.match(sid):
            raise ValueError(f"invalid session id: {sid!r}")
        d = self.reports / sid
        if not d.is_dir():
            return None

        members = [("clinician.html", d / "clinician.html"),
                   ("patient.html", d / "patient.html"),
                   ("result.json", d / "report.json")]
        present = [(n, f) for n, f in members if f.is_file()]
        if not present:
            return None

        # The encounter record too: a report without the questionnaire it
        # was decided on cannot be audited later.
        ctx = self.submitted / f"{sid}.json"
        if ctx.is_file():
            present.append(("encounter.json", ctx))

        buf = _io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for name, f in present:
                z.write(f, f"{sid}/{name}")
        return buf.getvalue()

    def report_file(self, sid: str, which: str):
        if not SESSION_RE.match(sid):
            raise ValueError(f"invalid session id: {sid!r}")
        if which not in ("clinician", "patient"):
            raise ValueError(f"unknown report: {which!r}")
        p = self.reports / sid / f"{which}.html"
        return p if p.is_file() else None

    def job_status(self, job_id: str):
        if not re.match(r"^Q-[0-9]{8}-[0-9]{6}-[0-9A-F]{6}$", job_id):
            raise ValueError(f"invalid job id: {job_id!r}")
        done = self.jobs_done / f"{job_id}.json"
        if done.is_file():
            try:
                with open(done, encoding="utf-8") as f:
                    body = json.load(f)
                # SAME COLLISION AS THE REPORT ENDPOINT, and this one was live.
                # The worker writes `status` = "ok"/"error" meaning "did the
                # assessment run". The polling contract uses `status` to mean
                # "has the job FINISHED". Spreading the file last overwrote
                # "done" with "ok", so api.js awaitQuality() -- which waits for
                # status === "done" -- never saw completion. Every capture span
                # until its 60 s timeout and told the operator the worker was
                # down, on images the gate had graded correctly in 1.5 s.
                # A result file means the job FINISHED, whatever the verdict.
                # Not "failed" even when the worker hit an exception: the
                # worker's error path sets decision = UNGRADABLE, and an
                # ungradable image must reach the operator as a clinical
                # routing to a human, not as an error toast that discards the
                # verdict (Architecture v1.0 section 09).
                run = body.pop("status", "ok")
                return {**body, "worker": run, "status": "done"}
            except (json.JSONDecodeError, OSError) as e:
                return {"status": "failed", "error": f"result unreadable: {e}"}
        if (self.jobs_pending / f"{job_id}.json").is_file():
            return {"status": "pending", "job_id": job_id}
        return None

    @staticmethod
    def new_id() -> str:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        return f"S-{stamp}-{secrets.token_hex(3).upper()}"

    def _path(self, sid: str, submitted: bool = False) -> Path:
        # Rejecting the id rather than sanitising it: a traversal attempt is
        # a bug or an attack, and silently "fixing" it hides both.
        if not SESSION_RE.match(sid):
            raise ValueError(f"invalid session id: {sid!r}")
        base = self.submitted if submitted else self.drafts
        return base / f"{sid}.json"

    def write(self, sid: str, ctx: dict, submitted: bool = False) -> Path:
        """Atomic write: temp file then replace, so a crash mid-write cannot
        leave a half-written record that MATLAB would later fail to parse."""
        path = self._path(sid, submitted)
        tmp = path.with_suffix(".json.tmp")
        with _write_lock:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(ctx, f, indent=2, ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        return path

    def read(self, sid: str):
        for submitted in (False, True):
            p = self._path(sid, submitted)
            if p.is_file():
                with open(p, encoding="utf-8") as f:
                    return json.load(f)
        return None

    def submit(self, sid: str, ctx: dict) -> Path:
        path = self.write(sid, ctx, submitted=True)
        draft = self._path(sid, submitted=False)
        if draft.is_file():
            draft.unlink()
        return path

    def listing(self):
        out = []
        for state, d in (("submitted", self.submitted), ("draft", self.drafts)):
            for p in sorted(d.glob("*.json"), reverse=True):
                try:
                    with open(p, encoding="utf-8") as f:
                        c = json.load(f)
                except (json.JSONDecodeError, OSError):
                    out.append({"session_id": p.stem, "state": "corrupt"})
                    continue
                out.append({
                    "session_id": c.get("session", {}).get("session_id", p.stem),
                    "state": state,
                    "patient_id": c.get("patient", {}).get("patient_id", ""),
                    "centre_id": c.get("session", {}).get("centre_id", ""),
                    "created_at": c.get("session", {}).get("created_at"),
                    "completed_at": c.get("session", {}).get("completed_at"),
                    "urgent": bool(c.get("flags", {}).get("urgent")),
                    "pathway": c.get("flags", {}).get("pathway"),
                })
        return out


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

def validate(ctx: dict, *, final: bool):
    """Server-side checks. The UI validates too, but a client is never the
    authority on what lands in a clinical record."""
    errs = []

    if not isinstance(ctx, dict):
        return ["payload must be a JSON object"]

    if ctx.get("schema_version") != SCHEMA_VERSION:
        errs.append(f"schema_version must be {SCHEMA_VERSION}")

    for key in ("session", "patient", "eligibility", "consent", "flags"):
        if not isinstance(ctx.get(key), dict):
            errs.append(f"missing or invalid block: {key}")

    if errs or not final:
        return errs

    if not ctx["patient"].get("patient_id"):
        errs.append("patient.patient_id is required")

    # Consent is a hard gate. A submitted record without it is a protocol
    # violation, not a form error, so the server refuses it outright.
    if ctx["consent"].get("given") is not True:
        errs.append("consent.given must be true to submit")

    if not ctx["session"].get("completed_at"):
        errs.append("session.completed_at is required")

    return errs


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(SimpleHTTPRequestHandler):
    store: Store = None
    app_dir: Path = None

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(self.app_dir), **kw)

    # --- helpers ----------------------------------------------------------

    def _json(self, code: int, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            raise ValueError("empty body")
        if n > MAX_BODY:
            raise ValueError("body too large")
        return json.loads(self.rfile.read(n).decode("utf-8"))

    def end_headers(self):
        # Local kiosk app: lock it down rather than leaving defaults open.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s %s\n" % (self.log_date_time_string(), fmt % args))

    # --- routes -----------------------------------------------------------

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/api/health":
            return self._json(200, {
                "ok": True,
                "schema_version": SCHEMA_VERSION,
                "data_dir": str(self.store.root),
                "time": datetime.now(timezone.utc).isoformat(),
            })

        if path == "/api/training":
            # Live training telemetry for the dashboard. Reads the same log
            # and results files the training scripts write, so it cannot go
            # stale independently of them.
            if training_status is None:
                return self._json(503, {"error": "training_status module unavailable"})
            try:
                return self._json(200, training_status.snapshot())
            except Exception as e:
                return self._json(500, {"error": f"{type(e).__name__}: {e}"})

        if path == "/api/sessions":
            return self._json(200, {"sessions": self.store.listing()})

        # --- sample images -------------------------------------------------
        # samples/ sits at the project root, outside the static app dir, so
        # it needs an explicit route. Read-only, one directory, no traversal:
        # the name is matched against a strict pattern rather than joined.
        if path.startswith("/samples/"):
            name = path.split("/", 2)[2]
            if not re.fullmatch(r"[A-Za-z0-9._-]{1,120}", name) or name.startswith("."):
                return self._json(400, {"error": "bad sample name"})
            f = Path(__file__).resolve().parents[2] / "samples" / name
            if not f.is_file():
                return self._json(404, {"error": "no such sample"})
            body = f.read_bytes()
            ctype = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                     "tif": "image/tiff", "tiff": "image/tiff",
                     "md": "text/markdown; charset=utf-8"}.get(
                         f.suffix.lower().lstrip("."), "application/octet-stream")
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # --- agent -------------------------------------------------------
        if path == "/api/agent/info":
            from agent.llm import get_provider
            return self._json(200, {
                "available": AGENT_AVAILABLE,
                "agent_version": AGENT_VERSION,
                "import_error": _AGENT_IMPORT_ERROR,
                "llm": get_provider().describe() if AGENT_AVAILABLE else {},
                "tools": describe_registry() if AGENT_AVAILABLE else [],
                "slots": [{"id": i, "label": l, "required": r}
                          for i, l, r in SLOTS] if AGENT_AVAILABLE else [],
                "models": model_table() if AGENT_AVAILABLE else [],
            })

        if path.startswith("/api/agent/run/"):
            sid = path.split("/")[4]
            with _AGENT_LOCK:
                rec = _AGENT_RUNS.get(sid)
            if rec is None:
                # Maybe a previous run finished and was persisted.
                f = self.store.reports / sid / "agent_trace.json"
                if f.is_file():
                    try:
                        with open(f, encoding="utf-8") as fh:
                            return self._json(200, {"status": "done",
                                                    "trace": json.load(fh)})
                    except (OSError, json.JSONDecodeError) as e:
                        return self._json(500, {"error": str(e)})
                return self._json(404, {"status": "none", "session_id": sid})
            return self._json(200, {
                "status": rec["status"],
                "events": rec["events"],
                "trace": rec.get("trace"),
                "error": rec.get("error", ""),
            })

        # --- reports ---------------------------------------------------
        if path.startswith("/api/reports/"):
            parts = [x for x in path.split("/") if x]      # api reports <sid> [which]
            sid = parts[2]
            try:
                if len(parts) == 3:
                    st = self.store.report_status(sid)
                    if st is None:
                        return self._json(404, {"status": "none", "session_id": sid})
                    return self._json(200, st)

                if parts[3] == "bundle.zip":
                    blob = self.store.report_bundle(sid)
                    if blob is None:
                        return self._json(404, {"error": "report not ready"})
                    self.send_response(200)
                    self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Length", str(len(blob)))
                    self.send_header("Content-Disposition",
                                     f'attachment; filename="{sid}_ophira.zip"')
                    self.end_headers()
                    self.wfile.write(blob)
                    return

                which = parts[3].replace(".html", "")
                f = self.store.report_file(sid, which)
                if f is None:
                    return self._json(404, {"error": "report not ready"})
                body = f.read_bytes()
                dl = parse_qs(urlparse(self.path).query).get("download", ["0"])[0]
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                if dl == "1":
                    # A clinician needs a file they can keep, print or attach,
                    # not a tab they will lose.
                    self.send_header("Content-Disposition",
                                     f'attachment; filename="{sid}_{which}.html"')
                self.end_headers()
                self.wfile.write(body)
                return
            except (ValueError, IndexError) as e:
                return self._json(400, {"error": str(e)})

        if path.startswith("/api/jobs/"):
            jid = path.rsplit("/", 1)[-1]
            try:
                st = self.store.job_status(jid)
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            if st is None:
                return self._json(404, {"error": "no such job"})
            return self._json(200, st)

        if path.startswith("/api/sessions/"):
            sid = path.rsplit("/", 1)[-1]
            try:
                ctx = self.store.read(sid)
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            if ctx is None:
                return self._json(404, {"error": "not found"})
            return self._json(200, ctx)

        if path == "/":
            self.path = "/index.html"
        return super().do_GET()

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            ctx = self._body()
        except (ValueError, json.JSONDecodeError) as e:
            return self._json(400, {"error": f"bad request body: {e}"})

        if path == "/api/sessions":
            errs = validate(ctx, final=False)
            if errs:
                return self._json(422, {"errors": errs})
            sid = ctx.get("session", {}).get("session_id") or Store.new_id()
            ctx.setdefault("session", {})["session_id"] = sid
            try:
                self.store.write(sid, ctx)
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            return self._json(201, {"session_id": sid})

        if path.startswith("/api/sessions/") and path.endswith("/images"):
            sid = path.split("/")[3]
            try:
                slot    = str(ctx["slot_id"])
                attempt = int(ctx["attempt"])
                name    = str(ctx.get("filename", "capture.jpg"))
                blob    = base64.b64decode(ctx["data_base64"], validate=True)
            except (KeyError, ValueError, TypeError, binascii.Error) as e:
                return self._json(400, {"error": f"bad image payload: {e}"})

            if not blob:
                return self._json(400, {"error": "empty image"})

            ext = os.path.splitext(name)[1] or ".jpg"
            try:
                p = self.store.save_image(sid, slot, attempt, ext, blob)
            except ValueError as e:
                return self._json(400, {"error": str(e)})

            job_id = self.store.enqueue_quality(sid, slot, attempt, p)
            sys.stderr.write(
                f"  CAPTURE {sid} {slot} attempt={attempt} "
                f"{len(blob)//1024} KB -> job {job_id}\n")
            return self._json(202, {
                "image_path": str(p),
                "job_id": job_id,
                "slot_id": slot,
                "attempt": attempt,
            })

        if path == "/api/agent/upload":
            # Stores the ORIGINAL through the same immutable path the
            # encounter app uses, but does NOT enqueue a quality job: the
            # agent runs the gate itself as its first tool, and assessing
            # the same capture twice would put two verdicts in the record.
            if not AGENT_AVAILABLE:
                return self._json(503, {"error": "agent layer unavailable"})
            try:
                sid = str(ctx["session_id"])
                slot = str(ctx["slot_id"])
                attempt = int(ctx.get("attempt", 1))
                name = str(ctx.get("filename", "capture.jpg"))
                blob = base64.b64decode(ctx["data_base64"], validate=True)
            except (KeyError, ValueError, TypeError, binascii.Error) as e:
                return self._json(400, {"error": f"bad payload: {e}"})
            if not blob:
                return self._json(400, {"error": "empty image"})
            ext = os.path.splitext(name)[1] or ".jpg"
            try:
                fp = self.store.save_image(sid, slot, attempt, ext, blob)
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            return self._json(201, {"slot_id": slot, "path": str(fp),
                                    "bytes": len(blob)})

        if path == "/api/agent/run":
            if not AGENT_AVAILABLE:
                return self._json(503, {"error": "agent layer unavailable",
                                        "detail": _AGENT_IMPORT_ERROR})
            sid = str(ctx.get("session_id") or "").strip()
            if not SESSION_RE.match(sid):
                return self._json(400, {"error": f"invalid session id: {sid!r}"})

            # Either one image_path (kept for the tests and the CLI) or a
            # list of {slot, path} for a full four-field encounter.
            images = ctx.get("images")
            if not images:
                one = str(ctx.get("image_path") or "").strip()
                images = [{"slot": "image", "path": one}] if one else []
            clean = []
            for it in images:
                q = str(it.get("path", "")).strip()
                if not q or not Path(q).is_file():
                    return self._json(400, {"error": f"image not found: {q!r}"})
                clean.append({"slot": str(it.get("slot", "image")), "path": q})
            if not clean:
                return self._json(400, {"error": "no images supplied"})
            images = clean

            with _AGENT_LOCK:
                if sid in _AGENT_RUNS and _AGENT_RUNS[sid]["status"] == "running":
                    return self._json(409, {"error": "a run is already active",
                                            "session_id": sid})
                _AGENT_RUNS[sid] = {"status": "running", "events": []}

            root = self.store.root
            site = str(ctx.get("site") or "default")
            context = ctx.get("context") or None
            use_llm = bool(ctx.get("use_llm", True))

            def _work():
                rec = _AGENT_RUNS[sid]

                def on_event(e, slot="image"):
                    # Streamed to the UI by polling. Appending under the
                    # lock keeps the trace ordered.
                    with _AGENT_LOCK:
                        rec["events"].append({
                            "event": e.event, "at": e.at, "tool": e.tool,
                            "reason": e.reason, "detail": e.detail,
                            "source": e.source, "slot": slot,
                        })

                try:
                    case = AgentCase(session_id=sid, images=images,
                                     sessions_root=root, site=site,
                                     context=context, use_llm=use_llm,
                                     on_event=on_event)
                    summary = case.run()

                    # Per-capture traces, plus one summary for the encounter.
                    d = root / "reports" / sid
                    d.mkdir(parents=True, exist_ok=True)
                    for slot, r in case.runs:
                        r.save_trace()
                    tmp = d / "agent_trace.json.tmp"
                    with open(tmp, "w", encoding="utf-8") as fh:
                        json.dump(summary, fh, indent=2)
                    os.replace(tmp, d / "agent_trace.json")

                    with _AGENT_LOCK:
                        rec["trace"] = summary
                        rec["status"] = "done"
                except Exception as e:                    # pragma: no cover
                    with _AGENT_LOCK:
                        rec["status"] = "error"
                        rec["error"] = f"{type(e).__name__}: {e}"

            threading.Thread(target=_work, daemon=True).start()
            sys.stderr.write(f"  AGENT RUN {sid} on {len(images)} image(s)" + chr(10))
            return self._json(202, {"session_id": sid, "status": "running"})

        if path.startswith("/api/sessions/") and path.endswith("/submit"):
            sid = path.split("/")[3]
            errs = validate(ctx, final=True)
            if errs:
                return self._json(422, {"errors": errs})
            try:
                p = self.store.submit(sid, ctx)
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            urgent = bool(ctx.get("flags", {}).get("urgent"))

            # Submitting is what triggers analysis. Until this existed the
            # encounter app stopped at "record stored" and the documents the
            # system generates never reached anyone: no results screen, no
            # download, no way for a clinician to receive the report.
            imgs = self.store.accepted_images(sid)
            report_job = self.store.enqueue_report(sid, imgs)

            sys.stderr.write(
                f"  SUBMITTED {sid} patient={ctx['patient'].get('patient_id')} "
                f"urgent={urgent} images={len(imgs)} -> job {report_job}" + chr(10)
            )
            return self._json(200, {
                "session_id": sid, "stored": str(p), "urgent": urgent,
                "report_job": report_job, "images": len(imgs),
            })

        return self._json(404, {"error": "no such endpoint"})

    def do_PUT(self):
        path = urlparse(self.path).path
        if not path.startswith("/api/sessions/"):
            return self._json(404, {"error": "no such endpoint"})
        sid = path.rsplit("/", 1)[-1]
        try:
            ctx = self._body()
        except (ValueError, json.JSONDecodeError) as e:
            return self._json(400, {"error": f"bad request body: {e}"})

        errs = validate(ctx, final=False)
        if errs:
            return self._json(422, {"errors": errs})
        try:
            self.store.write(sid, ctx)
        except ValueError as e:
            return self._json(400, {"error": str(e)})
        return self._json(200, {"session_id": sid, "saved": True})


# --------------------------------------------------------------------------

def main():
    here = Path(__file__).resolve()
    project_root = here.parents[2]

    ap = argparse.ArgumentParser(description="OPHIRA session server")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--host", default="127.0.0.1",
                    help="use 0.0.0.0 to allow other devices on the local network")
    ap.add_argument("--data", default=str(project_root / "data" / "sessions"))
    ap.add_argument("--app", default=str(here.parents[1]))
    args = ap.parse_args()

    Handler.store = Store(Path(args.data).resolve())
    Handler.app_dir = Path(args.app).resolve()

    if not (Handler.app_dir / "index.html").is_file():
        sys.exit(f"ERROR: no index.html in {Handler.app_dir}")

    srv = ThreadingHTTPServer((args.host, args.port), Handler)

    cols = shutil.get_terminal_size((72, 20)).columns
    line = "=" * min(72, cols)
    print(line)
    print("  OPHIRA session server")
    print(line)
    print(f"  UI        http://{args.host}:{args.port}/")
    print(f"  app dir   {Handler.app_dir}")
    print(f"  sessions  {Handler.store.root}")
    print(f"  schema    {SCHEMA_VERSION}")
    print(line)
    print("  Ctrl-C to stop\n")

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  stopped")
        srv.server_close()


if __name__ == "__main__":
    main()
