function [Iout, info] = preprocess(I, opts)
%PREPROCESS  The ONE preprocessing pipeline. Training and inference both call this.
%
%   This function is the contract. If training and inference ever diverge
%   here, every measured number in the project becomes meaningless. There is
%   deliberately no second code path.
%
%   [Iout, info] = ophira.preproc.preprocess(I)
%   [Iout, info] = ophira.preproc.preprocess(I, Size=512)
%
%   Sequence (Architecture v1.0 section 10):
%     FOV detect -> crop -> square pad -> resize -> Ben Graham -> CLAHE -> mask
%
%   PREPROC_VERSION is stamped into `info` and must be recorded in every
%   stage contract. Bump it whenever anything in this file changes.

arguments
    I
    opts.Size       (1,1) double  = 512
    opts.Alpha      (1,1) double  = 4
    opts.Gamma      (1,1) double  = 128
    opts.SigmaFrac  (1,1) double  = 1/30
    opts.UseCLAHE   (1,1) logical = true
    opts.ClipLimit  (1,1) double  = 0.01   % conservative; see section 10 safety note
    opts.UseBenGraham (1,1) logical = true
end

PREPROC_VERSION = "preproc_v1";

t0 = tic;

% --- 1. FOV detection and tight crop ------------------------------------
[Icrop, bbox, mask] = ophira.preproc.detectFOV(I);

% --- 2/3. Pad to square, then resize ------------------------------------
% Delegated to ophira.preproc.squareFrame so that overlays (lesion masks,
% saliency maps) can apply the IDENTICAL transform. Two copies of this
% arithmetic is two chances to draw a finding in the wrong place.
Ires = ophira.preproc.squareFrame(Icrop, opts.Size, "bilinear");
mres = ophira.preproc.squareFrame(mask,  opts.Size);

% --- 4. Ben Graham local-average subtraction ----------------------------
if opts.UseBenGraham
    Iout = ophira.preproc.benGraham(Ires, ...
        Alpha=opts.Alpha, Gamma=opts.Gamma, ...
        SigmaFrac=opts.SigmaFrac, Mask=mres);
else
    Iout = im2uint8(Ires);
end

% --- 5. Conservative CLAHE, luminance only ------------------------------
% Applied in L*a*b* so that colour ratios are preserved. Section 10 warns
% against aggressive transforms that can create or erase lesion-like
% structure, hence the low clip limit.
if opts.UseCLAHE
    lab = rgb2lab(Iout);
    L   = lab(:,:,1) / 100;
    L   = adapthisteq(L, 'ClipLimit', opts.ClipLimit, 'NumTiles', [8 8]);
    lab(:,:,1) = L * 100;
    Iout = lab2rgb(lab, 'OutputType', 'uint8');
end

% --- 6. Re-apply the mask (CLAHE lifts the black surround) --------------
Iout = Iout .* uint8(repmat(mres, 1, 1, size(Iout,3)));

% --- info ---------------------------------------------------------------
info = struct( ...
    'preproc_version', PREPROC_VERSION, ...
    'orig_size',       [size(I,1) size(I,2)], ...
    'fov_bbox',        bbox, ...
    'out_size',        [opts.Size opts.Size], ...
    'retina_frac',     sum(mres(:)) / numel(mres), ...
    'latency_ms',      toc(t0)*1000);
end
