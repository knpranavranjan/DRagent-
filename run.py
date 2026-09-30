#!/usr/bin/env python3
"""OPHIRA launcher — one command to run the whole system.

    python run.py              start everything and open the browser
    python run.py --check      check requirements only, start nothing
    python run.py --verify     run the full test suite, then stop
    python run.py --no-worker  frontend only (no grading; captures stay pending)
    python run.py --port 8080  use a different port
    python run.py --no-browser don't open a browser
    python run.py --tunnel     expose it on a public HTTPS URL (key-gated)

WHY A LAUNCHER AND NOT "JUST RUN THE SERVER"

The system is two processes that have to agree about one directory. The
Python server takes captures and writes job files; MATLAB picks those jobs
up, runs the models, and writes results back. Start only the server and the
encounter app looks alive but every capture sits at "analysing" forever --
which is exactly the failure an operator cannot diagnose.

So this checks both halves can actually run BEFORE starting either, and
says plainly which one is missing.

IT KILLS ONLY ITS OWN CHILDREN. Shutting down with `taskkill /IM MATLAB.exe`
also kills any unrelated MATLAB session -- a training run, an open desktop.
This tracks the PIDs it started and terminates those.
"""
from __future__ import annotations

import argparse
import glob
import os
import platform
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# Line-buffer stdout. Redirected to a file or a pipe, Python block-buffers,
# so "MATLAB worker starting..." was the last thing visible while the system
# came up fine behind it -- a launcher that looks hung when it is working.
try:
    sys.stdout.reconfigure(line_buffering=True)
except (AttributeError, ValueError):
    pass

# Models the CASCADE needs. Others in artifacts/models are controls and
# rejected hypotheses -- absent ones are not a problem.
REQUIRED_MODELS = [
    ("m1_teacher_aptos.mat", "DR grader (stage 2, deployed)"),
    ("m3_triage.mat", "triage filter (stage 1)"),
    ("m4_maculopathy.mat", "maculopathy head (stage 2b)"),
    ("m5_lesion_unet.mat", "lesion branch (stage 3)"),
    ("m7_calibration.mat", "temperature calibration"),
]

# m0b_quality_cnn.mat is DELIBERATELY ABSENT from this list.
#
# The master copy required it and the deployed system never loads it. The
# quality gate that runs at stage 0 is classical: assess.m calls
# extractFeatures.m and applyGate.m, and neither contains a model load.
# Demanding the file would block startup on something the pipeline does not
# use -- on a machine that legitimately will not carry it, because it is a
# training-time control rather than a deployed model.

# Colour only when a human is looking. Piping `python run.py > log` should
# produce a readable log, not a file full of escape codes.
if sys.stdout.isatty():
    if platform.system() == "Windows":
        os.system("")  # enable ANSI processing on cmd.exe
    G, Y, R, B, DIM, OFF = ("\033[32m", "\033[33m", "\033[31m",
                            "\033[36m", "\033[2m", "\033[0m")
else:
    G = Y = R = B = DIM = OFF = ""


def ok(msg, extra=""):
    print(f"  {G}OK{OFF}    {msg}" + (f"  {DIM}{extra}{OFF}" if extra else ""))


def warn(msg, extra=""):
    print(f"  {Y}WARN{OFF}  {msg}" + (f"\n        {DIM}{extra}{OFF}" if extra else ""))


def bad(msg, fix=""):
    print(f"  {R}FAIL{OFF}  {msg}" + (f"\n        {DIM}fix: {fix}{OFF}" if fix else ""))


