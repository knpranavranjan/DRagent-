function R = rulesV1(opts)
%RULESV1  Versioned thresholds for the clinical decision engine.
%
%   R = ophira.decision.rulesV1()
%   R = ophira.decision.rulesV1(Site="PHC-014")
%
%   Every value here is a CLINICAL POLICY CHOICE, not a tuned parameter.
%   Changing one changes who gets referred, so each carries its reasoning
%   and the version string is stamped into every decision the engine makes.
%
%   *** PER-SITE CALIBRATION IS MANDATORY, NOT OPTIONAL. ***
%
%   External validation on Messidor-2 measured what happens without it:
%
%       APTOS-fitted threshold, new site : sensitivity 0.456
%       recalibrated on ~870 local images: sensitivity 0.931
%
%   The models rank cases well everywhere (QWK 0.75 externally) but place
%   the referral boundary far too high on an unseen domain, missing more
%   than half of referable disease. A site that deploys with the shipped
%   threshold is running a system that looks confident and is dangerous.
%
%   So `referable_score_threshold` is deliberately NOT a single number. It
%   is looked up per site, and a site with no calibration record gets a
%   loud warning and the conservative default.
%
%   HISTORY WORTH KEEPING. Until run_24 this threshold was documented as
%   "APTOS-fitted, 0.50" and was neither. 0.50 was decodeCoral's argmax
%   boundary, and the decision engine read the decoded grade and never
%   consulted this field at all -- so every site, calibrated or not, ran on
%   the same implicit boundary and the warning below described a protection
%   that did not exist. The engine now thresholds the score directly.

arguments
    opts.Site (1,1) string = "default"
end

%% ---------------------------------------------- per-site referral threshold
% Threshold on P(DR grade > 1) from the CORAL head -- the quantity the
% referral decision is actually made on, not the decoded grade.
%
% Fitted per site for >= 0.90 sensitivity on local labelled data.
% *** THESE ARE THRESHOLDS ON sigmoid((b + z)/T), T = 1.22. ***
% A threshold fitted on the untempered score is a threshold on a different
% quantity and is NOT interchangeable with these. run_21 published 0.03 for
% Messidor-2 on the untempered score; run_24 refitted it here.
% TARGET SENSITIVITY 0.95. This is the knee of the curve, and BOTH domains
% agree on where it is (run_29). Marginal cost per additional referable
% case caught, per 1000 screened at 10% prevalence:
%
%     0.90 -> 0.95 :  9.3 extra referrals (in-domain) | 10.7 (external)
%     0.95 -> 0.97 : 19.4 extra referrals (in-domain) | 32.0 (external)
%     0.97 -> 0.99 :  catches NOTHING further, costs 29 more. Dominated.
%
% Past 0.95 the cost roughly triples externally while specificity falls to
% 0.671, which would refer 39% of everyone screened at realistic
% prevalence. A referral pathway that collapses under its own volume
% misses every patient, not 5% of them.
SITE_THRESHOLDS = dictionary( ...
    "default",     0.2330117, ... % APTOS calib split, target sens 0.95.
                               ... % Frozen test: sens 0.981 spec 0.894.
                               ... % UNCALIBRATED elsewhere -- see the warning.
    "messidor2",   0.0211263);    % Messidor-2 fit half, target sens 0.95.
                                  % Held-out report half: sens 0.931 spec 0.843.

%% ------------------------------------------------- per-site triage threshold
% THE FILTER IN FRONT OF THE GRADER IS ALSO A CLINICAL PARAMETER.
%
% run_25 ran the whole cascade on Messidor-2 and found the triage stage
% rejecting 77% of images before the grader ever ran -- 54 of 71 referable
% cases among them. The referral threshold above was fitted, honoured by
% the engine, and applied to nothing, because the images never arrived.
%
%   grader alone, APTOS threshold  : sens 0.456
%   grader alone, recalibrated     : sens 0.899
%   FULL CASCADE, either one       : sens 0.380
%
% The cascade was WORSE externally than the grader it wraps. Sensitivity
% lost at stage 1 cannot be recovered downstream: no later stage sees the
% image. So this threshold lives here with the referral threshold, not
% frozen inside m3_triage.mat where no site can reach it.
%
% Fitted for 0.99 sensitivity on REFERABLE disease -- triage is a safety
% filter, not a classifier, and may pass almost everything through.
SITE_TRIAGE = dictionary( ...
    "default",     0.0024551,   ... % APTOS calib. Frozen test: sens(ref)
                                ... % 1.000 at 53% escalation. The shipped
                                ... % 0.7673 scored 0.493 externally.
    "messidor2",   1.61411e-08);    % Messidor-2 fit half. Report half:
                                    % sens(ref) 0.995, 86% escalated.
