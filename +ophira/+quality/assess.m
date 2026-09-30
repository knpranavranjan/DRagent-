function r = assess(imgPath, opts)
%ASSESS  Run the full quality gate on an image file.
%
%   r = ophira.quality.assess("data/sessions/images/S-1/od_macula_1.jpg")
%   r = ophira.quality.assess(path, Attempt=2)
%
%   Convenience wrapper: read -> extract features -> apply gate. This is the
%   single entry point the worker and the tests both use, so there is one
%   code path from file to decision.

arguments
    imgPath (1,1) string
    opts.Attempt     (1,1) double = 1
    opts.MaxAttempts (1,1) double = 3
    opts.Thresholds  = ophira.quality.defaultThresholds()
end

if ~isfile(imgPath)
    error('ophira:quality:noFile', 'Image not found: %s', imgPath);
end

try
    I = imread(imgPath);
catch ME
    % An unreadable file is not a retake problem -- it is a storage or
    % transfer failure, and pretending otherwise sends the operator back to
    % the camera for no reason.
    r = struct( ...
        'decision',  "UNGRADABLE", ...
        'score',     0, ...
        'reasons',   struct('code',"file:unreadable", ...
                            'text',"Image file could not be read: " + string(ME.message), ...
                            'severity',"fatal"), ...
        'attempt',   opts.Attempt, ...
        'max_attempts', opts.MaxAttempts, ...
        'features',  struct(), ...
        'thresholds_version', opts.Thresholds.version, ...
        'gate_version', "quality_gate_v1", ...
        'assessed_at', string(datetime("now","Format","uuuu-MM-dd'T'HH:mm:ss")));
    return
end

f = ophira.quality.extractFeatures(I);
r = ophira.quality.applyGate(f, ...
        Thresholds=opts.Thresholds, ...
        Attempt=opts.Attempt, ...
        MaxAttempts=opts.MaxAttempts);
end
