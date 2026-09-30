function run(opts)
%RUN  Drain the quality-assessment job queue.
%
%   ophira.worker.run()                  % run until Ctrl-C
%   ophira.worker.run(Once=true)         % drain what is queued, then stop
%
%   The encounter front end writes a job file; this worker picks it up, runs
%   the quality gate, and writes the result. The two never call each other
%   directly.
%
%   WHY A FILE QUEUE RATHER THAN A SERVICE
%   MATLAB cannot be a web server on the deployed device, and the browser
%   cannot call MATLAB. A directory of JSON files is something both sides
%   already know how to use, survives either process dying, and can be
%   inspected by hand when something goes wrong. If the worker is down, jobs
%   simply accumulate and are processed when it returns -- the operator sees
%   "waiting for analysis" rather than an error.
%
%   THREE JOB KINDS, one queue:
%     Q-*.json  quality   one capture -> gate verdict, during the encounter
%     R-*.json  report    one submitted session -> full cascade + documents
%     T-*.json  tool      ONE agent tool call -> its structured result
%
%   T jobs exist so the agentic layer can run the pipeline a stage at a
%   time, observe each result and choose what to do next. They reuse this
%   worker rather than adding a second MATLAB process, which keeps the
%   models loaded once and keeps Python and MATLAB talking through the one
%   directory they already share.
%
%   Job      data/sessions/jobs/pending/{Q,R}-*.json
%   Result   data/sessions/jobs/done/{Q,R}-*.json
%   Reports  data/sessions/reports/<session_id>/{clinician,patient}.html

arguments
    opts.Root       (1,1) string  = ophira.projectRoot("data","sessions")
    opts.Once       (1,1) logical = false
    opts.PollSec    (1,1) double  = 0.5
    opts.Verbose    (1,1) logical = true
end

pendingDir = fullfile(opts.Root, "jobs", "pending");
doneDir    = fullfile(opts.Root, "jobs", "done");

if ~isfolder(pendingDir)
    error('ophira:worker:noQueue', ...
        ['Job queue not found: %s\n' ...
         'Start the encounter server first:\n' ...
         '    python app/server/ophira_server.py'], pendingDir);
end
if ~isfolder(doneDir); mkdir(doneDir); end

if opts.Verbose
    fprintf('OPHIRA quality worker\n');
    fprintf('  queue   %s\n', pendingDir);
    fprintf('  results %s\n', doneDir);
    fprintf('  gate    %s / %s\n', "quality_gate_v1", ...
        ophira.quality.defaultThresholds().version);
    if ~opts.Once; fprintf('  Ctrl-C to stop\n'); end
    fprintf('\n');
end

nDone = 0;
while true
    % Tool jobs first: an agent is waiting on each one synchronously, and
    % a report job can take twenty seconds.
    jobs = [dir(fullfile(pendingDir, "T-*.json")); ...
            dir(fullfile(pendingDir, "Q-*.json")); ...
            dir(fullfile(pendingDir, "R-*.json"))];

    for k = 1:numel(jobs)
        jobPath = fullfile(jobs(k).folder, jobs(k).name);
        if startsWith(jobs(k).name, "R-")
            nDone = nDone + processReport(jobPath, doneDir, opts.Root, opts.Verbose);
        elseif startsWith(jobs(k).name, "T-")
            nDone = nDone + processTool(jobPath, doneDir, opts.Verbose);
        else
            nDone = nDone + processOne(jobPath, doneDir, opts.Verbose);
        end
    end

    if opts.Once
        break
    end
    pause(opts.PollSec);
end

if opts.Verbose
    fprintf('\n%d job(s) processed.\n', nDone);
end
end

% =========================================================================
function n = processTool(jobPath, doneDir, verbose)
%PROCESSTOOL  Run ONE agent tool call and write its result back.
%
%   The agent owns the workflow; this owns nothing but the execution. It
%   refuses any name the registry in ophira.agent.tools does not know, so
%   a planner cannot reach a function nobody vetted.
n = 0; t0 = tic;

try
    job = jsondecode(fileread(jobPath));
catch ME
    movefile(jobPath, jobPath + ".bad");
    warning('ophira:worker:badToolJob', 'Unreadable tool job %s: %s', jobPath, ME.message);
    return
end

result = struct('job_id', job.job_id, 'kind', "tool", ...
                'tool', string(job.tool));

try
    args = struct();
    if isfield(job,'args') && isstruct(job.args); args = job.args; end
    result.result = ophira.agent.tools(string(job.tool), args);
    result.status = "ok";
