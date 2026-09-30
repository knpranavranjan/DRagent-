classdef tSession < matlab.unittest.TestCase
    %TSESSION  Tests for the frontend -> MATLAB handover.
    %
    %   Self-contained: writes its own fixture session files into a temporary
    %   folder, so it does not need the encounter server to be running and
    %   cannot be affected by real session data.
    %
    %   The important tests here are the SAFETY INVARIANT ones. A malformed
    %   clinical record that reaches the decision engine does not produce an
    %   error, it produces a confidently wrong routing decision -- so the
    %   reading layer has to refuse it.
    %
    %   >> runtests('tSession')

    properties
        Root string
    end

    methods (TestMethodSetup)
        function makeStore(tc)
            tc.Root = string(tempname);
            mkdir(fullfile(tc.Root, "submitted"));
            mkdir(fullfile(tc.Root, "drafts"));
            tc.addTeardown(@() rmdir(tc.Root, 's'));

            writeJson(fullfile(tc.Root,"submitted","S-ROUTINE.json"), fixture());

            u = fixture();
            u.session.session_id      = "S-URGENT";
            u.symptoms.reported       = {"sudden_vision_loss"};
            u.visual_acuity.od.value  = "6/60";
            u.flags.urgent            = true;
            u.flags.severe_va         = true;
            u.flags.urgent_reasons    = { ...
                struct('code',"symptom:sudden_vision_loss",'text',"Sudden loss of vision"), ...
                struct('code',"va:severe",'text',"Severely reduced acuity in the right eye (6/60)")};
            writeJson(fullfile(tc.Root,"submitted","S-URGENT.json"), u);

            d = fixture();
            d.session.session_id  = "S-DRAFT";
            d.session.completed_at = [];
            writeJson(fullfile(tc.Root,"drafts","S-DRAFT.json"), d);
        end
    end

    methods (Test)

        function testReadsSubmittedSession(tc)
            ctx = ophira.session.readSession("S-ROUTINE", Root=tc.Root);
            tc.verifyEqual(ctx.patient.patient_id, 'P-TEST-001');
            tc.verifyEqual(ctx.schema_version, 'context_core_v1');
            tc.verifyFalse(logical(ctx.flags.urgent));
        end

        function testDraftsHiddenUnlessRequested(tc)
            tc.verifyError(@() ophira.session.readSession("S-DRAFT", Root=tc.Root), ...
                'ophira:session:notFound');
            ctx = ophira.session.readSession("S-DRAFT", Root=tc.Root, AllowDraft=true);
            tc.verifyEqual(ctx.session.session_id, 'S-DRAFT');
        end

        function testListingPutsUrgentFirst(tc)
            % The clinician review queue is ordered urgent-first
            % (Architecture v1.0 section 19). If this ordering breaks, an
            % urgent case can sit below routine ones in the queue.
            T = ophira.session.listSessions(Root=tc.Root);
            tc.verifyEqual(height(T), 2);
            tc.verifyEqual(T.session_id(1), "S-URGENT");
            tc.verifyTrue(T.urgent(1));
            tc.verifyFalse(T.urgent(2));
        end

        function testMissingStoreErrorsRatherThanReturningEmpty(tc)
            % An empty result must never be ambiguous between "nothing was
            % screened" and "we looked in the wrong folder". The second
            % reads to an operator as "no urgent cases".
            tc.verifyError( ...
                @() ophira.session.listSessions(Root=fullfile(tc.Root,"nope")), ...
                'ophira:session:noStore');
        end

        function testSingleElementListsNormaliseToCellstr(tc)
            % jsondecode collapses a one-element JSON array to a bare value.
            % A patient reporting exactly one symptom must not produce a
            % different type from one reporting two.
            ctx = ophira.session.readSession("S-URGENT", Root=tc.Root);
            tc.verifyClass(ctx.symptoms.reported, 'cell');
            tc.verifyNumElements(ctx.symptoms.reported, 1);
            tc.verifyClass(ctx.diabetes.treatment, 'cell');
            tc.verifyClass(ctx.ocular_history.conditions, 'cell');
        end

        function testUrgentReasonsSurvive(tc)
            ctx = ophira.session.readSession("S-URGENT", Root=tc.Root);
            tc.verifyTrue(logical(ctx.flags.urgent));
            tc.verifyNumElements(ctx.flags.urgent_reasons, 2);
        end

        % --- safety invariants ------------------------------------------

        function testRejectsUrgentWithoutReason(tc)
            ctx = ophira.session.readSession("S-URGENT", Root=tc.Root);
            ctx.flags.urgent_reasons = [];
            tc.verifyError(@() ophira.session.validateContext(ctx), ...
                'ophira:session:urgentWithoutReason', ...
                'Every escalation must be attributable to a stated reason.');
        end

        function testRejectsCompletedSessionWithoutConsent(tc)
            ctx = ophira.session.readSession("S-ROUTINE", Root=tc.Root);
            ctx.consent.given = false;
            tc.verifyError(@() ophira.session.validateContext(ctx), ...
                'ophira:session:noConsent');
        end

        function testRejectsSchemaMismatch(tc)
            ctx = ophira.session.readSession("S-ROUTINE", Root=tc.Root);
            ctx.schema_version = 'context_core_v99';
            tc.verifyError(@() ophira.session.validateContext(ctx), ...
                'ophira:session:schemaMismatch');
        end

        function testRejectsMissingBlocks(tc)
            ctx = ophira.session.readSession("S-ROUTINE", Root=tc.Root);
            ctx = rmfield(ctx, 'flags');
            tc.verifyError(@() ophira.session.validateContext(ctx), ...
                'ophira:session:missingBlocks');
        end

        function testMissingSessionErrors(tc)
            tc.verifyError(@() ophira.session.readSession("S-NOPE", Root=tc.Root), ...
                'ophira:session:notFound');
        end

        function testProjectRootIsCwdIndependent(tc)
            % ophira.projectRoot must not depend on the current folder --
            % MATLAB's `run` changes it, and so do users.
            before = ophira.projectRoot();
            old = cd(tempdir);
            c = onCleanup(@() cd(old));
            tc.verifyEqual(ophira.projectRoot(), before);
            tc.verifyTrue(isfolder(ophira.projectRoot()));
        end

    end
