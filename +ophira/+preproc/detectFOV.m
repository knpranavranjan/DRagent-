function [Icrop, bbox, mask, ok] = detectFOV(I, opts)
%DETECTFOV  Find the circular retinal field of view and crop tightly to it.
%
%   Fundus images carry large black borders whose size varies by camera.
%   Cropping to the FOV before resizing is what makes images from different
%   cameras comparable -- it is the single most important preprocessing step
%   and it must be identical in training and inference.
%
%   [Icrop, bbox, mask, ok] = ophira.preproc.detectFOV(I)
%
%   Returns the cropped image, the [x y w h] bounding box used, the retina
%   mask within that crop, and OK -- false when no retinal field could be
%   found.
%
%   WHY `ok` EXISTS
%   When detection fails this function falls back to passing the whole frame
%   through, so that preprocessing still produces an image of the right
%   shape. But the fallback mask is all-true, which is a claim that the
%   entire frame is retina. For preprocessing that is harmless; for the
%   quality gate it is a lie that turns a black frame into "full retinal
%   coverage". Callers that make decisions must check `ok`.

arguments
    I
    opts.Threshold   (1,1) double = 0.05   % fraction of max intensity
    opts.MinAreaFrac (1,1) double = 0.10   % reject blobs smaller than this
    opts.Pad         (1,1) double = 0      % pixels of padding to keep
end

if size(I,3) == 3
    g = rgb2gray(I);
else
    g = I;
end
g = im2double(g);

% The retina is everything meaningfully brighter than the black surround.
bw = g > opts.Threshold;

% Close small gaps, then keep only the largest connected region so that
% specular flecks in the border do not extend the bounding box.
bw = imclose(bw, strel('disk', 5));
bw = imfill(bw, 'holes');

ok = true;

cc = bwconncomp(bw);
if cc.NumObjects == 0
    % Degenerate image. Pass the frame through so preprocessing still yields
    % a correctly shaped result, but report ok=false so decision-making
    % callers do not read the fallback mask as real coverage.
    [Icrop, bbox, mask, ok] = passthrough(I);
    return
end

numPix = cellfun(@numel, cc.PixelIdxList);
[~, big] = max(numPix);

if numPix(big) < opts.MinAreaFrac * numel(g)
    [Icrop, bbox, mask, ok] = passthrough(I);
    return
end

bw = false(size(bw));
bw(cc.PixelIdxList{big}) = true;

st   = regionprops(bw, 'BoundingBox');
bbox = st(1).BoundingBox;

% Integer pixel bounds, padded and clamped to the image.
x0 = max(1, floor(bbox(1)) - opts.Pad);
y0 = max(1, floor(bbox(2)) - opts.Pad);
x1 = min(size(I,2), ceil(bbox(1) + bbox(3)) + opts.Pad);
y1 = min(size(I,1), ceil(bbox(2) + bbox(4)) + opts.Pad);

bbox  = [x0, y0, x1-x0+1, y1-y0+1];
Icrop = I(y0:y1, x0:x1, :);
mask  = bw(y0:y1, x0:x1);
end

% -------------------------------------------------------------------------
function [Icrop, bbox, mask, ok] = passthrough(I)
Icrop = I;
bbox  = [1 1 size(I,2) size(I,1)];
mask  = true(size(I,1), size(I,2));
ok    = false;
end
