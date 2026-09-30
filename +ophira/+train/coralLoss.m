function [loss, P] = coralLoss(z, coralBias, grades, opts)
%CORALLOSS  Consistent-rank ordinal loss.
%
%   A grade is decomposed into K-1 binary questions: "is the grade > 0?",
%   "is it > 1?", ... "is it > K-2?". For a true grade g the targets are
%
%       g = 0 -> [0 0 0 0]
%       g = 2 -> [1 1 0 0]
%       g = 4 -> [1 1 1 1]
%
%   Because every task shares the weight vector and differs only by its
%   bias, the predicted probabilities are automatically non-increasing,
%   which is what makes the decoded grade well defined.
%
%   [loss, P] = ophira.train.coralLoss(z, coralBias, grades)
%
%   z          1 x N   shared logits from the network (dlarray)
%   coralBias  1 x K-1 learnable bias vector (dlarray)
%   grades     1 x N   integer labels in 0..K-1
%   P          K-1 x N predicted P(grade > k-1)

arguments
    z
    coralBias
    grades
    opts.ClassWeights = []      % 1 x K-1, upweight the rare severe boundaries
    opts.Eps (1,1) double = 1e-7
end

Km1 = numel(coralBias);
N   = numel(grades);

% logits_k,n = z_n + b_k      (broadcast to K-1 x N)
logits = reshape(coralBias, Km1, 1) + reshape(z, 1, N);
P      = sigmoid(logits);

% Ordinal targets: T(k,n) = 1 if grade_n > k-1
g = reshape(single(extractdata_if(grades)), 1, N);
T = single((0:Km1-1)' < g);

% Binary cross-entropy over all K-1 tasks
bce = -( T .* log(P + opts.Eps) + (1 - T) .* log(1 - P + opts.Eps) );

if ~isempty(opts.ClassWeights)
    w   = reshape(single(opts.ClassWeights), Km1, 1);
    bce = bce .* w;
    loss = sum(bce, 'all') / (sum(w) * N);
else
    loss = sum(bce, 'all') / (Km1 * N);
end
end

% -------------------------------------------------------------------------
function v = extractdata_if(x)
if isa(x, 'dlarray')
    v = extractdata(x);
else
    v = x;
end
end
