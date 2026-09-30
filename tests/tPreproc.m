classdef tPreproc < matlab.unittest.TestCase
    %TPREPROC  Unit tests for the preprocessing pipeline.
    %
    %   The pipeline is the contract between training and inference. If it
    %   drifts, every measured number in the project silently becomes wrong,
    %   and nothing else in the system will notice. Hence these tests.
    %
    %   A synthetic fundus image is used so the ground-truth FOV geometry is
    %   known exactly and the tests run without any dataset present.
    %
    %   >> runtests('tPreproc')

    properties
        I           % synthetic fundus
        CX = 1100
        CY = 700
        R  = 640
    end

    methods (TestMethodSetup)
        function makeImage(tc)
            rng(0);
            H = 1400; W = 2000;
            I = zeros(H, W, 3, 'uint8');
            [X, Y] = meshgrid(1:W, 1:H);
            mask = (X-tc.CX).^2 + (Y-tc.CY).^2 <= tc.R^2;

            % Radial illumination falloff, warm fundus colour.
            grad = 0.55 + 0.45*(1 - ((X-tc.CX).^2 + (Y-tc.CY).^2)/tc.R^2);
            base = cat(3, 200*grad, 110*grad, 60*grad);
            for c = 1:3
                ch = zeros(H,W); tmp = base(:,:,c);
                ch(mask) = tmp(mask);
                I(:,:,c) = uint8(ch);
            end

            % Small dark spots standing in for lesions.
            for k = 1:25
                a = rand*2*pi; d = rand*tc.R*0.85;
                px = round(tc.CX + d*cos(a)); py = round(tc.CY + d*sin(a));
                I(max(1,py-3):min(H,py+3), max(1,px-3):min(W,px+3), :) = 25;
            end
            tc.I = I;
        end
    end

    methods (Test)

        function testFOVFindsTheRetina(tc)
            [~, bbox] = ophira.preproc.detectFOV(tc.I);
            tc.verifyEqual(bbox(3), 2*tc.R, 'AbsTol', 20, 'FOV width wrong');
            tc.verifyEqual(bbox(4), 2*tc.R, 'AbsTol', 20, 'FOV height wrong');
            tc.verifyEqual(bbox(1), tc.CX - tc.R, 'AbsTol', 20);
            tc.verifyEqual(bbox(2), tc.CY - tc.R, 'AbsTol', 20);
        end

        function testFOVMaskCoversCircleInSquare(tc)
            [~, ~, m] = ophira.preproc.detectFOV(tc.I);
            % A circle inscribed in its bounding square covers pi/4 = 78.5%.
            tc.verifyEqual(mean(m(:)), pi/4, 'AbsTol', 0.02);
        end

        function testFOVSurvivesDegenerateImage(tc)
            % An all-black frame must not error; the quality gate rejects it.
            blank = zeros(100, 120, 3, 'uint8');
            [Icrop, bbox] = ophira.preproc.detectFOV(blank);
            tc.verifySize(Icrop, [100 120 3]);
            tc.verifyEqual(bbox, [1 1 120 100]);
        end

        function testOutputSizeAndCornersAreBlack(tc)
            for S = [384 512]
                Iout = ophira.preproc.preprocess(tc.I, Size=S);
                tc.verifySize(Iout, [S S 3]);

                corners = [Iout(1,1,:) Iout(1,end,:) Iout(end,1,:) Iout(end,end,:)];
                tc.verifyEqual(max(double(corners(:))), 0, ...
                    'Corners must be black: the retina mask was not re-applied after CLAHE.');
            end
        end

        function testIsDeterministic(tc)
            % THE critical property. Training and inference call this same
            % function; if it is not deterministic they diverge invisibly.
            a = ophira.preproc.preprocess(tc.I, Size=512);
            b = ophira.preproc.preprocess(tc.I, Size=512);
            tc.verifyEqual(a, b, 'Preprocessing is not deterministic.');
        end

        function testAspectRatioIsPreserved(tc)
            % Square padding before resize means a circular retina must stay
            % circular. Measure the mask's width:height ratio in the output.
            [~, info] = ophira.preproc.preprocess(tc.I, Size=512);
            tc.verifyEqual(info.retina_frac, pi/4, 'AbsTol', 0.03, ...
                'Retina area fraction changed: aspect ratio was distorted.');
        end

        function testBenGrahamRemovesIlluminationGradient(tc)
            % The synthetic image has a strong radial brightness ramp.
            %
            % Measure the LOW-FREQUENCY variation specifically. Ben Graham
            % removes the slow illumination ramp while amplifying local
            % detail by alpha, so total variance legitimately INCREASES --
            % testing global std would test the opposite of the claim.
            %
            % Retina pixels only, with the mask eroded so that blurring does
            % not pull the black surround into the measurement.
            [~, ~, m] = ophira.preproc.detectFOV(tc.I);
            mres = imresize(m, [512 512], 'nearest');
            mIn  = imerode(mres, strel('disk', 40));

            raw  = ophira.preproc.preprocess(tc.I, Size=512, UseBenGraham=false, UseCLAHE=false);
            proc = ophira.preproc.preprocess(tc.I, Size=512, UseBenGraham=true,  UseCLAHE=false);

            lowFreqSpread = @(X) std( ...
                subsref(imgaussfilt(double(rgb2gray(X)), 25), ...
                        substruct('()', {mIn})), 0, 'all');

            rampRaw  = lowFreqSpread(raw);
            rampProc = lowFreqSpread(proc);

            tc.verifyLessThan(rampProc, rampRaw, ...
                'Ben Graham did not flatten the low-frequency illumination ramp.');

            % And confirm the flip side: local detail is amplified, which is
            % the whole point of the transform for lesion visibility.
            detail = @(X) std( ...
                subsref(double(rgb2gray(X)) - imgaussfilt(double(rgb2gray(X)), 25), ...
                        substruct('()', {mIn})), 0, 'all');
            tc.verifyGreaterThan(detail(proc), detail(raw), ...
                'Ben Graham should amplify lesion-scale detail.');
        end

        function testVersionIsStamped(tc)
            % Every output must be traceable to the code that produced it.
            [~, info] = ophira.preproc.preprocess(tc.I, Size=512);
            tc.verifyEqual(info.preproc_version, "preproc_v1");
            tc.verifyGreaterThan(info.latency_ms, 0);
        end

    end
end
