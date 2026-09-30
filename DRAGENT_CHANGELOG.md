# DRagent — Change Log

Everything that differs from the master project at `../`, and why.

**No file outside `DRagent/` was created, modified, moved, renamed or
deleted.** Verified by checksum on the one master file that was read
(`artifacts/models/m1_teacher_aptos.mat`, md5 `50ba65bc…` before and after)
and by modification-time scan of the master tree.

---

## 1. Created an independent deployment copy

`DRagent/` — 45 MB, self-contained. Path resolution was already relative:
`startup_ophira.m` derives the root from `mfilename('fullpath')` and exports
`OPHIRA_ROOT`; `ophira.projectRoot` falls back to its own location. The copy
therefore resolves entirely to itself with no code change.

**Verified in isolation.** The whole package was copied to
`C:\Users\knpra\AppData\Local\Temp\OPHIRA_DEPLOY_TEST` — outside the master
tree — and `python run.py --verify` passed there: 81 tests, live inference,
exit code 0.

---

## 2. Converted `coralBias` from GPU-resident to host storage

**File** `artifacts/models/m1_teacher_aptos.mat`
**Tool** `scripts/make_cpu_safe_model.m` (new, DRagent-only)

**The problem.** `coralBias` was stored as a `dlarray` whose underlying data
was a `gpuArray` — an artefact of the training loop having run on a GPU when
the file was saved. On a machine with no CUDA device, loading it threw:

```
Error using double
Unable to find a supported GPU device.
Error in ophira.cascade.orchestrate (line 140)
b = double(extractdata(M.grader.coralBias));
```

That made an NVIDIA GPU a hard requirement for **inference**, which the
architecture never intended and which is a poor fit for the rural
deployment this system targets. All four other runtime models were already
host-resident.

**The change.** `coralBias = gather(coralBias)` — storage residency only.

**Verified before writing.** The tool refuses to save unless every one of
these holds:

| check | result |
|---|---|
| values | `[6.68019294739 2.24969935417 -2.31875157356 -7.74889183044]` — **identical** |
| shape | identical |
| class | `dlarray` → `dlarray` |
| variable set | 5 in, 5 out, same names |
| network weights | **max difference 0** |
| still on GPU? | no |

Unchanged: architecture, weights, CORAL thresholds, calibration (T =
1.2200), input resolution, preprocessing, inference logic. Nothing was
retrained.

**Result.** CPU-only inference now works — `canUseGPU: 0`, all six stages,
63 lesion tiles, REFERRAL grade 2, 13.5 s. Same action and grade as GPU.

---

## 3. Removed the phantom `m0b_quality_cnn.mat` startup requirement

**File** `run.py`

The master's `REQUIRED_MODELS` demanded `m0b_quality_cnn.mat`, which the
deployed system never loads. Traced: stage 0 is `quality/assess.m` →
`extractFeatures.m` → `applyGate.m`, and none of the three contains a model
load — the deployed quality gate is **classical image features**. The check
would have blocked startup on a training-time control.

Removed from the list; the reason is recorded in a comment where the entry
was. `run.py --check` now reports "all 5 cascade models present".

**Not changed:** quality-gate logic, thresholds, `m0b_quality_cnn.mat` in
the master.

---

## 4. Replaced the dataset-dependent verifier

**Files** `run.py` (`--verify` target), `scripts/run_deploy_verify.m` (new)

`run_99_verify_all.m:89` calls `ophira.data.readManifest("aptos_manifest")`
and samples 50 APTOS test images. It cannot run without the datasets this
package excludes — it would have failed for entirely the correct reason and
looked like a broken deployment.

`run_deploy_verify` checks what a deployment can honestly check: the five
models present and host-resident, the 81 unit and scenario tests, that
per-site calibration actually changes a decision, and a real inference on
the image in `samples/`.

It **fails** rather than skipping if `samples/` is empty — a verification
that is green because it skipped the only step that runs a model is worse
than none.

`run_99_verify_all.m` was not copied. The dataset-backed verification stays
in the master, where the data is.

---

## 5. Pointed the sample-image hint at `samples/`

**File** `run.py` (`sample_image()`)

