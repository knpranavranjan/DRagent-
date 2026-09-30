function s = stageContract(stage, opts)
%STAGECONTRACT  The single typed record every cascade stage emits.
%
%   Nothing downstream (routing, decision engine, reporting, traceability)
%   may read anything other than this struct. If a stage needs to communicate
%   something, it goes in here -- not in a side channel.
%
%   s = ophira.cascade.stageContract("stage2_grader")
%   s = ophira.cascade.stageContract("stage2_grader", grade=2, confidence=0.91)
%
%   Field groups
%     identity   : which stage, which versions produced this
%     inputs     : what it consumed
%     outputs    : what it produced (stage-specific, always present)
%     decision   : confidence / uncertainty / abstention / escalation
%     telemetry  : latency, memory  (measured, never assumed)
%     status     : ok | failed | skipped, plus a human-readable message

arguments
    stage (1,1) string
    opts.model_version   (1,1) string  = "unset"
    opts.threshold_ver   (1,1) string  = "unset"
    opts.preproc_ver     (1,1) string  = "unset"
    opts.image_id        (1,1) string  = ""
    opts.eye             (1,1) string  = ""      % OD | OS
    opts.field           (1,1) string  = ""      % macula | disc | tile_k
    opts.grade                         = []      % 0..4
    opts.probs                         = []      % 1xK calibrated probabilities
    opts.maculopathy                   = []
    opts.lesion_mask                   = []
    opts.quality_score                 = []
    opts.confidence                    = []
    opts.uncertainty                   = []
    opts.abstained       (1,1) logical = false
    opts.escalate_to     (1,1) string  = ""
    opts.latency_ms                    = []
    opts.peak_ram_mb                   = []
    opts.status          (1,1) string  = "ok"
    opts.message         (1,1) string  = ""
end

s = struct();

% --- identity -----------------------------------------------------------
s.stage          = stage;
s.model_version  = opts.model_version;
s.threshold_ver  = opts.threshold_ver;
s.preproc_ver    = opts.preproc_ver;
s.timestamp      = string(datetime("now","Format","uuuu-MM-dd'T'HH:mm:ss"));

% --- inputs -------------------------------------------------------------
s.inputs = struct( ...
    'image_id', opts.image_id, ...
    'eye',      opts.eye, ...
    'field',    opts.field);

% --- outputs ------------------------------------------------------------
s.outputs = struct( ...
    'grade',         opts.grade, ...
    'probs',         opts.probs, ...
    'maculopathy',   opts.maculopathy, ...
    'lesion_mask',   opts.lesion_mask, ...
    'quality_score', opts.quality_score);

% --- decision -----------------------------------------------------------
s.confidence  = opts.confidence;
s.uncertainty = opts.uncertainty;
s.abstained   = opts.abstained;
s.escalate_to = opts.escalate_to;

% --- telemetry ----------------------------------------------------------
s.latency_ms  = opts.latency_ms;
s.peak_ram_mb = opts.peak_ram_mb;

% --- status -------------------------------------------------------------
s.status  = opts.status;
s.message = opts.message;
end
