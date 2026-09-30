"""The access key must actually gate the server.

    python tests/test_remote_access.py

Starts a real server twice -- once with a key, once without -- and tries to
get past it. This exists because the server was written as a LOCAL KIOSK:
its only client was the browser on the same machine, so it had no
authentication at all and did not need any. `run.py --tunnel` publishes it
on the internet, which makes that assumption false.

The second half matters as much as the first: with no key configured the
behaviour must be byte-for-byte what it always was, because that is the
path every other test and the on-site deployment still use.
"""
import http.cookiejar
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 8931
KEY = "test-key-do-not-ship"
B = f"http://127.0.0.1:{PORT}"

fails = 0


def check(name, cond, extra=""):
    global fails
    if not cond:
        fails += 1
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f"  {extra}" if extra else ""))


def get(path, key_header=None, jar=None, method="GET", body=None):
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar)) \
        if jar is not None else urllib.request.build_opener()
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(B + path, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    if key_header:
        r.add_header("X-Ophira-Key", key_header)
    try:
        with op.open(r, timeout=10) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


env = {**os.environ, "OPHIRA_KEY": KEY}
srv = subprocess.Popen(
    [sys.executable, os.path.join(ROOT, "app", "server", "ophira_server.py"),
     "--port", str(PORT)],
    cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

for _ in range(60):
    try:
        get("/api/health", key_header=KEY)
        break
    except Exception:
        time.sleep(0.25)

try:
    print("=== with a key configured ===")

    s, b, h = get("/api/health")
    check("no key  -> 401", s == 401, f"got {s}")
    check("401 body leaks nothing about the system",
          b"schema" not in b and b"session" not in b.lower()
          and b"retinopathy" not in b.lower())

    s, _, _ = get("/api/health", key_header="wrong-key-entirely")
    check("wrong key -> 401", s == 401, f"got {s}")

    s, _, _ = get("/api/sessions")
    check("session list is gated too", s == 401, f"got {s}")

    s, _, _ = get("/api/sessions", method="POST", body={"x": 1})
    check("POST is gated (do_POST guard)", s == 401, f"got {s}")

    s, _, _ = get("/api/sessions/S-FAKE", method="PUT", body={"x": 1})
    check("PUT is gated (do_PUT guard)", s == 401, f"got {s}")

    s, _, _ = get("/index.html")
    check("the UI itself is gated, not just the API", s == 401, f"got {s}")

    s, _, _ = get("/samples/sample_fundus_referral.png")
    check("sample images are gated", s == 401, f"got {s}")

    s, b, _ = get("/api/health", key_header=KEY)
    check("correct key in header -> 200", s == 200, f"got {s}")

    jar = http.cookiejar.CookieJar()
    s, b, h = get(f"/api/health?k={KEY}", jar=jar)
    check("correct key in ?k= -> 200", s == 200, f"got {s}")
    names = [c.name for c in jar]
    check("first keyed visit sets a cookie", "ophira_key" in names, str(names))
    sc = h.get("Set-Cookie", "")
    check("cookie is HttpOnly", "HttpOnly" in sc, sc[:60])
    check("cookie is SameSite=Lax", "SameSite=Lax" in sc)
    check("cookie is NOT Secure over plain http (would lock the client out)",
          "Secure" not in sc)
    check("keyed responses are not cacheable", "no-store" in h.get("Cache-Control", ""))

    s, _, _ = get("/api/health", jar=jar)
    check("cookie alone works on the next request (no ?k= needed)",
          s == 200, f"got {s}")

    # cloudflared terminates TLS and forwards the original scheme. When it
    # says https, the cookie must be Secure.
    r = urllib.request.Request(B + f"/api/health?k={KEY}")
    r.add_header("X-Forwarded-Proto", "https")
    with urllib.request.urlopen(r, timeout=10) as resp:
        sc2 = dict(resp.headers).get("Set-Cookie", "")
    check("behind an HTTPS proxy the cookie IS Secure", "Secure" in sc2, sc2[:70])
finally:
    srv.terminate()
    try:
        srv.wait(timeout=10)
    except subprocess.TimeoutExpired:
        srv.kill()

# ---- and the untouched default: no key configured => exactly as before ----
print("\n=== with NO key configured (the local kiosk default) ===")
srv = subprocess.Popen(
    [sys.executable, os.path.join(ROOT, "app", "server", "ophira_server.py"),
     "--port", str(PORT + 1)],
    cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
B = f"http://127.0.0.1:{PORT + 1}"
for _ in range(60):
    try:
        get("/api/health")
        break
    except Exception:
        time.sleep(0.25)
try:
    s, b, h = get("/api/health")
    check("open access still works unchanged", s == 200, f"got {s}")
    check("and still reports the schema", b"schema_version" in b)
    check("no cookie is set when no key is configured",
          "Set-Cookie" not in h)

    # STALENESS. The app files were served with Last-Modified and no
    # Cache-Control, so browsers applied heuristic caching and kept showing
    # a build of index.html from before the page had changed -- on a server
    # that was serving the new one correctly the whole time. Nothing on
    # either side reported a fault.
    s, b, h = get("/index.html")
    cc = h.get("Cache-Control", "")
    check("static pages carry an explicit caching directive", bool(cc),
          cc or "ABSENT -- browsers will guess, and guess wrong")
    check("that directive forces revalidation", "no-cache" in cc, cc)
    check("but does not forbid storing (revalidation must stay cheap)",
          "no-store" not in cc, cc)

    lm = h.get("Last-Modified", "")
    check("Last-Modified is present to revalidate against", bool(lm), lm)
    op = urllib.request.build_opener()
    r = urllib.request.Request(B + "/index.html")
    r.add_header("If-Modified-Since", lm)
    try:
        with op.open(r, timeout=10) as resp:
            code, n = resp.status, len(resp.read())
    except urllib.error.HTTPError as e:
        code, n = e.code, len(e.read())
    check("an unchanged file revalidates to 304 with no body",
          code == 304 and n == 0, f"status={code} bytes={n}")

    s, _, h = get("/api/health")
    check("API replies still carry exactly one Cache-Control",
          sum(1 for k in h if k.lower() == "cache-control") == 1
          or h.get("Cache-Control", "").count("no-store") == 1,
          h.get("Cache-Control", ""))
finally:
    srv.terminate()
    try:
        srv.wait(timeout=10)
    except subprocess.TimeoutExpired:
        srv.kill()

print(f"\n{'AUTH OK' if fails == 0 else f'{fails} CHECK(S) FAILED'}")
sys.exit(1 if fails else 0)
