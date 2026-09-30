function out = tools(name, args)
%TOOLS  The agent's tool surface over the existing OPHIRA pipeline.
%
%   out = ophira.agent.tools("run_triage", struct('image_path', p))
%
%   Every tool returns a plain struct that jsonencode can serialise. The
%   Python agent never sees a MATLAB object.
%
%   *** THIS FILE ADDS NO MEDICAL LOGIC. ***
%
%   Five of the eight tools call an existing function unchanged:
%   assess_image_quality -> ophira.quality.assess, run_lesion_analysis ->
%   ophira.lesion.segment, run_xai -> ophira.report.overlays,
%   run_decision_engine -> ophira.decision.decisionEngine,
%   generate_clinician_report -> ophira.report.clinicianReport.
%
%   Three -- triage, grading, maculopathy -- live INLINE inside
%   ophira.cascade.orchestrate and have no standalone entry point. They are
%   reproduced here line for line, including the scale conventions that
%   differ between stages and the comments explaining why. That duplication
%   is a genuine risk: two copies can drift, and a drifted copy would give
%   a clinician numbers no validated pipeline ever produced.
%
%   So tAgentParity runs BOTH paths on real images and asserts identical
%   grade, referable score, uncertainty and maculopathy. If these ever
%   diverge, that test fails and this file is the one that is wrong.
%
%   The agent cannot reach anything not listed in the switch below.

arguments
    name (1,1) string
    args struct = struct()
end

t0 = tic;
site = getf(args, 'site', "default");
C = ophira.agent.context(site);

switch name

%% ---------------------------------------------------------------- quality
case "assess_image_quality"
    p = string(args.image_path);
    q = ophira.quality.assess(p, Attempt=double(getf(args,'attempt',1)));
    out = struct( ...
        'status',        ternary(q.decision == "ACCEPT", "PASS", "FAIL"), ...
        'decision',      string(q.decision), ...
        'quality_score', q.score, ...
        'reasons',       {reasonList(q.reasons)}, ...
        'attempt',       q.attempt, ...
        'max_attempts',  q.max_attempts, ...
        'gate_version',  string(q.gate_version), ...
        'image_path',    p);

%% ----------------------------------------------------------------- triage
case "run_triage"
    p = string(args.image_path);
    I = ophira.agent.preprocessed(p);

    % SCALE MUST MATCH TRAINING AND DIFFERS BETWEEN STAGES. M3 was trained
    % through augmentedImageDatastore on 0-255 with zscore in the input
    % layer. Dividing by 255 here produced p(any DR) = 0.055 on grade-3 and
    % grade-4 images against a 0.767 threshold -- the cascade cleared every
    % severe case as "no DR".
    X384 = dlarray(single(imresize(I,[384 384])), 'SSCB');
    sc = predict(C.models.triage.trained, X384);
    pAny = double(gather(extractdata(sc)));
    pAny = pAny(2);

    % The threshold comes from the RULES, not from m3_triage.mat.
    escalate = pAny >= C.rules.triage_threshold;

    out = struct( ...
        'stage',       "triage", ...
        'p_any_dr',    pAny, ...
        'threshold',   C.rules.triage_threshold, ...
        'escalate',    escalate, ...
        'result',      ternary(escalate, "referable_candidate", "cleared"), ...
        'confidence',  abs(2*pAny - 1), ...
        'uncertainty', 1 - abs(2*pAny - 1), ...
        'model',       "m3_triage");

