function r = applyGate(f, opts)
%APPLYGATE  Turn quality features into ACCEPT / RECAPTURE / UNGRADABLE.
%
%   r = ophira.quality.applyGate(features)
%
%   THE SAFETY RULE (Architecture v1.0 section 09):
%
%       UNGRADABLE IS NOT GRADE 0.
%
%   An image the system cannot assess must route to a human. It must never
%   fall through to "no disease detected". This function therefore has three
%   outcomes, not two, and the caller is expected to honour all three.
%
%   ACCEPT      -> continue to preprocessing and inference
%   RECAPTURE   -> fixable at the camera; ask the operator to retake
%   UNGRADABLE  -> not fixable by retaking; route to human review
%
%   The distinction between the last two is operational, not cosmetic.
%   Blur, poor exposure and uneven illumination are retake problems. A
%   cataract, a tiny pupil or a missing field are not -- repeatedly asking
%   the operator to retake an image that physically cannot be improved
%   wastes the encounter and frustrates the patient.
%
%   THRESHOLDS ARE PLACEHOLDERS. They are reasoned starting points, not
%   validated values. Step 4 of the build order sets them on DeepDRiD, which
%   carries image-quality labels; until then this gate is unvalidated
%   heuristics and must be described that way (docs/00, loophole L11).

arguments
    f struct
    opts.Thresholds = ophira.quality.defaultThresholds()
    opts.Attempt (1,1) double = 1      % how many times this field was tried
    opts.MaxAttempts (1,1) double = 3
end

T = opts.Thresholds;
reasons = struct('code', {}, 'text', {}, 'severity', {});

add = @(list, code, text, sev) [list, struct('code',code,'text',text,'severity',sev)];

% --- not fixable by retaking --------------------------------------------

if f.retina_frac < T.retina_frac_min
    reasons = add(reasons, "fov:no_retina", ...
        "No retinal field detected in the image.", "fatal");
end

if f.retina_frac >= T.retina_frac_min && f.circularity < T.circularity_min
    reasons = add(reasons, "fov:clipped", ...
        "The retinal field is clipped or partially out of frame.", "retake");
end

% --- fixable at the camera ----------------------------------------------

if f.focus_norm < T.focus_norm_min
    reasons = add(reasons, "focus:blurred", ...
        "Image is out of focus.", "retake");
end

if f.over_exposed_frac > T.over_exposed_max
    reasons = add(reasons, "exposure:over", ...
        "Image is over-exposed; reduce flash intensity.", "retake");
end

if f.under_exposed_frac > T.under_exposed_max
    reasons = add(reasons, "exposure:under", ...
        "Image is too dark; increase flash or check pupil dilation.", "retake");
end

if f.illum_uniformity < T.illum_uniformity_min
    reasons = add(reasons, "illumination:uneven", ...
        "Illumination is uneven; re-centre on the pupil.", "retake");
end

if f.contrast < T.contrast_min
    reasons = add(reasons, "contrast:low", ...
        "Very low contrast; media opacity or misalignment.", "retake");
end

if f.artifact_frac > T.artifact_frac_max
    reasons = add(reasons, "artifact:reflection", ...
        "Large reflection or artifact obscures the retina.", "retake");
end

if f.colour_balance < T.colour_balance_min
    reasons = add(reasons, "colour:imbalance", ...
        "Severe colour cast; check white balance.", "retake");
end

% --- score ---------------------------------------------------------------
% A single 0..1 number for the UI and for later threshold tuning. It is a
% convenience, NOT the decision: the decision comes from the named reasons
% above, so a failure can always be explained to the operator.
score = qualityScore(f, T);

% --- decision ------------------------------------------------------------
% NOTE: use [reasons.severity] (a string ARRAY), never {reasons.severity}.
% strcmp on a CELL whose elements are string objects returns false for
% every element -- the cell holds strings, not char vectors, so nothing
% matches. That silently disabled this entire branch: every fatal condition
% was downgraded to RECAPTURE, which would loop the operator on an image
% that can never pass instead of routing it to a human.
fatal = any(severities(reasons) == "fatal");

if fatal
    decision = "UNGRADABLE";
elseif isempty(reasons)
    decision = "ACCEPT";
elseif opts.Attempt >= opts.MaxAttempts
    % Repeated failure stops being a retake problem and becomes a human
    % problem (Architecture section 32: "repeated failure -> human
    % review/referral"). Do not loop the operator forever.
    decision = "UNGRADABLE";
    reasons = add(reasons, "attempts:exhausted", ...
        sprintf("Quality still insufficient after %d attempts.", opts.Attempt), "fatal");
else
    decision = "RECAPTURE";
end

r = struct( ...
    'decision',          decision, ...
    'score',             score, ...
    'reasons',           reasons, ...
    'attempt',           opts.Attempt, ...
    'max_attempts',      opts.MaxAttempts, ...
    'features',          f, ...
    'thresholds_version', T.version, ...
    'gate_version',      "quality_gate_v1", ...
    'assessed_at',       string(datetime("now","Format","uuuu-MM-dd'T'HH:mm:ss")));
end

% -------------------------------------------------------------------------
function s = severities(reasons)
%SEVERITIES  Severity field as a string ARRAY, safe when reasons is empty.
if isempty(reasons)
    s = strings(1,0);
else
    s = [reasons.severity];
end
end

% -------------------------------------------------------------------------
function s = qualityScore(f, T)
% Geometric mean of per-criterion sub-scores, so one bad criterion cannot be
% hidden by several good ones -- an arithmetic mean would let a completely
% blurred image pass on the strength of its exposure.
% NOTE: contrast is deliberately absent as a positive term. focus_norm is
% already variance-of-Laplacian DIVIDED BY contrast squared, so rewarding
% contrast again double-counts it -- and blurring a fundus image raises
% measured spread near the field edge, which made a heavier blur score
% HIGHER than a lighter one. Contrast still gates a rejection above; it just
% does not inflate the score.
sub = [ ...
    ramp(f.focus_norm,        T.focus_norm_min,      T.focus_norm_min*3), ...
    ramp(1-f.over_exposed_frac,  1-T.over_exposed_max*3,  1), ...
    ramp(1-f.under_exposed_frac, 1-T.under_exposed_max*3, 1), ...
    ramp(f.illum_uniformity,  T.illum_uniformity_min, 0.85), ...
    ramp(f.circularity,       T.circularity_min,     0.95), ...
    ramp(1-f.artifact_frac,   1-T.artifact_frac_max*4, 1)];

sub = max(sub, 1e-3);
s = exp(mean(log(sub)));
end

function y = ramp(x, lo, hi)
if hi <= lo; y = double(x >= lo); return; end
y = min(1, max(0, (x - lo) / (hi - lo)));
end
