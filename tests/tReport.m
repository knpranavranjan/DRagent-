classdef tReport < matlab.unittest.TestCase
    %TREPORT  Properties the two output documents must never lose.
    %
    %   The reports are the only part of this system a human actually
    %   reads. A wrong number in a log file is a bug; a wrong or missing
    %   caveat here is the difference between a clinician overriding the
    %   system and rubber-stamping it.
    %
    %   These tests protect the claims made in the report docstrings, not
    %   the formatting. Each one names the failure it prevents.
    %
    %   >> runtests('tReport')

    methods (Static)
        function r = result(action, opts)
            arguments
                action (1,1) string
                opts.Site (1,1) string = "default"
                opts.Graded (1,1) logical = true
                opts.Lesions (1,1) logical = false
            end
            e = struct('quality', struct('decision', "ACCEPT"));
            if opts.Graded
                e.dr_grade        = 3;
                e.dr_probs        = [0.02 0.05 0.13 0.55 0.25];
                e.uncertainty     = 0.31;
                e.referable_score = 0.87;
                e.maculopathy     = 1;
            end
            if opts.Lesions
                e.lesions = struct('lesions', ["MA","HE","EX","SE"], ...
                    'pixels',    struct('MA',120,'HE',300,'EX',2400,'SE',40), ...
                    'area_frac', struct('MA',1e-5,'HE',3e-5,'EX',2.6e-4,'SE',4e-6), ...
                    'fov_scale', 1.4, 'tiles', 63, 'latency_ms', 4400, ...
                    'status', "ok", 'message', "");
            end
            D = struct('action', action, ...
                'rules_fired', "dr:referable", ...
                'reasons', "DR grade 3 at or above the referable threshold (2)", ...
                'rules_version', "decision_rules_v1", ...
                'decided_at', "2026-09-21T10:00:00", 'inputs', struct());
            stages = {ophira.cascade.stageContract("stage0_quality"), ...
                      ophira.cascade.stageContract("stage9_decision")};
            if opts.Graded
                stages{end+1} = ophira.cascade.stageContract("stage2_grader");
            end
            r = struct('action', action, 'decision', D, 'evidence', e, ...
                       'stages', {stages}, 'stages_run', numel(stages), ...
                       'total_ms', 640, 'site', opts.Site);
        end

        function t = text(file)
            t = string(fileread(file));
        end

        function d = tmp()
            d = fullfile(tempdir, "ophira_treport");
            if ~isfolder(d); mkdir(d); end
        end
    end

    methods (Test)

        %% ---- patient slip: what must NOT be in it ----------------------
        function testPatientSlipCarriesNoClinicalJargon(tc)
            % A grade is a severity score a patient will compare with
            % someone else's, and a probability invites a conversation the
            % slip cannot support. Neither belongs on a take-home page.
            for a = ["ROUTINE","REFERRAL","URGENT","HUMAN REVIEW","RECAPTURE"]
                p = ophira.report.patientSlip(tReport.result(a), ...
                        Out=fullfile(tReport.tmp(), "slip.html"));
                t = lower(tReport.text(p));
                for banned = ["grade", "probability", "uncertaint", ...
                              "coral", "efficientnet", "model version"]
                    tc.verifyFalse(contains(t, banned), ...
                        sprintf('Patient slip for %s leaked "%s".', a, banned));
                end
            end
        end

        function testPatientSlipNeverClaimsAbsenceOfDisease(tc)
            % A screening pass means "nothing needing referral was visible
            % in today's photograph", which is not a negative diagnosis.
            p = ophira.report.patientSlip(tReport.result("ROUTINE"), ...
                    Out=fullfile(tReport.tmp(), "slip.html"));
            t = lower(tReport.text(p));
            tc.verifyFalse(contains(t, "you do not have"));
            tc.verifyFalse(contains(t, "your eyes are healthy"));
            tc.verifyFalse(contains(t, "no disease"));
        end

        function testPatientSlipAlwaysListsRedFlags(tc)
            % The commonest harm in screening is a patient told they were
            % fine who then ignores new symptoms. The red flags appear on
            % EVERY slip, including a clear one.
            for a = ["ROUTINE","REFERRAL","URGENT","HUMAN REVIEW","RECAPTURE"]
                p = ophira.report.patientSlip(tReport.result(a), ...
                        Out=fullfile(tReport.tmp(), "slip.html"));
                t = lower(tReport.text(p));
                tc.verifyTrue(contains(t, "sudden loss of vision"), ...
                    sprintf('Slip for %s omits the red-flag list.', a));
                tc.verifyTrue(contains(t, "straight away"));
            end
        end

        function testEveryActionProducesADistinctSlip(tc)
            seen = strings(0,1);
            for a = ["ROUTINE","REFERRAL","URGENT","HUMAN REVIEW","RECAPTURE"]
                p = ophira.report.patientSlip(tReport.result(a), ...
                        Out=fullfile(tReport.tmp(), "slip.html"));
                seen(end+1) = tReport.text(p); %#ok<AGROW>
            end
            tc.verifyEqual(numel(unique(seen)), 5, ...
                'Two actions produced the same slip; a patient would be told the wrong thing.');
        end

        %% ---- clinician report: what must BE in it ----------------------
        function testClinicianReportStatesTheRulesThatFired(tc)
            % An action with no visible grounds is asking to be
            % rubber-stamped.
            r = tReport.result("REFERRAL");
            p = ophira.report.clinicianReport(r, Out=fullfile(tReport.tmp(),"c.html"));
            t = tReport.text(p);
            tc.verifyTrue(contains(t, "dr:referable"));
            tc.verifyTrue(contains(t, r.decision.reasons(1)));
            tc.verifyTrue(contains(t, "decision_rules_v1"));
        end

        function testUncalibratedSiteIsWarnedInTheDocument(tc)
            % *** THE LOAD-BEARING REPORT TEST ***
            % An uncalibrated site measured 0.51 sensitivity externally. A
            % clinician reading a clear result from such a site must be
            % told so in the document, not in a log nobody opens.
            p = ophira.report.clinicianReport(tReport.result("ROUTINE", Site="default"), ...
                    Out=fullfile(tReport.tmp(),"c.html"));
            t = lower(tReport.text(p));
            tc.verifyTrue(contains(t, "not calibrated"), ...
                'An uncalibrated site must say so in the report itself.');
        end

        function testCalibratedSiteIsNotWarned(tc)
            p = ophira.report.clinicianReport(tReport.result("ROUTINE", Site="messidor2"), ...
                    Out=fullfile(tReport.tmp(),"c.html"));
            t = lower(tReport.text(p));
            tc.verifyFalse(contains(t, "not calibrated"));
            tc.verifyTrue(contains(t, "site calibration"));
        end

        function testReportListsWhatWasNotAssessed(tc)
            % A blank section reads as normal. Absence of a finding is not
            % a finding of absence.
            p = ophira.report.clinicianReport(tReport.result("RECAPTURE", Graded=false), ...
                    Out=fullfile(tReport.tmp(),"c.html"));
            t = tReport.text(p);
            tc.verifyTrue(contains(t, "Not assessed"));
            tc.verifyTrue(contains(lower(t), "did not reach the grader"));
            tc.verifyTrue(contains(lower(t), "glaucoma"), ...
                'The report must state that it does not look for other eye disease.');
        end

        function testLimitationsAreAlwaysPresent(tc)
            for a = ["ROUTINE","URGENT"]
                p = ophira.report.clinicianReport(tReport.result(a), ...
                        Out=fullfile(tReport.tmp(),"c.html"));
                t = lower(tReport.text(p));
                tc.verifyTrue(contains(t, "limitations"));
                tc.verifyTrue(contains(t, "prospective"), ...
                    'The report must state it has never been prospectively validated.');
            end
        end

        function testLesionChannelsCarryTheirOwnReliability(tc)
            % EX and SE differ by a factor of six in Dice. Printing them in
            % one undifferentiated table would imply they are equally good.
            p = ophira.report.clinicianReport(tReport.result("REFERRAL", Lesions=true), ...
                    Out=fullfile(tReport.tmp(),"c.html"));
            t = tReport.text(p);
            tc.verifyTrue(contains(t, "0.613"), 'EX Dice must be shown.');
            tc.verifyTrue(contains(t, "0.095"), 'SE Dice must be shown.');
            tc.verifyTrue(contains(lower(t), "localisation is unreliable"), ...
                'The weak SE channel must be marked as such.');
        end

        function testLesionEvidenceIsMarkedAsNonRouting(tc)
            % Stage 3 runs after the decision and no rule reads it. If the
            % report implied otherwise, a clinician would read an overlay
            % as having caused the referral it is meant to justify.
            p = ophira.report.clinicianReport(tReport.result("REFERRAL", Lesions=true), ...
                    Out=fullfile(tReport.tmp(),"c.html"));
            tc.verifyTrue(contains(lower(tReport.text(p)), "no routing rule reads"));
        end

        function testReportIsTraceableToModelVersions(tc)
            p = ophira.report.clinicianReport(tReport.result("REFERRAL"), ...
                    Out=fullfile(tReport.tmp(),"c.html"));
            t = tReport.text(p);
            tc.verifyTrue(contains(t, "How this was produced"));
            tc.verifyTrue(contains(t, "stage2_grader"));
        end

        function testNoDoubleEscapedEntities(tc)
            % Columns that go through esc() must contain PLAIN TEXT. An
            % &mdash; written into the lesion reliability note came back to
            % the clinician as the literal six characters "&mdash;" in the
            % middle of a sentence, because esc() turns & into &amp;.
            % Caught by rendering the report in a browser, not by any
            % string assertion -- so here is the string assertion.
            p = ophira.report.clinicianReport(tReport.result("REFERRAL", Lesions=true), ...
                    Out=fullfile(tReport.tmp(),"c.html"));
            t = tReport.text(p);
            for ent = ["&amp;mdash;", "&amp;ge;", "&amp;middot;", "&amp;nbsp;"]
                tc.verifyFalse(contains(t, ent), ...
                    sprintf('Double-escaped entity %s would render as literal text.', ent));
            end
        end

        function testTraceabilityNamesRealThresholds(tc)
            % "How this was produced" is an audit claim. Printing "unset"
            % against a stage whose threshold IS site-calibrated tells a
            % reviewer the opposite of the truth.
            r = tReport.result("REFERRAL");
            r.stages{end+1} = ophira.cascade.stageContract("stage1_triage", ...
                model_version="m3_triage", threshold_ver="decision_rules_v1/messidor2");
            p = ophira.report.clinicianReport(r, Out=fullfile(tReport.tmp(),"c.html"));
            t = tReport.text(p);
            tc.verifyTrue(contains(t, "decision_rules_v1/messidor2"), ...
                'The traceability table must name the ruleset and site actually used.');
        end

        function testHtmlIsEscaped(tc)
            % Reasons come from the decision engine, but operator and
            % centre ids come from the encounter app and are free text.
            r = tReport.result("REFERRAL");
            ctx = struct('session', struct('session_id', "S-1", ...
                'centre_id', "<script>x</script>", 'operator_id', "OP"));
            p = ophira.report.clinicianReport(r, Context=ctx, ...
                    Out=fullfile(tReport.tmp(),"c.html"));
            t = tReport.text(p);
            tc.verifyFalse(contains(t, "<script>x</script>"));
            tc.verifyTrue(contains(t, "&lt;script&gt;"));
        end

    end
end
