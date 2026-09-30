function Y = squareFrame(X, sz, method)
%SQUAREFRAME  Pad a field-of-view crop to square, then resize.
%
%   Y = ophira.preproc.squareFrame(Icrop, 512)
%   Y = ophira.preproc.squareFrame(mask,  512, "nearest")
%
%   THIS IS THE CANONICAL DISPLAY GEOMETRY, AND IT EXISTS TO STOP OVERLAYS
%   LYING ABOUT WHERE A FINDING IS.
%
%   ophira.preproc.preprocess pads the FOV crop to a square BEFORE resizing,
%   so a wide fundus is letterboxed rather than stretched. Anything that
%   wants to be drawn on top of that image -- a lesion mask, a saliency
%   heatmap -- has to go through the identical transform or it lands in the
%   wrong place. ophira.lesion.segment originally resized its mask straight
%   to 512x512, which distorts the aspect ratio: on a 4288x2848 fundus that
%   moves a finding by more than a hundred pixels vertically.
%
%   A misplaced overlay is worse than no overlay. It points a clinician at
%   healthy retina and implies the model found something there.
%
%   So both paths call this, and there is one transform to get wrong.

arguments
    X
    sz     (1,1) double = 512
    method (1,1) string = "bilinear"
end

[h, w, c] = size(X, 1:3);
side = max(h, w);

if islogical(X)
    P = false(side, side, c);
elseif isa(X, 'double') || isa(X, 'single')
    P = zeros(side, side, c, 'like', X);
else
    P = zeros(side, side, c, 'like', X);
end

r0 = floor((side - h)/2) + 1;
c0 = floor((side - w)/2) + 1;
P(r0:r0+h-1, c0:c0+w-1, :) = X;

if islogical(X)
    Y = imresize(P, [sz sz], "nearest");
else
    Y = imresize(P, [sz sz], method);
end
end
