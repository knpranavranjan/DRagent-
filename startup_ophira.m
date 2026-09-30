function startup_ophira()
%STARTUP_OPHIRA  Set up paths and verify the environment for the OPHIRA project.
%
%   Run this once at the start of every MATLAB session:
%       >> startup_ophira
%
%   The +ophira namespace package is resolved by adding the project ROOT to
%   the path (not the +ophira folder itself -- that is how MATLAB packages work).

root = fileparts(mfilename('fullpath'));

addpath(root);                          % makes +ophira visible as a package
addpath(fullfile(root,'scripts'));
addpath(fullfile(root,'tests'));

% Data/artifact locations are resolved through this one function so that
% nothing downstream ever hardcodes a path.
setenv('OPHIRA_ROOT', root);

fprintf('OPHIRA project root: %s\n', root);

% --- minimum viable environment check -----------------------------------
required = { ...
    'Deep Learning Toolbox',                  'Neural_Network_Toolbox'; ...
    'Image Processing Toolbox',               'Image_Toolbox';          ...
    'Statistics and Machine Learning Toolbox','Statistics_Toolbox'};

missing = {};
for k = 1:size(required,1)
    if ~license('test', required{k,2})
        missing{end+1} = required{k,1}; %#ok<AGROW>
    end
end

if isempty(missing)
    fprintf('Core toolboxes: OK\n');
else
    warning('ophira:missingToolbox', ...
        'Missing required toolbox(es):\n  %s', strjoin(missing, sprintf('\n  ')));
end

if canUseGPU()
    d = gpuDevice();
    fprintf('GPU: %s (%.1f GB)\n', d.Name, d.TotalMemory/1e9);
else
    fprintf(['GPU: NOT AVAILABLE. Training will be impractical.\n' ...
             '     Needs Parallel Computing Toolbox + a supported NVIDIA GPU.\n']);
end
end
