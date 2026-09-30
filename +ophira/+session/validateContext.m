function validateContext(ctx)
%VALIDATECONTEXT  Assert that a decoded session matches context_core_v1.
%
%   Called by readSession on every load. The front end validates, and the
%   server validates, and this validates again -- because a malformed
%   clinical record reaching the decision engine is the kind of failure that
%   produces a confidently wrong routing decision rather than an error.
%
%   ophira.session.validateContext(ctx)

arguments
    ctx struct
end

EXPECTED = "context_core_v1";

if ~isfield(ctx, 'schema_version')
    error('ophira:session:noSchema', 'Record has no schema_version field.');
end
if ~strcmp(ctx.schema_version, EXPECTED)
    error('ophira:session:schemaMismatch', ...
        ['Schema mismatch: record is "%s", this code expects "%s". ' ...
         'Migrate the record or use the matching code version.'], ...
        ctx.schema_version, EXPECTED);
end

blocks = ["session","patient","eligibility","consent","diabetes", ...
          "ocular_history","symptoms","visual_acuity","flags"];
missing = blocks(~isfield(ctx, blocks));
if ~isempty(missing)
    error('ophira:session:missingBlocks', ...
        'Record is missing required block(s): %s', strjoin(missing, ", "));
end

% --- fields the decision engine depends on -------------------------------
mustHave(ctx.session,  ["session_id","centre_id","operator_id"], "session");
mustHave(ctx.patient,  ["patient_id","age_years","sex"],         "patient");
mustHave(ctx.consent,  ["given","version"],                      "consent");
mustHave(ctx.flags,    ["urgent","urgent_reasons","pathway","rules_version"], "flags");

% --- safety invariants ---------------------------------------------------
% These are not schema checks. They are the properties that make the record
% safe to act on, and a violation means something upstream is broken.

if ~islogical(ctx.flags.urgent) && ~isnumeric(ctx.flags.urgent)
    error('ophira:session:badUrgent', 'flags.urgent must be boolean.');
end

% An urgent flag with no stated reason cannot be reviewed or audited.
if logical(ctx.flags.urgent) && isempty(ctx.flags.urgent_reasons)
    error('ophira:session:urgentWithoutReason', ...
        'flags.urgent is true but urgent_reasons is empty. Every escalation must be attributable.');
end

% A submitted encounter without consent is a protocol violation.
if isfield(ctx.session,'completed_at') && ~isempty(ctx.session.completed_at)
    if ~isequal(ctx.consent.given, true) && ~isequal(ctx.consent.given, 1)
        error('ophira:session:noConsent', ...
            'Session %s is marked complete but consent.given is not true.', ...
            ctx.session.session_id);
    end
end
end

% -------------------------------------------------------------------------
function mustHave(s, fields, name)
missing = fields(~isfield(s, fields));
if ~isempty(missing)
    error('ophira:session:missingFields', ...
        'Block "%s" is missing field(s): %s', name, strjoin(missing, ", "));
end
end
