function f = extractFeatures(I, opts)
%EXTRACTFEATURES  Image-quality features for the acquisition gate.
%
%   f = ophira.quality.extractFeatures(I)
%
%   Measures the five properties Architecture v1.0 section 09 lists: focus,
%   exposure/illumination, field of view, artifacts and anatomical coverage.
%
%   All measurements are taken INSIDE the retina mask. Including the black
%   surround would let a large border inflate "sharpness" (a hard black edge
%   has enormous Laplacian energy) and deflate exposure statistics. That
%   single mistake is the most common way a fundus quality metric ends up
%   measuring the camera's bezel instead of the retina.
%
%   Returns a struct of raw measurements. It makes NO accept/reject
%   decision -- that is applyGate's job, so the thresholds live in one
%   versioned place and the features can be re-scored without recomputation.

arguments
    I
    opts.Mask = []      % retina mask; computed if omitted
end

t0 = tic;

if size(I,3) == 3
    g = im2double(I(:,:,2));        % green channel: best vessel/lesion contrast
    rgb = im2double(I);
else
    g = im2double(I);
    rgb = repmat(g, 1, 1, 3);
end

% --- retina mask ---------------------------------------------------------
if isempty(opts.Mask)
    % detectFOV is run on the FULL frame so the mask aligns with the image.
    % `ok` is false when no retinal field could be found, in which case its
    % mask is an all-true fallback that must NOT be read as real coverage.
    [~, ~, fullMask, ok] = detectFullFrame(I);
    if ~ok
        f = nullFeatures(size(I), 0, toc(t0)*1000);
        return
    end
    mask = fullMask;
else
    mask = opts.Mask;
end

nPix = numel(g);
nRet = sum(mask(:));
retinaFrac = nRet / nPix;

if nRet < 0.02 * nPix
    % Essentially no retina found. Return a struct with the same fields so
    % downstream code never has to test for a special "failed" shape.
    f = nullFeatures(size(I), retinaFrac, toc(t0)*1000);
    return
end

% Interior mask: the retina/black boundary is a step edge with enormous
% gradient energy and extreme values. Including it would let a heavier blur
% score as *sharper* (the blur spreads bright retina into the dark surround,
% widening the measured spread) and would corrupt every exposure statistic.
% All photometric measurements below therefore use the ERODED mask.
erodeR = max(3, round(0.02 * min(size(g))));
inner  = imerode(mask, strel('disk', erodeR));
if sum(inner(:)) < 0.2 * nRet
    inner = mask;          % tiny field: erosion would remove everything
end

vals = g(inner);

% --- focus ---------------------------------------------------------------
% Variance of the Laplacian, the standard no-reference sharpness proxy.
% Normalised by local contrast so a dim-but-sharp image is not punished.
lap = imfilter(g, fspecial('laplacian', 0.2), 'replicate');
lapIn = lap(inner);
focusRaw = var(lapIn);
contrast = std(vals);
focusNorm = focusRaw / max(contrast^2, 1e-6);

% --- exposure ------------------------------------------------------------
% Measured across ALL THREE CHANNELS, not just green. In a fundus image red
% is by far the brightest channel, so a capture can have a completely blown
% red channel -- real information loss -- while green still looks fine.
% Scoring exposure on green alone silently passes those images.
overExposed  = 0;
underExposed = 0;
for c = 1:3
    ch = rgb(:,:,c);
    chIn = ch(inner);
    overExposed  = max(overExposed,  mean(chIn > 0.98));
    underExposed = max(underExposed, mean(chIn < 0.02));
end
meanLum = mean(vals);

% --- illumination uniformity --------------------------------------------
% Compare quadrant means inside the mask. A strongly lopsided fundus image
% usually means the pupil was not centred or the flash clipped the iris.
[h, w] = size(g);
qm = nan(1,4);
quads = {1:floor(h/2), 1:floor(w/2); 1:floor(h/2), floor(w/2)+1:w; ...
         floor(h/2)+1:h, 1:floor(w/2); floor(h/2)+1:h, floor(w/2)+1:w};
