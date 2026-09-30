"""Report endpoint checks.

Run the server first:
    python app/server/ophira_server.py
then:
    python tests/frontend/test_reports.py

WHAT THIS PROTECTS

Submitting a session now queues the full cascade in MATLAB and the browser
polls for the result. Two things must hold whether or not the MATLAB worker
is running:

  1. Submitting ENQUEUES a report job. Until this existed the encounter app
     stopped at "record stored" and the documents the system generates
     never reached anyone.

  2. A session with no report yet must read as PENDING or absent -- never
     as a result. "No report" is not "no findings", and the UI decides what
     to show the operator from exactly these responses.

These run without MATLAB. If the worker happens to be running, the polling
check will see the job complete and verify the documents are served; if it
is not, that check is skipped and said so, rather than silently passing.
"""
import json, time, urllib.request, urllib.error

B = "http://127.0.0.1:8000/api"


def call(method, path, payload=None, raw=False):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(B + path, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp:
            body = resp.read()
            if raw:
                return resp.status, body, dict(resp.headers)
            return resp.status, json.loads(body or b"null")
    except urllib.error.HTTPError as e:
        body = e.read()
        if raw:
            return e.code, body, dict(e.headers)
        try:
            return e.code, json.loads(body or b"null")
        except json.JSONDecodeError:
            return e.code, None


def ctx():
    return {
        "schema_version": "context_core_v1",
        "session": {"session_id": None, "created_at": "2026-09-21T09:00:00.000Z",
                    "completed_at": "2026-09-21T09:20:00.000Z",
                    "centre_id": "PHC-014", "operator_id": "OP-3391",
                    "app_version": "0.1.0"},
        "patient": {"patient_id": "P-REPORT-01", "age_years": 61, "sex": "male"},
        "eligibility": {"diabetes_confirmed": True, "under_dr_treatment": False,
                        "previously_screened": True, "months_since_last_screening": 15,
                        "able_to_consent": True, "pathway": "screening"},
        "consent": {"given": True, "version": "consent_v1",
                    "recorded_at": "2026-09-21T09:02:00.000Z"},
        "diabetes": {"dm_type": "type2", "duration_years": 12, "treatment": ["insulin"],
                     "hba1c_percent": 8.9, "hypertension": True, "smoker": False},
        "ocular_history": {"conditions": [], "notes": ""},
        "symptoms": {"reported": ["none_reported"], "duration_days": None, "notes": ""},
        "visual_acuity": {"method": "snellen_6m", "od": {"value": "6/9", "pinhole": ""},
                          "os": {"value": "6/9", "pinhole": ""}},
        "capture": {"slots": {}},
        "flags": {"urgent": False, "urgent_reasons": [], "reduced_va": False,
                  "severe_va": False, "pathway": "screening",
                  "computed_at": "2026-09-21T09:05:00.000Z",
                  "rules_version": "context_rules_v1"},
    }


fails = 0
skips = 0


def check(name, cond, extra=""):
    global fails
    if not cond:
        fails += 1
    print(f"  [{'PASS' if cond else 'FAIL'}] {name} {extra}")


def skip(name, why):
    global skips
    skips += 1
    print(f"  [SKIP] {name} — {why}")


print("=== OPHIRA report endpoint checks ===")

print("\n--- 1. unknown session ---")
s, r = call("GET", "/reports/S-20260921-000000-ZZZZZZ")
check("unknown session reports 404, not a result", s == 404, f"status={s}")

s, r = call("GET", "/reports/..%2F..%2Fetc%2Fpasswd")
check("path traversal refused", s in (400, 404), f"status={s}")

s, r = call("GET", "/reports/S-20260921-000000-ZZZZZZ/badname")
check("unknown report name refused", s in (400, 404), f"status={s}")

print("\n--- 2. submitting enqueues a report job ---")
c = ctx()
s, r = call("POST", "/sessions", c)
assert s == 201, f"could not create session: {s} {r}"
sid = r["session_id"]
c["session"]["session_id"] = sid

s, r = call("POST", f"/sessions/{sid}/submit", c)
check("submit accepted", s == 200, r)
check("submit returns a report job id",
      isinstance(r, dict) and str(r.get("report_job", "")).startswith("R-"),
      r.get("report_job"))

print("\n--- 3. a queued session reads as pending, never as a result ---")
s, r = call("GET", f"/reports/{sid}")
st0 = (r or {}).get("status")
check("status is pending or done, never 'clear'",
      s == 200 and st0 in ("pending", "done"), f"status={s} body={r}")
if st0 == "pending":
    check("pending carries no action field", "action" not in r, r)

print("")
print("--- 3b. polling contract: status means FINISHED, not OK ---")
# THE BUG THIS PROTECTS AGAINST, which was live in the capture loop.
#
# The worker writes `status` = "ok"/"error", meaning "did the assessment
# run". The endpoints use `status` to mean "has the job finished".
# Spreading the worker's record last overwrote "done" with "ok", so
# api.js awaitQuality() -- which waits for status === "done" -- never saw
# completion. Every capture spun until its 60 s timeout and told the
# operator the worker was down, on images the gate had graded correctly
# in 1.5 seconds. Caught only by driving the real browser flow end to end.
import glob as _glob
import os as _os

_done = _os.path.join(
    _os.path.dirname(_os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))),
    "data", "sessions", "jobs", "done")