%% ---------------------------------------------------------------- grading
case "run_dr_grading"
    p = string(args.image_path);
    I = ophira.agent.preprocessed(p);

    X512 = dlarray(single(I)/255, 'SSCB');
    z = double(gather(extractdata(predict(C.models.grader.net, X512))));
    b = double(extractdata(C.models.grader.coralBias));
    P = 1./(1+exp(-((b(:) + z)/C.models.temperature)));

    [grade, conf, unc, probs] = ophira.infer.decodeCoral(P');

    out = struct( ...
        'stage',            "grading", ...
        'grade',            grade, ...
        'grade_label',      gradeName(grade), ...
        'probabilities',    probs(:)', ...
        'confidence',       conf, ...
        'uncertainty',      unc, ...
        'referable_score',  P(2), ...              % P(grade > 1)
        'referable_threshold', C.rules.referable_score_threshold, ...
        'abstain_threshold',   C.rules.abstain_uncertainty, ...
        'temperature',      C.models.temperature, ...
        'model',            "m1_teacher_aptos");

%% ----------------------------------------------------------- maculopathy
case "run_maculopathy"
    if isempty(C.models.dme)
        out = struct('stage',"maculopathy", 'available',false, ...
                     'message',"m4_maculopathy.mat not present");
        return
    end
    p = string(args.image_path);
    I = ophira.agent.preprocessed(p);
    X512 = dlarray(single(I)/255, 'SSCB');

    f = predict(C.models.encoder, X512);
    f = gather(extractdata(f));
    if ndims(f) >= 3
        f = mean(f, [1 2]);
    end
    f = reshape(f, 1, []);
    ds = double(gather(extractdata(predict(C.models.dme.bestHead, ...
                dlarray(single(f)','CB')))))';
    [~, dmeGrade] = max(ds); dmeGrade = dmeGrade - 1;

    out = struct( ...
        'stage',        "maculopathy", ...
        'available',    true, ...
        'maculopathy',  dmeGrade, ...
        'scores',       ds(:)', ...
        'referable',    dmeGrade >= C.rules.referable_dme, ...
        'threshold',    C.rules.referable_dme, ...
        'model',        "m4_maculopathy");

%% --------------------------------------------------------------- lesions
case "run_lesion_analysis"
    p = string(args.image_path);
    L = ophira.agent.lesions(p);
    if L.status ~= "ok"
        out = struct('stage',"lesions", 'available',false, ...
                     'message',string(L.message));
        return
    end
    names = ["MA","HE","EX","SE"];
    px = struct(); af = struct(); found = strings(0,1);
    for k = 1:numel(names)
        n = names(k);
        px.(n) = L.pixels.(n);
        af.(n) = L.area_frac.(n);
        if L.pixels.(n) > 0; found(end+1) = n; end %#ok<AGROW>
    end
    out = struct( ...
        'stage',            "lesions", ...
        'available',        true, ...
        'lesions_detected', ~isempty(found), ...
        'lesion_types',     {cellstr(found)}, ...
        'pixels',           px, ...
        'area_fraction',    af, ...
        'tile_count',       L.tiles, ...
        'fov_scale',        L.fov_scale, ...
        'model',            "m5_lesion_unet");

%% ------------------------------------------------------------------- XAI
case "run_xai"
    p = string(args.image_path);
    ev = struct();
    if isfield(args,'lesion_mask_available') && logical(args.lesion_mask_available)
        % Cached: run_lesion_analysis already segmented this image. Without
        % the cache the tiled U-Net ran twice over the same 63 tiles.
        ev.lesions = ophira.agent.lesions(p);
    end
    P = ophira.report.overlays(p, ev);
    % The agent gives each capture a run id like "S-...::od_macula" so the
    % traces stay separable. ":" is not legal in a Windows path, so the id
    % is sanitised before it becomes a folder name. Without this every XAI
    % call failed with a path syntax error.
    sid = string(getf(args,'session_id',"adhoc"));
    sid = regexprep(sid, '[^A-Za-z0-9._-]', '_');
    outDir = ophira.projectRoot("data","sessions","reports", sid);
    if ~isfolder(outDir); mkdir(outDir); end
    saved = strings(0,1);
    for f = ["fundus","lesions","gradcam"]
        if P.(f) == ""; continue; end
        b64 = extractAfter(P.(f), "base64,");
        raw = matlab.net.base64decode(char(b64));
        fp = fullfile(outDir, "xai_" + f + ".jpg");
        fid = fopen(fp,'w'); fwrite(fid, raw); fclose(fid);
        saved(end+1) = string(fp); %#ok<AGROW>
    end
    out = struct( ...
        'stage',          "xai", ...
        'available',      P.status == "ok", ...
        'xai_type',       "gradcam", ...
        'overlay_paths',  {cellstr(saved)}, ...
        'interpretation', "attention, not lesions", ...
        'measured_note',  "Grad-CAM IoU 0.052 vs lesion masks; the supervised " + ...
                          "lesion branch reaches 0.074 and concentrates 2.4x " + ...
                          "more mass on true lesions. Read it as model " + ...
                          "attention, not as a map of disease.", ...
        'message',        string(P.message));

%% ------------------------------------------------------- decision engine
case "run_decision_engine"
    % THE BOUNDARY. The agent assembles evidence; this function decides.
    % Nothing here interprets, rounds, overrides or second-guesses it.
    ev = struct();
    if isfield(args,'evidence') && isstruct(args.evidence)
        ev = args.evidence;
    end
    D = ophira.decision.decisionEngine(ev, Rules=C.rules);
    out = struct( ...
        'source',        "decisionEngine", ...
        'authority',     "DETERMINISTIC DECISION ENGINE OUTPUT", ...
        'route',         string(D.action), ...
        'rules_fired',   {cellstr(D.rules_fired)}, ...
        'reasons',       {cellstr(D.reasons)}, ...
        'rules_version', string(D.rules_version), ...
        'site',          C.site, ...
        'calibrated',    C.rules.calibrated, ...
        'decided_at',    string(D.decided_at));

otherwise
    error('ophira:agent:unknownTool', ...
        'Tool "%s" is not in the registry.', name);
end

out.tool = name;
out.latency_ms = toc(t0)*1000;
out.ok = true;
end

%% ========================================================================
function c = reasonList(r)
c = {};
if isempty(r); return; end
for k = 1:numel(r)
    c{end+1} = struct('code', string(r(k).code), ...
                      'text', string(r(k).text), ...
                      'severity', string(r(k).severity)); %#ok<AGROW>
end
end

function n = gradeName(g)
names = ["no retinopathy","mild NPDR","moderate NPDR","severe NPDR","proliferative DR"];
if g >= 0 && g <= 4; n = names(g+1); else; n = "unknown"; end
end

function v = getf(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)); v = s.(f); else; v = d; end
end

function s = ternary(c,a,b); if c; s=a; else; s=b; end; end
