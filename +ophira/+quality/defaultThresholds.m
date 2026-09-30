function T = defaultThresholds()
%DEFAULTTHRESHOLDS  Quality-gate thresholds.
%
%   *** THESE ARE PLACEHOLDERS, NOT VALIDATED VALUES. ***
%
%   They are reasoned starting points chosen so that obviously unusable
%   images are rejected and obviously good ones pass. They have NOT been
%   set against quality ground truth.
%
%   Build order Step 4 replaces them with values fitted on DeepDRiD, which
%   ships image-quality labels, and reports the resulting sensitivity and
%   specificity of the gate. Until that happens this gate is unvalidated
%   heuristics and every document describing it must say so
%   (docs/00, loophole L11).
%
%   Changing any value here REQUIRES bumping `version`. The version string
%   is stamped into every quality result, so a stored decision can always be
%   traced back to the rules that produced it.

T = struct( ...
    'version', "quality_thresholds_v0_PLACEHOLDER", ...
    ...
    ... % --- fatal: not fixable by retaking ---
    'retina_frac_min',       0.05, ... % below this, no retina is present at all
    ...
    ... % --- retake: fixable at the camera ---
    'focus_norm_min',        0.010, ... % variance of Laplacian / contrast^2
    'contrast_min',          0.035, ... % std of green channel inside the retina
    'over_exposed_max',      0.050, ... % fraction of pixels at ceiling
    'under_exposed_max',     0.200, ... % fraction of pixels at floor
    'illum_uniformity_min',  0.220, ... % min/max quadrant mean
    'colour_balance_min',    0.040, ... % min/max channel mean
    'circularity_min',       0.600, ... % 4*pi*A/P^2 of the detected field
    'artifact_frac_max',     0.060, ... % saturated blobs as fraction of retina
    ...
    ... % --- workflow ---
    'max_attempts',          3);       % then UNGRADABLE -> human review
end
