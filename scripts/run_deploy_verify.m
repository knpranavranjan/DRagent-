%% RUN_DEPLOY_VERIFY
% Verification for the DRagent deployment copy — no datasets required.
%
%   >> startup_ophira
%   >> run_deploy_verify
%
%   or:  python run.py --verify
%
% WHY THIS IS NOT run_99_verify_all
%
% The master copy's verifier samples 50 APTOS test images through
% ophira.data.readManifest. That is the right thing to run where the
% datasets live, and it cannot run here: this deployment deliberately
% excludes 135 GB of training corpora. Running it would fail for entirely
% the correct reason and look like a broken deployment.
%
% So this checks what a DEPLOYMENT can honestly check:
%
%   1. the models the cascade loads are present and CPU-loadable
%   2. the 81 unit and scenario tests pass
%   3. per-site calibration is actually read by the decision engine
%   4. a real fundus image goes end to end and produces a report
%
% Step 4 needs one image, supplied at deploy time in samples/. Without it
% the script says so rather than passing quietly: a verifier that is green
% because it skipped the only test that runs a model is worse than none.

clear; clc;
t0 = tic;
problems = strings(0,1);

fprintf('\n================================================================\n');
fprintf('   DRagent — DEPLOYMENT VERIFICATION\n');
fprintf('   %s\n', string(datetime("now","Format","uuuu-MM-dd HH:mm")));
fprintf('   root: %s\n', ophira.projectRoot());
fprintf('================================================================\n');

%% ============================================================ 1. models
fprintf('\n[1/4]  RUNTIME MODELS\n');
fprintf('--------------------------------------------------------------\n');
MM = ophira.projectRoot("artifacts","models");
want = [ "m1_teacher_aptos.mat", "DR grader (stage 2)"
         "m3_triage.mat",        "triage (stage 1)"
         "m4_maculopathy.mat",   "maculopathy (stage 2b)"
         "m5_lesion_unet.mat",   "lesions (stage 3)"
         "m7_calibration.mat",   "temperature" ];
total = 0;
for i = 1:size(want,1)
    f = fullfile(MM, want(i,1));
    if ~isfile(f)
        fprintf('  [FAIL] missing %s\n', want(i,1));
        problems(end+1) = "missing model " + want(i,1); %#ok<SAGROW>
        continue
    end
    d = dir(f); total = total + d.bytes;
    fprintf('  [ok]   %-24s %6.1f MB  %s\n', want(i,1), d.bytes/1048576, want(i,2));
end
fprintf('  %-31s %6.1f MB\n', 'total', total/1048576);

% The fix this deployment exists for: no runtime variable may be
% GPU-resident, or the system cannot start on a machine without CUDA.
fprintf('\n  GPU residency check (must all be host-resident):\n');
for i = 1:size(want,1)
    f = fullfile(MM, want(i,1));
    if ~isfile(f); continue; end
    S = load(f); fn = fieldnames(S); bad = strings(0,1);
    for k = 1:numel(fn)
        v = S.(fn{k});
        try
            if isa(v,'gpuArray') || (isa(v,'dlarray') && isa(extractdata(v),'gpuArray'))
                bad(end+1) = string(fn{k}); %#ok<SAGROW>
            end
        catch
            bad(end+1) = string(fn{k}) + " (unreadable)"; %#ok<SAGROW>
        end
    end
    if isempty(bad)
        fprintf('    [ok]   %-24s host\n', want(i,1));
    else
        fprintf('    [FAIL] %-24s GPU-resident: %s\n', want(i,1), strjoin(bad,", "));
        problems(end+1) = want(i,1) + " has GPU-resident data"; %#ok<SAGROW>
    end
end

%% ============================================================= 2. tests
fprintf('\n[2/4]  UNIT AND SCENARIO TESTS\n');
fprintf('--------------------------------------------------------------\n');
% tAgentParity is part of DEPLOYMENT verification, not an extra:
% the agent reproduces three cascade stages that have no standalone
% entry point, and a drifted copy would hand a clinician numbers no
% validated pipeline produced.
suites = {'tCoral','tPreproc','tSession','tQuality','tDecision', ...
          'tReport','tAgentParity'};
r = runtests(suites);
nP = sum([r.Passed]); nF = sum([r.Failed]);
for s = string(suites)
    m = startsWith(string({r.Name}), s + "/");
    fprintf('  %-12s %3d passed, %d failed\n', s, sum([r(m).Passed]), sum([r(m).Failed]));
