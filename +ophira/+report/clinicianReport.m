function outPath = clinicianReport(result, opts)
%CLINICIANREPORT  Render one screening encounter as a clinician-facing report.
%
%   p = ophira.report.clinicianReport(result)
%   p = ophira.report.clinicianReport(result, Context=ctx, Out="report.html")
%
%   `result` is what ophira.cascade.orchestrate returns. `Context` is the
%   context_core record from ophira.session.readSession, when one exists.
%
%   WHAT THIS DOCUMENT IS FOR
%
%   A clinician has to be able to disagree with the system. That requires
%   knowing what it saw, what rule fired, how confident it was, and what it
%   did NOT assess. A report that states a recommendation without its
%   grounds is asking to be rubber-stamped, which is the failure mode this
%   whole project is about.
%
%   SO THREE RULES GOVERN THIS OUTPUT:
%
%   1. EVERY recommendation is printed next to the rules that produced it,
%      verbatim from the decision engine. Nothing is summarised away.
%
%   2. CALIBRATION STATUS IS ON THE FIRST SCREEN, not in a footnote. An
%      uncalibrated site measured 0.507 sensitivity externally. A clinician
%      reading a "no referral needed" from such a site must know that the
%      number behind it was fitted somewhere else.
%
%   3. EVERY AI FIGURE CARRIES ITS OWN RELIABILITY. The lesion channels
%      differ by a factor of six in Dice (EX 0.613, SE 0.095); printing
%      them in one table without that would imply they are equally good.
%
%   The report is deliberately NOT a diagnosis. It is evidence plus a
%   routing recommendation, and it says so.

arguments
    result struct
    opts.Context struct = struct()
    opts.Out (1,1) string = ""
    opts.Title (1,1) string = "OPHIRA screening report"
    opts.Images (1,:) string = string.empty   % originals, for the visual panels
end

if opts.Out == ""
    id = "encounter";
    if isfield(opts.Context,'session') && isfield(opts.Context.session,'session_id')
        id = string(opts.Context.session.session_id);
    end
    opts.Out = ophira.projectRoot("artifacts","reports", id + "_clinician.html");
end
d = fileparts(opts.Out);
if ~isfolder(d); mkdir(d); end

D = result.decision;
E = result.evidence;
calibrated = isCalibrated(result.site);

h = string.empty;

%% ---- head -------------------------------------------------------------
h = [h, htmlHead(opts.Title)];
% ?print=1 opens the browser print dialog on load. Every browser can save
% that as a PDF, which keeps ONE source of truth for the layout -- a
% second renderer (reportlab, weasyprint) would be a second layout to
% keep in sync, and drift between them is how reports start lying.
autoPrint = "<script>if(new URLSearchParams(location.search).get('print')){window.addEventListener('load',function(){setTimeout(function(){window.print();},250);});}</script>";
h = [h, "<body><main>"];
h = [h, sprintf("<h1>%s</h1>", esc(opts.Title))];
h = [h, identityBlock(opts.Context, result)];

%% ---- the recommendation and WHY --------------------------------------
h = [h, sprintf("<section class='act act-%s'>", lower(strrep(D.action," ","-")))];
h = [h, sprintf("<div class='label'>Recommended action</div>")];
h = [h, sprintf("<div class='action'>%s</div>", esc(D.action))];
h = [h, "<div class='label'>Because</div><ul class='reasons'>"];
for i = 1:numel(D.reasons)
    h = [h, sprintf("<li>%s</li>", esc(D.reasons(i)))]; %#ok<AGROW>
end
h = [h, "</ul>"];
h = [h, sprintf("<div class='rules'>Rules fired: <code>%s</code> &middot; ruleset <code>%s</code></div>", ...
        esc(strjoin(D.rules_fired, ", ")), esc(D.rules_version))];
h = [h, "</section>"];

%% ---- calibration, on the first screen --------------------------------
if calibrated
    h = [h, sprintf("<section class='note ok'><b>Site calibration:</b> " + ...
        "thresholds fitted on local labelled images for site <code>%s</code>.</section>", ...
        esc(result.site))];
