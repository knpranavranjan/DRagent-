function Iout = benGraham(I, opts)
%BENGRAHAM  Local-average colour subtraction for fundus images.
%
%   The classic Kaggle/APTOS normalisation. Subtracting a heavily blurred
%   copy removes the slow illumination gradient and the camera's colour
%   cast, leaving lesion-scale structure. It is the cheapest large accuracy
%   gain available on DR data.
%
%       Iout = alpha*I - alpha*blur(I) + gamma
%
%   Iout = ophira.preproc.benGraham(I)
%
%   Note the sigma is expressed as a FRACTION of image width, so the
%   operation is resolution-independent -- important because we apply it
%   both to full images and to high-resolution tiles.

arguments
    I
    opts.Alpha     (1,1) double = 4
    opts.Gamma     (1,1) double = 128
    opts.SigmaFrac (1,1) double = 1/30   % sigma = width/30
    opts.Mask                   = []     % retina mask; outside is forced black
end

Id = im2double(I) * 255;

sigma = max(1, opts.SigmaFrac * size(Id,2));
blur  = imgaussfilt(Id, sigma, 'FilterDomain', 'spatial', 'Padding', 'symmetric');

Iout = opts.Alpha*Id - opts.Alpha*blur + opts.Gamma;
Iout = uint8(min(255, max(0, Iout)));

% Outside the retina the subtraction produces mid-grey, which the network
% would happily learn from. Force it black.
if ~isempty(opts.Mask)
    m = opts.Mask;
    if ~isequal(size(m), [size(Iout,1) size(Iout,2)])
        m = imresize(m, [size(Iout,1) size(Iout,2)], 'nearest');
    end
    Iout = Iout .* uint8(repmat(m, 1, 1, size(Iout,3)));
end
end
