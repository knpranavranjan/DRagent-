function result = orchestrate(imagePath, opts)
%ORCHESTRATE  Run one image through the full OPHIRA cascade.
%
%   result = ophira.cascade.orchestrate("path/to/fundus.jpg")
%   result = ophira.cascade.orchestrate(p, Context=ctx, Site="PHC-014")
%
%   THE STAGE ORDER IS A SAFETY PROPERTY, NOT AN OPTIMISATION:
%
%     0  quality gate   ORIGINAL image, before any preprocessing
%     1  triage         cheap filter, ~99% sensitivity
%     2  grader         DR grade + uncertainty
%     2b maculopathy    shares the grader's encoder
%     3  lesions        only for cases a human will see
%     9  decision       deterministic routing
%
%   Stage 0 runs on the ORIGINAL. Preprocessing applies illumination
%   normalisation, Ben Graham subtraction and CLAHE -- operations whose
%   whole purpose is removing the defects the gate detects. Assessing a
%   preprocessed image would let a badly exposed capture score as well as a
%   good one.
%
%   Stage 3 runs only when the outcome is REFERRAL, URGENT or HUMAN REVIEW.
%   Lesion evidence exists for a clinician to look at; computing it for a
%   routine clear is wasted work.
%
%   WHICH GRADER. M1 (EfficientNet-B0), not the smaller distilled M2.
%   External validation measured M2 degrading twice as badly on unseen data
%   (QWK -0.322 vs -0.157); the 7 MB saved is not worth that.
%
%   Every stage emits an ophira.cascade.stageContract record, so the final
%   decision is traceable to the inputs and model versions that produced it.

arguments
    imagePath (1,1) string
    opts.Context struct = struct()
    opts.Site    (1,1) string = "default"
    opts.Attempt (1,1) double = 1
    opts.Models  struct = struct()
    opts.Lesions (1,1) logical = true
    opts.Verbose (1,1) logical = false
end

t0 = tic;
stages = {};
evidence = struct();
if ~isempty(fieldnames(opts.Context)); evidence.context = opts.Context; end

M = loadModels(opts.Models);

% Rules are resolved ONCE, before stage 1, because the triage filter needs
% them. Every operating point in the cascade is a site-calibrated clinical
% parameter, and the earliest stage is the one where miscalibration costs
% the most -- an image dropped at triage is never graded at all.
R = ophira.decision.rulesV1(Site=opts.Site);

%% ---- no capture at all -------------------------------------------------
% A session can be submitted without a usable image -- the camera failed,
% the patient could not be positioned, the encounter was cut short. That is
% NOT the same as no disease, and the decision engine must still run: an
% urgent symptom escalates whether or not a photograph exists.
if imagePath == "" || ~isfile(imagePath)
    stages{end+1} = ophira.cascade.stageContract("stage0_quality", ...
        status="skipped", message="No image supplied for this encounter.", ...
        latency_ms=0);
    result = finish(evidence, stages, opts, t0, R, "");
    return
end

%% ---- stage 0: quality, on the ORIGINAL --------------------------------
s = tic;
q = ophira.quality.assess(imagePath, Attempt=opts.Attempt);
evidence.quality = q;
stages{end+1} = ophira.cascade.stageContract("stage0_quality", ...
    image_id=imagePath, quality_score=q.score, ...
    escalate_to=ternary(q.decision=="ACCEPT","stage1_triage",""), ...
    model_version="quality_gate_v1", ...
    threshold_ver=ophira.quality.defaultThresholds().version, ...
    latency_ms=toc(s)*1000, ...
    status=lower(q.decision));

if q.decision ~= "ACCEPT"
    % A rejected image never reaches the grader. Routing is still the
    % decision engine's call, not the gate's.
    result = finish(evidence, stages, opts, t0, R, imagePath);
    return
end

%% ---- preprocess once, reused by every later stage ---------------------
s = tic;
I = ophira.preproc.preprocess(imread(imagePath), Size=512);
preprocMs = toc(s)*1000;