else
    h = [h, sprintf("<section class='note warn'><b>This site is not calibrated.</b> " + ...
        "Site <code>%s</code> has no local threshold fit, so the decision above used " + ...
        "thresholds fitted on a different population. Measured on external data, that " + ...
        "configuration detected <b>51%% of referable disease</b> versus <b>90%%</b> once " + ...
        "recalibrated. Treat a negative result from this site with corresponding caution, " + ...
        "and calibrate on local labelled images before routine screening use.</section>", ...
        esc(result.site))];
end

%% ---- what the encounter contributed ----------------------------------
h = [h, contextBlock(opts.Context)];

%% ---- AI findings ------------------------------------------------------
h = [h, "<h2>Image findings</h2>"];
h = [h, "<table><thead><tr><th>Measure</th><th>Value</th><th>Reliability</th></tr></thead><tbody>"];

if isfield(E,'quality')
    h = [h, row("Image quality", ...
        sprintf("%s", E.quality.decision), ...
        "Gate AUC 0.79 on held-out labels. Weakest component; see limitations.")];
end
if isfield(E,'dr_grade') && ~isempty(E.dr_grade)
    gtxt = sprintf("Grade %d &mdash; %s", E.dr_grade, gradeName(E.dr_grade));
    h = [h, row("Diabetic retinopathy", gtxt, ...
        "QWK 0.90 in-domain; 0.75 on external data.")];
end
if isfield(E,'referable_score') && ~isempty(E.referable_score)
    h = [h, row("P(referable, grade &ge; 2)", sprintf("%.3f", E.referable_score), ...
        sprintf("Referral threshold for this site: %.4f", siteThreshold(result.site)))];
end
if isfield(E,'uncertainty') && ~isempty(E.uncertainty)
    h = [h, row("Model uncertainty", sprintf("%.2f", E.uncertainty), ...
        uncertaintyNote(calibrated))];
end
if isfield(E,'maculopathy') && ~isempty(E.maculopathy)
    h = [h, row("Maculopathy risk", sprintf("%d", E.maculopathy), ...
        "Trained on a label defined by exudate proximity to the fovea, so it is " + ...
        "coupled to the exudate findings below rather than independent of them.")];
end
h = [h, "</tbody></table>"];

if isfield(E,'dr_probs') && ~isempty(E.dr_probs)
    h = [h, gradeBars(E.dr_probs)];
end

%% ---- where the findings are -------------------------------------------
h = [h, imageBlock(opts.Images, E)];

%% ---- lesion evidence, each with its own reliability -------------------
h = [h, lesionBlock(E)];

%% ---- what was NOT assessed -------------------------------------------
h = [h, notAssessedBlock(E, result)];

%% ---- agentic workflow, when a trace exists ----------------------------
h = [h, agentBlock(opts.Context)];

%% ---- traceability -----------------------------------------------------
h = [h, traceBlock(result)];

%% ---- limitations ------------------------------------------------------
h = [h, limitationsBlock()];

h = [h, sprintf("<footer>Generated %s &middot; ruleset %s &middot; this document is screening evidence and a routing recommendation, not a diagnosis.</footer>", ...
        esc(string(datetime("now","Format","uuuu-MM-dd HH:mm"))), esc(D.rules_version))];
h = [h, "</main>" + autoPrint + "</body></html>"];

fid = fopen(opts.Out, "w", "n", "UTF-8");
fwrite(fid, strjoin(h, newline));
fclose(fid);
outPath = opts.Out;
end

%% ========================================================================
function s = identityBlock(ctx, result)
s = "<section class='ident'><dl>";
if isfield(ctx,'session')
    s = s + kv("Session",  getf(ctx.session,'session_id'));
    s = s + kv("Centre",   getf(ctx.session,'centre_id'));
    s = s + kv("Operator", getf(ctx.session,'operator_id'));
end
if isfield(ctx,'patient')
    s = s + kv("Patient ID", getf(ctx.patient,'patient_id'));
    s = s + kv("Age", getf(ctx.patient,'age_years'));
    s = s + kv("Sex", getf(ctx.patient,'sex'));
end
s = s + kv("Site", result.site);
s = s + kv("Cascade time", sprintf("%.0f ms", result.total_ms));
s = s + "</dl></section>";
end

