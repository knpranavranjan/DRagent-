function T = listSessions(opts)
%LISTSESSIONS  Table of screening encounters on disk.
%
%   T = ophira.session.listSessions()
%   T = ophira.session.listSessions(Root="data/sessions", State="submitted")
%
%   Sorted urgent-first, then newest-first -- the same ordering the clinician
%   review queue uses (Architecture v1.0 section 19: urgent, then
%   abstained/ungradable, then sight-threatening, then referable, routine).

arguments
    opts.Root  (1,1) string = ophira.projectRoot("data","sessions")
    opts.State (1,1) string {mustBeMember(opts.State, ["all","submitted","draft"])} = "submitted"
end

% An absent store is reported, never silently returned as "no sessions".
% Empty-because-nothing-was-screened and empty-because-we-looked-in-the-
% wrong-place must not look identical to the operator.
if ~isfolder(opts.Root)
    error('ophira:session:noStore', ...
        ['Session store not found: %s\n' ...
         'Has the encounter server run yet? Start it with:\n' ...
         '    python app/server/ophira_server.py'], opts.Root);
end

folders = struct('name', {}, 'state', {});
if opts.State == "all" || opts.State == "submitted"
    folders(end+1) = struct('name', fullfile(opts.Root,"submitted"), 'state', "submitted");
end
if opts.State == "all" || opts.State == "draft"
    folders(end+1) = struct('name', fullfile(opts.Root,"drafts"), 'state', "draft");
end

rows = {};
for f = folders
    if ~isfolder(f.name); continue; end
    files = dir(fullfile(f.name, "*.json"));
    for k = 1:numel(files)
        p = fullfile(files(k).folder, files(k).name);
        try
            ctx = jsondecode(fileread(p));
        catch
            rows(end+1,:) = {string(erase(files(k).name,".json")), f.state, ...
                "", "", NaT, false, "CORRUPT", string(p)}; %#ok<AGROW>
            continue
        end
        rows(end+1,:) = { ...
            getf(ctx.session,'session_id',""), ...
            f.state, ...
            getf(ctx.patient,'patient_id',""), ...
            getf(ctx.session,'centre_id',""), ...
            parseTime(getf(ctx.session,'created_at',"")), ...
            logical(getf(ctx.flags,'urgent',false)), ...
            getf(ctx.flags,'pathway',""), ...
            string(p)}; %#ok<AGROW>
    end
end

if isempty(rows)
    T = table('Size',[0 8], ...
        'VariableTypes',{'string','string','string','string','datetime','logical','string','string'}, ...
        'VariableNames',{'session_id','state','patient_id','centre_id','created_at','urgent','pathway','path'});
    return
end

T = cell2table(rows, 'VariableNames', ...
    {'session_id','state','patient_id','centre_id','created_at','urgent','pathway','path'});

% Urgent first, then newest first.
T = sortrows(T, {'urgent','created_at'}, {'descend','descend'});

nUrgent = sum(T.urgent);
fprintf('%d session(s); %d flagged urgent\n', height(T), nUrgent);
if nUrgent > 0
    fprintf('  URGENT: %s\n', strjoin(T.session_id(T.urgent)', ', '));
end
end

% -------------------------------------------------------------------------
function v = getf(s, name, dflt)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
    if ischar(v); v = string(v); end
else
    v = dflt;
end
end

function t = parseTime(s)
t = NaT;
if strlength(string(s)) > 0
    try
        t = datetime(string(s), 'InputFormat', "uuuu-MM-dd'T'HH:mm:ss.SSSXXX", 'TimeZone','UTC');
    catch
        try
            t = datetime(string(s), 'InputFormat', "uuuu-MM-dd'T'HH:mm:ssXXX", 'TimeZone','UTC');
        catch
            t = NaT;
        end
    end
end
end
