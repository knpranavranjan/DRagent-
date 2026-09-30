classdef tDecision < matlab.unittest.TestCase
    %TDECISION  Scenario tests for the clinical decision engine (M9).
    %
    %   The engine CANNOT be clinically validated on public data -- no
    %   public dataset pairs fundus images with symptoms, visual acuity and
    %   grade. These tests are therefore the only assurance it gets, and
    %   they encode the safety properties the architecture commits to
    %   rather than merely exercising the code.
    %
    %   Each test names the rule it protects. If one fails, a patient is
    %   routed wrongly.
    %
    %   >> runtests('tDecision')

    methods (Static)
        function e = base()
            % A healthy, fully-assessed encounter.
            e = struct( ...
                'quality',     struct('decision', "ACCEPT"), ...
                'dr_grade',    0, ...
                'uncertainty', 0.10, ...
                'maculopathy', 0, ...
                'context',     struct('flags', struct( ...
                    'urgent', false, 'urgent_reasons', {{}}, ...
                    'reduced_va', false, 'pathway', "screening")));
        end
    end

    methods (Test)

        %% ---- baseline ---------------------------------------------------
        function testHealthyEncounterIsRoutine(tc)
            d = ophira.decision.decisionEngine(tDecision.base());
            tc.verifyEqual(d.action, "ROUTINE");
        end

        %% ---- rule 1: urgent symptoms outrank the AI ---------------------
        function testUrgentSymptomsOverrideGradeZero(tc)
            % *** THE LOAD-BEARING SAFETY TEST ***
            % Architecture section 02: urgent symptoms escalate independently
            % of AI grade. A patient reporting sudden vision loss must be
            % escalated even when the image looks perfectly normal.
            e = tDecision.base();
            e.dr_grade = 0;
            e.context.flags.urgent = true;
            e.context.flags.urgent_reasons = {struct('code',"symptom:sudden_vision_loss", ...
                                                     'text',"Sudden loss of vision")};
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "URGENT", ...
                'Urgent symptoms must override a grade-0 image.');
            tc.verifyTrue(any(d.rules_fired == "ctx:urgent"));
        end

        function testUrgentAppliesWithNoImageAtAll(tc)
            % Escalation must not depend on a capture having happened.
            e = struct('context', struct('flags', struct( ...
                'urgent', true, ...
                'urgent_reasons', {{struct('code',"va:severe", 'text',"Severe acuity loss")}}, ...
                'reduced_va', true, 'pathway', "screening")));
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "URGENT");
        end

        function testProliferativeDRIsUrgent(tc)
            e = tDecision.base(); e.dr_grade = 4;
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "URGENT");
            tc.verifyTrue(any(d.rules_fired == "dr:proliferative"));
        end

        %% ---- rule 2: ungradable is never routine ------------------------
        function testUngradableGoesToHumanNotRoutine(tc)
            % Architecture section 09. An image the system could not assess
            % must never fall through to "no disease detected".
            e = tDecision.base();
            e.quality = struct('decision', "UNGRADABLE");
            e.dr_grade = 0;
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "HUMAN REVIEW");
            tc.verifyNotEqual(d.action, "ROUTINE");
        end

        function testPoorQualityAsksForRecapture(tc)
            e = tDecision.base();
            e.quality = struct('decision', "RECAPTURE");
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "RECAPTURE");
        end

        function testMissingGradeGoesToHuman(tc)
            % Nothing assessed at all is not the same as nothing found.
            e = rmfield(tDecision.base(), 'dr_grade');
            e = rmfield(e, 'quality');
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "HUMAN REVIEW");
        end

        %% ---- rule 3: abstain rather than guess --------------------------
        function testHighUncertaintyAbstains(tc)
            e = tDecision.base();
            e.uncertainty = 0.80;
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "HUMAN REVIEW");
            tc.verifyTrue(any(d.rules_fired == "ai:abstain"));
        end

        %% ---- rule 4: maculopathy refers independently -------------------
        function testMaculopathyRefersOnGradeZero(tc)
            % Architecture section 13: maculopathy is NOT derived from the
            % DR grade. A threatened macula with mild retinopathy must still
            % be referred.
            e = tDecision.base();
            e.dr_grade = 0;
            e.maculopathy = 2;
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "REFERRAL");
            tc.verifyTrue(any(d.rules_fired == "dme:referable"));
        end

        function testReferableGradeRefers(tc)
            e = tDecision.base(); e.dr_grade = 2;
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "REFERRAL");
        end

        function testReducedAcuityRefersOnGradeZero(tc)
            e = tDecision.base();
            e.context.flags.reduced_va = true;
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "REFERRAL");
            tc.verifyTrue(any(d.rules_fired == "va:reduced"));
        end

        %% ---- precedence -------------------------------------------------
        function testUrgentBeatsUngradable(tc)
            e = tDecision.base();
            e.quality = struct('decision', "UNGRADABLE");
            e.context.flags.urgent = true;
            e.context.flags.urgent_reasons = {struct('code',"symptom:eye_pain", 'text',"Eye pain")};
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "URGENT");
        end

        function testUngradableBeatsUncertainty(tc)
            e = tDecision.base();
            e.quality = struct('decision', "UNGRADABLE");
            e.uncertainty = 0.9;
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "HUMAN REVIEW");
            tc.verifyTrue(any(d.rules_fired == "quality:ungradable"));
        end

        function testUncertaintyBeatsReferral(tc)
            % An uncertain grade-2 goes to a human rather than being acted
            % on: the referral would be made on a number the model itself
            % does not trust.
            e = tDecision.base();
            e.dr_grade = 2; e.uncertainty = 0.9;
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "HUMAN REVIEW");
        end

        %% ---- auditability -----------------------------------------------
        function testEveryDecisionIsAttributable(tc)
            % An action with no rule behind it cannot be explained to a
            % clinician or audited afterwards. The engine errors rather than
            % emitting one.
            scen = {tDecision.base()};
            e = tDecision.base(); e.dr_grade = 4; scen{end+1} = e;
            e = tDecision.base(); e.uncertainty = 0.9; scen{end+1} = e;
            e = tDecision.base(); e.quality = struct('decision',"UNGRADABLE"); scen{end+1} = e;
            e = tDecision.base(); e.maculopathy = 2; scen{end+1} = e;

            for i = 1:numel(scen)
                d = ophira.decision.decisionEngine(scen{i});
                tc.verifyNotEmpty(d.rules_fired, 'Every action must state a rule.');
                tc.verifyNotEmpty(d.reasons,     'Every action must state a reason.');
                tc.verifyNotEmpty(d.rules_version);
            end
        end

        function testDecisionIsDeterministic(tc)
            e = tDecision.base(); e.dr_grade = 2;
            a = ophira.decision.decisionEngine(e);
            b = ophira.decision.decisionEngine(e);
            tc.verifyEqual(a.action, b.action);
            tc.verifyEqual(a.rules_fired, b.rules_fired);
        end

        %% ---- per-site calibration ---------------------------------------
        function testUncalibratedSiteWarns(tc)
            % External validation measured 0.456 sensitivity with the
            % shipped threshold. Deploying uncalibrated must be loud.
            tc.verifyWarning(@() ophira.decision.rulesV1(Site="NEW-CLINIC"), ...
                'ophira:decision:uncalibrated');
        end

        function testSiteCalibrationChangesTheDecision(tc)
            % *** THE TEST THAT WAS MISSING. ***
            % rulesV1 warned loudly about uncalibrated sites and tDecision
            % checked that the warning fired -- but the engine read the
            % decoded grade and never consulted the threshold, so the
            % calibration changed no decision anywhere. A protection that
            % is configured, documented, warned about and inert is worse
            % than none: it reads as safety from the outside.
            %
            % The same evidence must route differently under the two sites.
            e = tDecision.base();
            e.dr_grade = 1;              % decoded grade is BELOW referable
            e.referable_score = 0.10;    % above messidor2's 0.042, below 0.474

            warnState = warning('off','ophira:decision:uncalibrated');
            cleanup = onCleanup(@() warning(warnState)); %#ok<NASGU>

            dDefault = ophira.decision.decisionEngine(e, ...
                Rules=ophira.decision.rulesV1(Site="default"));
            dSite = ophira.decision.decisionEngine(e, ...
                Rules=ophira.decision.rulesV1(Site="messidor2"));

            tc.verifyEqual(dDefault.action, "ROUTINE", ...
                'The APTOS default should not refer on a score of 0.10.');
            tc.verifyEqual(dSite.action, "REFERRAL", ...
                'A calibrated site must refer where its own threshold says so.');
            tc.verifyTrue(any(dSite.rules_fired == "dr:referable_score"));
        end

        function testScoreCannotSuppressAGradeReferral(tc)
            % The score rule is OR-ed with the grade rule. A site whose
            % threshold is set too high must not be able to cancel a
            % referral the grade alone would have triggered.
            e = tDecision.base();
            e.dr_grade = 3;
            e.referable_score = 0.001;
            warnState = warning('off','ophira:decision:uncalibrated');
            cleanup = onCleanup(@() warning(warnState)); %#ok<NASGU>
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "REFERRAL");
            tc.verifyTrue(any(d.rules_fired == "dr:referable"));
        end

        function testScoreRuleIsOptional(tc)
            % Evidence with no score at all must still route on the grade.
            e = tDecision.base(); e.dr_grade = 2;
            tc.verifyFalse(isfield(e,'referable_score'));
            d = ophira.decision.decisionEngine(e);
            tc.verifyEqual(d.action, "REFERRAL");
        end

        function testCalibratedSiteDoesNotWarn(tc)
            R = ophira.decision.rulesV1(Site="messidor2");
            tc.verifyTrue(R.calibrated);
            tc.verifyLessThan(R.referable_score_threshold, 0.5, ...
                'A calibrated site should refer more readily than the APTOS default.');
        end

    end
end
