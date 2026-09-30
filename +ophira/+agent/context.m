function C = context(site)
%CONTEXT  Models, rules and per-image preprocessing, cached for the agent.
%
%   C = ophira.agent.context("default")
%
%   The agent calls one stage at a time, so the things orchestrate.m loads
%   once per image would otherwise be loaded once per TOOL CALL: five model
%   files and a preprocessing pass, six times over. This caches them in the
%   worker process, which is where the agent's tool jobs are drained.
%
%   WHAT THIS IS NOT
%
%   It is not a second copy of the pipeline. Every model file, every
%   threshold and the preprocessing call are exactly the ones
%   ophira.cascade.orchestrate uses, and tAgentParity asserts that the
%   per-stage tools reproduce orchestrate's numbers on real images. If that
%   test fails, these two have drifted and the tools are wrong.

arguments
    site (1,1) string = "default"
end

persistent M RULES SITE

if isempty(M)
    MM = ophira.projectRoot("artifacts","models");
    M = struct();
    M.grader = load(fullfile(MM,"m1_teacher_aptos.mat"));
    M.triage = load(fullfile(MM,"m3_triage.mat"));

    c = load(fullfile(MM,"m7_calibration.mat"));
    M.temperature = c.T;

    f = fullfile(MM,"m4_maculopathy.mat");
    if isfile(f)
        M.dme = load(f);
        % The maculopathy head runs on the grader's encoder: the same graph
        % with the CORAL head removed. Identical construction to
        % orchestrate.m's loadModels.
        lg = layerGraph(M.grader.net);
        for nm = ["coral_shared","drop","gap"]
            try; lg = removeLayers(lg, nm); catch; end
        end
        M.encoder = dlnetwork(lg);
    else
        M.dme = [];
    end
end

if isempty(RULES) || SITE ~= site
    RULES = ophira.decision.rulesV1(Site=site);
    SITE = site;
end

C = struct('models', M, 'rules', RULES, 'site', site);
end
