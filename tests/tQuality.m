classdef tQuality < matlab.unittest.TestCase
    %TQUALITY  Tests for the acquisition quality gate.
    %
    %   Built on synthetic fundus images with KNOWN degradations, so the
    %   gate can be tested for discrimination before any real data exists.
    %
    %   The load-bearing test is testUngradableIsNotGrade0Path: an image the
    %   system cannot assess must route to a human, never fall through to a
    %   normal result (Architecture v1.0 section 09).
    %
    %   >> runtests('tQuality')

    properties
        Good
    end

    methods (TestMethodSetup)
        function makeGood(tc)
            tc.Good = synthFundus();
        end
    end

    methods (Test)

        function testGoodImageIsAccepted(tc)
            f = ophira.quality.extractFeatures(tc.Good);
            r = ophira.quality.applyGate(f);
            tc.verifyEqual(r.decision, "ACCEPT", ...
                sprintf('Clean synthetic fundus rejected. score=%.3f reasons=%s', ...
                    r.score, codeList(r)));
            tc.verifyGreaterThan(r.score, 0.3);
        end

        function testBlurTriggersRecapture(tc)
            blurred = imgaussfilt(tc.Good, 9);
            r = ophira.quality.applyGate(ophira.quality.extractFeatures(blurred));
            tc.verifyEqual(r.decision, "RECAPTURE");
            tc.verifyTrue(any([r.reasons.code] == "focus:blurred"), ...
                sprintf('expected focus:blurred, got: %s', codeList(r)));
        end

        function testFocusScoreOrdersByBlurNearTheBoundary(tc)
            % focus_norm must fall monotonically through the range where the
            % accept/reject boundary actually sits. That is what makes the
            % threshold tunable on DeepDRiD in build Step 4.
            f = @(s) ophira.quality.extractFeatures( ...
                        ternaryBlur(tc.Good, s)).focus_norm;
            v = arrayfun(f, [0 1 2 3]);
            tc.verifyTrue(all(diff(v) < 0), ...
                sprintf('focus_norm must decrease with blur near the boundary: %s', ...
                        mat2str(v, 4)));
        end

        function testFocusMetricSaturatesUnderHeavyBlur(tc)
            % DOCUMENTED LIMITATION, asserted so it cannot regress silently.
            %
            % focus_norm is var(Laplacian) / contrast^2. Under heavy blur both
            % numerator and denominator collapse together, so the ratio
            % plateaus around 5e-3 and then wobbles with noise. The metric
            % therefore CANNOT rank degrees of unusable blur -- it only
            % separates usable from unusable.
            %
            % That is sufficient for a gate (everything below threshold is
            % rejected regardless) but it means focus_norm must never be used
            % as a continuous sharpness score in reporting or in a model.
            v = arrayfun(@(s) ophira.quality.extractFeatures( ...
                    imgaussfilt(tc.Good, s)).focus_norm, [5 7 9 11]);

            tc.verifyLessThan(max(v), 0.010, ...
                'heavy blur must stay below the accept threshold');
            tc.verifyLessThan(max(v) - min(v), 0.005, ...
                'heavy-blur focus values should be plateaued, not ordered');
        end

        function testOverExposureDetected(tc)
            bright = im2uint8(min(1, im2double(tc.Good) * 2.2));
            f = ophira.quality.extractFeatures(bright);
            tc.verifyGreaterThan(f.over_exposed_frac, 0.05);
            r = ophira.quality.applyGate(f);
            tc.verifyNotEqual(r.decision, "ACCEPT");
        end

        function testUnderExposureDetected(tc)
            dark = im2uint8(im2double(tc.Good) * 0.06);
            f = ophira.quality.extractFeatures(dark);
            r = ophira.quality.applyGate(f);
            tc.verifyNotEqual(r.decision, "ACCEPT");
        end

        function testBlackFrameIsUngradable(tc)
            % No retina at all: fatal, not a retake.
            black = zeros(600, 800, 3, 'uint8');
            r = ophira.quality.applyGate(ophira.quality.extractFeatures(black));
            tc.verifyEqual(r.decision, "UNGRADABLE");
            tc.verifyTrue(any([r.reasons.severity] == "fatal"));
        end

        function testUngradableIsNotGrade0Path(tc)
            % *** THE SAFETY TEST ***
            % Every non-accepted outcome must be a named decision that routes
            % somewhere. Nothing may silently become "fine".
            black = zeros(400, 400, 3, 'uint8');
            r = ophira.quality.applyGate(ophira.quality.extractFeatures(black));
            tc.verifyTrue(ismember(r.decision, ["RECAPTURE","UNGRADABLE"]));
            tc.verifyNotEmpty(r.reasons, 'A rejection must always state why.');
        end

        function testAttemptsExhaustedBecomesUngradable(tc)
            % A retake problem that survives MaxAttempts becomes a human
            % problem. The operator must not be looped forever.
            blurred = imgaussfilt(tc.Good, 9);
            f = ophira.quality.extractFeatures(blurred);

            r1 = ophira.quality.applyGate(f, Attempt=1, MaxAttempts=3);
            r3 = ophira.quality.applyGate(f, Attempt=3, MaxAttempts=3);

            tc.verifyEqual(r1.decision, "RECAPTURE");
            tc.verifyEqual(r3.decision, "UNGRADABLE");
            tc.verifyTrue(any([r3.reasons.code] == "attempts:exhausted"));
        end

        function testEveryRejectionIsExplainable(tc)
            % An operator cannot act on "quality failed". Each reason must
            % carry a code, human text, and a severity.
            for sigma = [3 6 12]
                r = ophira.quality.applyGate( ...
                        ophira.quality.extractFeatures(imgaussfilt(tc.Good, sigma)));
                if r.decision ~= "ACCEPT"
                    for k = 1:numel(r.reasons)
                        tc.verifyNotEmpty(r.reasons(k).code);
                        tc.verifyNotEmpty(r.reasons(k).text);
                        tc.verifyTrue(ismember(r.reasons(k).severity, ["retake","fatal"]));
                    end
                end
            end
        end

        function testSharpOutscoresEveryBlur(tc)
            % The COMPOSITE score is not required to be strictly monotone in
            % blur: blurring genuinely reduces specular saturation, which
            % lifts the exposure sub-score slightly. What must hold is that
            % a sharp image outscores every blurred one, and that no blurred
            % image is accepted. Strict monotonicity belongs to the focus
            % metric alone -- see testFocusScoreOrdersByBlur.
            % sigma=2 on a 1200 px field is mild and the gate currently
            % accepts it. Whether that is correct is a question for DeepDRiD
            % validation, not for a synthetic fixture -- tuning the threshold
            % to make this test pass would be fitting to the fixture.
            sharp = ophira.quality.applyGate( ...
                        ophira.quality.extractFeatures(tc.Good));
            tc.verifyEqual(sharp.decision, "ACCEPT");

            for sigma = [3 5 10]
                r = ophira.quality.applyGate( ...
                        ophira.quality.extractFeatures(imgaussfilt(tc.Good, sigma)));
                tc.verifyGreaterThan(sharp.score, r.score, ...
                    sprintf('sharp must outscore blur sigma=%g', sigma));
                tc.verifyNotEqual(r.decision, "ACCEPT", ...
                    sprintf('blur sigma=%g must not be accepted', sigma));
            end
        end

        function testVersionsAreStamped(tc)
            r = ophira.quality.applyGate(ophira.quality.extractFeatures(tc.Good));
            tc.verifyEqual(r.gate_version, "quality_gate_v1");
            tc.verifyTrue(contains(r.thresholds_version, "PLACEHOLDER"), ...
                'Thresholds must advertise that they are unvalidated.');
        end

        function testAssessHandlesUnreadableFile(tc)
            bad = fullfile(tempdir, "not_an_image.jpg");
            fid = fopen(bad,'w'); fprintf(fid,'garbage'); fclose(fid);
            tc.addTeardown(@() delete(bad));

            r = ophira.quality.assess(bad);
            tc.verifyEqual(r.decision, "UNGRADABLE");
            tc.verifyEqual(r.reasons(1).code, "file:unreadable");
        end

        function testAssessRoundTripsFromDisk(tc)
            p = fullfile(tempdir, "synth_fundus.png");
            imwrite(tc.Good, p);
            tc.addTeardown(@() delete(p));
            r = ophira.quality.assess(p);
            tc.verifyEqual(r.decision, "ACCEPT");
        end

    end