The master read `data/manifests/aptos_manifest.csv` for a "try this image"
hint. That manifest is a training artefact and is not in this package. The
hint now reads `samples/`. The old code was already guarded and would have
degraded silently; this makes it useful instead.

---

## 6. Added a deployment end-to-end test

**File** `tests/frontend/test_deploy_e2e.py` (new)

The master's end-to-end tests select their image from the APTOS manifest and
pre-screen candidates through the gate — neither is available here. This one
drives the real HTTP API with `samples/` and asserts 20 properties.

**Measured:** ACCEPT 0.877 → REFERRAL (`dme:referable`) → clinician 98.5 KB
with 3 panels, patient slip 3.6 KB, bundle 64 KB. **20/20.**

---

## 7. Excluded — training datasets

Not copied: `datasets/` (135 GB), `data/processed/` (19 GB),
`data/manifests/` (11 MB).

Verified by tracing every filesystem reference in `+ophira`: all dataset
paths live in `+ophira/+data/import*.m` and `+ophira/+preproc/buildCache.m`,
and the runtime call graph — `worker/run` → `orchestrate` → quality,
preproc, triage, grader, maculopathy, lesions, decision, reports — never
reaches any of them.

Demonstrated: a full encounter on an image stored outside the project tree
produced REFERRAL, grade 2, referable 0.9598 and a 95 KB report.

`grep` for `datasets`, `manifests` and `processed` across all `DRagent`
source returns **only prose in comments** — no paths.

---

## 8. Excluded — twelve unused models (157 MB)

`m8_resnet18`, `m0_quality_gate`, `m2_student`, `m1_teacher_aptos_se`,
`m1_eyepacs_pretrained`, `m0b_quality_cnn`, `m5_lesion_unet_v1`,
`m0b_quality_cnn_extended`, `m6_fusion`, `m_ensemble`, `external_messidor2`,
`m5_wholeimage_eval`.

None appears in a runtime `load()`. Several are the *evidence* for design
decisions — `m2_student` and `m_ensemble` were dropped on external
validation — so they matter in the master and are meaningless here.

---

## 9. Excluded — training-time source files

Copied by name rather than wholesale, so no training path reaches this
package:

| Excluded | Package | Why |
|---|---|---|
| all of `+data/` | importers | every `datasets/` path lives here |
| `+preproc/buildCache.m` | preproc | writes `data/processed` |
| `+quality/{buildFeatureTable,trainGate}.m` | quality | gate training |
| `+eval/{recordResult,report}.m` | eval | writes `artifacts/results.csv` |
| `+train/{trainCoral,evaluateCoral}.m` | train | training loops |
| `+models/{buildLesionUNet,injectSE}.m` | models | construction, not inference |
| 37 of 39 `scripts/` | — | all training and evaluation |

Kept for the test suite only: `+eval/qwk.m`, `+train/coralLoss.m`,
`+models/{buildBackbone,buildCoralTrainNet,channelCount,expandCoralHead}.m`
— required by `tCoral`, never by the runtime path.

---

## 10. Not copied — stray files in the master

`datasets/_strays/{LICENSE,CC-BY-4.0}.txt` are **TIFF images with a `.txt`
extension** (they begin with the `II*` TIFF magic number, 1.46 MB each), not
licence text. Copied in error at first and removed. Worth correcting in the
master; not a deployment issue. See `samples/README.md`.

---

## Explicitly NOT changed

Model architecture · trained weights · thresholds · calibration values ·
preprocessing scaling · image dimensions · CORAL implementation · triage
logic · grading logic · DME logic · lesion segmentation · decision rules ·
XAI implementation · report content · clinical terminology · frontend
workflow · session structure.

**Including the things that look wrong and are not.** M3 declares a
224×224 input and is fed 384×384 — it works because the network is fully
convolutional before pooling, and the triage thresholds were fitted against
that behaviour. The per-stage scaling differences are also deliberate:
triage 0–255 with in-layer zscore, grader `/255`, lesions raw at native
resolution. "Correcting" any of these would silently invalidate the
operating points.

**No agentic AI layer was added.** No LLM, framework, API client or planner.
This is the stable baseline only.
