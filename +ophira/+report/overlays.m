function panels = overlays(imagePath, evidence, opts)
%OVERLAYS  Render the visual evidence panels for the clinician report.
%
%   panels = ophira.report.overlays(imagePath, evidence)
%
%   Returns a struct of base64 data URIs, ready to drop into an <img src>:
%       .fundus     the captured image as the models saw it
%       .lesions    M5 lesion segmentation, colour-coded by lesion type
%       .gradcam    Grad-CAM saliency over the same frame
%       .legend     struct describing which colour means what
%
%   WHY TWO OVERLAYS AND NOT ONE
%
%   These two answer different questions and are worth very different
%   amounts, which the report says out loud rather than leaving to
%   inference from a picture.
%
%     LESION OVERLAY -- supervised, trained on expert pixel annotations.
%     Measured against those annotations it concentrates 5.3x more of its
%     mass on true lesions than chance. This is the panel that answers
%     "where is the disease".
%
%     GRAD-CAM -- what the grader's own gradients attend to. Measured on
%     the SAME images, the same way, it concentrates 2.2x. It is a picture
%     of the model's attention, NOT a lesion map, and the two are commonly
%     confused. run_32 has the numbers.
%
%   Everything is drawn in ONE frame -- ophira.preproc.squareFrame -- so a
%   marking lands on the pixel it refers to. Both sources go through that
%   same transform; see the comment in squareFrame for what goes wrong
%   otherwise.
%
%   DATA URIs, NOT FILES. The report has to survive being downloaded,
%   emailed and printed. A report that references images/ is a report that
%   arrives blank at the district hospital.

arguments
    imagePath (1,1) string
    evidence  struct
    opts.Size    (1,1) double = 512
    opts.Quality (1,1) double = 88      % JPEG quality for the photo panels
    opts.Alpha   (1,1) double = 0.45    % heatmap opacity
    opts.Net                  = []      % M1, for Grad-CAM; loaded if absent
end

panels = struct('fundus', "", 'lesions', "", 'gradcam', "", ...
                'legend', struct(), 'status', "ok", 'message', "");

if imagePath == "" || ~isfile(imagePath)
    panels.status  = "skipped";
    panels.message = "No capture available for this encounter.";
    return
end

try
    I = imread(imagePath);
catch ME
    panels.status  = "failed";
    panels.message = "Could not read the capture: " + string(ME.message);
    return
end

%% ---- the frame everything is drawn in ---------------------------------
[Icrop, ~, ~, ok] = ophira.preproc.detectFOV(I);
if ~ok
    % Without a detected field of view the geometry is a guess, and a guess
    % would put every marking somewhere plausible but wrong.
    panels.status  = "skipped";
    panels.message = "Field of view could not be detected; overlays not drawn.";
    return
end
base = ophira.preproc.squareFrame(Icrop, opts.Size, "bilinear");
base = im2uint8(base);

panels.fundus = dataUri(base, opts.Quality);

%% ---- lesion overlay ----------------------------------------------------
LES    = ["MA","HE","EX","SE"];
NAMES  = ["Microaneurysms","Haemorrhages","Hard exudates","Cotton-wool spots"];
COLOUR = [235 64 64; 214 82 214; 250 200 60; 80 220 220];

if isfield(evidence,'lesions') && isstruct(evidence.lesions) ...
        && isfield(evidence.lesions,'mask') && ~isempty(evidence.lesions.mask)
    M = evidence.lesions.mask;
    if size(M,1) ~= opts.Size
        M = imresize(M, [opts.Size opts.Size], "nearest");
    end

    over = base;
    present = false(1, numel(LES));
    for c = 1:min(size(M,3), numel(LES))
        m = M(:,:,c);
        if ~any(m, 'all'); continue; end
        present(c) = true;
        % OUTLINE THE BIG FINDINGS, FILL THE TINY ONES.
        %
        % A solid patch over a large exudate hides the retina the clinician
        % has to judge for themselves -- the overlay should point, not
        % cover. But a microaneurysm is two or three pixels across, and an
        % outline of that is nothing at all, so those stay filled.
        big  = bwareaopen(m, 40);
        tiny = m & ~big;
        mark = (imdilate(big, strel('disk',2)) & ~imerode(big, strel('disk',2))) ...
               | imdilate(tiny, strel('disk',2));
        for k = 1:3
            ch = over(:,:,k);
            ch(mark) = uint8(0.2*double(ch(mark)) + 0.8*COLOUR(c,k));
            over(:,:,k) = ch;
        end
    end
    panels.lesions = dataUri(over, opts.Quality);

    leg = struct([]);
    for c = 1:numel(LES)
        leg(c).code    = LES(c);
        leg(c).name    = NAMES(c);
        leg(c).rgb     = sprintf("rgb(%d,%d,%d)", COLOUR(c,1), COLOUR(c,2), COLOUR(c,3));
        leg(c).present = present(c);
    end
    panels.legend = leg;
end

%% ---- Grad-CAM ----------------------------------------------------------
% Computed here rather than carried through the cascade: it is needed only
% when a human opens the report, and one backward pass is ~0.3 s.
try
    net = opts.Net;
    if isempty(net)
        M1 = load(ophira.projectRoot("artifacts","models","m1_teacher_aptos.mat"));
        net = M1.net;
    end
    Ip  = ophira.preproc.preprocess(I, Size=opts.Size);
    cam = ophira.xai.saliency(net, dlarray(single(Ip)/255,'SSCB'), Method="gradcam");
    cam = imresize(cam, [opts.Size opts.Size], "bilinear");
    cam = max(0, min(1, cam));
    panels.gradcam = dataUri(heatmap(base, cam, opts.Alpha), opts.Quality);
catch ME
    panels.message = "Grad-CAM unavailable: " + string(ME.message);
end
end

%% ========================================================================
function out = heatmap(base, cam, alpha)
% Blue -> red through the standard hot ramp, weighted by intensity so the
% cool end stays transparent and does not tint the whole retina.
cmap = uint8(255 * jetish(256));
idx  = uint8(round(cam * 255));
H = zeros(size(base), 'uint8');
for k = 1:3
    ch = cmap(:,k);
    H(:,:,k) = reshape(ch(double(idx)+1), size(cam));
end
w = alpha * cam;                      % transparent where there is no signal
out = uint8((1-w) .* double(base) + w .* double(H));
end

function C = jetish(n)
% A jet-like ramp built by hand so this does not depend on a toolbox
% colormap being on the path at report time.
x = linspace(0, 1, n)';
r = min(1, max(0, 1.5 - abs(4*x - 3)));
g = min(1, max(0, 1.5 - abs(4*x - 2)));
b = min(1, max(0, 1.5 - abs(4*x - 1)));
C = [r g b];
end

function uri = dataUri(img, quality)
% JPEG, because these are photographs: a lossless PNG of a 512 px fundus is
% roughly ten times larger, and the report is meant to be emailed.
f = fullfile(tempdir, "ophira_panel_" + string(randi(1e9)) + ".jpg");
imwrite(img, f, "Quality", quality);
c = onCleanup(@() delete(f));
fid = fopen(f, 'r');
raw = fread(fid, Inf, '*uint8');
fclose(fid);
uri = "data:image/jpeg;base64," + string(matlab.net.base64encode(raw));
end