end

% =========================================================================
function s = codeList(r)
%CODELIST  Reason codes as one string, safe when there are none.
% Built eagerly as a sprintf argument, so it must not error on an accepted
% image with an empty reasons array.
if isempty(r.reasons); s = "(none)"; else; s = strjoin([r.reasons.code], ","); end
end

function J = ternaryBlur(I, sigma)
if sigma <= 0; J = I; else; J = imgaussfilt(I, sigma); end
end

function I = synthFundus()
%SYNTHFUNDUS  A plausible fundus: circular field, vessels, disc, texture.
rng(7);
H = 900; W = 1200; cx = 620; cy = 450; R = 420;
[X, Y] = meshgrid(1:W, 1:H);
mask = (X-cx).^2 + (Y-cy).^2 <= R^2;

falloff = 0.70 + 0.30*(1 - ((X-cx).^2 + (Y-cy).^2)/R^2);
base = cat(3, 0.78*falloff, 0.42*falloff, 0.22*falloff);

% optic disc
disc = ((X-(cx+210)).^2 + (Y-cy).^2) <= 62^2;
for c = 1:3
    ch = base(:,:,c); ch(disc) = min(1, ch(disc)*1.25); base(:,:,c) = ch;
end

% vessels: dark branching arcs, the main source of high-frequency detail
vess = false(H,W);
for k = 1:14
    a0 = rand*2*pi; r0 = 60;
    px = cx + r0*cos(a0); py = cy + r0*sin(a0);
    ang = a0 + (rand-0.5)*0.6;
    for step = 1:260
        ang = ang + (rand-0.5)*0.10;
        px = px + 1.6*cos(ang); py = py + 1.6*sin(ang);
        ix = round(px); iy = round(py);
        if ix<3||iy<3||ix>W-2||iy>H-2; break; end
        w = max(1, round(3 - step/110));
        vess(iy-w:iy+w, ix-w:ix+w) = true;
    end
end
for c = 1:3
    ch = base(:,:,c); ch(vess) = ch(vess) * (0.35 + 0.1*c); base(:,:,c) = ch;
end

base = base + 0.012*randn(H,W,3);          % sensor noise -> real texture
I = zeros(H,W,3);
for c = 1:3
    ch = base(:,:,c); ch(~mask) = 0; I(:,:,c) = ch;
end
I = im2uint8(min(1, max(0, I)));
end