def kill_on_exit_job():
    """A Windows job object that kills its children when this process dies.

    WHY THIS IS NOT OPTIONAL

    MATLAB is a grandchild: run.py starts matlab.exe, which starts its own
    worker process. If run.py is killed rather than interrupted -- closed
    terminal, Task Manager, a supervisor -- the Python cleanup never runs
    and MATLAB keeps draining the job queue invisibly.

    That is not a tidy-up nicety. A stale worker running OLD CODE raced a
    freshly started one on the same queue during development and kept
    winning, so fixes appeared not to work at all. Two graders disagreeing
    about which build they are is a bad failure in a clinical tool.

    A job object with KILL_ON_JOB_CLOSE ties their lifetime to this process
    at the OS level, so it holds however this process ends. Returns None on
    non-Windows, where terminate() on the process group is enough.
    """
    if platform.system() != "Windows":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        k32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class IO_COUNTERS(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class BASIC_LIMIT(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.POINTER(ctypes.c_ulong)),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD)]

        class EXT_LIMIT(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", BASIC_LIMIT),
                ("IoInfo", IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t)]

        k32.CreateJobObjectW.restype = wintypes.HANDLE
        job = k32.CreateJobObjectW(None, None)
        if not job:
            return None

        info = EXT_LIMIT()
        info.BasicLimitInformation.LimitFlags = 0x2000  # KILL_ON_JOB_CLOSE
        if not k32.SetInformationJobObject(
                job, 9, ctypes.byref(info), ctypes.sizeof(info)):
            return None
        return (job, k32)
    except Exception:
        return None


def adopt(job, proc):
    """Put a child in the job object, so it cannot outlive this process."""
    if not job:
        return
    handle, k32 = job
    try:
        import ctypes
        k32.AssignProcessToJobObject(handle, int(proc._handle))
    except Exception:
        pass  # best effort; Ctrl-C cleanup still applies


def find_matlab() -> str | None:
    """MATLAB on PATH, else the newest standard Windows install."""
    exe = shutil.which("matlab")
    if exe:
        return exe
    pats = [
        r"C:\Program Files\MATLAB\R*\bin\matlab.exe",
        r"C:\Program Files (x86)\MATLAB\R*\bin\matlab.exe",
        "/usr/local/MATLAB/R*/bin/matlab",
        "/Applications/MATLAB_R*.app/bin/matlab",
    ]
    hits: list[str] = []
    for p in pats:
        hits += glob.glob(p)
    return sorted(hits)[-1] if hits else None


KEY_FILE = ROOT / ".ophira_key"


def persistent_key() -> str:
    """The access key, reused across runs.

    A fresh random key every start is the safer default in the abstract,
    and in practice it meant the operator had to fetch a new link out of
    the terminal before every single session -- including from a phone
    that could not see the terminal. People work around that by writing
    the key somewhere worse.

    So it is generated once and kept in .ophira_key, which is gitignored.
    Delete that file to rotate it; the next run mints a new one and every
    old link stops working immediately.

    NOTE: this does not make the URL stable. A Cloudflare quick tunnel is
    assigned a random hostname on every run, whatever the key is. Only a
    named tunnel gives a fixed address -- DEPLOY_REMOTE.md has the steps.
    """
    try:
        existing = KEY_FILE.read_text(encoding="utf-8").strip()
        if len(existing) >= 16:
            return existing
    except OSError:
        pass
    fresh = secrets.token_urlsafe(24)
    try:
        KEY_FILE.write_text(fresh, encoding="utf-8")
        if platform.system() != "Windows":
            os.chmod(KEY_FILE, 0o600)
    except OSError as e:
        # Not fatal: the key still works for this run, it just will not
        # survive a restart. Say so rather than failing to start.
        warn(f"could not save the access key to {KEY_FILE.name}: {e}",
             "the link will change on the next run")
    return fresh


LINK_FILE = ROOT / "SHARE LINK.txt"