function s = contextBlock(ctx)
% The questionnaire, visual acuity and symptoms are what the decision
% engine used. They never reach the network -- that separation is what
% lets the image models be trained on public data carrying no context.
if isempty(fieldnames(ctx)); s = ""; return; end
s = "<h2>Encounter record</h2>";
s = s + "<p class='hint'>Used by the decision engine only. These values are never " + ...
        "shown to the image model.</p><dl class='ctx'>";
if isfield(ctx,'visual_acuity')
    s = s + kv("Visual acuity OD", va(ctx.visual_acuity,'od'));
    s = s + kv("Visual acuity OS", va(ctx.visual_acuity,'os'));
    s = s + kv("VA method",        getf(ctx.visual_acuity,'method'));
end
if isfield(ctx,'diabetes')
    s = s + kv("Diabetes type",     getf(ctx.diabetes,'dm_type'));
    s = s + kv("Duration (years)",  getf(ctx.diabetes,'duration_years'));
    s = s + kv("Treatment",         getf(ctx.diabetes,'treatment'));
    s = s + kv("Last HbA1c (%)",    getf(ctx.diabetes,'hba1c_percent'));
    s = s + kv("Hypertension",      yn(getf(ctx.diabetes,'hypertension')));
end
if isfield(ctx,'ocular_history')
    s = s + kv("Ocular history", getf(ctx.ocular_history,'conditions'));
end
if isfield(ctx,'eligibility')
    s = s + kv("Under DR treatment", yn(getf(ctx.eligibility,'under_dr_treatment')));
end
if isfield(ctx,'symptoms')
    r = getf(ctx.symptoms,'reported');
    if r == ""; r = "none reported"; end
    s = s + kv("Symptoms", r);
end
if isfield(ctx,'flags')
    s = s + kv("Pathway", getf(ctx.flags,'pathway'));
end
s = s + "</dl>";
end

function s = imageBlock(images, E)
%IMAGEBLOCK  The captured image, and where the system says the disease is.
%
%   Two overlays, because they answer different questions and are worth
%   very different amounts. Saying so is the point: a heatmap that looks
%   authoritative but does not track lesions can make a reader LESS
%   accurate than no picture at all.
if isempty(images)
    s = "";
    return
end

s = "<h2>Where the findings are</h2>";
s = s + "<p class='hint'>Markings are drawn on the captured image in the " + ...
        "frame the models analysed, so a marking sits on the pixel it " + ...
        "refers to.</p>";

any_ok = false;
for i = 1:numel(images)
    P = ophira.report.overlays(images(i), E);
    if P.status ~= "ok"
        s = s + sprintf("<p class='hint'>%s</p>", esc(P.message));
        continue
    end
    any_ok = true;

    [~, nm, ex] = fileparts(images(i));
    s = s + sprintf("<div class='shot-name'>%s</div>", esc(string(nm) + string(ex)));
    s = s + "<div class='shots'>";

    s = s + panel("Captured image", P.fundus, ...
        "As the models received it, cropped to the retina.");

    if P.lesions ~= ""
        s = s + panel("Lesion map <span class='tag tag-good'>supervised</span>", ...
            P.lesions, ...
            "Trained on expert pixel annotations. Concentrates 5.3x more " + ...
            "of its marking on true lesions than chance.");
    end

    if P.gradcam ~= ""
        s = s + panel("Grad-CAM <span class='tag tag-warn'>attention, not lesions</span>", ...
            P.gradcam, ...
            "Where the grader's gradients point. Measured the same way on " + ...
            "the same images it reaches only 2.2x, so read it as the model's " + ...
            "attention and NOT as a map of disease.");
    end

    s = s + "</div>";

    if ~isempty(fieldnames(P.legend))
        s = s + "<div class='legend'>";
        for k = 1:numel(P.legend)
            if ~P.legend(k).present; continue; end
            s = s + sprintf("<span class='lg'><i style='background:%s'></i>" + ...
                            "%s</span>", P.legend(k).rgb, esc(P.legend(k).name));
        end
        s = s + "</div>";
    end
end

if any_ok
    s = s + "<p class='hint'>Absence of a marking is not evidence of a " + ...
            "healthy retina: the lesion model scores Dice 0.61 on hard " + ...
            "exudates and 0.10 on cotton-wool spots, so it misses findings.</p>";
