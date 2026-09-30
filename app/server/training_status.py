"""Live training status for the dashboard.

Reads the same files the training scripts write -- artifacts/results.csv and
artifacts/*.log -- rather than keeping any state of its own. If MATLAB dies,
the dashboard reflects that immediately instead of showing a stale cache.
"""

import csv
import re
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "artifacts"
RESULTS = ARTIFACTS / "results.csv"

# Log file -> (display name, total epochs). Newest-modified wins.
RUNS = {
    "c2_pretrain.log":   ("C2 — M1 pretrain on EyePACS", 12),
    "c3_finetune.log":   ("C3 — M1 fine-tune on APTOS (3 seeds)", 20),
    "c4_distill.log":    ("C4 — M2 student distillation", 20),
    "c5_triage.log":     ("C5 — M3 triage filter", 15),
    "b4_m5_v2.log":      ("M5 — lesion branch", 60),
    "b2_maculopathy.log":("M4 — maculopathy", 30),
    "b3_m0b.log":        ("M0b — quality CNN", 40),
    "c1_eyepacs_prep.log": ("C1 — EyePACS preparation", None),
}

GATES = {"auc", "auc_referable", "qwk", "dice_EX", "dice_HE",
         "dice_MA", "dice_SE", "sens_referable", "ece"}


def _gpu():
    try:
        out = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5).stdout.strip()
        u, mu, mt, t = [x.strip() for x in out.split(",")]
        return {"util": int(u), "mem_used": int(mu), "mem_total": int(mt), "temp": int(t)}
    except Exception:
        return None


def _matlab_running():
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq MATLAB.exe"],
                             capture_output=True, text=True, timeout=5).stdout
        return "MATLAB.exe" in out
    except Exception:
        return False


def _active_run():
    """Most recently modified known log, plus whatever progress it reports."""
    newest, newest_t = None, 0
    for fname in RUNS:
        p = ARTIFACTS / fname
        if p.is_file() and p.stat().st_mtime > newest_t:
            newest, newest_t = fname, p.stat().st_mtime

    if newest is None:
        return {"active": False}, []

    name, total_epochs = RUNS[newest]
    path = ARTIFACTS / newest
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        lines = []

    tail = [l for l in lines if l.strip()][-14:]

    epoch = elapsed = None
    it = it_total = None
    for l in reversed(lines):
        # "EPOCH  3 | ..." or "epoch  3 | ..." or "  ep 1 iter 400/1317 ... (12.1 min)"
        m = re.search(r"^\s*(?:EPOCH|epoch)\s+(\d+)", l)
        if m and epoch is None:
            epoch = int(m.group(1))
        m2 = re.search(r"\bep\s+(\d+)\s+iter\s+(\d+)/\s*(\d+)", l)
        if m2:
            if epoch is None:
                epoch = int(m2.group(1))
            if it is None:
                it, it_total = int(m2.group(2)), int(m2.group(3))
        m3 = re.search(r"\(([\d.]+)\s*min\)", l)
        if m3 and elapsed is None:
            elapsed = float(m3.group(1))
        if epoch is not None and elapsed is not None and it is not None:
            break

    # Stale if nothing has been written for 10 minutes and MATLAB is gone.
    idle_s = time.time() - newest_t
    active = _matlab_running() and idle_s < 600

    # ETA from FRACTIONAL epochs. Using whole epochs makes the estimate wildly
    # wrong early on: 3.6 min into epoch 1 of 12 reads as "3.6 min per epoch"
    # and predicts 40 minutes for a job that takes hours.
    eta = None
    progress = None
    if epoch and total_epochs:
        frac = ((epoch - 1) + (it / it_total if it and it_total else 0)) / total_epochs
        progress = min(1.0, max(0.0, frac))
        if active and elapsed and progress > 0.01:
            eta = max(0.0, elapsed * (1 - progress) / progress)

    return {
        "active": active,
        "name": name,
        "log": newest,
        "epoch": epoch,
        "epochs": total_epochs,
        "elapsed_min": elapsed,
        "eta_min": eta,
        "progress": progress,
        "iter": it, "iter_total": it_total,
        "stage": f"log idle {idle_s/60:.1f} min" if idle_s > 60 else "running",
    }, tail


def _results():
    """Latest value per (model, metric, split)."""
    if not RESULTS.is_file():
        return []
    latest = {}
    try:
        with open(RESULTS, newline="", encoding="utf-8-sig") as f:
            for row in csv.DictReader(f):
                try:
                    v = float(row["value"])
                except (ValueError, KeyError, TypeError):
                    continue
                latest[(row["model"], row["metric"], row.get("split", ""))] = {
                    "model": row["model"], "metric": row["metric"],
                    "value": v, "dataset": row.get("dataset", ""),
                    "split": row.get("split", ""),
                }
    except OSError:
        return []

    rows = list(latest.values())
    # Gated metrics first so the scoreboard leads with what is being judged.
    rows.sort(key=lambda r: (r["metric"] not in GATES, r["model"], r["metric"]))
    return rows


def snapshot():
    run, tail = _active_run()
    res = _results()

    gated = [r for r in res if r["metric"] in GATES]
    passed = 0
    for r in gated:
        tgt = {"auc": .85, "auc_referable": .85, "qwk": .85, "dice_EX": .53,
               "dice_HE": .44, "dice_MA": .20, "dice_SE": .40,
               "sens_referable": .90, "ece": .05}[r["metric"]]
        if (r["value"] <= tgt) if r["metric"] == "ece" else (r["value"] >= tgt):
            passed += 1

    models_dir = ROOT / "artifacts" / "models"
    n_models = len(list(models_dir.glob("m*.mat"))) if models_dir.is_dir() else 0

    return {
        "run": run,
        "log_tail": tail,
        "results": res,
        "models_trained": n_models,
        "gates_passed": passed,
        "gates_total": len(gated),
        "gpu": _gpu(),
        "disk_free_gb": round(shutil.disk_usage(ROOT).free / 1e9),
        "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
