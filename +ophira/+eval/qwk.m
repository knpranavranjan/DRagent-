function [k, C] = qwk(yTrue, yPred, numClasses)
%QWK  Quadratic weighted kappa -- the primary DR grading metric.
%
%   Penalises disagreement by the SQUARE of the grade distance, so
%   confusing grade 0 with grade 4 is far worse than 0 with 1. This is why
%   the field uses it for ordinal DR grading instead of accuracy.
%
%   [k, C] = ophira.eval.qwk(yTrue, yPred, 5)
%
%   Interpretation: 1 = perfect, 0 = chance, negative = worse than chance.
%
%   ALWAYS report this with a bootstrap confidence interval
%   (ophira.eval.bootstrapCI). A single QWK number on one split is not
%   evidence -- see docs/00 loophole L9.

arguments
    yTrue
    yPred
    numClasses (1,1) double = 5
end

yTrue = double(yTrue(:));
yPred = double(yPred(:));
N     = numel(yTrue);
K     = numClasses;

% Observed confusion matrix
C = zeros(K);
for i = 1:N
    C(yTrue(i)+1, yPred(i)+1) = C(yTrue(i)+1, yPred(i)+1) + 1;
end

% Quadratic penalty weights
[I, J] = ndgrid(0:K-1, 0:K-1);
W = (I - J).^2 / (K-1)^2;

% Expected matrix under independence of the two marginals
histTrue = sum(C, 2);
histPred = sum(C, 1);
E = (histTrue * histPred) / N;

num = sum(W .* C, 'all');
den = sum(W .* E, 'all');

if den == 0
    k = 0;
else
    k = 1 - num/den;
end
end