%
% NOTE THE COST, AND DO NOT HIDE IT. Made safe on an unseen domain the
% filter escalates 86% of images, so it buys almost no compute there. The
% cascade's efficiency claim holds ON A CALIBRATED SITE and nowhere else.

if isKey(SITE_THRESHOLDS, opts.Site)
    thr = SITE_THRESHOLDS(opts.Site);
    triageThr = SITE_TRIAGE(opts.Site);
    calibrated = opts.Site ~= "default";
else
    thr = SITE_THRESHOLDS("default");
    triageThr = SITE_TRIAGE("default");
    calibrated = false;
end

if ~calibrated
    warning('ophira:decision:uncalibrated', ...
        ['Site "%s" has no local calibration. Using the APTOS-fitted ' ...
         'threshold (%.2f), which measured 0.456 sensitivity on external ' ...
         'data -- it misses more than half of referable disease. ' ...
         'Calibrate on local labelled images before screening.'], opts.Site, thr);
end

R = struct( ...
    'version',      "decision_rules_v1", ...
    'site',         opts.Site, ...
    'calibrated',   calibrated, ...
    ...
    ... % ---- urgent ----
    ... % Grade 4 is proliferative DR: sight-threatening on the image alone,
    ... % and urgent regardless of symptoms.
    'urgent_grade',            4, ...
    ...
    ... % ---- referral ----
    ... % Grade >= 2 is moderate NPDR, the standard referable threshold in
    ... % screening programmes.
    'referable_grade',         2, ...
    'referable_score_threshold', thr, ...
    ...
    ... % ---- triage ----
    ... % Threshold on P(any DR) at stage 1. Site-calibrated for the same
    ... % reason as the referral threshold, and for a harsher one: an image
    ... % dropped here is never graded at all.
    'triage_threshold',        triageThr, ...
    ...
    ... % DME risk >= 1 refers on its own. Maculopathy is not derived from
    ... % the DR grade -- a macula can be threatened while retinopathy looks
    ... % mild (Architecture v1.0 section 13).
    'referable_dme',           1, ...
    ...
    ... % ---- abstention ----
    ... % Above this the model declines rather than guessing. Read off the
    ... % risk-coverage curve: abstaining on the most uncertain half raised
    ... % QWK 0.904 -> 0.971 and cut error 22.4% -> 2.3%.
    ...
    ... % HELD AT 0.55 DELIBERATELY. Loosening to 0.50 clears every
    ... % in-domain miss (12 -> 0) for 27% local review, and run_28 shows
    ... % that benefit does NOT survive domain shift: at a calibrated site
    ... % the cases the model MISSES are LESS uncertain (mean 0.368) than
    ... % the ones it catches (0.501). Uncertainty inverts off-domain, so
    ... % abstention there is close to noise -- 22 misses fall only to 18
    ... % at 0.50, and to 9 only at 42% review.
    ...
    ... % THE CAUSE IS KNOWN AND FIXABLE. Temperature T = 1.22 was fitted
    ... % on APTOS and is never refit per site, so uncertainty is an
    ... % UNCALIBRATED quantity everywhere else -- exactly the mistake the
    ... % referral threshold above used to make. Refit T per site, then
    ... % revisit this number. Until then, do not pay 27% review load for
    ... % a safety net that is only known to work at home.
    'abstain_uncertainty',     0.55, ...
    ...
    ... % ---- quality ----
    'max_capture_attempts',    3);
end