end

% =========================================================================
function s = fixture()
s = struct( ...
  'schema_version', "context_core_v1", ...
  'session', struct('session_id',"S-ROUTINE",'created_at',"2026-09-20T13:00:00.000Z", ...
                    'completed_at',"2026-09-20T13:10:00.000Z",'centre_id',"PHC-014", ...
                    'operator_id',"OP-3391",'app_version',"0.1.0"), ...
  'patient', struct('patient_id',"P-TEST-001",'age_years',54,'sex',"female"), ...
  'eligibility', struct('diabetes_confirmed',true,'under_dr_treatment',false, ...
                    'previously_screened',true,'months_since_last_screening',18, ...
                    'able_to_consent',true,'pathway',"screening"), ...
  'consent', struct('given',true,'version',"consent_v1",'recorded_at',"2026-09-20T13:02:00.000Z"), ...
  'diabetes', struct('dm_type',"type2",'duration_years',8,'treatment',{{"oral"}}, ...
                    'hba1c_percent',7.8,'hypertension',true,'smoker',false), ...
  'ocular_history', struct('conditions',{{}},'notes',""), ...
  'symptoms', struct('reported',{{"none_reported"}},'duration_days',[],'notes',""), ...
  'visual_acuity', struct('method',"snellen_6m", ...
                    'od',struct('value',"6/9",'pinhole',""), ...
                    'os',struct('value',"6/12",'pinhole',"")), ...
  'capture', struct('slots',struct()), ...
  'flags', struct('urgent',false,'urgent_reasons',{{}},'reduced_va',false, ...
                    'severe_va',false,'pathway',"screening", ...
                    'computed_at',"2026-09-20T13:05:00.000Z", ...
                    'rules_version',"context_rules_v1"));
end

function writeJson(path, s)
fid = fopen(path, 'w');
fprintf(fid, '%s', jsonencode(s, PrettyPrint=true));
fclose(fid);
end
