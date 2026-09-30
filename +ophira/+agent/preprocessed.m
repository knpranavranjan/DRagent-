function I = preprocessed(imagePath)
%PREPROCESSED  The 512 px preprocessed image, cached per path.
%
%   orchestrate.m preprocesses once and reuses the result across stages 1,
%   2 and 2b. The agent calls those stages separately, so without a cache
%   the same Ben Graham + CLAHE pass would run three times on the same
%   file -- about a second of pure waste per case, and worse, three
%   chances for the stages to disagree about what they were looking at.
%
%   Keyed by path AND modification time: an operator who retakes into the
%   same filename must not be served the rejected capture.

arguments
    imagePath (1,1) string
end

persistent KEY IMG

d = dir(imagePath);
if isempty(d)
    error('ophira:agent:noImage', 'Image not found: %s', imagePath);
end
k = imagePath + "|" + string(d.datenum) + "|" + string(d.bytes);

if isempty(KEY) || KEY ~= k
    IMG = ophira.preproc.preprocess(imread(imagePath), Size=512);
    KEY = k;
end
I = IMG;
end
