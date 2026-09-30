%% AGENT_BASELINE
% The cascade's own answer for the image in samples/, with no agent.
%
%   >> startup_ophira
%   >> agent_baseline
%
% Exists so tests/test_agent.py can compare "agent OFF" with "agent ON"
% without embedding MATLAB source in a command line — quoting through the
% shell mangled it, and a comparison that silently fails to run is worse
% than no comparison.
%
% Prints one machine-readable line:
%   BASELINE=<route>|<grade>|<referable_score>|<uncertainty>|<ms>

d = ophira.projectRoot("samples");
p = "";
% Skip demo_* -- those are degraded branch-demonstration inputs, and the
% baseline must be measured on the same capture the agent is measured on.
for ext = ["*.png","*.jpg","*.jpeg","*.tif","*.tiff"]
    f = dir(fullfile(d, ext));
    for k = 1:numel(f)
        if startsWith(f(k).name, "demo_"); continue; end
        p = string(fullfile(f(k).folder, f(k).name)); break;
    end
    if p ~= ""; break; end
end
if p == ""
    fprintf('BASELINE=NONE|||\n');
    return
end

ctx = struct('flags', struct('urgent', false, 'urgent_reasons', {{}}, ...
                             'reduced_va', false, 'pathway', "screening"));
w = warning('off','ophira:decision:uncalibrated');
t = tic;
r = ophira.cascade.orchestrate(p, Context=ctx, Site="default");
ms = toc(t)*1000;
warning(w);

grade = NaN; ref = NaN; unc = NaN;
if isfield(r.evidence,'dr_grade') && ~isempty(r.evidence.dr_grade)
    grade = r.evidence.dr_grade;
end
if isfield(r.evidence,'referable_score') && ~isempty(r.evidence.referable_score)
    ref = r.evidence.referable_score;
end
if isfield(r.evidence,'uncertainty') && ~isempty(r.evidence.uncertainty)
    unc = r.evidence.uncertainty;
end

% %.17g prints full double precision. At 10 decimal places the
% agent-vs-cascade comparison failed on ROUNDING rather than on any
% real difference -- a test that reports a divergence that is not
% there is as bad as one that misses a divergence that is.
fprintf('BASELINE=%s|%d|%.17g|%.17g|%.0f\n', r.action, grade, ref, unc, ms);
