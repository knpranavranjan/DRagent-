import json, urllib.request, urllib.error
B = "http://127.0.0.1:8000/api"

def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(B+path, data=data, method=method,
                               headers={"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")

def ctx(**over):
    c = {
      "schema_version":"context_core_v1",
      "session":{"session_id":None,"created_at":"2026-09-20T13:00:00.000Z","completed_at":None,
                 "centre_id":"PHC-014","operator_id":"OP-3391","app_version":"0.1.0"},
      "patient":{"patient_id":"P-2026-00471","age_years":54,"sex":"female"},
      "eligibility":{"diabetes_confirmed":True,"under_dr_treatment":False,"previously_screened":True,
                     "months_since_last_screening":18,"able_to_consent":True,"pathway":"screening"},
      "consent":{"given":True,"version":"consent_v1","recorded_at":"2026-09-20T13:02:00.000Z"},
      "diabetes":{"dm_type":"type2","duration_years":8,"treatment":["oral"],
                  "hba1c_percent":7.8,"hypertension":True,"smoker":False},
      "ocular_history":{"conditions":[],"notes":""},
      "symptoms":{"reported":["none_reported"],"duration_days":None,"notes":""},
      "visual_acuity":{"method":"snellen_6m","od":{"value":"6/9","pinhole":""},
                       "os":{"value":"6/12","pinhole":""}},
      "capture":{"slots":{}},
      "flags":{"urgent":False,"urgent_reasons":[],"reduced_va":False,"severe_va":False,
               "pathway":"screening","computed_at":"2026-09-20T13:05:00.000Z",
               "rules_version":"context_rules_v1"}
    }
    for k,v in over.items(): c[k] = v
    return c

fails = 0
def check(name, cond, extra=""):
    global fails
    print(f"  [{'PASS' if cond else 'FAIL'}] {name} {extra}")
    if not cond: fails += 1

print("--- 1. routine session lifecycle ---")
s, r = call("POST","/sessions", ctx())
check("create returns 201 + id", s==201 and r["session_id"].startswith("S-"), r)
sid = r["session_id"]

c = ctx(); c["session"]["session_id"] = sid
s, r = call("PUT", f"/sessions/{sid}", c)
check("draft save 200", s==200)

c["session"]["completed_at"] = "2026-09-20T13:10:00.000Z"
s, r = call("POST", f"/sessions/{sid}/submit", c)
check("submit 200, not urgent", s==200 and r["urgent"] is False, r)

s, r = call("GET", f"/sessions/{sid}")
check("read back after submit", s==200 and r["patient"]["patient_id"]=="P-2026-00471")

print("\n--- 2. SAFETY: consent gate ---")
c2 = ctx(); c2["session"]["session_id"]=sid+"X"
s, r = call("POST","/sessions", c2); sid2 = r["session_id"]
c2["session"]["session_id"]=sid2
c2["session"]["completed_at"]="2026-09-20T13:10:00.000Z"
c2["consent"]["given"]=False
s, r = call("POST", f"/sessions/{sid2}/submit", c2)
check("submit WITHOUT consent is refused 422", s==422, r)
check("  reason names consent", any("consent" in e for e in r.get("errors",[])))

print("\n--- 3. SAFETY: urgent session ---")
c3 = ctx()
c3["symptoms"]["reported"]=["sudden_vision_loss"]
c3["visual_acuity"]["od"]["value"]="6/60"
c3["flags"]={"urgent":True,
             "urgent_reasons":[{"code":"symptom:sudden_vision_loss","text":"Sudden loss of vision"},
                               {"code":"va:severe","text":"Severely reduced acuity in the right eye (6/60)"}],
             "reduced_va":True,"severe_va":True,"pathway":"screening",
             "computed_at":"2026-09-20T13:05:00.000Z","rules_version":"context_rules_v1"}
s, r = call("POST","/sessions", c3); sid3 = r["session_id"]
c3["session"]["session_id"]=sid3
c3["session"]["completed_at"]="2026-09-20T13:12:00.000Z"
s, r = call("POST", f"/sessions/{sid3}/submit", c3)
check("urgent session submits and is flagged", s==200 and r["urgent"] is True, r)

print("\n--- 4. malformed input ---")
s, r = call("POST","/sessions", {"schema_version":"wrong_version"})
check("bad schema_version refused 422", s==422, r)
s, r = call("GET","/sessions/../../etc/passwd")
check("path traversal refused", s in (400,404), f"status={s}")
s, r = call("POST","/sessions", {"schema_version":"context_core_v1"})
check("missing blocks refused 422", s==422)

print("\n--- 5. listing ---")
s, r = call("GET","/sessions")
sessions = r["sessions"]
check("listing returns sessions", s==200 and len(sessions)>=3, f"n={len(sessions)}")
check("listing surfaces urgent flag", any(x["urgent"] for x in sessions))

print(f"\n{'ALL API CHECKS PASSED' if fails==0 else f'{fails} CHECK(S) FAILED'}")
print(f"URGENT_SID={sid3}")
print(f"ROUTINE_SID={sid}")