%% ---- stage 1: triage --------------------------------------------------
s = tic;
% *** SCALE MUST MATCH TRAINING, AND IT DIFFERS BETWEEN STAGES. ***
%
% M3 was trained with trainnet + augmentedImageDatastore, which feeds
% 0-255 single, and its input layer carries zscore normalisation with a
% mean around 89-98. The grader (stage 2) was trained in a custom loop on
% single(I)/255 with Normalization="none".
%
% Dividing by 255 here produced p(any DR) = 0.055 on grade-3 and grade-4
% images against a 0.767 threshold -- the cascade cleared every severe case
% as "no DR" while every individual model still tested fine. Caught only by
% the end-to-end run.
X384 = dlarray(single(imresize(I,[384 384])), 'SSCB');   % 0-255, NOT /255
sc = predict(M.triage.trained, X384);
pAny = double(gather(extractdata(sc)));
pAny = pAny(2);

% The threshold comes from the RULES, not from m3_triage.mat. The value
% baked into the model file (0.7673) was fitted on APTOS and measured 0.493
% referable sensitivity on Messidor-2 -- it silently dropped 110 of 217
% referable cases before the grader could see them.
escalate = pAny >= R.triage_threshold;

stages{end+1} = ophira.cascade.stageContract("stage1_triage", ...
    image_id=imagePath, confidence=pAny, ...
    escalate_to=ternary(escalate,"stage2_grader",""), ...
    model_version="m3_triage", threshold_ver=R.version + "/" + opts.Site, ...
    latency_ms=toc(s)*1000);

if ~escalate
    % Cleared by the filter: grade 0, no further compute. The filter is
    % tuned so that clearing a severe case is what it must never do.
    evidence.dr_grade = 0;
    % Binary uncertainty, NOT 1-pAny. A confidently negative image has
    % pAny near 0, which 1-pAny turns into "uncertainty 0.99" -- above the
    % 0.55 abstention threshold, so every cleared image was routed to a
    % human. Uncertainty must peak at pAny = 0.5 and fall towards both ends.
    evidence.uncertainty = 1 - abs(2*pAny - 1);
    result = finish(evidence, stages, opts, t0, R, imagePath);
    return
end

%% ---- stage 2: grader --------------------------------------------------
s = tic;
X512 = dlarray(single(I)/255, 'SSCB');
z = double(gather(extractdata(predict(M.grader.net, X512))));
b = double(extractdata(M.grader.coralBias));
P = 1./(1+exp(-((b(:) + z)/M.temperature)));