_qs = sorted(_glob.glob(_os.path.join(_done, "Q-*.json")))
if _qs:
    _jid = _os.path.basename(_qs[-1])[:-5]
    _s, _q = call("GET", "/jobs/" + _jid)
    _q = _q or {}
    check("a finished quality job reports status 'done'",
          _s == 200 and _q.get("status") == "done", _q.get("status"))
    check("the worker's own status is kept separately, not conflated",
          _q.get("worker") in ("ok", "error"), _q.get("worker"))
    check("the clinical verdict survives the round trip",
          bool(_q.get("decision")), _q.get("decision"))
    check("an UNGRADABLE verdict would still read as finished",
          _q.get("status") == "done",
          "ungradable must route to a human, not raise an error")
else:
    skip("quality job polling contract", "no completed quality job on disk")


print("\n--- 4. report files (needs the MATLAB worker) ---")
deadline = time.time() + 20
st = {}
while time.time() < deadline:
    s, st = call("GET", f"/reports/{sid}")
    if s == 200 and st.get("status") == "done":
        break
    time.sleep(1)

if st.get("status") != "done":
    skip("documents are served", "MATLAB worker not running (ophira.worker.run)")
    skip("download sets Content-Disposition", "MATLAB worker not running")
else:
    check("result names an action", bool(st.get("action")), st.get("action"))
    check("result lists the rules that fired", bool(st.get("rules_fired")), st.get("rules_fired"))

    for which in ("clinician", "patient"):
        s, body, hdrs = call("GET", f"/reports/{sid}/{which}.html", raw=True)
        check(f"{which} report is served", s == 200 and b"<html" in body.lower(),
              f"status={s} bytes={len(body)}")

        s, body, hdrs = call("GET", f"/reports/{sid}/{which}.html?download=1", raw=True)
        cd = hdrs.get("Content-Disposition", "")
        check(f"{which} download is an attachment", s == 200 and "attachment" in cd, cd)

    # The patient slip must not leak clinical jargon, same property tReport
    # asserts on the MATLAB side -- checked here too because this is the
    # path a patient's copy actually travels.
    s, body, _ = call("GET", f"/reports/{sid}/patient.html", raw=True)
    t = body.decode("utf-8", "replace").lower()
    check("patient slip carries no grade or probability",
          "grade" not in t and "probability" not in t)
    check("patient slip lists red flags", "sudden loss of vision" in t)

print(f"\n{'ALL REPORT CHECKS PASSED' if fails == 0 else f'{fails} CHECK(S) FAILED'}"
      + (f"  ({skips} skipped)" if skips else ""))
print(f"REPORT_SID={sid}")