end
end

function s = panel(title, uri, note)
% NOTE: ["a" ... "b"] is a 1x2 string ARRAY in MATLAB, not a concatenation,
% and sprintf then treats it as two format strings and errors. Use +.
s = sprintf("<figure class='shot'><img src='%s' alt='%s'>" + ...
            "<figcaption><b>%s</b><span>%s</span></figcaption></figure>", ...
            uri, esc(regexprep(title, '<[^>]*>', '')), title, esc(note));
end

function s = lesionBlock(E)
if ~isfield(E,'lesions') || ~isstruct(E.lesions)
    s = "<h2>Lesion evidence</h2><p class='hint'>Not computed. Lesion " + ...
        "segmentation runs only for cases routed to a clinician.</p>";
    return
end
L = E.lesions;
if L.status ~= "ok"
    s = sprintf("<h2>Lesion evidence</h2><p class='hint'>%s</p>", esc(L.message));
    return
end

% Reliability per channel, from IDRiD Dice and the APTOS transfer check.
% NOTE: the last column is HTML-ESCAPED on the way out, so it must contain
% plain text only. An &mdash; entity here rendered as the literal six
% characters in the clinician's report.
% These differ enough that presenting them in one undifferentiated table
% would misrepresent three of the four.
meta = { ...
 "EX", "Hard exudates",      0.613, 0.946, "Strongest channel.";
 "SE", "Cotton-wool spots",  0.095, 0.828, "Burden tracks severity, but localisation is unreliable (Dice 0.10); do not read the outline as accurate.";
 "MA", "Microaneurysms",     0.424, 0.763, "Moderate.";
 "HE", "Haemorrhages",       0.404, 0.695, "Weak separation on external images; corroborate before acting."};

s = "<h2>Lesion evidence</h2>";
s = s + "<p class='hint'>Explanation only. No routing rule reads these values &mdash; " + ...
        "the recommendation above was made on the grade, the maculopathy head and the " + ...
        "encounter record.</p>";
s = s + "<table><thead><tr><th>Lesion</th><th>Retinal area</th><th>Dice (IDRiD)</th>" + ...
        "<th>Ranks severity (AUC)</th><th>How to read it</th></tr></thead><tbody>";
for i = 1:size(meta,1)
    k = meta{i,1};
    if ~isfield(L.area_frac, k); continue; end
    s = s + sprintf("<tr><td><b>%s</b> %s</td><td class='num'>%.3f%%</td>" + ...
                    "<td class='num'>%.3f</td><td class='num'>%.3f</td><td>%s</td></tr>", ...
        esc(k), esc(meta{i,2}), 100*L.area_frac.(k), meta{i,3}, meta{i,4}, esc(meta{i,5}));
end
s = s + "</tbody></table>";
s = s + sprintf("<p class='hint'>Computed at %.2f&times; native scale over %d tiles.</p>", ...
                L.fov_scale, L.tiles);
end

function s = notAssessedBlock(E, result)
% Absence of a finding is not a finding of absence. Anything the cascade
% skipped is listed explicitly, because a blank section reads as normal.
missing = string.empty;
ran = string.empty;
for k = 1:numel(result.stages); ran(end+1) = result.stages{k}.stage; end %#ok<AGROW>

if ~any(ran == "stage2_grader")
    missing(end+1) = "Diabetic retinopathy grading &mdash; the image did not reach the grader.";
end
if ~isfield(E,'maculopathy') || isempty(E.maculopathy)
    missing(end+1) = "Maculopathy risk &mdash; not assessed for this image.";
end
if ~isfield(E,'lesions')
    missing(end+1) = "Lesion segmentation &mdash; not run.";
end
missing(end+1) = "Optic disc, glaucoma and non-diabetic retinal disease &mdash; this system does not look for them at all.";

s = "<h2>Not assessed</h2><ul class='missing'>";
for m = missing; s = s + sprintf("<li>%s</li>", m); end
s = s + "</ul>";
end

function s = agentBlock(ctx)
%AGENTBLOCK  What the agent did, and what it did NOT do.
%
%   Present only when an agent run produced a trace for this session. The
%   wording is deliberate: the agent ORCHESTRATED evidence collection. It
%   did not diagnose, and the report must never be readable as if it did.
s = "";
sid = "";
if isstruct(ctx) && isfield(ctx,'session') && isfield(ctx.session,'session_id')
    sid = string(ctx.session.session_id);