[grade, conf, unc, probs] = ophira.infer.decodeCoral(P');
evidence.dr_grade = grade;
evidence.dr_probs = probs;
evidence.uncertainty = unc;
evidence.referable_score = P(2);        % P(grade > 1), what referral uses

stages{end+1} = ophira.cascade.stageContract("stage2_grader", ...
    image_id=imagePath, grade=grade, probs=probs, ...
    confidence=conf, uncertainty=unc, ...
    model_version="m1_teacher_aptos", threshold_ver="calib_v1/" + opts.Site, ...
    latency_ms=toc(s)*1000 + preprocMs);

%% ---- stage 2b: maculopathy (shares the grader's encoder) --------------
if isfield(M, 'dme') && ~isempty(M.dme)
    s = tic;
    f = predict(M.encoder, X512);
    f = gather(extractdata(f));
    % Global-average-pool over the spatial dims, whatever shape comes back.
    % A single-image batch can arrive as 1x1xCx1 or as a bare N-D array, and
    % a plain transpose fails on the latter -- so reduce explicitly and
    % flatten to a row rather than guessing at ndims.
    if ndims(f) >= 3
        f = mean(f, [1 2]);
    end
    f = reshape(f, 1, []);
    ds = double(gather(extractdata(predict(M.dme.bestHead, dlarray(single(f)','CB')))))';
    [~, dmeGrade] = max(ds); dmeGrade = dmeGrade - 1;
    evidence.maculopathy = dmeGrade;
    stages{end+1} = ophira.cascade.stageContract("stage2b_maculopathy", ...
        image_id=imagePath, maculopathy=dmeGrade, ...
        model_version="m4_maculopathy", threshold_ver="argmax (uncalibrated)", ...
        latency_ms=toc(s)*1000);
end

result = finish(evidence, stages, opts, t0, R, imagePath);
end

%% ========================================================================
function r = finish(evidence, stages, opts, t0, R, imagePath)
D = ophira.decision.decisionEngine(evidence, Rules=R);

%% ---- stage 3: lesions, for cases a human will see ---------------------
% Deliberately AFTER the decision, and deliberately not fed back into it.
% Lesion evidence is an EXPLANATION for a referral that has already been
% made on the grade, the maculopathy head and the encounter record. Letting
% it route as well would mean a clinician reading an overlay that had
% helped cause the referral it is supposed to justify.
%
% It costs ~4.5 s -- an order of magnitude more than every other stage
% combined -- which is precisely why it runs for roughly the third of cases
% that a human opens, and not for a routine clear.
if opts.Lesions && any(D.action == ["REFERRAL","URGENT","HUMAN REVIEW"]) ...
        && imagePath ~= "" && isfile(imagePath)
    s = tic;
    % The ORIGINAL image: M5 was trained on raw tiles, not on the
    % Ben Graham / CLAHE output the grader consumes.
    % ReturnMask: the clinician report draws this on the captured image.
    % It costs nothing extra -- the mask already exists at this point.
    L = ophira.lesion.segment(imread(imagePath), ReturnMask=true);
    evidence.lesions = L;
    stages{end+1} = ophira.cascade.stageContract("stage3_lesions", ...
        image_id=imagePath, model_version="m5_lesion_unet", ...
        threshold_ver="p>0.5, FOV-scaled", ...
        status=L.status, message=L.message, latency_ms=toc(s)*1000);
end

stages{end+1} = ophira.cascade.stageContract("stage9_decision", ...
    model_version="deterministic rules (not a model)", ...
    escalate_to=D.action, threshold_ver=D.rules_version, status="ok", ...
    message=strjoin(D.reasons, "; "));

r = struct( ...
    'action',        D.action, ...
    'decision',      D, ...
    'evidence',      evidence, ...
    'stages',        {stages}, ...
    'stages_run',    numel(stages), ...
    'total_ms',      toc(t0)*1000, ...
    'site',          opts.Site);

if opts.Verbose
    fprintf('  %-22s -> %s (%.0f ms, %d stages)\n', ...
        "cascade", D.action, r.total_ms, numel(stages));
    for i = 1:numel(D.reasons); fprintf('      %s\n', D.reasons(i)); end
end
end

function M = loadModels(pre)
% Loaded once and cached between calls: reloading a 16 MB network per image
% would dominate the measured latency and misrepresent the cascade's cost.
persistent CACHE
if ~isempty(fieldnames(pre)); M = pre; return; end
if ~isempty(CACHE); M = CACHE; return; end

MM = ophira.projectRoot("artifacts","models");
M = struct();
M.grader = load(fullfile(MM,"m1_teacher_aptos.mat"));
M.triage = load(fullfile(MM,"m3_triage.mat"));

c = load(fullfile(MM,"m7_calibration.mat"));
M.temperature = c.T;

f = fullfile(MM,"m4_maculopathy.mat");
if isfile(f)
    M.dme = load(f);
    lg = layerGraph(M.grader.net);
    for nm = ["coral_shared","drop","gap"]
        try; lg = removeLayers(lg, nm); catch; end
    end
    M.encoder = dlnetwork(lg);
else
    M.dme = [];
end

CACHE = M;
end

function s = ternary(c,a,b); if c; s=a; else; s=b; end; end
