function [net, info] = buildBackbone(name, opts)
%BUILDBACKBONE  Load a pretrained backbone, headless, at a chosen input size.
%
%   Only codegen-safe backbones are offered. MobileNetV3 is deliberately
%   absent: it is not in the Deep Learning Toolbox pretrained set, and
%   importing it from ONNX produces automatically generated custom layers,
%   which MATLAB Coder cannot code-generate. See docs/02 and docs/05.
%
%   [net, info] = ophira.models.buildBackbone("efficientnetb0", Size=512)

arguments
    name (1,1) string {mustBeMember(name, ["mobilenetv2","efficientnetb0", ...
                                           "resnet18","squeezenet"])}
    opts.Size        (1,1) double = 512
    opts.Pretrained  (1,1) logical = true
end

inputSize = [opts.Size opts.Size 3];

% MATLAB's value is "pretrained", not "imagenet" -- the only accepted
% members are 'none' and 'pretrained'.
if opts.Pretrained
    w = "pretrained";
else
    w = "none";
end

% imagePretrainedNetwork (R2024a+) returns a dlnetwork with the
% classification head already removed when NumClasses is omitted.
if exist('imagePretrainedNetwork', 'file') == 2
    base = imagePretrainedNetwork(name, Weights=w);
else
    error('ophira:oldRelease', ...
        ['imagePretrainedNetwork not found. This project targets R2024a or ' ...
         'newer. On an older release, substitute the legacy loaders ' ...
         '(mobilenetv2 / efficientnetb0 / resnet18) and convert with dlnetwork.']);
end

lg = layerGraph(base);

% Strip whatever head the pretrained net shipped with; we attach our own.
names = {lg.Layers.Name};
for k = numel(lg.Layers):-1:1
    L = lg.Layers(k);
    if isa(L,'nnet.cnn.layer.ClassificationOutputLayer') || ...
       isa(L,'nnet.cnn.layer.SoftmaxLayer') || ...
       isa(L,'nnet.cnn.layer.FullyConnectedLayer')
        lg = removeLayers(lg, L.Name);
    else
        break   % stop at the first non-head layer from the end
    end
end

% Replace the input layer so the backbone accepts our working resolution.
inLayer = imageInputLayer(inputSize, Name="input", Normalization="none");
lg = replaceLayer(lg, names{1}, inLayer);

net = dlnetwork(lg);

info = struct( ...
    'name',          name, ...
    'input_size',    inputSize, ...
    'pretrained',    opts.Pretrained, ...
    'feature_layer', string(net.OutputNames{1}), ...
    'num_learnables', sum(cellfun(@numel, net.Learnables.Value)));
end
