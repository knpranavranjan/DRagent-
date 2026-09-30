function ctx = readSession(sessionId, opts)
%READSESSION  Load a submitted screening encounter into MATLAB.
%
%   This is the handover point between the clinical workflow front end and
%   the MATLAB pipeline. The front end writes context_core_v1 JSON; MATLAB
%   reads it here and nowhere else.
%
%   ctx = ophira.session.readSession("S-20260920-143012-A1B2C3")
%   ctx = ophira.session.readSession(id, Root="data/sessions", AllowDraft=true)
%
%   THE DATA BOUNDARY
%   The struct returned here feeds ophira.decision.* ONLY. It must never be
%   passed to a network, a preprocessing function, or a training routine.
%   The image model sees pixels; the decision engine sees this. Keeping the
%   two apart is what lets the model be trained and evaluated on public
%   datasets that carry no clinical context at all.

arguments
    sessionId (1,1) string
    opts.Root       (1,1) string  = ophira.projectRoot("data","sessions")
    opts.AllowDraft (1,1) logical = false
end

candidates = fullfile(opts.Root, "submitted", sessionId + ".json");
if opts.AllowDraft
    candidates(end+1) = fullfile(opts.Root, "drafts", sessionId + ".json");
end

path = "";
for c = candidates
    if isfile(c); path = c; break; end
end

if path == ""
    error('ophira:session:notFound', ...
        'Session "%s" not found under %s.', sessionId, opts.Root);
end

raw = fileread(path);
ctx = jsondecode(raw);

ophira.session.validateContext(ctx);

% jsondecode turns a JSON array of objects into a struct array, and an array
% of strings into a cell -- but an array with ONE element collapses to a
% bare value. Normalise the list-valued fields so downstream code can always
% assume a cellstr, which is the kind of edge case that only shows up in
% production with a patient reporting exactly one symptom.
ctx.diabetes.treatment          = asCellstr(ctx.diabetes.treatment);
ctx.ocular_history.conditions   = asCellstr(ctx.ocular_history.conditions);
ctx.symptoms.reported           = asCellstr(ctx.symptoms.reported);
end

% -------------------------------------------------------------------------
function c = asCellstr(v)
if isempty(v)
    c = {};
elseif ischar(v) || isstring(v)
    c = cellstr(v);
elseif iscell(v)
    c = cellfun(@(x) char(string(x)), v, 'UniformOutput', false);
else
    c = {};
end
end