catch ME
    % A failed tool is reported as a failed tool. It is never reported as
    % a result, and it never becomes a clinical finding by default -- the
    % agent decides what to do about it, and the decision engine still
    % refuses to route on evidence it does not have.
    result.status  = "error";
    result.error   = string(ME.message);
    result.error_id = string(ME.identifier);
    warning('ophira:worker:toolFailed', '%s (%s): %s', ...
            job.job_id, job.tool, ME.message);
end

result.processed_at = string(datetime("now","Format","uuuu-MM-dd'T'HH:mm:ss"));
result.latency_ms   = toc(t0)*1000;

writeJson(fullfile(doneDir, job.job_id + ".json"), result);
delete(jobPath);

if verbose
    fprintf('  %s  tool %-24s %-6s %.0f ms\n', job.job_id, job.tool, ...
            result.status, result.latency_ms);
end
n = 1;
end

% =========================================================================
function n = processReport(jobPath, doneDir, root, verbose)
%PROCESSREPORT  Run the full cascade for a submitted session and write the
%   two documents the clinic actually receives.
%
%   A session can carry several captures (OD and OS, macula and disc). Each
%   is graded independently and the SESSION action is the most severe of
%   them, in the decision engine's own precedence order. An eye is not made
%   safe by the other eye looking fine.
n = 0; t0 = tic;

try
    job = jsondecode(fileread(jobPath));
catch ME
    movefile(jobPath, jobPath + ".bad");
    warning('ophira:worker:badJob', 'Unreadable report job %s: %s', jobPath, ME.message);
    return
end

result = struct('job_id', job.job_id, 'kind', "report", ...
                'session_id', job.session_id);

try
    ctx = ophira.session.readSession(string(job.session_id), Root=root);

    imgs = string(job.images);
    if isempty(imgs) || all(imgs == "")
        % No capture at all is not "no disease". The decision engine is run
        % on the context alone, which can still escalate on symptoms.
        rs = {ophira.cascade.orchestrate("", Context=ctx, Lesions=false)};
        imgs = strings(0,1);
    else
        rs = cell(numel(imgs),1);
        for i = 1:numel(imgs)
            rs{i} = ophira.cascade.orchestrate(imgs(i), Context=ctx);
        end
    end

    [gov, govIdx] = governing(rs);

    outDir = fullfile(root, "reports", string(job.session_id));
    if ~isfolder(outDir); mkdir(outDir); end

    % The originals go in so the report can show WHERE the findings are.
    % Panels are rendered from the captures the operator actually took, not
    % from a cached derivative.
    cp = ophira.report.clinicianReport(gov, Context=ctx, Images=imgs, ...
            Out=fullfile(outDir, "clinician.html"));
    pp = ophira.report.patientSlip(gov, Context=ctx, ...
            Out=fullfile(outDir, "patient.html"));

    perImage = cell(numel(rs),1);
    for i = 1:numel(rs)
        nm = ""; if i <= numel(imgs); [~,b,e] = fileparts(imgs(i)); nm = b+e; end
        perImage{i} = struct('image', nm, 'action', string(rs{i}.action), ...
                             'stages', rs{i}.stages_run, ...
                             'ms', round(rs{i}.total_ms));
    end

    result.action      = string(gov.action);
    result.governing   = govIdx;
    result.per_image   = perImage;
    result.reasons     = cellstr(gov.decision.reasons);
    result.rules_fired = cellstr(gov.decision.rules_fired);
    result.site        = string(gov.site);
    result.calibrated  = ophira.decision.rulesV1(Site=gov.site).calibrated;
    result.clinician_html = string(cp);
    result.patient_html   = string(pp);
    result.status      = "ok";

catch ME
    % A worker crash must never present as a clear result. The same rule as
    % the quality path: anything that could not be assessed goes to a human.
    result.action  = "HUMAN REVIEW";
    result.status  = "error";
    result.error   = string(ME.message);
    result.reasons = {char("Report generation failed: " + string(ME.message))};
    warning('ophira:worker:reportFailed', '%s: %s', job.job_id, ME.message);
end

result.processed_at = string(datetime("now","Format","uuuu-MM-dd'T'HH:mm:ss"));
result.latency_ms   = toc(t0)*1000;

