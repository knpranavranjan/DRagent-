function D = decisionEngine(evidence, opts)
%DECISIONENGINE  M9 — deterministic clinical workflow routing.
%
%   D = ophira.decision.decisionEngine(evidence)
%
%   *** THIS IS NOT A MODEL. ***
%   It is versioned, deterministic logic. Given the same inputs it returns
%   the same action, every time, and every action carries the list of rules
%   that fired. That is what makes a screening decision auditable -- a
%   network cannot tell a clinician why it routed a patient.
%
%   INPUT `evidence` fields (all optional; absent means "not assessed"):
%     quality        struct from ophira.quality.assess
%     dr_grade       0-4 from the cascade grader
%     dr_probs       1xK calibrated probabilities
%     referable_score  P(grade > 1), tempered; thresholded per site
%     uncertainty    0-1 normalised entropy
%     maculopathy    0-2 DME risk
%     lesions        struct of per-lesion pixel counts
%     context        context_core record from the encounter app
%
%   OUTPUT actions, in descending precedence:
%     URGENT       same-day / emergency referral
%     HUMAN REVIEW clinician must look; includes ungradable and abstention
%     REFERRAL     routine ophthalmology referral
%     RECAPTURE    retake the image
%     ROUTINE      rescreen at the standard interval
%
%   PRECEDENCE IS DELIBERATE AND NOT NEGOTIABLE:
%
%   1. URGENT symptoms outrank everything, including a grade-0 image.
%      A patient reporting sudden vision loss is escalated whether the model
%      says grade 0 or grade 4, and whether or not an image was captured at
%      all (Architecture v1.0 section 02).
%
%   2. UNGRADABLE IS NEVER ROUTINE. An image the system could not assess
%      routes to a human. It must never fall through to "no disease
%      detected" (section 09).
%
%   3. HIGH UNCERTAINTY ABSTAINS. The model declines rather than guessing
%      (section 17).
%
%   4. MACULOPATHY CAN REFER ON ITS OWN, independently of the DR grade
%      (section 13).
%
%   The engine can never be clinically validated on public data -- no public
%   dataset pairs fundus images with symptoms, visual acuity and grade -- so
%   it is unit- and scenario-tested instead, and that limitation is stated
%   wherever its outputs are reported.

arguments
    evidence struct
    opts.Rules = ophira.decision.rulesV1()
end

R = opts.Rules;
fired = strings(0,1);
reasons = strings(0,1);

add = @(code, text) deal([fired; code], [reasons; text]);

%% ---- 1. URGENT: symptoms and acuity, independent of any AI output ------
% Read from the encounter record, which the CNN never sees.
urgentCtx = false;
if isfield(evidence, 'context') && isfield(evidence.context, 'flags')
    f = evidence.context.flags;
    if isfield(f,'urgent') && logical(f.urgent)
        urgentCtx = true;
        [fired, reasons] = add("ctx:urgent", "Urgent symptom or acuity flag from the encounter");
        if isfield(f,'urgent_reasons')
            for k = 1:numel(f.urgent_reasons)
                r = f.urgent_reasons(k);
                if isstruct(r) && isfield(r,'text')
                    reasons(end+1) = "  - " + string(r.text); %#ok<AGROW>
                end
            end
        end
    end
end

% Proliferative DR is sight-threatening on the image alone.
if hasField(evidence,'dr_grade') && evidence.dr_grade >= R.urgent_grade
    [fired, reasons] = add("dr:proliferative", ...
        sprintf("DR grade %d at or above the urgent threshold (%d)", ...
                evidence.dr_grade, R.urgent_grade));
end

if any(startsWith(fired, ["ctx:urgent","dr:proliferative"]))
    D = finish("URGENT", fired, reasons, R, evidence);
    return
end

%% ---- 2. QUALITY: ungradable is never routine --------------------------
if hasField(evidence,'quality')
    q = evidence.quality;
    switch string(q.decision)
        case "UNGRADABLE"
            [fired, reasons] = add("quality:ungradable", ...
                "Image could not be assessed. Ungradable is not grade 0.");
            D = finish("HUMAN REVIEW", fired, reasons, R, evidence);
            return
        case "RECAPTURE"
            [fired, reasons] = add("quality:recapture", ...
                "Image quality insufficient; retake required.");
            D = finish("RECAPTURE", fired, reasons, R, evidence);
            return
    end
end

% No grade and no quality verdict means nothing was assessed at all.
if ~hasField(evidence,'dr_grade')
    [fired, reasons] = add("dr:absent", "No DR grade available for this eye.");
    D = finish("HUMAN REVIEW", fired, reasons, R, evidence);
    return
