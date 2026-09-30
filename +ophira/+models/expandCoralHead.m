function deployNet = expandCoralHead(trainNet, coralBias)
%EXPANDCORALHEAD  Fold the CORAL shared weight + bias vector into a plain fc layer.
%
%   This is the step that makes CORAL deployable.
%
%   Training form        fc(1) -> z,  then logits_k = z + b_k  (b outside the net)
%   Deployment form      fc(K-1) -> sigmoid,  all rows of W equal to w
%
%   The two are mathematically identical:
%
%       row_k of W = w  and  bias_k = b_k
%       =>  logit_k = w'*f + b_k        (exactly as in training)
%
%   Rank monotonicity is preserved because every row of W is the same
%   vector, so the K-1 logits differ only by their biases -- which is the
%   whole point of CORAL.
%
%   Every layer in the result (fullyConnectedLayer, sigmoidLayer) is
%   built-in and code-generable. No custom layers. Verify with:
%       analyzeNetworkForCodegen(deployNet, TargetLibrary='arm-compute')
%
%   deployNet = ophira.models.expandCoralHead(trainNet, coralBias)

arguments
    trainNet  (1,1) dlnetwork
    coralBias
end

b   = extractdata(coralBias);
b   = single(b(:));          % (K-1) x 1
Km1 = numel(b);

% Pull the shared weight row out of the trained fc(1) layer.
idx = strcmp(trainNet.Learnables.Layer, "coral_shared") & ...
      strcmp(trainNet.Learnables.Parameter, "Weights");
if ~any(idx)
    error('ophira:noCoralLayer', ...
        'Layer "coral_shared" not found. Was this net built by buildCoralTrainNet?');
end
w = extractdata(trainNet.Learnables.Value{idx});   % 1 x F
w = single(reshape(w, 1, []));

% Replicate the shared row K-1 times; attach the learned per-task biases.
W = repmat(w, Km1, 1);        % (K-1) x F

lg = layerGraph(trainNet);
lg = removeLayers(lg, "coral_shared");

newHead = [
    fullyConnectedLayer(Km1, Name="coral_fc", Weights=W, Bias=b)
    sigmoidLayer(Name="coral_sig")];

lg = addLayers(lg, newHead);
lg = connectLayers(lg, "drop", "coral_fc");

deployNet = dlnetwork(lg);

fprintf('CORAL head expanded: fc(1)+bias(%d) -> fc(%d)+sigmoid (codegen-safe)\n', ...
    Km1, Km1);
end