% The browser polls for reports/<sid>/report.json, so that file is the
% completion signal and must be written last.
outDir = fullfile(root, "reports", string(job.session_id));
if ~isfolder(outDir); mkdir(outDir); end
writeJson(fullfile(doneDir, job.job_id + ".json"), result);
writeJson(fullfile(outDir, "report.json"), result);
delete(jobPath);

if verbose
    fprintf('  %s  %-13s %s  %d image(s)  %.0f ms\n', job.job_id, ...
        result.action, job.session_id, numel(string(job.images)), result.latency_ms);
end
n = 1;
end

function [gov, idx] = governing(rs)
% Decision-engine precedence. RECAPTURE sits above ROUTINE because an
% unusable image must not be reported as a clear result.
order = ["URGENT","HUMAN REVIEW","REFERRAL","RECAPTURE","ROUTINE"];
best = numel(order) + 1; idx = 1;
for i = 1:numel(rs)
    r = find(order == string(rs{i}.action), 1);
    if isempty(r); r = numel(order); end
    if r < best; best = r; idx = i; end
end
gov = rs{idx};
end

function writeJson(path, s)
tmp = path + ".tmp";
fid = fopen(tmp, 'w', 'n', 'UTF-8');
fprintf(fid, '%s', jsonencode(s, PrettyPrint=true));
fclose(fid);
movefile(tmp, path);
end

% =========================================================================
function n = processOne(jobPath, doneDir, verbose)
n = 0;
t0 = tic;

try
    job = jsondecode(fileread(jobPath));
catch ME
    % A malformed job cannot be retried usefully; move it aside so the queue
    % does not jam on it forever.
    movefile(jobPath, jobPath + ".bad");
    warning('ophira:worker:badJob', 'Unreadable job %s: %s', jobPath, ME.message);
    return
end

result = struct( ...
    'job_id',     job.job_id, ...
    'session_id', job.session_id, ...
    'slot_id',    job.slot_id, ...
    'attempt',    job.attempt, ...
    'image_path', job.image_path);

try
    q = ophira.quality.assess(string(job.image_path), ...
            Attempt=job.attempt, ...
            MaxAttempts=ophira.quality.defaultThresholds().max_attempts);

    result.decision  = q.decision;
    result.score     = q.score;
    result.reasons   = reasonsToCell(q.reasons);
    result.features  = q.features;
    result.gate_version       = q.gate_version;
    result.thresholds_version = q.thresholds_version;
    result.status    = "ok";

catch ME
    % A worker crash must not present as a passing image. Anything the
    % worker cannot assess is UNGRADABLE and goes to a human -- the same
    % rule as an image that fails assessment (Architecture section 09).
    result.decision  = "UNGRADABLE";
    result.score     = 0;
    result.reasons   = {struct('code',"worker:error", ...
                               'text',"Quality assessment failed: " + string(ME.message), ...
                               'severity',"fatal")};
    result.status    = "error";
    result.error     = string(ME.message);
    warning('ophira:worker:assessFailed', '%s: %s', job.job_id, ME.message);
end

result.processed_at = string(datetime("now","Format","uuuu-MM-dd'T'HH:mm:ss"));
result.latency_ms   = toc(t0)*1000;

% Write the result BEFORE removing the job, so a crash between the two
% leaves a duplicate (harmless, idempotent) rather than a lost job.
outPath = fullfile(doneDir, job.job_id + ".json");
tmp = outPath + ".tmp";
fid = fopen(tmp, 'w');
fprintf(fid, '%s', jsonencode(result, PrettyPrint=true));
fclose(fid);
movefile(tmp, outPath);
delete(jobPath);

if verbose
    if isempty(result.reasons)
        why = "";
    else
        codes = cellfun(@(r) string(r.code), result.reasons);
        why = " [" + strjoin(codes, ",") + "]";
    end
    fprintf('  %s  %-10s score=%.3f  %s attempt %d  %.0f ms%s\n', ...
        job.job_id, result.decision, result.score, job.slot_id, ...
        job.attempt, result.latency_ms, why);
end

n = 1;
end

% -------------------------------------------------------------------------
function c = reasonsToCell(reasons)
% jsonencode turns a struct ARRAY into a JSON array of objects, but a 1x1
% struct into a bare object. The browser always wants an array, so force a
% cell -- the same one-element collapse that bites on the way back in.
c = {};
for k = 1:numel(reasons)
    c{end+1} = struct('code', reasons(k).code, ...
                      'text', reasons(k).text, ...
                      'severity', reasons(k).severity); %#ok<AGROW>
end
end
