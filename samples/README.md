# samples/

One fundus image, used by `run.py --verify` and
`tests/frontend/test_deploy_e2e.py` so that verification actually executes
the models rather than passing on a skipped test.

## Provenance

| | |
|---|---|
| file | `sample_fundus_referral.png` |
| source | APTOS 2019 Blindness Detection, training set |
| original id | `01c7808d901d` |
| reference grade | 2 (moderate NPDR) |
| quality gate | ACCEPT, score 0.877 |
| pipeline result | REFERRAL — `dme:referable` |

## Before redistributing this package

**Confirm you have the right to include this image.** It comes from a
Kaggle competition dataset whose terms govern redistribution, and I have
not verified those terms for you. If in doubt, delete it:

```
rm samples/sample_fundus_referral.png
```

Nothing in the runtime path reads this folder. `run.py --verify` will then
report `[SKIP] no image in samples/` and count that as a problem, which is
deliberate — a verification that is green because it skipped the only step
that runs a model is worse than no verification. Replace it with any
fundus image you are entitled to use and verification works again.

## Not a licence file

The master project has `datasets/_strays/{LICENSE,CC-BY-4.0}.txt`. Those
are **TIFF images with a .txt extension** (they begin with the `II*` TIFF
magic number), not licence text. They were not copied here. Worth
correcting in the master at some point; it is not a deployment issue.

## Naming convention — load-bearing

| prefix | purpose | used by |
|---|---|---|
| *(none)* | **verification** capture, passes the gate | `run.py --verify`, `tAgentParity`, `test_agent.py`, `test_deploy_e2e.py` |
| `demo_` | **demonstration** input, may be degraded on purpose | `AGENTIC_DEMO.md` branch scenarios |

Every "pick a sample" helper **skips `demo_*`**. This is not tidiness.
`demo_poor_quality.png` sorts alphabetically before the real sample, and
when it was added the helpers grabbed it — so `tAgentParity` silently
dropped from 7 assertions to 5, `test_agent.py` crashed on a missing
grade, and the deployment E2E failed. All three depended on directory
order without saying so.

If you add a capture the gate should reject, name it `demo_*`.