end

%% ---- 3. UNCERTAINTY: abstain rather than guess -------------------------
if hasField(evidence,'uncertainty') && evidence.uncertainty >= R.abstain_uncertainty
    [fired, reasons] = add("ai:abstain", ...
        sprintf("Model uncertainty %.2f at or above the abstention threshold (%.2f)", ...
                evidence.uncertainty, R.abstain_uncertainty));
    D = finish("HUMAN REVIEW", fired, reasons, R, evidence);
    return
end

%% ---- 4. REFERRAL: grade, maculopathy, or acuity ------------------------
refer = false;

if evidence.dr_grade >= R.referable_grade
    refer = true;
    [fired, reasons] = add("dr:referable", ...
        sprintf("DR grade %d at or above the referable threshold (%d)", ...
                evidence.dr_grade, R.referable_grade));
end

% THE CALIBRATED SCORE REFERS IN ITS OWN RIGHT.
%
% The decoded grade carries an implicit boundary at P(grade>1) = 0.5, which
% is an argmax artefact, not a clinical choice. On an unseen domain that
% boundary sits in the wrong place: Messidor-2 measured sensitivity 0.456
% there, against 0.899 at the locally fitted 0.042.
%
% Until this rule existed the engine read the decoded grade only, so
% R.referable_score_threshold was never consulted and per-site calibration
% had no effect on any decision. The score is OR-ed with the grade rather
% than replacing it: a site whose threshold is set too high must not be
% able to suppress a referral the grade alone would have triggered.
if hasField(evidence,'referable_score') ...
        && evidence.referable_score >= R.referable_score_threshold
    refer = true;
    [fired, reasons] = add("dr:referable_score", ...
        sprintf("Referable score %.3f at or above the %s threshold (%.3f)", ...
                evidence.referable_score, ...
                ternary(R.calibrated, "site-calibrated", "UNCALIBRATED default"), ...
                R.referable_score_threshold));
end

% Maculopathy refers on its own -- it is not derived from the DR grade.
if hasField(evidence,'maculopathy') && evidence.maculopathy >= R.referable_dme
    refer = true;
    [fired, reasons] = add("dme:referable", ...
        sprintf("Maculopathy risk %d at or above threshold (%d), independent of DR grade", ...
                evidence.maculopathy, R.referable_dme));
end

if hasField(evidence,'context') && isfield(evidence.context,'flags') ...
        && isfield(evidence.context.flags,'reduced_va') ...
        && logical(evidence.context.flags.reduced_va)
    refer = true;
    [fired, reasons] = add("va:reduced", "Reduced visual acuity recorded at the encounter");
end

if refer
    D = finish("REFERRAL", fired, reasons, R, evidence);
    return
end

%% ---- 5. ROUTINE --------------------------------------------------------
[fired, reasons] = add("dr:below_referable", ...
    sprintf("DR grade %d below the referable threshold and no other trigger", ...
            evidence.dr_grade));
D = finish("ROUTINE", fired, reasons, R, evidence);
end

%% ========================================================================
function D = finish(action, fired, reasons, R, evidence)
D = struct( ...
    'action',        action, ...
    'rules_fired',   fired, ...
    'reasons',       reasons, ...
    'rules_version', R.version, ...
    'decided_at',    string(datetime("now","Format","uuuu-MM-dd'T'HH:mm:ss")), ...
    'inputs',        summarise(evidence));

% Every routing decision must be attributable. An action with no rule
% behind it cannot be explained to a clinician or audited afterwards.
if isempty(fired)
    error('ophira:decision:noRule', ...
        'Action "%s" produced with no rule fired. Every decision must be attributable.', action);
end
end

function s = summarise(e)
s = struct();
for f = ["dr_grade","uncertainty","maculopathy"]
    if hasField(e, f); s.(f) = e.(f); else; s.(f) = []; end
end
if hasField(e,'quality'); s.quality = string(e.quality.decision); else; s.quality = "not assessed"; end
if hasField(e,'context') && isfield(e.context,'flags')
    s.ctx_urgent = logical(getfielddef(e.context.flags,'urgent',false));
    s.ctx_pathway = string(getfielddef(e.context.flags,'pathway',""));
else
    s.ctx_urgent = false; s.ctx_pathway = "";
end
end

function tf = hasField(s, f)
tf = isfield(s, f) && ~isempty(s.(f)) && ~(isnumeric(s.(f)) && all(isnan(s.(f))));
end

function s = ternary(c, a, b)
if c; s = a; else; s = b; end
end

function v = getfielddef(s, f, d)
if isfield(s,f) && ~isempty(s.(f)); v = s.(f); else; v = d; end
end
