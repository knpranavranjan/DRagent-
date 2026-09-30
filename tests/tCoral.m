classdef tCoral < matlab.unittest.TestCase
    %TCORAL  Unit tests for the CORAL ordinal head.
    %
    %   The critical test is testExpansionIsExact: it proves that the
    %   deployed fc(K-1) network produces IDENTICAL outputs to the training
    %   form. If that ever fails, the Raspberry Pi path is silently broken
    %   and every deployed prediction is wrong.
    %
    %   >> runtests('tCoral')

    methods (Test)

        function testLossIsZeroOnPerfectPrediction(tc)
            % Targets for grade 2 with K=5 are [1 1 0 0]; a model whose
            % sigmoids match should incur near-zero loss.
            coralBias = dlarray(single([20 20 -20 -20]));  % saturated sigmoids
            z         = dlarray(single(0));
            [loss, P] = ophira.train.coralLoss(z, coralBias, 2);

            tc.verifyLessThan(double(extractdata(loss)), 1e-4);
            tc.verifyEqual(double(extractdata(P))' > 0.5, [true true false false]);
        end

        function testLossIsHighOnInvertedPrediction(tc)
            coralBias = dlarray(single([20 20 20 20]));    % predicts grade 4
            z         = dlarray(single(0));
            loss = ophira.train.coralLoss(z, coralBias, 0); % truth is grade 0

            tc.verifyGreaterThan(double(extractdata(loss)), 5);
        end

        function testDecodeCoralMonotone(tc)
            % Cumulative probabilities must decode to the count above 0.5.
            tc.verifyEqual(ophira.infer.decodeCoral([0.99 0.98 0.97 0.96]), 4);
            tc.verifyEqual(ophira.infer.decodeCoral([0.99 0.90 0.10 0.02]), 2);
            tc.verifyEqual(ophira.infer.decodeCoral([0.10 0.05 0.02 0.01]), 0);
        end

        function testDecodeHandlesNonMonotoneInput(tc)
            % INT8 quantisation on an edge device can perturb monotonicity.
            % cummin must repair it rather than producing a nonsense grade.
            g = ophira.infer.decodeCoral([0.9 0.4 0.7 0.1]);
            tc.verifyEqual(g, 1);       % cummin -> [0.9 0.4 0.4 0.1]
        end

        function testProbsSumToOne(tc)
            [~,~,~,p] = ophira.infer.decodeCoral([0.95 0.80 0.30 0.05]);
            tc.verifyEqual(sum(p), 1, 'AbsTol', 1e-10);
            tc.verifyGreaterThanOrEqual(min(p), 0);
        end

        function testUncertaintyIsHighAtBoundary(tc)
            % A case sitting exactly on a grade boundary must report high
            % uncertainty -- this is what the cascade escalates on.
            [~, confSure,  uncSure]  = ophira.infer.decodeCoral([0.99 0.99 0.01 0.01]);
            [~, confEdge,  uncEdge]  = ophira.infer.decodeCoral([0.99 0.51 0.49 0.01]);

            tc.verifyGreaterThan(uncEdge, uncSure);
            tc.verifyLessThan(confEdge, confSure);
        end

        function testExpansionIsExact(tc)
            % *** THE LOAD-BEARING TEST ***
            % Training form:   fc(1) -> z, logits = z + b
            % Deployed form:   fc(K-1) with all rows = w, bias = b
            % These must agree to floating-point tolerance.
            K = 5;

            [net, coralBias] = ophira.models.buildCoralTrainNet("mobilenetv2", ...
                Size=224, NumClasses=K, Pretrained=false);

            X = dlarray(single(rand(224,224,3,2)), 'SSCB');

            % --- training-form output
            z = predict(net, X);
            z = reshape(z, 1, []);
            logitsTrain = reshape(extractdata(coralBias), K-1, 1) + ...
                          reshape(extractdata(z), 1, []);
            Ptrain = 1 ./ (1 + exp(-logitsTrain));

            % --- deployed-form output
            deployNet = ophira.models.expandCoralHead(net, coralBias);
            Pdeploy   = extractdata(predict(deployNet, X));
            Pdeploy   = reshape(Pdeploy, K-1, []);

            tc.verifyEqual(double(Pdeploy), double(Ptrain), 'AbsTol', 1e-5, ...
                'Deployed CORAL head diverges from training form.');
        end

        function testBatchNormStateIsCarriedForward(tc)
            % *** REGRESSION TEST for the bug that destroyed M5 (docs/12). ***
            %
            % forward() returns updated batch-norm running statistics as its
            % SECOND output. If a custom training loop drops it, net.State
            % stays at initialisation forever: training looks healthy
            % because forward() uses batch statistics, while predict()
            % normalises with statistics that were never learned.
            %
            % The existing tests could not catch this -- they all run on an
            % untrained network, where both paths see identical (initial)
            % state and therefore agree.
            %
            % This test asserts the mechanism directly: after a forward pass
            % on data that is NOT zero-mean/unit-variance, the returned
            % state must differ from the initial state.
            net = ophira.models.buildCoralTrainNet("mobilenetv2", ...
                Size=224, NumClasses=5, Pretrained=false);

            bn = startsWith(net.State.Layer, "") & ...
                 ismember(net.State.Parameter, ["TrainedMean","TrainedVariance"]);
            tc.assumeTrue(any(bn), 'backbone has no batch-norm layers to test');

            before = net.State.Value(bn);

            % Deliberately off-distribution input so the running statistics
            % must move if they are being updated at all.
            X = dlarray(single(rand(224,224,3,4) * 3 + 2), 'SSCB');
            [~, state] = forward(net, X);

            after = state.Value(bn);

            moved = false;
            for k = 1:numel(before)
                if ~isequal(size(before{k}), size(after{k})); moved = true; break; end
                if max(abs(extractdata(before{k}) - extractdata(after{k})), [], 'all') > 1e-6
                    moved = true; break
                end
            end

            tc.verifyTrue(moved, ...
                ['forward() did not update batch-norm state. If this fails, ' ...
                 'every custom training loop in the project is silently broken.']);
        end

        function testQWKPerfectAndChance(tc)
            y = [0 1 2 3 4 0 1 2 3 4]';
            tc.verifyEqual(ophira.eval.qwk(y, y, 5), 1, 'AbsTol', 1e-12);

            % Systematically shifting every grade by 1 must score well below 1.
            tc.verifyLessThan(ophira.eval.qwk(y, min(y+1,4), 5), 0.95);
        end

        function testQWKPenalisesDistance(tc)
            % Labels must span classes, otherwise kappa is degenerate
            % (see testQWKIsZeroWhenLabelsHaveNoVariance).
            y = [0 0 1 1 2 2 3 3 4 4]';

            pNear = y;  pNear(1) = 1;    % off by 1
            pFar  = y;  pFar(1)  = 4;    % off by 4

            near = ophira.eval.qwk(y, pNear, 5);
            far  = ophira.eval.qwk(y, pFar,  5);

            tc.verifyGreaterThan(near, far, ...
                'QWK must penalise distant errors more than near ones.');
        end

        function testQWKIsZeroWhenLabelsHaveNoVariance(tc)
            % GOTCHA, encoded deliberately.
            % If every true label is the same class, the expected matrix
            % scales exactly with the observed one and QWK is 0 no matter
            % how wrong the predictions are. Kappa needs variation in both
            % marginals to mean anything.
            %
            % Practical consequence: never compute QWK on a single-grade
            % subgroup. Per-grade performance goes through sensitivity /
            % specificity instead.
            y = [0 0 0 0]';
            tc.verifyEqual(ophira.eval.qwk(y, [1 0 0 0]', 5), 0, 'AbsTol', 1e-12);
            tc.verifyEqual(ophira.eval.qwk(y, [4 0 0 0]', 5), 0, 'AbsTol', 1e-12);
        end

    end
end