def write_link_file(public: str, key: str, port: int) -> Path | None:
    """Put the live link somewhere that is not terminal scrollback.

    The link existed only in the launcher's output, which meant finding it
    again was "scroll up in the black window" -- and if that window was
    closed, minimised behind others, or the link had scrolled past, the
    only way to get it back was to restart everything and issue a new one.

    Written fresh on every run and deleted on shutdown, because a file
    holding a dead link is worse than no file: it is the one someone
    copies and sends.
    """
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    body = (
        "OPHIRA - live share link\n"
        f"issued {stamp}  (valid only while the launcher window is open)\n"
        + ("=" * 58) + "\n\n"
        "Open this on any phone, tablet or laptop:\n\n"
        f"  {public}/?k={key}\n\n"
        "Agent view:\n\n"
        f"  {public}/agent.html?k={key}\n\n"
        "On this PC:\n\n"
        f"  http://127.0.0.1:{port}/?k={key}\n\n"
        + ("=" * 58) + "\n"
        "Copy the WHOLE line including the ?k= part -- that is the key,\n"
        "and without it the page answers 'Access key required'.\n\n"
        "Anyone holding this link has full access, so send it privately.\n\n"
        "This link dies when the launcher window closes, and the hostname\n"
        "is different every run. This file is deleted on shutdown so that\n"
        "a dead link is never left lying around to be copied.\n"
    )
    try:
        LINK_FILE.write_text(body, encoding="utf-8")
        return LINK_FILE
    except OSError:
        return None  # never worth failing a working deployment over


def find_cloudflared() -> str | None:
    """cloudflared on PATH, in tools/, or in the usual winget install spot."""
    exe = shutil.which("cloudflared")
    if exe:
        return exe
    local = ROOT / "tools" / ("cloudflared.exe" if platform.system() == "Windows"
                              else "cloudflared")
    if local.is_file():
        return str(local)
    hits = glob.glob(os.path.expandvars(
        r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\Cloudflare.cloudflared*"
        r"\cloudflared.exe"))
    return sorted(hits)[-1] if hits else None


TRYCF = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")


