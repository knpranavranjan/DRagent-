function L = lesions(imagePath)
%LESIONS  Lesion segmentation for one image, cached per file.
%
%   The agent calls run_lesion_analysis to collect the evidence, and then
%   run_xai to draw it. Both need the mask. Without a cache the tiled
%   U-Net runs twice over the same 63 tiles -- about six seconds of pure
%   duplication on every referred case, which is most of the agent's
%   measured overhead.
%
%   Same keying rule as ophira.agent.preprocessed: path plus modification
%   time and size, so a retake into the same filename is never served the
%   rejected capture's mask.

arguments
    imagePath (1,1) string
end

persistent KEY VAL

d = dir(imagePath);
if isempty(d)
    error('ophira:agent:noImage', 'Image not found: %s', imagePath);
end
k = imagePath + "|" + string(d.datenum) + "|" + string(d.bytes);

if isempty(KEY) || KEY ~= k
    VAL = ophira.lesion.segment(imread(imagePath), ReturnMask=true);
    KEY = k;
end
L = VAL;
end