end
fprintf('  %-12s %3d passed, %d failed\n', 'TOTAL', nP, nF);
if nF > 0; problems(end+1) = sprintf("%d test(s) failed", nF); end

%% ====================================================== 3. calibration
fprintf('\n[3/4]  PER-SITE CALIBRATION IS READ BY THE ENGINE\n');
fprintf('--------------------------------------------------------------\n');
w = warning('off','ophira:decision:uncalibrated');
e = struct('quality', struct('decision',"ACCEPT"), 'dr_grade', 1, ...
           'uncertainty', 0.10, 'referable_score', 0.10);
dD = ophira.decision.decisionEngine(e, Rules=ophira.decision.rulesV1(Site="default"));
dM = ophira.decision.decisionEngine(e, Rules=ophira.decision.rulesV1(Site="messidor2"));
warning(w);
fprintf('  same evidence, referable score 0.10\n');
fprintf('    site "default"   -> %s\n', dD.action);
fprintf('    site "messidor2" -> %s\n', dM.action);
if dD.action ~= dM.action
    fprintf('  [ok]   calibration changes the decision\n');
else
    fprintf('  [FAIL] calibration is inert\n');
    problems(end+1) = "site calibration not read by the engine";
end

%% ========================================================= 4. inference
fprintf('\n[4/4]  END-TO-END INFERENCE ON A REAL IMAGE\n');
fprintf('--------------------------------------------------------------\n');
sampleDir = ophira.projectRoot("samples");
imgs = [];
if isfolder(sampleDir)
    for ext = ["*.png","*.jpg","*.jpeg","*.tif","*.tiff"]
        imgs = [imgs; dir(fullfile(sampleDir, ext))]; %#ok<AGROW>
    end
    % demo_* are deliberately degraded branch-demonstration inputs, one of
    % which the gate rejects by design. Verification must run on a capture
    % that reaches the models, or it proves nothing.
    if ~isempty(imgs)
        imgs = imgs(~startsWith(string({imgs.name}'), "demo_"));
    end
end

if isempty(imgs)
    fprintf('  [SKIP] no image in %s\n', sampleDir);
    fprintf('         Put one fundus image there and re-run. Until then the\n');
    fprintf('         models in this package have NOT been executed, and this\n');
    fprintf('         verification cannot claim the pipeline works.\n');
    problems(end+1) = "inference not exercised (no sample image)";
else
    p = string(fullfile(imgs(1).folder, imgs(1).name));
    fprintf('  image: %s\n', imgs(1).name);
    ctx = struct('flags', struct('urgent',false,'urgent_reasons',{{}}, ...
                                 'reduced_va',false,'pathway',"screening"));
    w = warning('off','ophira:decision:uncalibrated');
    tt = tic;
    res = ophira.cascade.orchestrate(p, Context=ctx, Site="default");
    el = toc(tt);
    warning(w);

    fprintf('  action      : %s\n', res.action);
    if isfield(res.evidence,'dr_grade') && ~isempty(res.evidence.dr_grade)
        fprintf('  DR grade    : %d\n', res.evidence.dr_grade);
    end
    fprintf('  stages      : %d in %.1f s\n', res.stages_run, el);
    for i = 1:numel(res.decision.reasons)
        fprintf('  reason      : %s\n', res.decision.reasons(i));
    end

    outDir = ophira.projectRoot("artifacts","reports");
    if ~isfolder(outDir); mkdir(outDir); end
    cp = ophira.report.clinicianReport(res, Images=p, ...
            Out=fullfile(outDir,"verify_clinician.html"));
    sp = ophira.report.patientSlip(res, Out=fullfile(outDir,"verify_patient.html"));
    dc = dir(cp); ds = dir(sp);
    txt = fileread(cp);
    np = numel(strfind(txt, 'data:image/jpeg;base64'));
    fprintf('  clinician   : %.0f KB, %d embedded panel(s)\n', dc.bytes/1024, np);
    fprintf('  patient     : %.0f KB\n', ds.bytes/1024);
    if np < 1
        fprintf('  [WARN] no image panels embedded\n');
    end
    fprintf('  [ok]   pipeline executed end to end\n');
end

%% ============================================================== verdict
fprintf('\n================================================================\n');
if isempty(problems)
    fprintf('   DEPLOYMENT VERIFIED          (%.1f min)\n', toc(t0)/60);
else
    fprintf('   %d PROBLEM(S):\n', numel(problems));
    for p = problems'; fprintf('     - %s\n', p); end
end
fprintf('================================================================\n\n');

if ~isempty(problems)
    error('dragent:verifyFailed', '%d verification problem(s).', numel(problems));
end
