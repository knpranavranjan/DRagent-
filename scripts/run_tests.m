%% RUN_TESTS
% Full MATLAB test suite.
%
%   >> startup_ophira
%   >> run_tests
%
% The frontend has its own suites, which do not need MATLAB:
%   node tests/frontend/test_rules.mjs     clinical escalation rules
%   python tests/frontend/test_api.py      session API (server must be running)

clear; clc;

% tQuality and tDecision were written but never added here, so the suite
% reported "all green" while skipping the gate and the decision engine --
% the two components that decide what happens to a patient. Any new suite
% must be listed here or it does not exist.
suites = {'tCoral', 'tPreproc', 'tSession', 'tQuality', 'tDecision', 'tReport'};

fprintf('================ OPHIRA TEST SUITE ================\n\n');
r = runtests(suites);

fprintf('\n================ SUMMARY ================\n');
for s = suites
    m = startsWith({r.Name}, [s{1} '/']);
    fprintf('  %-12s %2d passed, %2d failed\n', s{1}, ...
        sum([r(m).Passed]), sum([r(m).Failed]));
end
fprintf('  %-12s %2d passed, %2d failed  (%.1f s)\n', 'TOTAL', ...
    sum([r.Passed]), sum([r.Failed]), sum([r.Duration]));

if any([r.Failed])
    fprintf('\nFAILURES:\n');
    for k = find([r.Failed])
        fprintf('  - %s\n', r(k).Name);
    end
else
    fprintf('\nAll green.\n');
end
