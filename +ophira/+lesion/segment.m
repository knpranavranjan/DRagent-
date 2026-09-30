function L = segment(I, opts)
%SEGMENT  M5 lesion segmentation over a whole fundus image (stage 3).
%
%   L = ophira.lesion.segment(I)
%   L = ophira.lesion.segment(I, Net=net, ReturnMask=true)
%
%   Returns per-lesion pixel counts and area fractions for
%   MA (microaneurysms), HE (haemorrhages), EX (hard exudates) and
%   SE (soft exudates / cotton-wool spots).
%
%   *** THE INPUT IS THE ORIGINAL IMAGE, NOT THE PREPROCESSED ONE. ***
%
%   M5 was trained on tiles cut from RAW IDRiD images -- no Ben Graham
%   subtraction, no CLAHE, only `single(tile)/255`. Feeding it the
%   preprocessed 512 px image would be the same class of mistake that made
%   the triage stage clear every severe case: an input the network has
%   never seen, at a scale it has never seen.
%
%   *** SCALE IS NORMALISED BY FIELD OF VIEW, NOT BY IMAGE SIZE. ***
%
%   A microaneurysm is a few pixels across, and how many pixels depends
%   entirely on the camera's resolution. IDRiD's retina spans a median of
%   3416 px (measured over all 81 segmentation images, min 3413, max 3805).
%   Messidor's spans roughly a third of that. Resizing the whole FRAME to a
%   fixed size would not fix this, because the black border varies by
%   camera. So the FOV is detected, cropped, and rescaled to IDRiD's width.
%
%   WHAT THIS OUTPUT IS FOR
%   Explanation, not routing. Stage 3 runs only for cases a clinician will
%   already see, and no decision rule reads it. Dice on IDRiD test is
%   MA 0.424, HE 0.404, EX 0.613, SE 0.095 -- SE in particular is too weak
%   to act on, and every number here travels with that caveat.

arguments
    I
    opts.Net                      = []
    opts.ReturnMask (1,1) logical = false
    opts.Tile       (1,1) double  = 512
    opts.Stride     (1,1) double  = 384
    opts.RefFOV     (1,1) double  = 3416   % IDRiD median FOV width, measured
    opts.Threshold  (1,1) double  = 0.5
    opts.ReturnProb (1,1) logical = false   % averaged probability map, for XAI comparison
    opts.DisplaySize (1,1) double = 512     % frame the returned mask is drawn in
end

persistent CACHE

LESIONS = ["MA","HE","EX","SE"];
t0 = tic;

net = opts.Net;
if isempty(net)
    if isempty(CACHE)
        CACHE = load(ophira.projectRoot("artifacts","models","m5_lesion_unet.mat"));
    end
    net = CACHE.bestNet;
end

%% ---- crop to the retina, then match IDRiD's scale ----------------------
[Icrop, ~, fovMask, ok] = ophira.preproc.detectFOV(I);

% A failed FOV detection returns an all-true mask, which would claim the
% whole frame is retina and put the scale factor wildly wrong. Lesion
% evidence from that is not evidence.
if ~ok
    L = emptyResult(LESIONS, toc(t0)*1000);
    L.status  = "skipped";
    L.message = "Field of view could not be detected; lesion evidence not computed.";
    return
end

% The ORIGINAL crop geometry, kept so the mask can be mapped back onto the
% image a clinician actually sees. Everything below works in a rescaled,
% possibly padded frame; an overlay drawn in that frame is misplaced.
cropSize = [size(Icrop,1) size(Icrop,2)];

scale = opts.RefFOV / size(Icrop, 2);
if abs(scale - 1) > 0.02
    Icrop   = imresize(Icrop, scale);
    fovMask = imresize(fovMask, scale, "nearest");
end
[H, W, ~] = size(Icrop);

% Pad if the rescaled retina is smaller than one tile, which happens with
% low-resolution cameras.
padY = max(0, opts.Tile - H); padX = max(0, opts.Tile - W);
if padY > 0 || padX > 0
    Icrop   = padarray(Icrop,   [padY padX 0], 0, "post");
    fovMask = padarray(fovMask, [padY padX],   false, "post");
    [H, W, ~] = size(Icrop);
end

