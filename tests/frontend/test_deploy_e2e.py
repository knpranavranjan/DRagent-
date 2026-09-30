"""End-to-end test for the DRagent deployment package.

    python run.py                          # terminal 1 (server + worker)
    python tests/frontend/test_deploy_e2e.py

Drives the real HTTP API the browser uses, with the fundus image in
samples/, and checks that a complete encounter produces both documents.

WHY THIS EXISTS SEPARATELY FROM THE MASTER'S TESTS

The master copy's end-to-end tests pick their image out of
data/manifests/aptos_manifest.csv and pre-screen candidates through the
quality gate. Neither the manifest nor the candidate pool ships with this
deployment, so those tests cannot run here. This one uses the single image
in samples/ and nothing else.

It asserts the things a deployment can get wrong: that the queue is picked
up, that a real grade comes back, that the documents are served and
downloadable, and that the patient slip still carries no clinical jargon.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

# Defaults to the local kiosk. Point it at a tunnel to verify that a REMOTE
# deployment really grades images, rather than assuming that because it
# works on the machine it is running on, it works through the tunnel:
#
#   OPHIRA_BASE=https://xyz.trycloudflare.com OPHIRA_KEY=<key> #       python tests/frontend/test_deploy_e2e.py
#
# The difference is not cosmetic. A tunnel adds TLS termination, a proxy
# that rewrites headers, and a request timeout -- and the image upload is
# a multi-megabyte base64 POST, which is exactly the shape of request an
# intermediary is most likely to cut off.
ORIGIN = os.environ.get("OPHIRA_BASE", "http://127.0.0.1:8000").rstrip("/")
KEY = os.environ.get("OPHIRA_KEY", "")
B = ORIGIN + "/api"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

fails = 0


def check(name, cond, extra=""):
    global fails
    if not cond:
        fails += 1
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f"  {extra}" if extra else ""))


def call(method, path, payload=None, raw=False):
    data = json.dumps(payload).encode() if payload is not None else None
    hdrs = {"Content-Type": "application/json"}
    if KEY:
        hdrs["X-Ophira-Key"] = KEY
    r = urllib.request.Request(B + path, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(r, timeout=120 if KEY else 30) as resp:
            body = resp.read()
            return (resp.status, body, dict(resp.headers)) if raw else \
                   (resp.status, json.loads(body or b"null"))
    except urllib.error.HTTPError as e:
        body = e.read()
        if raw:
            return e.code, body, dict(e.headers)
        try:
            return e.code, json.loads(body or b"null")
        except json.JSONDecodeError:
            return e.code, None


def sample():
    d = os.path.join(ROOT, "samples")
    if not os.path.isdir(d):
        return None
    # demo_* files are deliberately degraded branch-demonstration inputs;
    # one is rejected by the gate on purpose. Skip them here.
    for f in sorted(os.listdir(d)):
        if f.startswith("demo_"):
            continue
        if os.path.splitext(f)[1].lower() in (".png", ".jpg", ".jpeg", ".tif", ".tiff"):
            return os.path.join(d, f)
    return None


def ctx(pid="P-DEPLOY-01"):
    now = "2026-09-30T09:00:00.000Z"
    return {
        "schema_version": "context_core_v1",
        "session": {"session_id": None, "created_at": now, "completed_at": now,
                    "centre_id": "PHC-DEPLOY", "operator_id": "OP-01",
                    "app_version": "0.1.0"},
        "patient": {"patient_id": pid, "age_years": 60, "sex": "female"},
        "eligibility": {"diabetes_confirmed": True, "under_dr_treatment": False,
                        "previously_screened": True, "months_since_last_screening": 14,
                        "able_to_consent": True, "pathway": "screening"},
        "consent": {"given": True, "version": "consent_v1", "recorded_at": now},
        "diabetes": {"dm_type": "type2", "duration_years": 11, "treatment": ["insulin"],
                     "hba1c_percent": 8.2, "hypertension": True, "smoker": False},
        "ocular_history": {"conditions": [], "notes": ""},
        "symptoms": {"reported": ["none_reported"], "duration_days": None, "notes": ""},
        "visual_acuity": {"method": "snellen_6m",
                          "od": {"value": "6/9", "pinhole": ""},
                          "os": {"value": "6/9", "pinhole": ""}},
        "capture": {"slots": {}},
        "flags": {"urgent": False, "urgent_reasons": [], "reduced_va": False,
                  "severe_va": False, "pathway": "screening", "computed_at": now,
                  "rules_version": "context_rules_v1"},
    }


print("=== DRagent deployment end-to-end ===")
print(f"  root: {ROOT}")
print(f"  host: {ORIGIN}" + ("  (keyed)" if KEY else "  (no key)"))

s, h = call("GET", "/health")
if s != 200:
    print("\n  Server is not running. Start it with:  python run.py\n")
    sys.exit(1)
print(f"  server: up, schema {h['schema_version']}")

img = sample()
if not img:
    print("\n  [SKIP] no image in samples/ — cannot run the pipeline\n")
    sys.exit(0)
print(f"  image : {os.path.basename(img)}")

c = ctx()
s, r = call("POST", "/sessions", c)
check("session created", s == 201, f"status={s}")
sid = (r or {}).get("session_id")
if not sid:
    sys.exit(1)
c["session"]["session_id"] = sid

print("\n--- capture -> quality gate (MATLAB) ---")
with open(img, "rb") as f:
    blob = base64.b64encode(f.read()).decode()
s, r = call("POST", f"/sessions/{sid}/images",
            {"slot_id": "od_macula", "attempt": 1,
             "filename": os.path.basename(img), "data_base64": blob})
check("capture accepted", s == 202, f"status={s}")
job = (r or {}).get("job_id")

verdict = None
t0 = time.time()
while job and time.time() - t0 < 120:
    s, q = call("GET", f"/jobs/{job}")
    if (q or {}).get("status") == "done":
        verdict = q
        break
    time.sleep(0.5)
check("quality gate returned a verdict", verdict is not None,
      f"{verdict['decision']} score {verdict['score']:.3f}" if verdict else "timeout")

print("\n--- submit -> cascade ---")
s, r = call("POST", f"/sessions/{sid}/submit", c)
check("submit accepted", s == 200, f"status={s}")
check("report job queued", str((r or {}).get("report_job", "")).startswith("R-"))

st = {}
t0 = time.time()
while time.time() - t0 < 300:
    s, st = call("GET", f"/reports/{sid}")
    if s == 200 and (st or {}).get("status") == "done":
        break
    time.sleep(1)

check("report completed", (st or {}).get("status") == "done", (st or {}).get("status"))
if (st or {}).get("status") != "done":
    print(f"\n{fails} CHECK(S) FAILED")
    sys.exit(1)

print(f"      action : {st.get('action')}")
print(f"      rules  : {', '.join(st.get('rules_fired', []))}")
for pi in st.get("per_image", []):
    print(f"      {pi.get('image')}: {pi.get('action')} "
          f"({pi.get('stages')} stages, {pi.get('ms')} ms)")

check("an action was decided", bool(st.get("action")), st.get("action"))
check("the rules that fired are recorded", bool(st.get("rules_fired")))
# A RECAPTURE means the gate rejected the image and no model ran.
acts = [p.get("action") for p in st.get("per_image", [])]
check("the image reached the models", bool(acts) and all(a != "RECAPTURE" for a in acts), acts)

print("\n--- documents ---")
for which in ("clinician", "patient"):
    s, body, hdrs = call("GET", f"/reports/{sid}/{which}.html", raw=True)
    check(f"{which} served", s == 200 and b"<html" in body.lower(),
          f"{len(body)} bytes")
    s, body, hdrs = call("GET", f"/reports/{sid}/{which}.html?download=1", raw=True)
    check(f"{which} downloads as a file",
          "attachment" in hdrs.get("Content-Disposition", ""))

s, body, _ = call("GET", f"/reports/{sid}/clinician.html", raw=True)
t = body.decode("utf-8", "replace")
check("clinician report embeds the image panels",
      t.count("data:image/jpeg;base64") >= 3, f"{t.count('data:image/jpeg;base64')} panels")
check("Grad-CAM is labelled as attention, not lesions",
      "attention, not lesions" in t.lower())
check("calibration status is stated", "calibrat" in t.lower())
check("limitations are present", "Limitations" in t)
check("printable (PDF) support", "window.print()" in t and "@page{size:A4" in t)

s, body, _ = call("GET", f"/reports/{sid}/patient.html", raw=True)
t = body.decode("utf-8", "replace").lower()
check("patient slip carries no grade", "grade" not in t)
check("patient slip lists red flags", "sudden loss of vision" in t)

s, body, hdrs = call("GET", f"/reports/{sid}/bundle.zip", raw=True)
check("bundle downloads", s == 200 and body[:2] == b"PK", f"{len(body)} bytes")

print(f"\n{'DEPLOYMENT E2E PASSED' if fails == 0 else f'{fails} CHECK(S) FAILED'}")
print(f"SID={sid}")
sys.exit(1 if fails else 0)
