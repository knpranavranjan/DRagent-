function [grade, conf, unc, probs] = decodeCoral(P, opts)
%DECODECORAL  Turn K-1 cumulative probabilities into a grade plus uncertainty.
%
%   P(k) = P(grade > k-1), non-increasing in k by construction.
%
%       P = [0.98 0.91 0.12 0.03]  ->  grade 2
%
%   Decoding is a comparison and a sum -- deliberately trivial, so it
%   code-generates without thought.
%
%   [grade, conf, unc, probs] = ophira.infer.decodeCoral(P)
%
%   grade  0..K-1
%   conf   distance of the deciding probability from the 0.5 boundary,
%          rescaled to [0,1]. Low conf means the case sits on a grade border.
%   unc    normalised entropy of the implied per-class distribution.
%          This is what the cascade escalates on and what the decision
%          engine abstains on.
%   probs  1 x K implied per-class probabilities

arguments
    P
    opts.Threshold (1,1) double = 0.5
    opts.Monotonic (1,1) logical = true
end

if isa(P, 'dlarray'); P = extractdata(P); end
P = double(P(:))';
Km1 = numel(P);
K   = Km1 + 1;

% Training guarantees monotonicity; quantisation on the edge device can
% perturb it by a fraction. Enforce it so decoding stays well defined.
if opts.Monotonic
    P = cummin(P);
end

grade = sum(P > opts.Threshold);

% Per-class probabilities from the cumulative form:
%   p(0)   = 1 - P(1)
%   p(k)   = P(k) - P(k+1)
%   p(K-1) = P(K-1)
probs      = zeros(1, K);
probs(1)   = 1 - P(1);
probs(2:K-1) = P(1:Km1-1) - P(2:Km1);
probs(K)   = P(Km1);
probs      = max(probs, 0);
probs      = probs / max(sum(probs), eps);

% Confidence: how far the deciding boundary is from 0.5.
if grade == 0
    margin = opts.Threshold - P(1);
elseif grade == Km1
    margin = P(Km1) - opts.Threshold;
else
    margin = min(P(grade) - opts.Threshold, opts.Threshold - P(grade+1));
end
conf = min(1, max(0, 2 * margin));

% Uncertainty: normalised entropy over the implied class distribution.
q   = probs(probs > 0);
unc = -sum(q .* log(q)) / log(K);
end
