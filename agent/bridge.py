"""Python -> MATLAB tool bridge, over the queue the system already uses.

The deployment's two processes talk through `data/sessions/jobs/`. The
agent does not change that: it writes a `T-*.json` tool job and waits for
the matching result, exactly as the encounter app does for captures.

WHY NOT MATLAB ENGINE FOR PYTHON
--------------------------------
It would be faster per call. It would also put a second, differently
configured MATLAB inside the web server process, and replace a mechanism
that already survives either side dying with one that does not. The
verified baseline uses the queue; the agent layer is not the place to
rewrite it.

The cost is real and measured, not hidden: roughly 0.3 s of polling
latency per tool call. `agent.orchestrator` reports it separately from
tool execution time so the overhead is visible rather than absorbed.
"""
from __future__ import annotations

import json
import os
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class WorkerUnavailable(RuntimeError):
    """The MATLAB worker did not answer. NEVER a clinical result."""


class MatlabToolBridge:
    def __init__(self, sessions_root: Path, poll: float = 0.15,
                 timeout: float = 300.0):
        self.pending = Path(sessions_root) / "jobs" / "pending"
        self.done = Path(sessions_root) / "jobs" / "done"
        self.pending.mkdir(parents=True, exist_ok=True)
        self.done.mkdir(parents=True, exist_ok=True)
        self.poll = poll
        self.timeout = timeout
        self.queue_wait_ms = 0.0   # cumulative, reported as agent overhead

    def worker_alive(self, probe_timeout: float = 20.0) -> bool:
        """Is anything draining the queue? Asked before a case starts.

        A case that begins with no worker would stall on its first tool and
        look like a hung agent rather than a missing dependency.
        """
        try:
            self.call("assess_image_quality",
                      {"image_path": "__probe__"}, timeout=probe_timeout)
        except WorkerUnavailable:
            return False
        except Exception:
            # The tool errored, which means a worker ran it. That is the
            # answer we wanted.
            return True
        return True

    def call(self, tool: str, args: dict[str, Any],
             timeout: float | None = None) -> dict[str, Any]:
        job_id = ("T-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
                  + "-" + secrets.token_hex(3).upper())
        job = {
            "job_id": job_id,
            "kind": "tool",
            "tool": tool,
            "args": args,
            "queued_at": datetime.now(timezone.utc).isoformat(),
        }
        tmp = self.pending / f"{job_id}.json.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(job, f, indent=2)
        os.replace(tmp, self.pending / f"{job_id}.json")

        out = self.done / f"{job_id}.json"
        deadline = time.time() + (timeout or self.timeout)
        t0 = time.time()
        while time.time() < deadline:
            if out.is_file():
                self.queue_wait_ms += (time.time() - t0) * 1000
                for _ in range(20):          # the writer moves it into place
                    try:
                        with open(out, encoding="utf-8") as f:
                            return json.load(f)
                    except (json.JSONDecodeError, OSError):
                        time.sleep(0.05)
                raise WorkerUnavailable(f"Result for {job_id} was unreadable.")
            time.sleep(self.poll)

        # Leave the job in place: a worker that starts later will still run
        # it, and the file is the evidence of what was asked for.
        raise WorkerUnavailable(
            f"No response from the MATLAB worker for {tool} within "
            f"{timeout or self.timeout:.0f}s. Start it with "
            f"ophira.worker.run() — no result is being invented."
        )