def start_tunnel(port: int, log: Path, job) -> tuple[subprocess.Popen, str] | None:
    """Open a Cloudflare quick tunnel to the local server.

    WHY A TUNNEL AND NOT PORT FORWARDING

    Forwarding a port puts this machine's IP on the public internet and
    needs a router change that outlives the demo. A tunnel is an OUTBOUND
    connection: nothing is opened on the network, it survives the address
    changing, and it stops existing when this process does.

    The URL is issued fresh each run and is not reserved. That is the cost
    of needing no account and no domain -- see DEPLOY_REMOTE.md for the
    named-tunnel upgrade if a stable address is wanted.
    """
    exe = find_cloudflared()
    if not exe:
        return None
    lf = open(log, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [exe, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{port}"],
        stdout=lf, stderr=subprocess.STDOUT)
    adopt(job, proc)

    # cloudflared prints the assigned hostname a second or two in, inside a
    # banner. Poll the log rather than the pipe: the pipe is already going
    # to a file so the whole run stays diagnosable after the fact.
    t0 = time.time()
    while time.time() - t0 < 45:
        if proc.poll() is not None:
            return None
        try:
            m = TRYCF.search(log.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            m = None
        if m:
            return proc, m.group(0)
        time.sleep(0.4)
    proc.terminate()
    return None


def port_free(host: str, port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.6)
        return s.connect_ex((host, port)) != 0


def preflight(port: int, host: str, want_worker: bool, needs_port: bool = True,
              want_tunnel: bool = False):
    """Returns (can_serve, matlab_path). Prints a verdict for every check."""
    print(f"\n{B}Requirements{OFF}")
    print("  " + "-" * 60)
    fatal = []

    # --- python ---------------------------------------------------------
    v = sys.version_info
    if v >= (3, 9):
        ok(f"Python {v.major}.{v.minor}.{v.micro}")
    else:
        bad(f"Python {v.major}.{v.minor} is too old (need 3.9+)",
            "install a newer Python and re-run")
        fatal.append("python")

    # --- project layout -------------------------------------------------
    needed = ["app/server/ophira_server.py", "app/index.html", "+ophira", "startup_ophira.m"]
    missing = [p for p in needed if not (ROOT / p).exists()]
    if missing:
        bad(f"not a complete OPHIRA checkout — missing {', '.join(missing)}",
            f"run this from the project root ({ROOT})")
        fatal.append("layout")
    else:
        ok("project layout", str(ROOT))

    # --- writable session store -----------------------------------------
    store = ROOT / "data" / "sessions"
    try:
        (store / "jobs" / "pending").mkdir(parents=True, exist_ok=True)
        probe = store / ".write_probe"
        probe.write_text("x", encoding="utf-8")
        probe.unlink()
        ok("session store writable", str(store))
    except OSError as e:
        bad(f"cannot write to {store}: {e}", "check permissions or disk space")
        fatal.append("store")

    # --- port ------------------------------------------------------------
    if not needs_port:
        warn(f"port {port} not checked", "this run starts no server")
    elif port_free(host, port):
        ok(f"port {port} is free")
    else:
        bad(f"port {port} is already in use",
            f"stop the other process, or run: python run.py --port {port + 1}")
        fatal.append("port")

    # --- MATLAB ----------------------------------------------------------
    matlab = find_matlab()
    if not want_worker:
        warn("MATLAB worker disabled (--no-worker)",
             "captures will be accepted but never graded")
    elif matlab:
        ok("MATLAB found", matlab)
    else:
        warn("MATLAB not found — starting the frontend only",
             "the encounter app will run, but every capture will sit at "
             "'analysing' forever because nothing grades it")

    # --- trained models ---------------------------------------------------
    mdir = ROOT / "artifacts" / "models"
    absent = [(f, d) for f, d in REQUIRED_MODELS if not (mdir / f).exists()]
    if not absent:
        ok(f"all {len(REQUIRED_MODELS)} cascade models present", str(mdir))
    else:
        for f, d in absent:
            bad(f"missing model {f} — {d}",
                "train it with the matching scripts/run_*.m, or restore artifacts/models")
        fatal.append("models")

    # --- tunnel ----------------------------------------------------------
    if want_tunnel:
        cf = find_cloudflared()
        if cf:
            ok("cloudflared found", cf)
        else:
            bad("cloudflared not installed — cannot open a tunnel",
                "winget install --id Cloudflare.cloudflared    "
                "(or drop cloudflared.exe in tools/)")
            fatal.append("cloudflared")

    print("  " + "-" * 60)
    return (not fatal), (matlab if want_worker else None)


def sample_image() -> str | None:
    """A fundus image to try the capture step with.

    The master copy looked this up in data/manifests/aptos_manifest.csv.
    That manifest is a training artefact and is not part of this
    deployment, so the hint comes from samples/ instead -- a folder whose
    whole purpose is to hold one image the operator can smoke-test with.
    """
    d = ROOT / "samples"
    if not d.is_dir():
        return None
    for f in sorted(d.iterdir()):
        # demo_* are degraded branch-demonstration inputs and one of them is
        # rejected by the gate on purpose. Offering one as "try this" hands
        # the operator an image that cannot pass, labelled as one that does.
        if f.name.startswith("demo_"):
            continue
        if f.suffix.lower() in {".png", ".jpg", ".jpeg", ".tif", ".tiff"}:
            return str(f)
    return None


def wait_for_http(url: str, timeout: float, key: str | None = None) -> bool:
    """Poll until the server answers.

    The key has to be sent. With authentication on, an unkeyed probe gets a
    valid 401 from a perfectly healthy server -- urlopen raises on that, so
    the launcher would report "server did not come up" about a server that
    had come up, every single tunnel run.
    """
    req = urllib.request.Request(url)
    if key:
        req.add_header("X-Ophira-Key", key)
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            with urllib.request.urlopen(req, timeout=1):
                return True
        except (urllib.error.URLError, OSError):
            time.sleep(0.3)
    return False


def wait_for_line(path: Path, needle: str, timeout: float) -> bool:
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if needle in path.read_text(encoding="utf-8", errors="replace"):
                return True
        except OSError:
            pass
        time.sleep(0.4)
    return False


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="run.py", description="Start the OPHIRA screening system.")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--no-worker", action="store_true",
                    help="frontend only; captures are stored but never graded")
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="check requirements and exit")
    ap.add_argument("--verify", action="store_true",
                    help="run the full test suite and exit")
    ap.add_argument("--tunnel", action="store_true",
                    help="publish a public HTTPS URL via Cloudflare. Always "
                         "key-gated; there is no unauthenticated tunnel.")
    ap.add_argument("--key", default=os.environ.get("OPHIRA_KEY") or None,
                    help="access key to use instead of the saved one in "
                         ".ophira_key")
    a = ap.parse_args()

    # A key is generated for --tunnel and cannot be turned off. Exposing a
    # screening tool that accepts fundus images to the open internet, with
    # no gate, is not a mode this launcher offers.
    key = (a.key or persistent_key()) if a.tunnel else a.key

    print(f"\n{B}OPHIRA{OFF}  diabetic retinopathy screening")
    print(f"{DIM}  {ROOT}{OFF}")

    # --verify starts no server, so a port already in use is irrelevant
    # to it. Blocking verification because the app happens to be
    # running was a launcher bug, not a real requirement.
    can_serve, matlab = preflight(a.port, a.host, not a.no_worker,
                                  needs_port=not a.verify,
                                  want_tunnel=a.tunnel)

    if a.check:
        print(f"\n{'ready to start' if can_serve else 'NOT ready — see FAIL lines above'}\n")
        return 0 if can_serve else 1

    if not can_serve:
        print(f"\n{R}Cannot start.{OFF} Fix the FAIL lines above, then re-run.\n")
        return 1

    if a.verify:
        if not matlab:
            print(f"\n{R}--verify needs MATLAB.{OFF}\n")
            return 1
        print(f"\n{B}Full verification{OFF}  (this takes a few minutes)\n")
        # run_99_verify_all belongs to the MASTER copy: it samples 50 APTOS
        # images through ophira.data.readManifest, so it needs the datasets
        # this deployment deliberately excludes. Running it here would fail
        # for the right reason and look like a broken deployment.
        #
        # run_deploy_verify covers what CAN be verified without datasets:
        # the unit and scenario suites, plus a real inference on a supplied
        # fundus image.
        return subprocess.call([matlab, "-batch", "startup_ophira; run_deploy_verify"],
                               cwd=str(ROOT))

    job = kill_on_exit_job()

    # A link file from a previous run holds a link that no longer works.
    # Shutdown removes it, but only on the Ctrl-C path -- killed from Task
    # Manager or lost to a power cut, it survives. Clear it now so a stale
    # one cannot sit next to a starting system looking current.
    try:
        LINK_FILE.unlink(missing_ok=True)
    except OSError:
        pass

    logs = ROOT / "artifacts" / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    srv_log, wrk_log = logs / "server.log", logs / "worker.log"
    children: list[tuple[str, subprocess.Popen]] = []

    print(f"\n{B}Starting{OFF}")
    print("  " + "-" * 60)

    # --- server ----------------------------------------------------------
    sf = open(srv_log, "w", encoding="utf-8")
    cmd = [sys.executable, str(ROOT / "app" / "server" / "ophira_server.py"),
           "--port", str(a.port), "--host", a.host]
    if key:
        # Through the environment, not argv. Command lines are readable by
        # any user on the box via the process list; the environment of
        # another user's process is not.
        cmd_env = {**os.environ, "OPHIRA_KEY": key}
    else:
        cmd_env = None
    p = subprocess.Popen(
        cmd, cwd=str(ROOT), stdout=sf, stderr=subprocess.STDOUT, env=cmd_env)
    adopt(job, p)
    children.append(("server", p))

    url = f"http://{a.host}:{a.port}"
    if wait_for_http(f"{url}/api/health", 20, key):
        ok("encounter server", url)
    else:
        bad("server did not come up", f"see {srv_log}")
        p.terminate()
        return 1

    # --- worker ----------------------------------------------------------
    if matlab:
        if wrk_log.exists():
            wrk_log.unlink()
        wf = open(wrk_log, "w", encoding="utf-8")
        w = subprocess.Popen(
            [matlab, "-batch", "startup_ophira; ophira.worker.run(PollSec=0.5)"],
            cwd=str(ROOT), stdout=wf, stderr=subprocess.STDOUT)
        adopt(job, w)
        children.append(("worker", w))
        print(f"  {DIM}...   MATLAB worker starting (loads toolboxes, ~30s){OFF}", flush=True)
        if wait_for_line(wrk_log, "Ctrl-C to stop", 180):
            ok("MATLAB worker", "grading live")
        else:
            warn("worker did not report ready in 180s",
                 f"it may still be loading — watch {wrk_log}")
    else:
        warn("no worker", "captures will not be graded")

    # --- tunnel ----------------------------------------------------------
    public = None
    if a.tunnel:
        cf_log = logs / "tunnel.log"
        print(f"  {DIM}...   opening Cloudflare tunnel{OFF}", flush=True)
        got = start_tunnel(a.port, cf_log, job)
        if got:
            tproc, public = got
            children.append(("tunnel", tproc))
            ok("public tunnel", public)
        else:
            warn("tunnel did not open — the system is running locally only",
                 f"see {cf_log}")

    print("  " + "-" * 60)

    if public:
        link = f"{public}/?k={key}"
        wrote = write_link_file(public, key, a.port)
        print(f"\n{G}Public link:{OFF}  {link}")
        print(f"{DIM}  agent UI    {public}/agent.html?k={key}{OFF}")
        print(f"{DIM}  Anyone with this link has full access. It is the "
              f"credential.{OFF}")
        print(f"{DIM}  The key is reused from .ophira_key — delete that "
              f"file to rotate it.{OFF}")
        print(f"{DIM}  The HOSTNAME still changes each run; see "
              f"DEPLOY_REMOTE.md for a fixed address.{OFF}")
        if wrote:
            print(f"\n{G}Also saved to:{OFF}  {wrote}")
            print(f"{DIM}  Open that file any time instead of scrolling "
                  f"back through this window.{OFF}")
        print(f"{DIM}  Closing this window closes the tunnel.{OFF}")

    print(f"\n{G}Open:{OFF}  {url}" + (f"/?k={key}" if key else ""))
    print(f"{DIM}  dashboard   {url}/dashboard.html"
          f"{f'?k={key}' if key else ''}{OFF}")
    print(f"{DIM}  logs        {srv_log.parent}{OFF}")
    if matlab:
        # Looked up in the manifest rather than hardcoded: the dataset lives
        # wherever the import put it, and a wrong path in a "try this" hint
        # is worse than no hint.
        img = sample_image()
        if img:
            print(f"{DIM}  test image  {img}{OFF}")
            print(f"{DIM}              (passes the quality gate -> REFERRAL){OFF}")
    print(f"\n{DIM}Ctrl-C to stop both processes.{OFF}\n")

    if not a.no_browser:
        webbrowser.open(f"{url}/?k={key}" if key else url)

    # --- run until interrupted -------------------------------------------
    try:
        while True:
            for name, proc in children:
                if proc.poll() is not None:
                    print(f"\n{R}{name} exited (code {proc.returncode}){OFF}")
                    raise KeyboardInterrupt
            time.sleep(1)
    except KeyboardInterrupt:
        print(f"\n{B}Stopping{OFF}")
        # Only the processes THIS script started. Killing by image name would
        # take down an unrelated MATLAB session -- a training run, an open
        # desktop -- which is a mistake that is easy to make and hard to undo.
        for name, proc in reversed(children):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
            print(f"  stopped {name}")
        # The link in it is dead now. Leaving the file behind means someone
        # copies yesterday's link out of it and cannot work out why the page
        # will not load.
        try:
            LINK_FILE.unlink(missing_ok=True)
        except OSError:
            pass
        print()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
