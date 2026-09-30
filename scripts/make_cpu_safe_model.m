function make_cpu_safe_model(srcRoot)
%MAKE_CPU_SAFE_MODEL  Write a CPU-loadable copy of M1 into this deployment.
%
%   make_cpu_safe_model("C:\path\to\master\project")
%
%   READS the master project's m1_teacher_aptos.mat. WRITES only into this
%   deployment's artifacts/models. The master file is never opened for
%   writing.
%
%   WHY THIS EXISTS
%
%   m1_teacher_aptos.mat stores `coralBias` as a dlarray whose underlying
%   data is a gpuArray -- an artefact of the training loop having run on a
%   GPU when the file was saved. Loading it on a machine with no CUDA
%   device throws at ophira.cascade.orchestrate:
%
%       Error using double
%       Unable to find a supported GPU device.
%
%   That makes an NVIDIA GPU a hard requirement for INFERENCE, which is not
%   something the architecture ever intended and is a poor fit for the
%   rural deployment this system is for.
%
%   THE CHANGE IS STORAGE RESIDENCY AND NOTHING ELSE. gather() moves the
%   four CORAL bias values from device memory to host memory. The values,
%   the class, the shape, the network weights, the thresholds and the
%   calibration are all preserved, and this function verifies that bit for
%   bit before it writes anything.

arguments
    srcRoot (1,1) string
end

src = fullfile(srcRoot, "artifacts", "models", "m1_teacher_aptos.mat");
dstRoot = string(fileparts(fileparts(mfilename('fullpath'))));
dst = fullfile(dstRoot, "artifacts", "models", "m1_teacher_aptos.mat");

if ~isfile(src)
    error('dragent:noSource', 'Master model not found: %s', src);
end
if ~contains(dst, "DRagent")
    error('dragent:unsafeTarget', ...
        'Refusing to write outside DRagent. Target was: %s', dst);
end

fprintf('source (read-only) : %s\n', src);
fprintf('target             : %s\n\n', dst);

S = load(src);
fn = fieldnames(S);
fprintf('variables in the master file:\n');
for k = 1:numel(fn)
    fprintf('  %-14s %s\n', fn{k}, class(S.(fn{k})));
end

if ~isfield(S, 'coralBias')
    error('dragent:noCoralBias', 'coralBias not present -- aborting.');
end

before = S.coralBias;
onGPU = isa(extractdata(before), 'gpuArray');
fprintf('\ncoralBias: class %s, data on GPU: %d\n', class(before), onGPU);

vBefore = double(gather(extractdata(before)));
fprintf('values before : %s\n', mat2str(vBefore, 12));

% THE FIX. gather() on the dlarray moves its data to host memory and
% returns a dlarray of the same size and class.
S.coralBias = gather(before);

vAfter = double(extractdata(S.coralBias));
fprintf('values after  : %s\n', mat2str(vAfter, 12));

% Refuse to write if anything moved.
if ~isequal(size(before), size(S.coralBias))
    error('dragent:shapeChanged', 'coralBias shape changed -- aborting.');
end
if ~isa(S.coralBias, class(before))
    error('dragent:classChanged', 'coralBias class changed -- aborting.');
end
if ~isequaln(vBefore, vAfter)
    error('dragent:valuesChanged', ...
        'coralBias VALUES changed. This must be a residency change only.');
end
if isa(extractdata(S.coralBias), 'gpuArray')
    error('dragent:stillOnGPU', 'coralBias is still GPU-resident -- aborting.');
end
fprintf('\nvalues identical, shape identical, class identical, now on host.\n');

if ~isfolder(fileparts(dst)); mkdir(fileparts(dst)); end
save(dst, '-struct', 'S', '-v7.3');

% Read the written file back and check every variable against the master.
R = load(dst);
rn = fieldnames(R);
if ~isequal(sort(fn), sort(rn))
    error('dragent:varsLost', 'Variable set differs after save.');
end
fprintf('\nwritten and reloaded. %d variables, same names.\n', numel(rn));

% Network weights must be untouched.
w1 = S.net.Learnables; w2 = R.net.Learnables;
maxDiff = 0;
for r = 1:height(w1)
    d = max(abs(double(gather(extractdata(w1.Value{r}))) - ...
                double(gather(extractdata(w2.Value{r})))), [], 'all');
    maxDiff = max(maxDiff, d);
end
fprintf('max weight difference vs master: %g\n', maxDiff);
if maxDiff ~= 0
    error('dragent:weightsChanged', 'Network weights changed -- aborting.');
end

d = dir(dst);
fprintf('\nDONE: %s (%.1f MB)\n', dst, d.bytes/1048576);
end