end
if sid == ""; return; end

f = ophira.projectRoot("data","sessions","reports", sid, "agent_trace.json");
if ~isfile(f); return; end
try
    T = jsondecode(fileread(f));
catch
    return
end
m = T.metrics;

s = "<h2>Agentic workflow summary</h2>";
s = s + "<table><tbody>";
s = s + row2("Agent version", esc(string(T.agent_version)));
s = s + row2("Tools executed", string(m.tools_executed));
s = s + row2("Adaptive branches", string(m.replans));
s = s + row2("Evidence items", string(m.evidence_items));
s = s + row2("Unresolved tool errors", string(m.tool_failures));
if isfield(T,'llm') && isfield(T.llm,'available') && T.llm.available
    s = s + row2("Narrative source", esc(string(T.llm.provider) + " / " + string(T.llm.model)));
else
    s = s + row2("Narrative source", "deterministic (no LLM reachable)");
end
s = s + row2("Decision source", "<b>deterministic OPHIRA decision engine</b>");
s = s + row2("Agent role", "evidence orchestration and report synthesis");
s = s + row2("Clinical decision authority", "<b>OPHIRA decision engine</b>");
s = s + "</tbody></table>";

if isfield(T,'synthesis') && isfield(T.synthesis,'text') && ...
        strlength(string(T.synthesis.text)) > 0
    s = s + sprintf("<p class='hint'>%s</p>", esc(string(T.synthesis.text)));
end
s = s + "<p class='hint'>The agent selected which evidence to collect and in " + ...
        "what order. It did not grade the retina, did not set any threshold, " + ...
        "and did not decide the referral.</p>";
end

function s = row2(k, v)
s = sprintf("<tr><td>%s</td><td class='v'>%s</td></tr>", k, v);
end

function s = traceBlock(result)
s = "<h2>How this was produced</h2><table class='trace'><thead><tr>";
s = s + "<th>Stage</th><th>Model</th><th>Thresholds</th><th>Status</th><th>ms</th>";
s = s + "</tr></thead><tbody>";
for k = 1:numel(result.stages)
    st = result.stages{k};
    ms = ""; if ~isempty(st.latency_ms); ms = sprintf("%.0f", st.latency_ms); end
    s = s + sprintf("<tr><td>%s</td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td class='num'>%s</td></tr>", ...
        esc(st.stage), esc(st.model_version), esc(st.threshold_ver), esc(st.status), ms);
end
s = s + "</tbody></table>";
end

function s = limitationsBlock()
s = strjoin([ "<h2>Limitations</h2><ul class='lim'>" ...
 "<li>This system has never been validated in a prospective clinical study. Every figure here comes from retrospective public datasets.</li>" ...
 "<li>The decision engine cannot be validated on public data at all &mdash; no public dataset pairs fundus images with symptoms, visual acuity and grade. Its rules are scenario-tested only.</li>" ...
 "<li>Performance drops on cameras and populations the models have not seen. Referable sensitivity measured 0.93 in-domain and 0.51 on an external set before local recalibration.</li>" ...
 "<li>Model uncertainty is calibrated on the development population only. On external data the cases the model misses are <i>less</i> uncertain than the ones it catches, so a low uncertainty score is not reassurance at an uncalibrated site.</li>" ...
 "<li>Maculopathy risk is trained on a label defined by exudate position, not on macular oedema confirmed by OCT.</li>" ...
 "<li>A RECAPTURE recommendation is only safe if the retake actually happens. Images rejected by the quality gate include referable disease.</li>" ...
 "</ul>"], "");
end

%% ---- small helpers -----------------------------------------------------
function s = row(name, val, note)
s = sprintf("<tr><td>%s</td><td class='v'>%s</td><td class='hint'>%s</td></tr>", ...
            name, val, esc(string(note)));
end

function s = kv(k, v)
if v == ""; s = ""; return; end
s = sprintf("<dt>%s</dt><dd>%s</dd>", esc(string(k)), esc(string(v)));
end