%% ---- slide the network over the retina --------------------------------
ys = tileStarts(H, opts.Tile, opts.Stride);
xs = tileStarts(W, opts.Tile, opts.Stride);

acc = zeros(H, W, numel(LESIONS), 'single');
cnt = zeros(H, W, 'single');
nTiles = 0;

for y = ys
    batchX = []; coords = [];
    for x = xs
        % Skip tiles that are mostly outside the retina. They are black,
        % the network has nothing to find in them, and at this scale they
        % are about a fifth of the grid.
        if mean(fovMask(y:y+opts.Tile-1, x:x+opts.Tile-1), 'all') < 0.10
            continue
        end
        batchX = cat(4, batchX, single(Icrop(y:y+opts.Tile-1, x:x+opts.Tile-1, :))/255);
        coords(end+1) = x; %#ok<AGROW>
    end
    if isempty(coords); continue; end

    P = gather(extractdata(predict(net, dlarray(batchX, 'SSCB'))));
    nTiles = nTiles + numel(coords);
    for k = 1:numel(coords)
        x = coords(k);
        acc(y:y+opts.Tile-1, x:x+opts.Tile-1, :) = ...
            acc(y:y+opts.Tile-1, x:x+opts.Tile-1, :) + P(:,:,:,k);
        cnt(y:y+opts.Tile-1, x:x+opts.Tile-1) = ...
            cnt(y:y+opts.Tile-1, x:x+opts.Tile-1) + 1;
    end
end

cnt(cnt == 0) = 1;
Prob = acc ./ cnt;
B = Prob > opts.Threshold;
B = B & fovMask;                       % nothing outside the retina counts

%% ---- report ------------------------------------------------------------
fovPix = max(sum(fovMask, 'all'), 1);
L = struct();
L.lesions    = LESIONS;
L.pixels     = struct();
L.area_frac  = struct();
for c = 1:numel(LESIONS)
    n = sum(B(:,:,c), 'all');
    L.pixels.(LESIONS(c))    = double(n);
    L.area_frac.(LESIONS(c)) = double(n) / double(fovPix);
end

L.fov_scale  = scale;
L.tiles      = nTiles;
L.latency_ms = toc(t0)*1000;
L.status     = "ok";
L.message    = "";

% The mask is large; it is returned only when something will display it.
%
% IT IS MAPPED BACK THROUGH THE EXACT TRANSFORM THE DISPLAY IMAGE USES.
% Resizing B straight to 512x512 -- which this did originally -- stretches
% the aspect ratio, because B lives in a frame that was rescaled by FOV
% WIDTH and then padded. On a 4288x2848 fundus that shifts a finding by
% over a hundred pixels vertically, which would point a clinician at
% healthy retina and imply the model found something there.
if opts.ReturnMask
    % 1. undo the pad added for tiling, 2. undo the FOV rescale,
    % 3. apply the same pad-to-square + resize as ophira.preproc.preprocess.
    hS = min(size(B,1), max(1, round(cropSize(1) * scale)));
    wS = min(size(B,2), max(1, round(cropSize(2) * scale)));
    Bc = B(1:hS, 1:wS, :);
    Bc = imresize(Bc, cropSize, "nearest");
    L.mask = ophira.preproc.squareFrame(Bc, opts.DisplaySize);
end

% The raw probability map, in the SAME cropped-and-rescaled frame the
% tiling ran in. Used as the supervised control arm when saliency methods
% are scored against lesion masks -- a control has to be measured on
% exactly the same footing as the thing it controls for.
if opts.ReturnProb
    L.prob    = max(Prob, [], 3) .* double(fovMask);
    L.fovMask = fovMask;
end
end

%% ========================================================================
function s = tileStarts(n, tile, stride)
s = 1:stride:(n - tile + 1);
if isempty(s); s = 1; end
if s(end) ~= n - tile + 1; s(end+1) = n - tile + 1; end
end

function L = emptyResult(LESIONS, ms)
L = struct('lesions', LESIONS, 'pixels', struct(), 'area_frac', struct(), ...
           'fov_scale', NaN, 'tiles', 0, 'latency_ms', ms, ...
           'status', "ok", 'message', "");
for c = 1:numel(LESIONS)
    L.pixels.(LESIONS(c))    = NaN;
    L.area_frac.(LESIONS(c)) = NaN;
end
end
