# OPHIRA AI — DRagent Deployment Manifest

**Project** OPHIRA AI — explainable, uncertainty-aware diabetic retinopathy screening
**This copy** `DRagent` — standalone deployment baseline
**Built** 2026-09-30
**Package size** 45 MB (37.2 MB models · 4.0 MB sample image · 0.4 MB code · rest is runtime scaffolding)

---

## 1. Purpose

A self-contained, runnable copy of the OPHIRA screening system: everything
needed to take a new fundus image and produce a clinician report and a
patient slip. Nothing needed to train or re-evaluate anything.

**The master project at `../` is untouched and remains the research copy.**
It holds the 135 GB of datasets, 19 GB of preprocessed caches, 12 further
model files, and the scripts that produced every published number. Delete
none of it — this package cannot reproduce it.

---

## 2. Runtime components

| Layer | Path | Role |
|---|---|---|
| Frontend | `app/index.html`, `app/js/`, `app/css/` | ten-step encounter, capture, results, report view |
| Dashboard | `app/dashboard.html` | telemetry view |
| Server | `app/server/ophira_server.py` | serves the app, stores sessions and originals, writes job files, serves reports |
| Queue | `data/sessions/jobs/{pending,done}` | the only coupling between Python and MATLAB |
| Worker | `+ophira/+worker/run.m` | drains `Q-*` (quality) and `R-*` (report) jobs |
| Cascade | `+ophira/+cascade/orchestrate.m` | stage order, which is a safety property |
| Quality | `+ophira/+quality/` | `assess` → `extractFeatures` → `applyGate`, **classical, no model** |
| Preproc | `+ophira/+preproc/` | `detectFOV`, `squareFrame`, `benGraham`, CLAHE |
| Decision | `+ophira/+decision/` | `decisionEngine`, `rulesV1` — versioned rules, **not a model** |
| Lesions | `+ophira/+lesion/segment.m` | tiled U-Net at native resolution |
| XAI | `+ophira/+xai/saliency.m` | Grad-CAM, HiResCAM, Score-CAM, Integrated Gradients |
| Reports | `+ophira/+report/` | `clinicianReport`, `patientSlip`, `overlays` |
| Sessions | `+ophira/+session/` | the only entry point for clinical context |

Python and MATLAB never call each other. They share one directory.

---

## 3. Models

All five are loaded by traced call sites. No other model ships.

| Model | Size | Loaded by | Stage |
|---|---|---|---|
| `m1_teacher_aptos.mat` | 17.8 MB | `orchestrate.m:239`, `overlays.m:129` | 2 — DR grader (EfficientNet-B0 + CORAL) |
| `m3_triage.mat` | 10.3 MB | `orchestrate.m:240` | 1 — triage filter |
| `m5_lesion_unet.mat` | 7.8 MB | `segment.m:54` | 3 — lesion segmentation |
| `m4_maculopathy.mat` | 1.3 MB | `orchestrate.m:247` | 2b — maculopathy head |
| `m7_calibration.mat` | 24 KB | `orchestrate.m:242` | temperature, T = 1.2200 |
| | **37.2 MB** | | |

**All five verified host-resident** (no GPU-resident variables) by
`run_deploy_verify` step 1.

---

## 4. Software requirements

**Python** ≥ 3.9. **No third-party packages** — the server imports only
the standard library. No virtual environment required.

**MATLAB** R2026a.

| Toolbox | Status | Why |
|---|---|---|
| Deep Learning Toolbox | **required** | `dlnetwork`, `predict`, `dlgradient` |
| Image Processing Toolbox | **required** | `imresize`, `adapthisteq`, `imdilate`, `bwareaopen` |
| Statistics and Machine Learning Toolbox | **required** | checked at startup; used by the classical quality gate |
| Parallel Computing Toolbox | **optional** | GPU acceleration only — see §7 |
| Deep Learning Toolbox Model for MobileNet-v2 | **tests only** | `tCoral` builds a backbone; runtime never does |

**Node.js** not required. **No** database, Docker, external API, credentials,
`.env`, or symlinks. One localhost port (8000, `--port` to change).

---

## 5. Startup

```
cd DRagent
python run.py
```

Starts the server, starts the MATLAB worker, waits until both report ready,
opens the browser. Ctrl-C stops both.

| flag | effect |
|---|---|
| `--check` | requirements only, start nothing |
| `--verify` | full verification, then exit |
| `--no-worker` | frontend only — captures stored, never graded |
| `--port N` | different port |
| `--no-browser` | don't open a browser |

Children are held in a Windows job object, so they die with the launcher
however it ends. It only ever terminates PIDs it started.

---

## 6. Verification

```
python run.py --check     # requirements
python run.py --verify    # models, 81 tests, calibration, live inference
```

**Measured on this build:**