function s = gradeBars(p)
names = ["0 none","1 mild","2 moderate","3 severe","4 proliferative"];
s = "<div class='bars'>";
for i = 1:min(numel(p), numel(names))
    s = s + sprintf("<div class='bar'><span class='bl'>%s</span>" + ...
        "<span class='bt'><i style='width:%.1f%%'></i></span>" + ...
        "<span class='bv'>%.2f</span></div>", names(i), 100*p(i), p(i));
end
s = s + "</div>";
end

function n = gradeName(g)
names = ["no retinopathy","mild NPDR","moderate NPDR","severe NPDR","proliferative DR"];
if g >= 0 && g <= 4; n = names(g+1); else; n = "unknown"; end
end

function t = siteThreshold(site)
R = suppressWarn(@() ophira.decision.rulesV1(Site=site));
t = R.referable_score_threshold;
end

function tf = isCalibrated(site)
R = suppressWarn(@() ophira.decision.rulesV1(Site=site));
tf = R.calibrated;
end

function out = suppressWarn(fn)
w = warning('off','ophira:decision:uncalibrated');
c = onCleanup(@() warning(w)); %#ok<NASGU>
out = fn();
end

function s = uncertaintyNote(calibrated)
if calibrated
    s = "Above 0.55 the system abstains and refers to a human.";
else
    s = "Uncertainty is calibrated on the development population only. " + ...
        "At an uncalibrated site it does not reliably flag the cases the model gets wrong.";
end
end

function v = va(s, eye)
% visual_acuity.od / .os are objects {value, pinhole}, not scalars.
v = "";
if ~isstruct(s) || ~isfield(s, eye); return; end
e = s.(eye);
if ~isstruct(e); v = string(e); return; end
v = getf(e, 'value');
ph = getf(e, 'pinhole');
if ph ~= ""; v = v + " (pinhole " + ph + ")"; end
end

function t = yn(v)
if v == ""; t = ""; elseif v == "1" || v == "true"; t = "yes"; else; t = "no"; end
end

function v = getf(s, f)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f))
    v = s.(f);
    if iscell(v); v = strjoin(string(v), ", "); end
    v = string(v);
    if numel(v) > 1; v = strjoin(v, ", "); end
else
    v = "";
end
end

function s = esc(t)
s = string(t);
s = replace(s, "&", "&amp;");
s = replace(s, "<", "&lt;");
s = replace(s, ">", "&gt;");
end

