function C = channelCount(net, inputSize)
%CHANNELCOUNT  Number of channels a headless backbone emits.
%
%   Needed to size the squeeze-excitation bottleneck. Determined by a single
%   forward pass rather than a lookup table, so it stays correct if the
%   backbone or input size changes.
%
%   C = ophira.models.channelCount(net, 512)

arguments
    net (1,1) dlnetwork
    inputSize (1,1) double
end

x = dlarray(zeros(inputSize, inputSize, 3, 1, 'single'), 'SSCB');
y = predict(net, x);
C = size(y, 3);
end