```
[1/4] 5 models present, 37.2 MB, all host-resident
[2/4] tCoral 11 · tPreproc 8 · tSession 12 · tQuality 14 · tDecision 21 · tReport 15
      TOTAL 81 passed, 0 failed
[3/4] same evidence: site "default" -> ROUTINE, site "messidor2" -> REFERRAL
[4/4] sample_fundus_referral.png -> REFERRAL, grade 2, 6 stages, 9.4 s
      clinician 95 KB with 3 panels · patient slip 3 KB
      DEPLOYMENT VERIFIED
```

End-to-end over HTTP: `python tests/frontend/test_deploy_e2e.py` (needs the
stack running) — 20/20 checks, bundle 64 KB.

**`run_99_verify_all` from the master does NOT run here.** It samples 50
APTOS images through `ophira.data.readManifest`, so it needs the datasets
this package excludes. `run_deploy_verify` replaces it with what a
deployment can honestly check.

---

## 7. GPU and CPU

Both work. Verified with `CUDA_VISIBLE_DEVICES=-1`:

| | GPU (RTX 5080) | CPU only |
|---|---|---|
| quality | — | 1.3 s |
| triage | — | 0.5 s |
| grader | — | 0.8 s |
| maculopathy | — | 0.2 s |
| lesions (63 tiles) | ~5 s | 6.1 s |
| **full cascade** | **~7 s** | **13.5 s** |
| overlays + Grad-CAM | ~2 s | 2.6 s |

Same action, same grade either way. CPU-only works **because** of the
`coralBias` fix — see `DRAGENT_CHANGELOG.md`. Without it the system
refuses to start on a machine with no CUDA device.

---

## 8. Runtime workflow

```
BROWSER  ten-step encounter (registration -> ... -> acuity)
   |
   v  POST /api/sessions/<sid>/images
SERVER  stores the ORIGINAL (immutable), writes jobs/pending/Q-*.json
   |
   v
WORKER  stage 0 quality gate -> ACCEPT / RECAPTURE / UNGRADABLE
   |     classical features; three attempts then UNGRADABLE -> human
   v  POST /api/sessions/<sid>/submit
SERVER  writes jobs/pending/R-*.json with the accepted originals
   |
   v
WORKER  per image: orchestrate
          stage 1  triage      p(any DR) vs site threshold
          stage 2  grader      CORAL -> grade + uncertainty + referable score
          stage 2b maculopathy shared encoder
          stage 9  decision    URGENT / HUMAN REVIEW / REFERRAL / RECAPTURE / ROUTINE
          stage 3  lesions     only when a human will see the case
        session action = MOST SEVERE across eyes
   |
   v
REPORTS clinicianReport + patientSlip, images embedded as base64
   |
   v
BROWSER results screen: action, reasons, per-eye table, report inline,
        PDF / HTML / bundle.zip downloads
```

Clinical context reaches the decision engine and **never** the networks.
Verified: identical image evidence with and without a context record,
different routing.

---

## 9. Known limitations

These are properties of the system, not of this package. The clinician
report states them on every page it produces.

- **Never prospectively validated.** Every figure comes from retrospective
  public datasets.
- **Per-site calibration is mandatory.** Uncalibrated, the full cascade
  measured **0.507** referable sensitivity externally; calibrated, **0.904**
  of gradable images. `rulesV1` warns loudly and the report says so on its
  first screen. Only `default` (APTOS-fitted) and `messidor2` thresholds
  ship.
- **The decision engine cannot be validated on public data** — no public
  dataset pairs fundus images with symptoms, visual acuity and grade. Its
  rules are scenario-tested (21 tests) only.
- **Uncertainty is an in-domain refinement, not an off-domain safety net.**
  Externally the cases the grader misses are *less* uncertain (0.305) than
  the ones it catches (0.501). Per-site temperature was tested and rejected.
- **The quality gate is the binding external constraint** — it rejected 19
  of 71 referable images in external testing. A RECAPTURE is safe only if
  the retake happens.
- **Grad-CAM does not localise lesions** (IoU 0.052, mass lift 2.2× vs the
  supervised branch's 5.3×). The report labels it "attention, not lesions".
- **Lesion channels differ widely**: Dice 0.613 hard exudates, 0.095
  cotton-wool. Absence of a marking is not evidence of a healthy retina.
- **Single operator assumed.** The file queue is idempotent, but two
  workers on one queue has caused a stale-code race in development. Run one.

---

## 10. Relationship to the master project

The master at `../` is the complete research copy: datasets, caches, all 17
models, every training and evaluation script, and the full document set.

**Nothing in this package writes to it.** `scripts/make_cpu_safe_model.m`
reads one file from it and refuses to write anywhere outside `DRagent`.

This package cannot retrain, re-validate, or reproduce any published
number. For that, use the master.
