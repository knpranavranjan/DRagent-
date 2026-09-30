function S = saliency(net, X, opts)
%SALIENCY  Saliency maps for the CORAL grader, four methods, one interface.
%
%   S = ophira.xai.saliency(net, X)                    % Grad-CAM
%   S = ophira.xai.saliency(net, X, Method="hirescam")
%   S = ophira.xai.saliency(net, X, Method="scorecam", MaxChannels=128)
%   S = ophira.xai.saliency(net, X, Method="intgrad",  Steps=32)
%
%   `X` is a dlarray 'SSCB' with batch size 1, scaled exactly as the grader
%   was trained: single(I)/255 at 512 px.
%
%   Returns a map normalised to [0,1] at the resolution the method produces
%   (16x16 for the CAM family at 512 px input, 512x512 for integrated
%   gradients). Callers upsample.
%
%   *** WHY predict() AND NOT forward() ***
%
%   Automatic differentiation normally goes through forward(), which runs
%   layers in TRAINING mode. This network has batch normalisation, and at
%   batch size 1 training-mode BN normalises every channel to zero mean --
%   it would produce a confident-looking map of essentially nothing. It
%   also has dropout, which would make the map non-deterministic.
%
%   predict() is differentiable here and runs inference-mode BN. Verified:
%   the logit through the AD path equals the logit from a plain predict()
%   call to four decimals.
%
%   *** WHAT SCORE IS DIFFERENTIATED ***
%
%   The CORAL head emits ONE shared logit z, with P(grade > k) =
%   sigmoid((b_k + z)/T). Every threshold is monotone in z, so z is the
%   severity score and the natural target -- there is no per-class logit to
%   pick, and differentiating a single P(grade>k) would only rescale the
%   map by sigmoid'(.), leaving the spatial pattern identical.

arguments
    net
    X
    opts.Method      (1,1) string = "gradcam"
    opts.Layer       (1,1) string = "efficientnet-b0|model|head|MulLayer"
    opts.Steps       (1,1) double = 32     % integrated gradients
    opts.MaxChannels (1,1) double = 128    % score-CAM budget
end

switch lower(opts.Method)
    case "gradcam"
        [A, g] = actAndGrad(net, X, opts.Layer);
        % Channel weights are the spatially pooled gradients; the map is
        % the positively-contributing part of the weighted channel sum.
        w = mean(g, [1 2]);
        S = relu0(sum(w .* A, 3));

    case "hirescam"
        [A, g] = actAndGrad(net, X, opts.Layer);
        % HiResCAM multiplies elementwise instead of pooling the gradient
        % first, so it cannot attribute to a location whose gradient is
        % zero. Strictly more faithful to the model than Grad-CAM.
        S = relu0(sum(g .* A, 3));

    case "scorecam"
        S = scoreCAM(net, X, opts.Layer, opts.MaxChannels);

    case "intgrad"
        S = integratedGradients(net, X, opts.Steps);

    otherwise
        error('ophira:xai:method', 'Unknown method "%s".', opts.Method);
end

S = normalise01(S);
end

%% ========================================================================
function [A, g] = actAndGrad(net, X, layer)
[A, g] = dlfeval(@agInner, net, X, layer);
A = double(gather(extractdata(A)));
g = double(gather(extractdata(g)));
end

function [A, g] = agInner(net, X, layer)
[A, z] = predict(net, X, Outputs=[layer, string(net.OutputNames{1})]);
g = dlgradient(sum(z, 'all'), A);
end

function S = scoreCAM(net, X, layer, maxCh)
% Gradient-free: each channel's activation map becomes a soft mask on the
% input, and its weight is the score that masked input produces.
%
% EfficientNet-B0's head has 1280 channels, which would be 1280 forward
% passes per image. Channels are ranked by activation energy and the top
% `maxCh` are used -- the rest contribute almost nothing to the weighted
% sum and this is standard practice for the method.
A = predict(net, X, Outputs=layer);
A = double(gather(extractdata(A)));
[H, W, C] = size(A, 1:3);

energy = squeeze(sum(A, [1 2]));
[~, ord] = sort(energy, 'descend');
sel = ord(1:min(maxCh, C));

Xd = double(gather(extractdata(X)));
sz = size(Xd, 1:2);

base = double(gather(extractdata(predict(net, X))));

scores = zeros(numel(sel), 1);
BATCH = 16;
for i = 1:BATCH:numel(sel)
    j = min(numel(sel), i+BATCH-1);
    Xb = zeros([sz 3 j-i+1], 'single');
    for k = i:j
        m = A(:,:,sel(k));
        m = m - min(m(:)); if max(m(:)) > 0; m = m / max(m(:)); end
        m = imresize(m, sz, "bilinear");
        Xb(:,:,:,k-i+1) = single(Xd .* m);
    end
    sc = double(gather(extractdata(predict(net, dlarray(Xb,'SSCB')))));
    scores(i:j) = sc(:) - base;     % contribution relative to the full image
end

% Softmax over contributions, as the method specifies, then weight.
wgt = exp(scores - max(scores)); wgt = wgt / sum(wgt);
S = zeros(H, W);
for k = 1:numel(sel)
    S = S + wgt(k) * A(:,:,sel(k));
end
S = relu0(S);
end

function S = integratedGradients(net, X, steps)
% Input-space attribution. Baseline is a black image, which for a fundus
% photograph is the physically meaningful "no retina" reference.
Xd = extractdata(X);
base = zeros(size(Xd), 'like', Xd);

total = zeros(size(Xd), 'like', Xd);
for s = 1:steps
    alpha = (s - 0.5) / steps;          % midpoint rule
    Xi = dlarray(base + alpha * (Xd - base), 'SSCB');
    g = dlfeval(@igInner, net, Xi);
    total = total + g;
end
attr = (Xd - base) .* (total / steps);

% Sum the signed attribution over colour channels, then keep the positive
% part: these are the pixels pushing the severity score UP.
S = double(gather(extractdata(sum(attr, 3))));
S = relu0(S);
end

function g = igInner(net, X)
z = predict(net, X);
g = dlgradient(sum(z, 'all'), X);
end

function S = relu0(S)
S = max(S, 0);
end

function S = normalise01(S)
S = double(S);
S = S - min(S(:));
m = max(S(:));
if m > 0; S = S / m; end
end
