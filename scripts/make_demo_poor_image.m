%% MAKE_DEMO_POOR_IMAGE
% A deliberately degraded capture, so the quality-failure branch can be
% demonstrated against the REAL gate rather than by faking a verdict.
%
% Under-exposed and defocused, which is what a mis-aimed fundus camera
% actually produces. The gate is not told anything: it assesses this the
% same way it assesses a real capture, and it is free to accept it.
src = ophira.projectRoot("samples","sample_fundus_referral.png");
dst = ophira.projectRoot("samples","demo_poor_quality.png");
I = imread(src);
J = uint8(double(I) * 0.22);                 % under-exposed
J = imgaussfilt(J, 9);                        % out of focus
imwrite(J, dst);
q = ophira.quality.assess(string(dst));
fprintf('degraded image -> gate says %s (score %.3f)\n', q.decision, q.score);
for k = 1:numel(q.reasons)
    fprintf('   %s: %s\n', q.reasons(k).code, q.reasons(k).text);
end
d = dir(dst); fprintf('size %.1f MB\n', d.bytes/1048576);