function s = htmlHead(title)
s = ["<!doctype html><html lang='en'><head><meta charset='utf-8'>" ...
 "<meta name='viewport' content='width=device-width,initial-scale=1'>" ...
 sprintf("<title>%s</title>", esc(title)) ...
 "<style>" ...
 ":root{--ink:#16202c;--mut:#5d6b7a;--line:#dde3ea;--bg:#fff;--panel:#f6f8fa;" ...
 "--warn:#b3541e;--warnbg:#fff4ea;--ok:#1e6b45;--okbg:#eef8f2;--accent:#1f4e79}" ...
 "*{box-sizing:border-box}" ...
 "body{margin:0;background:var(--bg);color:var(--ink);" ...
 "font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif}" ...
 "main{max-width:860px;margin:0 auto;padding:32px 16px 64px}" ...
 "h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;text-transform:uppercase;" ...
 "letter-spacing:.06em;color:var(--mut);margin:32px 0 10px;border-bottom:1px solid var(--line);padding-bottom:6px}" ...
 ".ident dl{display:grid;grid-template-columns:auto 1fr;gap:2px 14px;margin:14px 0;font-size:13px}" ...
 "dl.ctx{display:grid;grid-template-columns:auto 1fr;gap:2px 14px;font-size:13px}" ...
 "dt{color:var(--mut)}dd{margin:0}" ...
 ".act{border:1px solid var(--line);border-left:5px solid var(--accent);" ...
 "background:var(--panel);padding:16px 18px;border-radius:6px;margin:18px 0}" ...
 ".act-urgent{border-left-color:#b3241e;background:#fdf0ef}" ...
 ".act-referral{border-left-color:#b3541e;background:var(--warnbg)}" ...
 ".act-human-review{border-left-color:#7a5bb5;background:#f5f1fb}" ...
 ".act-recapture{border-left-color:#8a7420;background:#fdf9e9}" ...
 ".act-routine{border-left-color:var(--ok);background:var(--okbg)}" ...
 ".label{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);margin-top:8px}" ...
 ".action{font-size:26px;font-weight:650;letter-spacing:-.01em}" ...
 ".reasons{margin:6px 0 0;padding-left:18px}.reasons li{margin:3px 0}" ...
 ".rules{margin-top:10px;font-size:12px;color:var(--mut)}" ...
 ".note{padding:12px 14px;border-radius:6px;margin:14px 0;font-size:13px}" ...
 ".note.warn{background:var(--warnbg);border:1px solid #f0d6be;color:var(--warn)}" ...
 ".note.ok{background:var(--okbg);border:1px solid #cfe7da;color:var(--ok)}" ...
 "table{width:100%;border-collapse:collapse;font-size:13px;margin:8px 0}" ...
 "th{text-align:left;font-weight:600;color:var(--mut);font-size:11px;" ...
 "text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid var(--line);padding:7px 8px}" ...
 "td{padding:7px 8px;border-bottom:1px solid var(--line);vertical-align:top}" ...
 "td.num{text-align:right;font-variant-numeric:tabular-nums}" ...
 "td.v{font-weight:600}" ...
 ".hint{color:var(--mut);font-size:12px}" ...
 "code{font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;" ...
 "background:var(--panel);padding:1px 5px;border-radius:3px}" ...
 ".shot-name{font:12px ui-monospace,Menlo,Consolas,monospace;color:var(--mut);margin:14px 0 6px}" ...
 ".shots{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px;margin:0 0 10px}" ...
 ".shot{margin:0}" ...
 ".shot img{width:100%;border-radius:5px;border:1px solid var(--line);display:block;background:#000}" ...
 ".shot figcaption{margin-top:6px;font-size:11px;line-height:1.45}" ...
 ".shot figcaption b{display:block;color:var(--ink);font-size:12px;margin-bottom:2px}" ...
 ".shot figcaption span{color:var(--mut)}" ...
 ".tag{display:inline-block;font-size:9px;font-weight:600;text-transform:uppercase;" ...
 "letter-spacing:.04em;padding:1px 5px;border-radius:3px;margin-left:4px;vertical-align:middle}" ...
 ".tag-good{background:#e6f4ec;color:#1e6b45}" ...
 ".tag-warn{background:#fdf0e6;color:#b3541e}" ...
 ".legend{display:flex;flex-wrap:wrap;gap:12px;margin:0 0 14px;font-size:11px;color:var(--mut)}" ...
 ".lg{display:inline-flex;align-items:center;gap:5px}" ...
 ".lg i{width:11px;height:11px;border-radius:2px;display:inline-block}" ...
 ".bars{margin:10px 0}" ...
 ".bar{display:grid;grid-template-columns:130px 1fr 44px;align-items:center;gap:10px;margin:3px 0;font-size:12px}" ...
 ".bl{color:var(--mut)}" ...
 ".bt{background:var(--panel);border-radius:3px;height:9px;overflow:hidden}" ...
 ".bt i{display:block;height:100%;background:var(--accent)}" ...
 ".bv{text-align:right;font-variant-numeric:tabular-nums}" ...
 "ul.missing,ul.lim{margin:6px 0;padding-left:18px;font-size:13px;color:var(--mut)}" ...
 "ul.missing li,ul.lim li{margin:4px 0}" ...
 "footer{margin-top:36px;padding-top:12px;border-top:1px solid var(--line);" ...
 "font-size:12px;color:var(--mut)}" ...
 "@page{size:A4;margin:14mm 12mm}" ...
 "@media print{" ...
   "html,body{background:#fff;color:#000}" ...
   "main{max-width:none;padding:0}" ...
   "h2{break-after:avoid;page-break-after:avoid}" ...
   "table,.act,.note,.bars,dl,.shot,.shots{break-inside:avoid;page-break-inside:avoid}" ...
   "tr{break-inside:avoid}" ...
   ".act{border-left-width:4px}" ...
   "footer{break-before:avoid}" ...
   "a{text-decoration:none;color:inherit}" ...
 "}" ...
 "</style></head>"];
s = strjoin(s, "");
end
