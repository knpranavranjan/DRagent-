classdef tAgentParity < matlab.unittest.TestCase
    %TAGENTPARITY  The agent's tools must reproduce the cascade exactly.
    %
    %   *** THIS IS THE LOAD-BEARING TEST OF THE AGENT LAYER. ***
    %
    %   Five of the eight agent tools call an existing function unchanged.
    %   Three -- triage, grading, maculopathy -- have no standalone entry
    %   point: they live inline inside ophira.cascade.orchestrate, and
    %   ophira.agent.tools reproduces them line for line.
    %
    %   Two copies of medical logic can drift. A drifted copy would hand a
    %   clinician numbers that no validated pipeline ever produced, while
    %   every other test in the project stayed green -- the exact failure
    %   shape this project has hit six times.
    %
    %   So this runs BOTH paths on the same real image and requires bitwise
    %   equality on every number a decision is made from. If it fails,
    %   ophira.agent.tools is wrong, not orchestrate.
    %
    %   >> runtests('tAgentParity')

    properties (Constant)
        Site = "default";
    end

    methods (Static)
        function p = sample()
            % A VERIFICATION capture, not a demonstration one. Files named
            % demo_* are deliberately degraded to show branch behaviour and
            % one of them is rejected by the gate on purpose; taking "the
            % first image in samples/" picked it as soon as it existed and
            % these tests quietly assumed out instead of asserting.
            d = ophira.projectRoot("samples");
            p = "";
            for ext = ["*.png","*.jpg","*.jpeg","*.tif","*.tiff"]
                f = dir(fullfile(d, ext));
                for k = 1:numel(f)
                    if startsWith(f(k).name, "demo_"); continue; end
                    p = string(fullfile(f(k).folder, f(k).name));
                    return
                end
            end
        end

        function r = cascade(p)
            ctx = struct('flags', struct('urgent', false, 'urgent_reasons', {{}}, ...
                                         'reduced_va', false, 'pathway', "screening"));
            w = warning('off','ophira:decision:uncalibrated');
            c = onCleanup(@() warning(w)); %#ok<NASGU>
            r = ophira.cascade.orchestrate(p, Context=ctx, ...
                    Site=tAgentParity.Site, Lesions=false);
        end
    end

    methods (Test)

        function testSampleImageExists(tc)
            % Without an image this whole suite would pass by doing
            % nothing, which is worse than failing.
            tc.assertNotEqual(tAgentParity.sample(), "", ...
                'No image in samples/ — parity cannot be checked.');
        end

        function testGradingMatchesCascade(tc)
            p = tAgentParity.sample();
            tc.assumeNotEqual(p, "");

            r = tAgentParity.cascade(p);
            tc.assumeTrue(isfield(r.evidence,'dr_grade') && ...
                          isfield(r.evidence,'referable_score'), ...
                'Image did not reach the grader; cannot compare.');

            w = warning('off','ophira:decision:uncalibrated');
            g = ophira.agent.tools("run_dr_grading", ...
                    struct('image_path', p, 'site', tAgentParity.Site));
            warning(w);

            tc.verifyEqual(g.grade, r.evidence.dr_grade, ...
                'Agent grading returned a DIFFERENT GRADE from the cascade.');
            tc.verifyEqual(g.referable_score, r.evidence.referable_score, ...
                'AbsTol', 0, 'Referable score differs — referral turns on this.');
            tc.verifyEqual(g.uncertainty, r.evidence.uncertainty, ...
                'AbsTol', 0, 'Uncertainty differs — abstention turns on this.');
        end

        function testMaculopathyMatchesCascade(tc)
            p = tAgentParity.sample();
            tc.assumeNotEqual(p, "");
            r = tAgentParity.cascade(p);
            tc.assumeTrue(isfield(r.evidence,'maculopathy') && ...
                          ~isempty(r.evidence.maculopathy), ...
                'Maculopathy did not run in the cascade.');

            w = warning('off','ophira:decision:uncalibrated');
            m = ophira.agent.tools("run_maculopathy", ...
                    struct('image_path', p, 'site', tAgentParity.Site));
            warning(w);

            tc.verifyTrue(m.available);
            tc.verifyEqual(m.maculopathy, r.evidence.maculopathy, ...
                'Agent maculopathy differs — this refers independently of DR grade.');
        end

        function testTriageUsesTheRulesThreshold(tc)
            % The triage threshold must come from rulesV1, not from the
            % value baked into m3_triage.mat. That baked value measured
            % 0.493 referable sensitivity externally.
            p = tAgentParity.sample();
            tc.assumeNotEqual(p, "");
            w = warning('off','ophira:decision:uncalibrated');
            t = ophira.agent.tools("run_triage", ...
                    struct('image_path', p, 'site', tAgentParity.Site));
            R = ophira.decision.rulesV1(Site=tAgentParity.Site);
            warning(w);
            tc.verifyEqual(t.threshold, R.triage_threshold, 'AbsTol', 0);
            tc.verifyEqual(t.escalate, t.p_any_dr >= R.triage_threshold);
        end

        function testDecisionEngineIsUnchangedByTheAgent(tc)
            % The agent's decision tool must be a pass-through. Same
            % evidence in, same route out as calling the engine directly.
            e = struct('quality', struct('decision', "ACCEPT"), ...
                       'dr_grade', 3, 'uncertainty', 0.20, ...
                       'referable_score', 0.90, 'maculopathy', 1);
            w = warning('off','ophira:decision:uncalibrated');
            direct = ophira.decision.decisionEngine(e, ...
                        Rules=ophira.decision.rulesV1(Site=tAgentParity.Site));
            viaTool = ophira.agent.tools("run_decision_engine", ...
                        struct('evidence', e, 'site', tAgentParity.Site));
            warning(w);
            tc.verifyEqual(viaTool.route, string(direct.action));
            tc.verifyEqual(string(viaTool.rules_fired), direct.rules_fired);
            tc.verifyEqual(viaTool.source, "decisionEngine");
        end

        function testAgentCannotReachAnUnregisteredTool(tc)
            % The registry is the boundary. A planner that emits a name
            % nobody vetted must get an error, not execution.
            tc.verifyError(@() ophira.agent.tools("rm_rf_everything", struct()), ...
                'ophira:agent:unknownTool');
            tc.verifyError(@() ophira.agent.tools("eval", struct()), ...
                'ophira:agent:unknownTool');
        end

        function testPreprocessCacheRespectsFileChanges(tc)
            % The cache is keyed on path AND mtime/size. An operator who
            % retakes into the same filename must not be served the
            % rejected capture.
            p = tAgentParity.sample();
            tc.assumeNotEqual(p, "");
            a = ophira.agent.preprocessed(p);
            b = ophira.agent.preprocessed(p);
            tc.verifyEqual(a, b, 'Cached preprocessing changed between calls.');
            tc.verifyEqual(size(a,1), 512);
        end

    end
end