for k = 1:4
    sub  = g(quads{k,1}, quads{k,2});
    subM = inner(quads{k,1}, quads{k,2});
    if sum(subM(:)) > 100; qm(k) = mean(sub(subM)); end
end
qm = qm(~isnan(qm));
if numel(qm) >= 2
    illumUniformity = min(qm) / max(max(qm), eps);   % 1 = perfectly even
else
    illumUniformity = 0;
end

% --- colour balance ------------------------------------------------------
% A heavy channel imbalance indicates white-balance failure or a washed-out
% capture; either makes lesion colour cues unreliable.
chMeans = zeros(1,3);
for c = 1:3
    ch = rgb(:,:,c);
    chMeans(c) = mean(ch(inner));
end
colourBalance = min(chMeans) / max(max(chMeans), eps);

% --- field of view -------------------------------------------------------
% How circular is the detected region? A clipped or partial field scores low.
st = regionprops(mask, 'Area', 'Perimeter', 'BoundingBox');
if ~isempty(st)
    [~, big] = max([st.Area]);
    P = st(big).Perimeter;
    A = st(big).Area;
    circularity = min(1, 4*pi*A / max(P^2, eps));
    bb = st(big).BoundingBox;
    aspect = min(bb(3),bb(4)) / max(max(bb(3),bb(4)), eps);
else
    circularity = 0; aspect = 0;
end

% --- artifacts -----------------------------------------------------------
% Saturated blobs larger than a plausible optic disc: dust, lens flare,
% reflections. The disc itself is bright but bounded, so a size floor
% expressed as a fraction of the retina keeps it from being flagged.
sat = inner & (g > 0.99);
artifactFrac = 0;
if any(sat(:))
    cc = bwconncomp(sat);
    sizes = cellfun(@numel, cc.PixelIdxList);
    big = sizes(sizes > 0.004 * nRet);
    artifactFrac = sum(big) / nRet;
end

f = struct( ...
    'focus_raw',          focusRaw, ...
    'focus_norm',         focusNorm, ...
    'contrast',           contrast, ...
    'mean_luminance',     meanLum, ...
    'over_exposed_frac',  overExposed, ...
    'under_exposed_frac', underExposed, ...
    'illum_uniformity',   illumUniformity, ...
    'colour_balance',     colourBalance, ...
    'retina_frac',        retinaFrac, ...
    'circularity',        circularity, ...
    'aspect',             aspect, ...
    'artifact_frac',      artifactFrac, ...
    'image_height',       size(I,1), ...
    'image_width',        size(I,2), ...
    'features_version',   "quality_features_v1", ...
    'latency_ms',         toc(t0)*1000);
end

% -------------------------------------------------------------------------
function f = nullFeatures(sz, retinaFrac, ms)
f = struct('focus_raw',0,'focus_norm',0,'contrast',0,'mean_luminance',0, ...
    'over_exposed_frac',0,'under_exposed_frac',1,'illum_uniformity',0, ...
    'colour_balance',0,'retina_frac',retinaFrac,'circularity',0,'aspect',0, ...
    'artifact_frac',0,'image_height',sz(1),'image_width',sz(2), ...
    'features_version',"quality_features_v1",'latency_ms',ms);
end

function [Icrop, bbox, mask, ok] = detectFullFrame(I)
%DETECTFULLFRAME  detectFOV, but with the mask expressed on the FULL frame.
% detectFOV returns a mask relative to its crop. Quality features are
% measured against the original image, so the mask has to be placed back.
[Icrop, bbox, cropMask, ok] = ophira.preproc.detectFOV(I);
mask = false(size(I,1), size(I,2));
if ok
    x0 = bbox(1); y0 = bbox(2);
    mask(y0:y0+size(cropMask,1)-1, x0:x0+size(cropMask,2)-1) = cropMask;
else
    mask(:) = true;     % fallback; callers must honour ok=false
end
end
