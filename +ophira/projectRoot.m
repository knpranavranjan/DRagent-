function p = projectRoot(varargin)
%PROJECTROOT  Absolute path to the OPHIRA project, plus optional subpaths.
%
%   p = ophira.projectRoot()
%   p = ophira.projectRoot("data","sessions")
%
%   WHY THIS EXISTS
%   Relative paths resolve against the current folder, and the current folder
%   is not stable: MATLAB's `run` changes it, a user may cd anywhere, and a
%   deployed executable starts wherever it was launched. A data path that
%   silently resolves to the wrong place makes ophira.session.listSessions
%   return an empty list -- which an operator reads as "no urgent cases".
%
%   Every default data path in the project goes through here instead.

root = string(getenv('OPHIRA_ROOT'));

if strlength(root) == 0 || ~isfolder(root)
    % startup_ophira was not run, or the variable is stale. Fall back to the
    % location of this file: <root>/+ophira/projectRoot.m
    here = fileparts(mfilename('fullpath'));
    root = string(fileparts(here));
end

if isempty(varargin)
    p = root;
else
    p = fullfile(root, varargin{:});
end
end
