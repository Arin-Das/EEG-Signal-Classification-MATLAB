classdef EEGAppBands < matlab.apps.AppBase

    properties (Access = public)
        UIFigure
        UIAxes
        UploadButton
        LoadGreenButton
        AnalyzeButton
        ExportButton
        BandDropDown
        ChannelDropDown
        CommentLabel
        StateLabel
        MultiChannelButton
        ExportExcelButton

        EEGData
        GreenLine
        FilteredData
        fs = 250
        SelectedChannel = 1
        SelectedBand = "Theta"

        % Channel names for the CURRENTLY loaded recording. Unlike a fixed
        % montage, different EEG sources may use different channel names,
        % counts, and orderings (e.g. unipolar Fp1/Fp2/... vs bipolar
        % FP1-F7/F7-T7/...). This is refreshed by loadEEG() every time a
        % file is loaded: .edf files supply their own channel names; .mat
        % files may supply a "channelNames" variable; .csv/.mat without
        % names fall back to DefaultChannelNames (if the column count
        % matches) or generic Ch1..ChN labels otherwise. Every part of
        % the app (dropdowns, asymmetry pairing, plots, exports) reads
        % from this property rather than assuming a fixed montage.
        ChannelNames = {'Fp1','Fp2','F3','F4','C3','C4','O1','O2'}

        % Power-line noise frequency to notch out before spectral analysis.
        % Set to 60 if your data was recorded in a 60 Hz-mains region (e.g. US).
        NotchFreq = 50

        % How many seconds of each band's waveform to display in the PDF
        % waveform pages. Full-length traces compress hundreds of cycles
        % into a small subplot and become visually indistinguishable from
        % noise, even when correctly filtered - showing a wider, taller
        % panel keeps individual cycles readable. Filtering itself still
        % uses the FULL signal (via filtfilt) to avoid edge artifacts;
        % only the plotted portion is cropped afterward.
        WaveformDisplaySeconds = 10
    end

    properties (Access = private)
        Bands = struct('Delta',[0.5 4],'Theta',[4 8],'Alpha',[8 13],'Beta',[13 30],'Gamma',[30 45]);
        % Fallback montage used only when a loaded file supplies no
        % channel names (e.g. plain .csv/.mat) AND the column count
        % matches this list's length. Never assumed for files that
        % carry their own channel names (.edf) or that have a
        % different channel count.
        DefaultChannelNames = {'Fp1','Fp2','F3','F4','C3','C4','O1','O2'};
        % Illustrative relative-power reference ranges (% of 0.5-45 Hz total
        % power), roughly representative of eyes-closed resting adult EEG.
        % NOT a validated clinical normative dataset - for illustration only.
        NormalRangesRel = struct('Delta',[10 30],'Theta',[8 25],'Alpha',[15 40],'Beta',[8 30],'Gamma',[1 10]);
        % Broadband range used as the denominator for relative power / total power
        BroadBand = [0.5 45];
        % Amplitude-excursion threshold (in SDs) used for the artifact-quality check
        ArtifactSD = 5;
        % Threshold (in SDs) for the separate large-amplitude-transient report
        TransientSD = 4;
        % Relative-power asymmetry (%) beyond which a pair is flagged
        AsymmetryThreshold = 15;
        % Relative power (%) above which generalized slowing is flagged
        SlowingThreshold = 55;

        % Cache of bandPowersPSD() results, keyed by channel index. Several
        % features (asymmetry check, clinical pattern flags, exports) call
        % bandPowersPSD for the SAME channel more than once per analysis;
        % pwelch is the most expensive step in the pipeline, so caching
        % avoids redundant recomputation without changing any result
        % (inputs - EEGData/fs/NotchFreq/Bands - are constant within a
        % single loaded recording). Cleared on every new file load via
        % resetPSDCache() so nothing from a previous recording can leak in.
        PSDCache = containers.Map('KeyType','double','ValueType','any');

        % For long recordings, spectral analysis uses evenly-spaced excerpts
        % totalling this many seconds. This keeps the entire app responsive
        % while retaining samples from the beginning, middle and end.
        FastAnalysisSeconds = 120;
        % The live plot only shows a short readable window, so filtering a
        % full multi-hour trace before drawing it is unnecessary.
        LiveFilterSeconds = 40;

        % ================= CLINICAL EEG PATTERN FLAG THRESHOLDS =================
        % Research/educational heuristic thresholds only - NOT clinically
        % validated diagnostic criteria. Centralized here (rather than
        % scattered through the analysis functions) so they can be
        % reviewed/tuned in one place as the app is tested against more
        % datasets. See computeClinicalPatternFlags() for how each is used.
        PatternThresholds = struct( ...
            'SeizureTransientRateFlag', 6, ...    % transients/min => "Flagged for review"
            'DementiaSlowingRel',       55, ...   % Delta+Theta relative % considered elevated
            'DementiaAlphaLowRel',      15, ...   % Alpha relative % considered reduced
            'ADHDThetaBetaRatio',       2.0, ...  % Theta/Beta ratio => "Possible"
            'DepressionAsymmetryPct',   15 ...    % frontal alpha asymmetry % => "Present"
        );

        % --- Report styling constants (reused across all PDF pages) ---
        ReportNavy   = [0.10 0.20 0.36];
        ReportAccent = [0.20 0.45 0.72];
        ReportGray   = [0.35 0.35 0.35];
        ReportLtGray = [0.95 0.95 0.96];
        ReportBorder = [0.55 0.55 0.58];
    end

    methods (Access = private)

        %% --- Universal file reader: .mat / .csv / .edf -> numeric matrix + fs ---
        % Centralizes file-format handling so both the patient-EEG loader
        % and the reference-EEG loader use one code path. Returns a
        % samples x channels numeric matrix and the detected/declared
        % sampling rate. Throws an error (with a descriptive message) on
        % anything it can't parse, so callers can uialert() it directly.
        %
        % needsFs (optional, default true): whether the caller actually
        % uses the returned sampling rate for anything. Patient EEG needs
        % an accurate fs for every calculation, so a .csv (which has no
        % standard way to store fs) prompts the user for it. The "Normal
        % EEG" reference line is plotted purely for visual side-by-side
        % comparison and never feeds any calculation, so callers that pass
        % needsFs=false skip that prompt entirely - asking for a number
        % that would never be used was confusing rather than helpful.
        function [data,fsOut,chNamesOut] = readAnyEEGFile(app,file,needsFs)
            if nargin < 3
                needsFs = true;
            end
            [~,~,ext] = fileparts(file);
            data = []; fsOut = app.fs; chNamesOut = {}; % chNamesOut empty = "unknown, use fallback"

            switch lower(ext)
                case '.mat'
                    S = load(file);
                    if isfield(S,'EEG')
                        data = S.EEG;
                        if isfield(S,'fs'), fsOut = S.fs; end
                        if isfield(S,'channelNames'), chNamesOut = cellstr(S.channelNames); end
                    else
                        error('EEG variable not found in .mat file (expected variable named "EEG")');
                    end

                case '.csv'
                    [data,fsOut] = app.readCsvWithAutoSamplingRate(file,needsFs);

                case '.edf'
                    try
                        info = edfinfo(file);
                    catch
                        error('Reading .edf requires the Signal Processing Toolbox (edfinfo/edfread not found).');
                    end
                    T = edfread(file);
                    varNames = T.Properties.VariableNames; % used only to index the table
                    nChTmp = numel(varNames);

                    % Sampling rate: samples per channel / record duration (seconds)
                    durSec = seconds(info.DataRecordDuration);
                    nSampPerRecord = info.NumSamples; % per-channel, per-record
                    fsPerCh = double(nSampPerRecord) / durSec;
                    fsOut = round(fsPerCh(1)); % assume first channel's fs for the whole matrix

                    colData = cell(1,nChTmp);
                    maxLen = 0;
                    for c = 1:nChTmp
                        col = T.(varNames{c});
                        if iscell(col)
                            vec = vertcat(col{:});
                        else
                            vec = col;
                        end
                        colData{c} = double(vec);
                        maxLen = max(maxLen, numel(vec));
                    end

                    data = nan(maxLen,nChTmp);
                    for c = 1:nChTmp
                        v = colData{c};
                        data(1:numel(v),c) = v;
                    end

                    % Use the TRUE channel labels from the EDF header
                    % (e.g. "FP1-F7"), not MATLAB's sanitized table
                    % variable names (which mangle them into things like
                    % "SignalLabel1_FP1_F7"). Falls back to the table
                    % variable names only if SignalLabels is unavailable
                    % or its count doesn't match the data.
                    try
                        rawLabels = strtrim(cellstr(info.SignalLabels));
                        if numel(rawLabels) == nChTmp
                            chNamesOut = rawLabels;
                        else
                            chNamesOut = varNames;
                        end
                    catch
                        chNamesOut = varNames;
                    end

                otherwise
                    error('Unsupported file type: %s (use .mat, .csv, or .edf)', ext);
            end
        end

        function [data,fsOut] = readCsvWithAutoSamplingRate(app,file,needsFs)
            % A CSV normally has no formal sampling-rate field. When it
            % includes a Time/Timestamp column, calculate fs from its median
            % interval and remove that column from the EEG matrix. With no
            % detectable time axis, use the app default without showing a
            % popup; values alone cannot reveal the true recording rate.
            if nargin < 3
                needsFs = true;
            end
            data = readmatrix(file);
            fsOut = app.fs;
            if isempty(data) || size(data,1) < 3
                return
            end

            timeCol = [];
            timeUnitMs = false;
            try
                opts = detectImportOptions(file);
                names = opts.VariableNames;
                for c = 1:min(numel(names),size(data,2))
                    label = lower(regexprep(names{c},'[^a-z0-9]',''));
                    if contains(label,'timestamp') || contains(label,'time')
                        timeCol = c;
                        timeUnitMs = contains(label,'ms') || contains(label,'msec') || contains(label,'millisecond');
                        break
                    end
                end
            catch
                % Continue with the safe numeric-column fallback below.
            end

            % Headerless exports often store time in the first column. Only
            % treat it as time when it is strictly increasing with a
            % sub-second step; this avoids confusing sample-index columns.
            if isempty(timeCol) && size(data,2) >= 2
                firstCol = data(:,1);
                valid = firstCol(isfinite(firstCol));
                if numel(valid) >= 3
                    dtGuess = median(diff(valid));
                    if all(diff(valid) > 0) && isfinite(dtGuess) && dtGuess > 0 && dtGuess < 1
                        timeCol = 1;
                    end
                end
            end

            if ~isempty(timeCol)
                timeVals = data(:,timeCol);
                valid = isfinite(timeVals);
                dt = median(diff(timeVals(valid)));
                if timeUnitMs
                    dt = dt/1000;
                end
                fsGuess = 1/dt;
                if isfinite(fsGuess) && fsGuess >= 1 && fsGuess <= 5000
                    if needsFs
                        fsOut = round(fsGuess);
                    end
                    data(:,timeCol) = [];
                end
            end
        end

        %% --- Load EEG Data ---
        function loadEEG(app,file)
            progDlg = uiprogressdlg(app.UIFigure,'Title','Please Wait', ...
                'Message','Loading EEG data...','Indeterminate','on');
            progCleanup = onCleanup(@() close(progDlg)); %#ok<NASGU>

            try
                [app.EEGData,app.fs,chNamesLoaded] = app.readAnyEEGFile(file,true);
            catch ME
                uialert(app.UIFigure, ME.message, 'Error', 'Icon','error');
                app.EEGData = [];
                return;
            end

            if isempty(app.EEGData) || ~isnumeric(app.EEGData)
                uialert(app.UIFigure,'Loaded data is empty or non-numeric','Error', 'Icon','error');
                app.EEGData = [];
                return;
            end

            % New recording loaded - any cached PSD results from a
            % previously loaded file are now stale and must not be reused.
            app.resetPSDCache();

            % A previously loaded "Normal EEG" (GreenLine) overlay is also
            % stale once a new patient file is loaded - its channel count/
            % order may no longer correspond to this recording, which could
            % silently overlay the wrong (misleading) visual comparison.
            % It is visual-only (never feeds any calculation), so simply
            % clearing it here is the safe choice; the user can reload a
            % matching Normal EEG file afterwards if they still want one.
            app.GreenLine = [];

            % Basic length sanity check for filtering/PSD later
            if size(app.EEGData,1) < 4*app.fs
                uialert(app.UIFigure, sprintf(['Warning: signal is shorter than 4x the sample rate ' ...
                    '(%d samples at fs=%d). Spectral estimates may be unreliable.'], ...
                    size(app.EEGData,1), app.fs), 'Short Recording', 'Icon','warning');
            end

            % --- Resolve channel names for THIS recording ---
            % Priority: names supplied by the file itself (edf, or a .mat
            % "channelNames" variable) > the default 8-channel montage
            % (only if the column count matches it) > generic Ch1..ChN.
            % ALL channels present in the recording are analyzed in the
            % background (Multi-Channel View, PDF, Excel cover every
            % channel) - there is no cap and no per-channel selector in
            % the UI. The single live plot/Analyze panel always reflects
            % the first channel (see SelectedChannel below).
            nChData = size(app.EEGData,2);
            if ~isempty(chNamesLoaded) && numel(chNamesLoaded) >= nChData
                app.ChannelNames = chNamesLoaded(1:nChData);
            elseif nChData <= numel(app.DefaultChannelNames)
                app.ChannelNames = app.DefaultChannelNames(1:nChData);
            else
                app.ChannelNames = arrayfun(@(i) sprintf('Ch%d',i), 1:nChData, 'UniformOutput', false);
            end
            app.SelectedChannel = 1;

            % Keep the live channel selector in sync with the recording.
            % EDF labels are retained exactly as supplied by edfinfo (for
            % example, "FP1-F7"), rather than substituting a fixed montage.
            app.ChannelDropDown.Items = app.ChannelNames;
            app.ChannelDropDown.Value = app.ChannelNames{app.SelectedChannel};
            app.ChannelDropDown.Enable = 'on';

            app.plotRaw();
            figure(app.UIFigure) % keep main UI visible
        end

        %% --- Plot raw signal with a real time axis ---
        function plotRaw(app)
            cla(app.UIAxes)
            n = size(app.EEGData,1);
            t = (0:n-1)'/app.fs;
            plot(app.UIAxes, t, app.EEGData(:,app.SelectedChannel), 'r')
            xlabel(app.UIAxes,'Time (s)')
            ylabel(app.UIAxes,'Amplitude (\muV)')
            legend(app.UIAxes, {'Patient EEG'}, 'Location','best')
            title(app.UIAxes,['Raw EEG - ' app.ChannelNames{app.SelectedChannel}])
            % Long recordings compress thousands of cycles into a few
            % hundred pixels and look like a solid noise block even
            % though the data itself is fine. Default to a readable
            % close-up window; the full recording is still there - use
            % the toolbar's zoom-out/Home button to see all of it.
            app.setReadableTimeWindow(t(end));
        end

        %% --- Set a readable default x-axis window on the live plot ---
        % Shared by plotRaw and analyzeEEG so both default to a close-up
        % view (full data remains plotted/available - this only changes
        % what's initially visible; zoom/pan/Home in the toolbar reveals
        % the rest of the recording).
        function setReadableTimeWindow(app,totalDurationSec)
            winSec = min(app.WaveformDisplaySeconds*2, totalDurationSec);
            if winSec > 0
                xlim(app.UIAxes,[0 winSec]);
                if winSec < totalDurationSec
                    subtitle(app.UIAxes, sprintf( ...
                        'Showing first %.0fs of %.0fs - zoom out / Home button in toolbar to see the full recording', ...
                        winSec, totalDurationSec));
                end
            end
        end

        %% --- Preprocess: detrend + notch-filter a channel ---
        % Removes slow drift (detrend) and power-line interference (notch)
        % before any spectral or filtering step. This is a minimal but
        % essential preprocessing stage that was previously missing.
        function sig = preprocessChannel(app,channel)
            sig = app.preprocessSignal(double(app.EEGData(:,channel)));
        end

        %% --- Preprocess an arbitrary signal vector (detrend + notch) ---
        % Delegates to the Static method below so the exact same code path
        % used here is also directly callable from outside the class
        % (e.g. runEEGValidation.m via EEGAppBands.preprocessEEGSignal),
        % with no separate standalone file needed.
        function sig = preprocessSignal(app,sig)
            sig = app.preprocessEEGSignal(sig, app.fs, app.NotchFreq);
        end

        %% --- Preprocess + bandpass-filter an arbitrary raw vector to a
        %% named band. Returns [] if the filter can't be applied at this
        %% fs/length. Shared by the reference overlay and the all-band
        %% waveform grid so every band uses identical filtering logic.
        function out = filterBandGeneric(app,raw,bandName)
            out = [];
            % This helper is used only by the on-screen/PDF waveform
            % previews. Limiting it to the visible portion avoids filtering
            % an entire long recording solely to display its first seconds.
            raw = raw(1:min(numel(raw),round(app.LiveFilterSeconds*app.fs)));
            sig = app.preprocessSignal(raw);
            br = app.Bands.(char(bandName));
            nyq = app.fs/2;
            if br(2) >= nyq
                return
            end
            try
                [b,a] = butter(4,br/nyq,'bandpass');
                if numel(sig) <= 3*(max(numel(a),numel(b))-1)
                    return
                end
                out = filtfilt(b,a,sig);
            catch
                out = [];
            end
        end

        %% --- Apply the same preprocessing + currently-selected band
        %% filter to a reference vector, for the live plot overlay.
        function out = filterReference(app,raw)
            out = app.filterBandGeneric(raw,app.SelectedBand);
        end

        %% --- Bandpass Filter (used only for the time-domain display plot) ---
        function ok = applyBandFilter(app)
            ok = true;
            raw = app.EEGData(:,app.SelectedChannel);
            nDisplay = min(numel(raw),round(app.LiveFilterSeconds*app.fs));
            sig = app.preprocessSignal(double(raw(1:nDisplay)));
            br = app.Bands.(app.SelectedBand);

            nyq = app.fs/2;
            if br(2) >= nyq
                uialert(app.UIFigure, sprintf(['Band upper edge (%.1f Hz) is at or above the Nyquist ' ...
                    'frequency (%.1f Hz) for fs=%d. Increase the sample rate or pick a lower band.'], ...
                    br(2), nyq, app.fs), 'Filter Error', 'Icon','error');
                ok = false;
                return;
            end
            try
                [b,a] = butter(4,br/nyq,'bandpass');
                if numel(sig) <= 3*(max(numel(a),numel(b))-1)
                    uialert(app.UIFigure,'Signal too short for a stable filtfilt at this filter order.','Filter Error', 'Icon','error');
                    ok = false;
                    return;
                end
                app.FilteredData = filtfilt(b,a,sig);
            catch ME
                uialert(app.UIFigure, ['Filtering failed: ' ME.message], 'Filter Error', 'Icon','error');
                ok = false;
            end
        end

        %% --- PSD-based absolute & relative band power (Welch's method) ---
        % Delegates to the Static computeBandPowerPSD method below - the
        % exact algorithm validated by runEEGValidation.m against
        % synthetic signals with known ground truth (see that script's
        % header for methodology and Methods_and_Validation_Results.txt
        % for results once run). One implementation, used identically
        % here and from the validation script via EEGAppBands.computeBandPowerPSD(...).
        function [absPower,relPower,fields,peakAlphaFreq,pctBad] = bandPowersPSD(app,channel)
            if isKey(app.PSDCache,channel)
                c = app.PSDCache(channel);
                absPower = c.absPower; relPower = c.relPower; fields = c.fields;
                peakAlphaFreq = c.peakAlphaFreq; pctBad = c.pctBad;
                return
            end
            sig = app.preprocessPSDChannel(channel);
            [absPower,relPower,fields,peakAlphaFreq,pctBad] = ...
                app.computeBandPowerPSD(sig, app.fs, app.Bands, app.BroadBand, app.ArtifactSD);
            c = struct();
            c.absPower = absPower; c.relPower = relPower; c.fields = fields;
            c.peakAlphaFreq = peakAlphaFreq; c.pctBad = pctBad;
            app.PSDCache(channel) = c;
        end

        function sig = preprocessPSDChannel(app,channel)
            raw = double(app.EEGData(:,channel));
            maxSamples = round(app.FastAnalysisSeconds*app.fs);
            if numel(raw) <= maxSamples
                sig = app.preprocessSignal(raw);
                return
            end

            % Four equally spaced continuous excerpts give a representative
            % PSD without making a 1-hour recording block the UI for minutes.
            nSegments = 4;
            segmentLength = floor(maxSamples/nSegments);
            starts = round(linspace(1,numel(raw)-segmentLength+1,nSegments));
            sig = zeros(segmentLength*nSegments,1);
            for s = 1:nSegments
                outIdx = (s-1)*segmentLength + (1:segmentLength);
                inIdx = starts(s):starts(s)+segmentLength-1;
                sig(outIdx) = app.preprocessSignal(raw(inIdx));
            end
        end

        function [absPower,relPower,fields,peakAlphaFreq,pctBad] = multiChannelPreviewPowers(app,channel)
            % Reuse the cached fast PSD result so opening the summary also
            % speeds up later Analyze, PDF and Excel actions.
            [absPower,relPower,fields,peakAlphaFreq,pctBad] = app.bandPowersPSD(channel);
        end

        %% --- Clear the PSD cache (call whenever a new recording is loaded,
        %% since a new file means new EEGData/fs and any previously cached
        %% per-channel results would otherwise be stale/wrong) ---
        function resetPSDCache(app)
            app.PSDCache = containers.Map('KeyType','double','ValueType','any');
        end

        %% --- Multi-Pattern Flagging (relative-power based) ---
        % NOTE: These are observation-based relative-band-power ratio flags for
        % illustrative/educational purposes only. They are NOT validated
        % diagnostic criteria and must not be used for clinical decisions.
        function patterns = detectPatterns(~,relPower,fields)
            idx = struct();
            for i=1:numel(fields), idx.(fields{i}) = relPower(i); end
            Delta=idx.Delta; Theta=idx.Theta; Alpha=idx.Alpha; Beta=idx.Beta;

            patterns = {};

            if any(isnan(relPower))
                patterns{end+1} = 'Some bands unavailable at this sample rate';
            end
            if ~isnan(Theta) && ~isnan(Beta) && Beta>0 && Theta/Beta>2
                patterns{end+1} = 'High Theta/Beta ratio (may indicate a reduced-attention pattern)';
            end
            if ~isnan(Delta) && ~isnan(Alpha) && Alpha>0 && Delta/Alpha>2
                patterns{end+1} = 'High Delta/Alpha ratio (may indicate a drowsy/low-arousal pattern)';
            end
            if ~isnan(Theta) && ~isnan(Alpha) && ~isnan(Beta) && Theta>Alpha && Theta>Beta
                patterns{end+1} = 'Theta-dominant activity (consistent with a drowsy pattern)';
            end
            if ~isnan(Beta) && ~isnan(Alpha) && ~isnan(Theta) && Beta>Alpha && Beta>Theta
                patterns{end+1} = 'Beta-dominant activity (consistent with an alert/high-arousal pattern)';
            end
            if ~isnan(Alpha) && ~isnan(Beta) && ~isnan(Theta) && Alpha>Beta && Alpha>Theta
                patterns{end+1} = 'Alpha-dominant activity (consistent with a relaxed pattern)';
            end
            if ~isnan(Delta) && ~isnan(Theta) && ~isnan(Alpha) && ~isnan(Beta) && (Delta+Theta) > (Alpha+Beta)*1.5
                patterns{end+1} = 'Slow-wave dominant pattern (Delta + Theta > 1.5 x Alpha + Beta)';
            end

            if isempty(patterns)
                patterns = {'No patterns flagged'};
            end
        end

        %% --- Generalized slowing observation (descriptive, not diagnostic) ---
        % Reports whether combined Delta+Theta relative power on the selected
        % channel exceeds SlowingThreshold. This is purely a description of
        % the spectral shape (excess low-frequency power). It does NOT
        % constitute an "encephalopathy" or diffuse-dysfunction finding -
        % that determination requires clinical context (history, medications,
        % labs) that this tool has no access to.
        function [isSlow,slowPct] = assessSlowing(app,relPower,fields)
            idx = struct();
            for i=1:numel(fields), idx.(fields{i}) = relPower(i); end
            if isnan(idx.Delta) || isnan(idx.Theta)
                isSlow = false; slowPct = NaN;
                return
            end
            slowPct = idx.Delta + idx.Theta;
            isSlow = slowPct > app.SlowingThreshold;
        end

        %% --- Dynamic hemispheric-pair detection (channel-name based) ---
        % Different EEG sources use different channel names/counts/orders
        % (e.g. unipolar Fp1/Fp2/F3/F4/... vs bipolar FP1-F7/F7-T7/...).
        % Rather than assuming a fixed montage/index layout, this scans
        % app.ChannelNames for the standard 10-20 naming convention
        % (odd number = left hemisphere, even number = right hemisphere,
        % e.g. Fp1<->Fp2, F3<->F4, C3<->C4, O1<->O2, T3<->T4, P3<->P4)
        % and returns an Nx2 matrix of matched [leftIdx rightIdx] pairs.
        % Returns an empty (0x2) matrix if no pairs can be matched (e.g.
        % bipolar montage names), so callers can report "insufficient
        % channel data" instead of crashing or mis-pairing channels.
        %% --- Extract the lead (first) electrode from a channel name ---
        % Unipolar montages name channels as a single electrode, e.g.
        % "Fp1". Bipolar montages (very common in EDF exports, e.g. the
        % standard 10-20 "double banana") name channels as
        % "electrode-reference", e.g. "FP1-F7" (Fp1 referenced to F7).
        % Hemispheric/frontal pairing only needs the FIRST electrode to
        % decide left vs. right, so this strips any "-reference" suffix
        % and returns just that leading token (e.g. "FP1-F7" -> "FP1").
        % Names that don't match a leading letters+digits pattern (e.g.
        % generic "Ch3" or malformed labels) return '' so callers can
        % skip them, exactly as before.
        function leadNames = extractLeadElectrodes(~,names)
            n = numel(names);
            leadNames = cell(n,1);
            for i = 1:n
                tok = regexp(names{i}, '^([A-Za-z]+\d+)', 'tokens', 'once');
                if isempty(tok)
                    leadNames{i} = '';
                else
                    leadNames{i} = upper(tok{1});
                end
            end
        end

        function pairs = findHemisphericPairs(app)
            pairs = zeros(0,2);
            leadNames = app.extractLeadElectrodes(app.ChannelNames);
            n = numel(leadNames);
            parsed = cell(n,2); % {base, num}
            for i = 1:n
                tok = regexp(leadNames{i}, '^([A-Za-z]+)(\d+)$', 'tokens', 'once');
                if isempty(tok)
                    parsed{i,1} = ''; parsed{i,2} = NaN;
                else
                    parsed{i,1} = upper(tok{1});
                    parsed{i,2} = str2double(tok{2});
                end
            end
            for i = 1:n
                if isempty(parsed{i,1}) || isnan(parsed{i,2}) || mod(parsed{i,2},2)==0
                    continue % only start from odd (left) channels
                end
                for j = 1:n
                    if j==i, continue; end
                    if strcmp(parsed{i,1},parsed{j,1}) && parsed{j,2} == parsed{i,2}+1
                        pairs(end+1,:) = [i j]; %#ok<AGROW>
                        break
                    end
                end
            end
        end

        %% --- Dynamic frontal-pair detection (for depression-associated
        %% frontal alpha asymmetry). Prefers Fp1/Fp2, then F3/F4, then
        %% F7/F8, using whatever channel names are actually present.
        %% Returns empty indices (idxL=[]) if no suitable pair exists.
        function [idxL,idxR,pairLabel] = findFrontalPair(app)
            idxL = []; idxR = []; pairLabel = '';
            prefs = {{'FP1','FP2'},{'F3','F4'},{'F7','F8'}};
            % Matched on the LEAD electrode so both unipolar names
            % ("Fp1") and bipolar names ("FP1-F7") resolve correctly -
            % see extractLeadElectrodes() for why.
            leadNames = app.extractLeadElectrodes(app.ChannelNames);
            for p = 1:numel(prefs)
                li = find(strcmpi(leadNames,prefs{p}{1}),1);
                ri = find(strcmpi(leadNames,prefs{p}{2}),1);
                if ~isempty(li) && ~isempty(ri)
                    idxL = li; idxR = ri;
                    % Use the canonical short 10-20 label pair (e.g.
                    % "FP1/FP2") rather than the full channel names
                    % (e.g. "FP1-F7/FP2-F8" for a bipolar montage) - the
                    % full bipolar wiring isn't needed for this summary
                    % label, and a long label previously overflowed the
                    % narrow Value column in the PDF pattern-flags table.
                    pairLabel = sprintf('%s/%s', prefs{p}{1}, prefs{p}{2});
                    return
                end
            end
        end

        %% --- Cross-channel (hemispheric) asymmetry check ---
        % Compares relative band power between left/right electrode pairs
        % (Fp1/Fp2, F3/F4, C3/C4, O1/O2). Reports the pairs and bands where
        % the difference exceeds AsymmetryThreshold. This is a descriptive
        % statistical comparison only - it does NOT localize a lesion.
        % Real focal/lateralizing interpretation requires expert visual
        % review of multi-channel morphology and clinical correlation.
        function asymLines = assessAsymmetry(app,fields)
            asymLines = {};
            nCh = min(size(app.EEGData,2), length(app.ChannelNames));
            pairsDyn = app.findHemisphericPairs();
            if isempty(pairsDyn)
                asymLines = {'Insufficient channel data for hemispheric pairing (channel names do not match the standard 10-20 odd/even naming convention)'};
                return
            end
            for p = 1:size(pairsDyn,1)
                chL = pairsDyn(p,1);
                chR = pairsDyn(p,2);
                if chL > nCh || chR > nCh
                    continue % pair not available at this channel count
                end
                try
                    [~,relL,~,~,~] = app.bandPowersPSD(chL);
                    [~,relR,~,~,~] = app.bandPowersPSD(chR);
                catch
                    % PSD failing for one hemispheric pair (e.g. bad data
                    % on that channel) shouldn't abort the whole asymmetry
                    % scan - skip just this pair and continue with the rest.
                    continue
                end
                for i = 1:numel(fields)
                    if isnan(relL(i)) || isnan(relR(i))
                        continue
                    end
                    diffAbs = abs(relL(i)-relR(i));
                    if diffAbs > app.AsymmetryThreshold
                        asymLines{end+1} = sprintf('%s/%s %s: relative power differs by %.1f%% (L=%.1f%%, R=%.1f%%)', ...
                            app.ChannelNames{chL}, app.ChannelNames{chR}, fields{i}, diffAbs, relL(i), relR(i)); %#ok<AGROW>
                    end
                end
            end
            if isempty(asymLines)
                asymLines = {'No inter-hemispheric relative-power difference exceeded threshold'};
            end
        end

        %% --- Large-amplitude transient report (descriptive, not spike detection) ---
        % Counts amplitude excursions beyond TransientSD standard deviations
        % on the selected channel. This is a simple threshold-crossing count,
        % NOT epileptiform spike/sharp-wave detection - real spike detection
        % requires waveform morphology analysis (rise time, sharpness,
        % duration, field distribution across channels) which this amplitude
        % threshold cannot provide. Flagged as "large-amplitude transients"
        % to avoid implying a specific clinical waveform was identified.
        function [nTransients,transientRate] = assessTransients(app,channel)
            sig = double(app.EEGData(:,channel));
            mu = mean(sig); sd = std(sig);
            isTransient = abs(sig-mu) > app.TransientSD*sd;
            nTransients = sum(isTransient);
            durationSec = numel(sig)/app.fs;
            if durationSec > 0
                transientRate = nTransients/(durationSec/60); % per minute
            else
                transientRate = NaN;
            end
        end

        %% ================= CLINICAL EEG PATTERN FLAGS =================
        % Research/educational EEG pattern flags only. This is NOT a
        % medical diagnosis system: it reports whether measured spectral
        % features are consistent with predefined research patterns, using
        % the centralized, easily-tunable app.PatternThresholds. Results
        % are always phrased as "Possible" / "Not prominent" / "Flagged
        % for review" / "Insufficient evidence" - never as a diagnosis.
        %
        % Returns a struct (ClinicalPatterns-style) so new conditions can
        % be added later as new fields without touching the GUI/export
        % code, which simply iterates/display whatever fields are present.
        function flags = computeClinicalPatternFlags(app,relPower,fields,transRate)
            flags = struct('Seizure','','Dementia','','ADHD','','Depression','');

            idx = struct();
            for i=1:numel(fields), idx.(fields{i}) = relPower(i); end

            % --- Pattern 1: Seizure-like activity ---
            % Reuses the existing amplitude-transient heuristic rather than
            % a separate detector. A failure to flag does NOT prove a
            % seizure is absent, so we never say "No seizure".
            if isnan(transRate)
                flags.Seizure = 'Insufficient evidence';
            elseif transRate >= app.PatternThresholds.SeizureTransientRateFlag
                flags.Seizure = 'Flagged for review';
            else
                flags.Seizure = 'Not detected by current heuristic';
            end

            % --- Pattern 2: Dementia-associated slowing pattern ---
            % Combines two features (elevated Delta+Theta AND reduced
            % Alpha) rather than a single arbitrary threshold.
            if isnan(idx.Delta) || isnan(idx.Theta) || isnan(idx.Alpha)
                flags.Dementia = 'Insufficient evidence';
            else
                slowPct = idx.Delta + idx.Theta;
                highSlow = slowPct > app.PatternThresholds.DementiaSlowingRel;
                lowAlpha = idx.Alpha < app.PatternThresholds.DementiaAlphaLowRel;
                if highSlow && lowAlpha
                    flags.Dementia = sprintf('Possible (Delta+Theta %.1f%%, Alpha %.1f%%)', slowPct, idx.Alpha);
                else
                    flags.Dementia = sprintf('Not prominent (Delta+Theta %.1f%%, Alpha %.1f%%)', slowPct, idx.Alpha);
                end
            end

            % --- Pattern 3: ADHD-associated Theta/Beta pattern ---
            if isnan(idx.Theta) || isnan(idx.Beta) || idx.Beta <= 0
                flags.ADHD = 'Insufficient evidence';
            else
                tbRatio = idx.Theta / idx.Beta;
                if tbRatio >= app.PatternThresholds.ADHDThetaBetaRatio
                    flags.ADHD = sprintf('Possible (Theta/Beta = %.2f)', tbRatio);
                else
                    flags.ADHD = sprintf('Not prominent (Theta/Beta = %.2f)', tbRatio);
                end
            end

            % --- Pattern 4: Depression-associated frontal alpha asymmetry ---
            [li,ri,pairLabel] = app.findFrontalPair();
            if isempty(li)
                flags.Depression = 'Insufficient channel data';
            else
                try
                    [~,relL,fL,~,~] = app.bandPowersPSD(li);
                    [~,relR,fR,~,~] = app.bandPowersPSD(ri);
                    aL = relL(strcmp(fL,'Alpha')); aR = relR(strcmp(fR,'Alpha'));
                    if isempty(aL) || isempty(aR) || isnan(aL) || isnan(aR)
                        flags.Depression = 'Insufficient evidence';
                    else
                        asym = abs(aL-aR);
                        if asym > app.PatternThresholds.DepressionAsymmetryPct
                            flags.Depression = sprintf('Present (%s Alpha asymmetry %.1f%%)', pairLabel, asym);
                        else
                            flags.Depression = sprintf('Not prominent (%s Alpha asymmetry %.1f%%)', pairLabel, asym);
                        end
                    end
                catch
                    flags.Depression = 'Insufficient evidence';
                end
            end
        end

        %% --- Format a computeClinicalPatternFlags struct into display lines ---
        function lines = formatClinicalPatternFlags(~,flags)
            lines = {
                ['Seizure-like activity: ' flags.Seizure]
                ['Dementia-associated slowing pattern: ' flags.Dementia]
                ['ADHD-associated Theta/Beta pattern: ' flags.ADHD]
                ['Frontal alpha asymmetry: ' flags.Depression]
            };
        end

        %% --- Analyze EEG and Update UI ---
        function analyzeEEG(app)
            progDlg = uiprogressdlg(app.UIFigure,'Title','Please Wait', ...
                'Message','Analyzing EEG signal...','Indeterminate','on');
            progCleanup = onCleanup(@() close(progDlg)); %#ok<NASGU>

            ok = app.applyBandFilter();
            if ~ok, return; end

            % --- Time-domain display of the selected band ---
            cla(app.UIAxes)
            hold(app.UIAxes,'on')
            n = numel(app.FilteredData);
            t = (0:n-1)'/app.fs;

            greenPlotted = false;
            if ~isempty(app.GreenLine)
                % Filter the reference with the SAME preprocessing + band
                % filter as the patient, so the overlay is a like-for-like
                % comparison rather than raw-vs-filtered.
                gCh = min(app.SelectedChannel,size(app.GreenLine,2));
                gSig = app.filterReference(app.GreenLine(:,gCh));
                if ~isempty(gSig)
                    tg = (0:numel(gSig)-1)'/app.fs;
                    plot(app.UIAxes,tg,gSig,'g')
                    greenPlotted = true;
                end
            end
            plot(app.UIAxes,t,app.FilteredData,'r')
            hold(app.UIAxes,'off')
            xlabel(app.UIAxes,'Time (s)')
            ylabel(app.UIAxes,'Amplitude (\muV)')
            % Legend labels must match exactly what was plotted (and in
            % the same order) - a mismatched label count previously caused
            % MATLAB to mislabel the red Patient line as "Normal EEG"
            % whenever no Normal EEG was actually loaded/plotted.
            if greenPlotted
                legend(app.UIAxes, {'Normal EEG','Patient EEG'}, 'Location','best')
            else
                legend(app.UIAxes, {'Patient EEG'}, 'Location','best')
            end
            title(app.UIAxes,[char(app.SelectedBand) ' Band - ' app.ChannelNames{app.SelectedChannel}])
            app.setReadableTimeWindow(t(end));
            drawnow

            % --- PSD-based power analysis (the core upgrade) ---
            try
                [absPower,relPower,fields,peakAlphaFreq,pctBad] = app.bandPowersPSD(app.SelectedChannel);
            catch ME
                uialert(app.UIFigure, ['Spectral analysis failed: ' ME.message], 'Analysis Error', 'Icon','error');
                return
            end

            bandIdx = strcmp(fields, app.SelectedBand);
            relThis = relPower(bandIdx);
            absThis = absPower(bandIdx);
            nr = app.NormalRangesRel.(char(app.SelectedBand));

            status = "Within Reference Range";
            if isnan(relThis)
                status = "Not resolvable at current sampling rate";
            elseif relThis < nr(1)
                status = "Below Reference Range";
            elseif relThis > nr(2)
                status = "Above Reference Range";
            end

            commentLines = {
                ['Band: ',char(app.SelectedBand)];
                ['Relative Power: ',num2str(relThis,'%.1f'),' %'];
                ['Absolute Power: ',num2str(absThis,'%.2f'),' \muV^2'];
                ['Reference Range (rel.): ',num2str(nr(1)),'-',num2str(nr(2)),' %'];
                ['Status: ',char(status)]
            };
            if pctBad > 5
                commentLines{end+1} = sprintf('Data quality: %.1f%% samples flagged as outliers', pctBad);
            else
                commentLines{end+1} = sprintf('Data quality: OK (%.1f%% outlier samples)', pctBad);
            end
            commentLines{end+1} = '(PSD-based, Welch method. Reference values illustrative, not clinically validated)';
            app.CommentLabel.Value = commentLines;

            % --- Dominant-band state estimate (from relative power) ---
            validMask = ~isnan(relPower);
            if ~any(validMask)
                state = "Undetermined";
            else
                relValid = relPower; relValid(~validMask) = -Inf;
                [~,idx] = max(relValid);
                labelMap = containers.Map({'Delta','Theta','Alpha','Beta','Gamma'}, ...
                                           {'Delta-dominant (deep/slow-wave)','Theta-dominant (drowsy)', ...
                                            'Alpha-dominant (relaxed)','Beta-dominant (active/alert)', ...
                                            'Gamma-dominant (high-frequency activity)'});
                state = labelMap(fields{idx});
            end

            % --- Pattern flags (short, plain-language) ---
            patList = app.detectPatterns(relPower,fields);

            % --- Generalized slowing (one line) ---
            [isSlow,slowPct] = app.assessSlowing(relPower,fields);
            if isnan(slowPct)
                slowStr = 'N/A (bands unresolved)';
            elseif isSlow
                slowStr = sprintf('Elevated (Delta + Theta = %.1f%%; threshold = %.0f%%)', slowPct, app.SlowingThreshold);
            else
                slowStr = sprintf('Not elevated (Delta + Theta = %.1f%%)', slowPct);
            end

            % --- Cross-channel asymmetry (one line, or list only if flagged) ---
            asymLines = app.assessAsymmetry(fields);
            if numel(asymLines)==1 && contains(asymLines{1},'No inter-hemispheric')
                asymDisplay = {'None detected'};
            else
                asymDisplay = asymLines(:);
            end

            % --- Large-amplitude transients (one line) ---
            [nTrans,transRate] = app.assessTransients(app.SelectedChannel);
            transStr = sprintf('%d events (>%.0fSD, %.1f/min)', nTrans, app.TransientSD, transRate);

            % --- Clinical EEG pattern flags (research/educational only) ---
            clinFlags = app.computeClinicalPatternFlags(relPower,fields,transRate);
            clinLines = app.formatClinicalPatternFlags(clinFlags);

            % --- Assemble: short headers, one fact per line, single disclaimer ---
            lines = {};
            lines{end+1} = 'BRAIN STATE';
            lines{end+1} = sprintf('State: %s', char(state));
            if ~isnan(peakAlphaFreq)
                lines{end+1} = sprintf('Alpha Peak: %.2f Hz', peakAlphaFreq);
            end
            lines{end+1} = '';
            lines{end+1} = 'EEG PATTERN (FLAGGED OBSERVATIONS)';
            for i = 1:numel(patList)
                lines{end+1} = ['- ' patList{i}]; %#ok<AGROW>
            end
            lines{end+1} = '';
            lines{end+1} = 'CLINICAL EEG PATTERN FLAGS (research/educational only - not a diagnosis)';
            for i = 1:numel(clinLines)
                lines{end+1} = ['- ' clinLines{i}]; %#ok<AGROW>
            end
            lines{end+1} = '';
            lines{end+1} = 'OBSERVATIONS';
            lines{end+1} = sprintf('Slowing: %s', slowStr);
            lines{end+1} = sprintf('Transients: %s', transStr);
            lines{end+1} = 'Asymmetry:';
            for i = 1:numel(asymDisplay)
                lines{end+1} = ['  - ' asymDisplay{i}]; %#ok<AGROW>
            end
            lines{end+1} = '';
            lines{end+1} = 'Note: descriptive/heuristic findings only - not a clinical diagnosis.';

            app.StateLabel.Value = lines(:);
        end

        %% --- Multi-Channel Summary View ---
        % Computes relative band power for every available channel and
        % displays them side-by-side as a grouped bar chart, plus a
        % status table (Above/Below/Within reference range per channel
        % per band). This is a descriptive, non-diagnostic comparison -
        % it does NOT localize disease; it summarizes spectral shape
        % across channels so patterns are easier to see at a glance,
        % similar to how a clinician scans a full montage rather than
        % one channel at a time.
        function showMultiChannelSummary(app)
            if isempty(app.EEGData)
                uialert(app.UIFigure,'Upload patient EEG first','Error', 'Icon','error');
                return
            end

            progDlg = uiprogressdlg(app.UIFigure,'Title','Please Wait', ...
                'Message','Computing multi-channel summary...','Indeterminate','on');
            progCleanup = onCleanup(@() close(progDlg)); %#ok<NASGU>

            % IMPORTANT:
            % All available channels are analyzed here. The dropdown below
            % changes ONLY what is displayed in the Multi-Channel window.
            % It does not remove channels from PSD analysis, caching,
            % asymmetry calculations, PDF export, or Excel export.
            nCh = min(size(app.EEGData,2), length(app.ChannelNames));
            fieldsRef = fieldnames(app.Bands);
            nBands = numel(fieldsRef);

            relMatrix = nan(nCh,nBands);
            qualityPct = nan(nCh,1);
            statusMatrix = strings(nCh,nBands);

            % ---- Full background analysis: every available channel ----
            for ch = 1:nCh
                try
                    [~,relPower,fields,~,pctBad] = app.multiChannelPreviewPowers(ch);
                catch
                    % A single channel's PSD failing shouldn't abort the
                    % whole multi-channel scan - it just stays as NaN/blank
                    % in the summary table for this channel, everything
                    % else still populates normally.
                    continue
                end
                qualityPct(ch) = pctBad;
                for b = 1:nBands
                    idxB = strcmp(fields, fieldsRef{b});
                    if ~any(idxB), continue; end
                    val = relPower(idxB);
                    relMatrix(ch,b) = val;
                    if isnan(val)
                        statusMatrix(ch,b) = "N/A";
                        continue
                    end
                    nr = app.NormalRangesRel.(fieldsRef{b});
                    if val < nr(1)
                        statusMatrix(ch,b) = "Below";
                    elseif val > nr(2)
                        statusMatrix(ch,b) = "Above";
                    else
                        statusMatrix(ch,b) = "Within";
                    end
                end
            end

            % The PSD calculation is complete at this point. Close the
            % modal progress dialog BEFORE constructing/redrawing the
            % separate summary UI; otherwise MATLAB can leave its "Please
            % Wait" window on top while the new figure is being rendered.
            delete(progCleanup);
            drawnow;

            % ---- Identify the recommended essential 8-channel view ----
            % Prefer the standard 10-20 names when they are actually
            % present. If a recording does not contain some of them, fill
            % the remaining slots with the first unused available channels.
            essentialPreferred = {'Fp1','Fp2','F3','F4','C3','C4','O1','O2'};
            essentialIdx = [];
            for k = 1:numel(essentialPreferred)
                hit = find(strcmpi(strtrim(app.ChannelNames(1:nCh)), essentialPreferred{k}),1);
                if ~isempty(hit) && ~ismember(hit,essentialIdx)
                    essentialIdx(end+1) = hit; %#ok<AGROW>
                end
            end
            for k = 1:nCh
                if numel(essentialIdx) >= min(8,nCh)
                    break
                end
                if ~ismember(k,essentialIdx)
                    essentialIdx(end+1) = k; %#ok<AGROW>
                end
            end
            essentialIdx = essentialIdx(1:min(8,nCh));

            % Plain-language labels + colors for each status.
            greenC = [0.85 0.95 0.87];
            redC = [0.98 0.87 0.87];
            orangeC = [1.00 0.93 0.82];
            grayC = [0.92 0.92 0.92];

            function label = plainLabel(s)
                switch s
                    case "Within"
                        label = "Normal";
                    case "Above"
                        label = "Higher than usual";
                    case "Below"
                        label = "Lower than usual";
                    otherwise
                        label = "Unavailable";
                end
            end

            % ---- Standalone Multi-Channel window ----
            f = uifigure('Name','Multi-Channel EEG Summary', ...
                'Position',[100 70 1160 790],'Color','w');
            gl = uigridlayout(f,[6 1]);
            gl.RowHeight = {84,54,'2x',30,'2x',30};
            gl.RowSpacing = 6;
            gl.Padding = [12 10 12 10];

            % Header banner
            headerPanel = uipanel(gl,'BackgroundColor',app.ReportNavy,'BorderType','none');
            headerPanel.Layout.Row = 1;
            hg = uigridlayout(headerPanel,[2 1]);
            hg.RowHeight = {34,30};
            hg.Padding = [16 10 16 8];
            hg.RowSpacing = 2;
            hg.BackgroundColor = app.ReportNavy;
            uilabel(hg,'Text','Multi-Channel EEG Band Power Summary', ...
                'FontSize',16,'FontWeight','bold','FontColor','w', ...
                'BackgroundColor',app.ReportNavy, ...
                'VerticalAlignment','center','WordWrap','off');
            uilabel(hg,'Text',sprintf('All %d available channel(s) summarized - display filter only.',nCh), ...
                'FontSize',10,'FontColor',[0.85 0.90 1], ...
                'BackgroundColor',app.ReportNavy, ...
                'VerticalAlignment','center','WordWrap','off');

            % ---- Channel View dropdown ----
            controlPanel = uipanel(gl,'Title','Channel View');
            controlPanel.Layout.Row = 2;
            cgl = uigridlayout(controlPanel,[1 4]);
            cgl.ColumnWidth = {130,230,'1x',250};
            cgl.Padding = [10 5 10 5];
            uilabel(cgl,'Text','Display channels:', ...
                'FontWeight','bold','HorizontalAlignment','right');
            viewDropDown = uidropdown(cgl, ...
                'Items',{'Essential Channels','First 8 Channels','First 12 Channels','All Channels'}, ...
                'Value','Essential Channels');
            infoLabel = uilabel(cgl,'Text','','FontAngle','italic', ...
                'FontColor',app.ReportGray,'HorizontalAlignment','left');
            uilabel(cgl,'Text',sprintf('Fast analysis: up to %ds/channel',app.FastAnalysisSeconds), ...
                'FontColor',app.ReportAccent,'FontWeight','bold', ...
                'HorizontalAlignment','right');

            % Chart and table handles are created once and refreshed by the
            % dropdown callback; no re-analysis is performed when the user
            % changes the view.
            ax = uiaxes(gl);
            ax.Layout.Row = 3;

            noteLbl = uilabel(gl,'Text','', ...
                'FontAngle','italic','FontSize',10,'FontColor',app.ReportGray, ...
                'HorizontalAlignment','center','WordWrap','on');
            noteLbl.Layout.Row = 4;

            tbl = uitable(gl,'Data',cell(0,1),'ColumnName',{'Channel'});
            tbl.Layout.Row = 5;
            tbl.RowStriping = 'on';

            footLbl = uilabel(gl,'Text', ...
                'Findings are descriptive/heuristic EEG patterns only and are not a clinical diagnosis.', ...
                'FontAngle','italic','FontSize',9,'FontColor',app.ReportGray, ...
                'HorizontalAlignment','center');
            footLbl.Layout.Row = 6;

            % Store a simple update callback. Selecting a different option
            % changes only chart/table rows; all PSD results remain cached.
            viewDropDown.ValueChangedFcn = @updateChannelView;
            updateChannelView();

            function idxView = getViewIndices(viewName)
                switch char(viewName)
                    case 'Essential Channels'
                        idxView = essentialIdx;
                    case 'First 8 Channels'
                        idxView = 1:min(8,nCh);
                    case 'First 12 Channels'
                        idxView = 1:min(12,nCh);
                    otherwise
                        idxView = 1:nCh;
                end
            end

            function updateChannelView(~,~)
                idxView = getViewIndices(viewDropDown.Value);
                if isempty(idxView)
                    infoLabel.Text = 'No channels available';
                    cla(ax);
                    tbl.Data = cell(0,1);
                    return
                end

                % ---- Chart ----
                cla(ax);
                visibleRel = relMatrix(idxView,:);
                validRows = ~all(isnan(visibleRel),2);
                if any(validRows)
                    plotIdx = idxView(validRows);
                    barH = bar(ax,relMatrix(plotIdx,:), 'grouped');
                    bandColors = [0.20 0.32 0.55; 0.20 0.55 0.55; ...
                                  0.30 0.65 0.35; 0.85 0.55 0.20; ...
                                  0.55 0.35 0.65];
                    for b = 1:min(nBands,numel(barH))
                        barH(b).FaceColor = bandColors(min(b,size(bandColors,1)),:);
                    end
                    legendLabels = cell(1,nBands);
                    for b = 1:nBands
                        br = app.Bands.(fieldsRef{b});
                        legendLabels{b} = sprintf('%s (%.1f-%.1f Hz)', ...
                            fieldsRef{b},br(1),br(2));
                    end
                    ax.XTick = 1:numel(plotIdx);
                    ax.XTickLabel = app.ChannelNames(plotIdx);
                    ax.XTickLabelRotation = 45;
                    ax.FontSize = 9;
                    legend(ax,legendLabels,'Location','northeastoutside');
                    ylabel(ax,'Relative Power (%)');
                    xlabel(ax,'Channel');
                    title(ax,sprintf('Share of Activity by Frequency Band (%d displayed)',numel(idxView)));
                    grid(ax,'on'); ax.GridAlpha = 0.15; box(ax,'on');
                else
                    title(ax,'No channel data available');
                end

                % ---- Table ----
                legendLabels = cell(1,nBands);
                for b = 1:nBands
                    br = app.Bands.(fieldsRef{b});
                    legendLabels{b} = sprintf('%s (%.1f-%.1f Hz)',fieldsRef{b},br(1),br(2));
                end
                colNames = ['Channel',legendLabels,{'Signal Quality'}];
                tblData = cell(numel(idxView),numel(colNames));

                for r = 1:numel(idxView)
                    ch = idxView(r);
                    tblData{r,1} = app.ChannelNames{ch};
                    for b = 1:nBands
                        st = statusMatrix(ch,b);
                        if st == ""
                            tblData{r,1+b} = 'Unavailable';
                        elseif st == "N/A"
                            tblData{r,1+b} = 'Unavailable (band unresolved at this sampling rate)';
                        else
                            tblData{r,1+b} = sprintf('%.1f%% - %s', ...
                                relMatrix(ch,b),plainLabel(st));
                        end
                    end
                    if isnan(qualityPct(ch))
                        tblData{r,end} = 'Unavailable';
                    elseif qualityPct(ch) > 5
                        tblData{r,end} = sprintf('Needs review (%.1f%% unusual points)',qualityPct(ch));
                    else
                        tblData{r,end} = sprintf('Good (%.1f%% unusual points)',qualityPct(ch));
                    end
                end
                tbl.Data = tblData;
                tbl.ColumnName = colNames;

                % ---- Status-cell colors ----
                % Existing cell styles are intentionally left in place; the
                % newest style is applied on top when the view changes.
                for r = 1:numel(idxView)
                    ch = idxView(r);
                    for b = 1:nBands
                        st = statusMatrix(ch,b);
                        if st == "Within"
                            c = greenC;
                        elseif st == "Above"
                            c = redC;
                        elseif st == "Below"
                            c = orangeC;
                        else
                            c = grayC;
                        end
                        addStyle(tbl,uistyle('BackgroundColor',c), ...
                            'cell',[r,1+b]);
                    end
                    if isnan(qualityPct(ch))
                        qc = grayC;
                    elseif qualityPct(ch) > 5
                        qc = orangeC;
                    else
                        qc = greenC;
                    end
                    addStyle(tbl,uistyle('BackgroundColor',qc), ...
                        'cell',[r,numel(colNames)]);
                end

                infoLabel.Text = sprintf('%d of %d channels displayed',numel(idxView),nCh);
                noteLbl.Text = ['Colors compare each reading with a typical/illustrative range: ' ...
                    'green = normal, red = higher than usual, orange = lower than usual. ' ...
                    'These are descriptive comparisons only, not clinical thresholds.'];
                drawnow;
            end

            figure(app.UIFigure) % keep main UI focused after
        end

        %% ================= Report page helpers (shared by every PDF page) =================

        % Creates a blank, invisible report page (classic figure/axes, not
        % uifigure - exportgraphics cannot reliably capture an invisible
        % uifigure) with the standard header banner already drawn.
        function [fig,ax] = newPdfPage(app)
            fig = figure('Visible','off','Position',[100 100 680 900],'Color','w');
            ax = axes(fig,'Position',[0 0 1 1]);
            axis(ax,'off'); hold(ax,'on')
            xlim(ax,[0 1]); ylim(ax,[0 1]); set(ax,'YDir','reverse')
            rectangle(ax,'Position',[0 0 1 0.065],'FaceColor',app.ReportNavy,'EdgeColor','none')
            text(ax,0.025,0.0325,'Elevated-X EEG Analysis Tool','Color','w', ...
                'FontSize',15,'FontWeight','bold','VerticalAlignment','middle')
            text(ax,0.975,0.0325,'EEG BAND POWER REPORT','Color',[0.82 0.91 1], ...
                'FontSize',8.5,'FontWeight','bold','HorizontalAlignment','right','VerticalAlignment','middle')
        end

        % Draws the running footer (tool label + page number) near the
        % bottom of an overlay-axis report page.
        function drawPageFooter(app,ax,pageNum)
            text(ax,0.025,0.978,'Elevated-X EEG Analysis Tool - Descriptive, non-diagnostic report', ...
                'FontSize',6.5,'FontAngle','italic','Color',[0.55 0.55 0.55])
            text(ax,0.975,0.978,sprintf('Page %d',pageNum), ...
                'FontSize',6.5,'Color',[0.55 0.55 0.55],'HorizontalAlignment','right')
        end

        % Draws a section title with underline; returns the y-position to
        % continue drawing content below it.
        function yOut = drawSectionTitle(app,ax,y,titleStr)
            text(ax,0.025,y,titleStr,'Color',app.ReportNavy,'FontSize',11.5,'FontWeight','bold')
            y = y + 0.006;
            line(ax,[0.025 0.26],[y+0.013 y+0.013],'Color',app.ReportAccent,'LineWidth',2)
            yOut = y + 0.032;
        end

        % Draws a bulleted, word-wrapped list of strings starting at y;
        % returns the y-position after the last item.
        function yOut = drawBulletList(app,ax,y,items,accent)
            if isempty(items)
                yOut = y;
                return
            end
            for i = 1:numel(items)
                lns = app.wrapTextLocal(items{i}, 95);
                text(ax,0.055,y,'-','FontSize',8.5,'Color',accent)
                for w = 1:numel(lns)
                    text(ax,0.075,y,lns{w},'FontSize',7.8,'Color',[0.15 0.15 0.15])
                    y = y + 0.019;
                end
                y = y + 0.003;
            end
            yOut = y;
        end

        % Collapses a full pattern-flag sentence into a short table tag,
        % e.g. "Beta-dominant relative spectrum (...)" -> "Beta-dominant".
        % Used only for the condensed Channel Overview table; the full
        % sentence is still shown wherever the underlying value drives
        % the observation (e.g. app.StateLabel in the live app UI).
        function tag = shortenPatternTag(~,str)
            s = lower(str);
            if contains(s,'unavailable')
                tag = 'Band N/A';
            elseif contains(s,'theta/beta')
                tag = 'High Theta/Beta';
            elseif contains(s,'delta/alpha')
                tag = 'High Delta/Alpha';
            elseif contains(s,'theta-dominant')
                tag = 'Theta-dominant';
            elseif contains(s,'beta-dominant')
                tag = 'Beta-dominant';
            elseif contains(s,'alpha-dominant')
                tag = 'Alpha-dominant';
            elseif contains(s,'slow-wave dominant')
                tag = 'Slow-wave';
            elseif contains(s,'no patterns flagged')
                tag = '-';
            elseif length(str) > 22
                tag = [str(1:20) '..'];
            else
                tag = str;
            end
        end

        % Draws one channel's band-power bar chart (with shaded reference
        % range) into a supplied axes handle. Shared by the small-multiple
        % chart-grid pages so the drawing logic isn't duplicated per page.
        function drawChannelBarAxes(app,axC,res,fieldsRef)
            nBandsLocal = numel(fieldsRef);
            bandColors = [0.20 0.32 0.55; 0.20 0.55 0.55; 0.30 0.65 0.35; 0.85 0.55 0.20];
            refLow = nan(1,nBandsLocal); refHigh = nan(1,nBandsLocal);
            for i = 1:nBandsLocal
                nrI = app.NormalRangesRel.(fieldsRef{i});
                refLow(i) = nrI(1); refHigh(i) = nrI(2);
            end
            hold(axC,'on')
            barVals = res.relPower; barVals(isnan(barVals)) = 0;
            for i = 1:nBandsLocal
                cIdx = min(i,size(bandColors,1));
                patch(axC,[i-0.28 i+0.28 i+0.28 i-0.28],[0 0 barVals(i) barVals(i)], ...
                    bandColors(cIdx,:),'EdgeColor','none')
                patch(axC,[i-0.35 i+0.35 i+0.35 i-0.35],[refLow(i) refLow(i) refHigh(i) refHigh(i)], ...
                    [0.3 0.7 0.3],'FaceAlpha',0.15,'EdgeColor',[0.3 0.7 0.3],'LineStyle','--','LineWidth',0.75)
            end
            hold(axC,'off')
            grid(axC,'on'); box(axC,'on')
            axC.GridAlpha = 0.15;
            axC.XTick = 1:nBandsLocal;
            axC.XTickLabel = fieldsRef;
            % Leave breathing room after Gamma so the final bar and label
            % do not touch the right edge of the chart box.
            xlim(axC,[0.45 nBandsLocal+0.65])
            axC.FontSize = 7.5;
            ylabel(axC,'Relative Power (%)','FontSize',7.5)
        end

        % Draws one band's filtered waveform (patient, plus reference if
        % available) into a supplied axes handle. sigPreprocessed is the
        % patient channel after detrend+notch (see preprocessChannel);
        % refRawCol is the raw reference column, or [] if none loaded.
        function drawBandWaveformAxes(app,axW,sigPreprocessed,refRawCol,bandName)
            br = app.Bands.(bandName);
            nyq = app.fs/2;
            plotted = false;
            hold(axW,'on')
            if br(2) < nyq
                try
                    [bF,aF] = butter(4,br/nyq,'bandpass');
                    if numel(sigPreprocessed) > 3*(max(numel(aF),numel(bF))-1)
                        % Filter the FULL signal first (filtfilt needs enough
                        % length to avoid edge artifacts), then crop only the
                        % plotted portion to a short window for readability.
                        filtSig = filtfilt(bF,aF,sigPreprocessed);
                        winN = min(numel(filtSig), max(round(app.WaveformDisplaySeconds*app.fs),1));
                        filtSigWin = filtSig(1:winN);
                        tW = (0:winN-1)'/app.fs;
                        if ~isempty(refRawCol)
                            refSig = app.filterBandGeneric(refRawCol,bandName);
                            if ~isempty(refSig)
                                winNRef = min(numel(refSig), winN);
                                refSigWin = refSig(1:winNRef);
                                tRef = (0:winNRef-1)'/app.fs;
                                plot(axW,tRef,refSigWin,'Color',[0.25 0.65 0.30],'LineWidth',0.8)
                            end
                        end
                        plot(axW,tW,filtSigWin,'Color',[0.75 0.20 0.20],'LineWidth',0.8)
                        plotted = true;
                    end
                catch
                    plotted = false;
                end
            end
            hold(axW,'off')
            if plotted
                grid(axW,'on'); box(axW,'on')
                axW.GridAlpha = 0.12; axW.FontSize = 7.5;
                xlabel(axW,'Time (s)','FontSize',7.5)
                ylabel(axW,'Amplitude (uV)','FontSize',7.5)
            else
                text(axW,0.5,0.5,'Not resolvable at current fs','Units','normalized', ...
                    'HorizontalAlignment','center','FontSize',7.5,'Color',[0.5 0.5 0.5])
                axW.XTick = []; axW.YTick = [];
            end
            title(axW,bandName,'FontSize',9,'FontWeight','bold')
        end

        %% ================= Clinical Pattern PDF Page =================
        % Draws one full PDF page: a bordered table showing the four
        % clinical-research pattern flags (ADHD-associated Theta/Beta,
        % Dementia-associated slowing, Seizure-associated transients,
        % Depression-associated frontal alpha asymmetry) with their
        % measured metric, numeric value, and status - followed by a
        % prominent disclaimer box. Clinical terms are used ONLY as
        % "research context" labels, never as diagnoses.
        function drawClinicalPatternsPage(app,ax,flags,relPower,fields,transRate,pageNum)
            navy  = app.ReportNavy;
            gray  = app.ReportGray;
            lt    = app.ReportLtGray;
            bdr   = app.ReportBorder;
            red   = [0.75 0.20 0.20];
            grn   = [0.20 0.55 0.30];
            org   = [0.80 0.55 0.10];

            % Lookup helper
            idx = struct();
            for i=1:numel(fields), idx.(fields{i}) = relPower(i); end

            y = app.drawSectionTitle(ax,0.085, ...
                'SECTION 2.5 - SPECTRAL PATTERN ANALYSIS (Research Reference)');

            % --- Table header ---
            colX = [0.025 0.43 0.62 0.77 0.975];
            colHdr = {'Pattern (Research Context)','Metric','Value','Status'};
            rowH = 0.028;
            tblTop = y;
            rectangle(ax,'Position',[colX(1) tblTop colX(end)-colX(1) rowH], ...
                'FaceColor',navy,'EdgeColor',bdr)
            for c = 1:numel(colHdr)
                text(ax,colX(c)+0.01,tblTop+rowH/2,colHdr{c}, ...
                    'FontSize',7.5,'FontWeight','bold','Color','w','VerticalAlignment','middle')
            end
            y = tblTop + rowH;

            % ---- Row builder ----
            function yOut = drawPatternRow(~, yIn, stripe, label, ctxLine, metric, valStr, statusStr, statusColor)
                y = yIn;
                if stripe
                    rectangle(ax,'Position',[colX(1) y colX(end)-colX(1) rowH*1.8], ...
                        'FaceColor',lt,'EdgeColor','none')
                end
                text(ax,colX(1)+0.01,y+rowH*0.45,label, ...
                    'FontSize',7.8,'FontWeight','bold','Color',[0.1 0.1 0.1],'VerticalAlignment','middle')
                text(ax,colX(1)+0.01,y+rowH*1.25,ctxLine, ...
                    'FontSize',6.8,'FontAngle','italic','Color',gray,'VerticalAlignment','middle')
                text(ax,colX(2)+0.01,y+rowH*0.9,metric, ...
                    'FontSize',7.5,'Color',[0.15 0.15 0.15],'VerticalAlignment','middle')
                text(ax,colX(3)+0.01,y+rowH*0.9,valStr, ...
                    'FontSize',7.8,'FontWeight','bold','Color',[0.1 0.1 0.1],'VerticalAlignment','middle')
                % Status badge
                rectangle(ax,'Position',[colX(4)+0.01 y+0.005 colX(5)-colX(4)-0.02 rowH*1.5], ...
                    'FaceColor',statusColor,'EdgeColor','none','Curvature',0.3)
                text(ax,(colX(4)+colX(5))/2,y+rowH*0.9,statusStr, ...
                    'FontSize',7.5,'FontWeight','bold','Color','w', ...
                    'HorizontalAlignment','center','VerticalAlignment','middle')
                yOut = y + rowH*1.8 + 0.004;
            end

            % --- Row 1: Theta/Beta (ADHD-associated) ---
            if isfield(idx,'Theta') && isfield(idx,'Beta') && ...
               ~isnan(idx.Theta) && ~isnan(idx.Beta) && idx.Beta > 0
                tbR = idx.Theta/idx.Beta;
                valStr1 = sprintf('%.2f',tbR);
                thr = app.PatternThresholds.ADHDThetaBetaRatio;
                if tbR >= thr
                    st1 = 'Elevated'; sc1 = red;
                else
                    st1 = 'Normal'; sc1 = grn;
                end
            else
                valStr1 = 'N/A'; st1 = 'N/A'; sc1 = [0.6 0.6 0.6];
            end
            y = drawPatternRow(app, y, false, ...
                'ADHD-associated pattern', ...
                'Research context only: elevated theta/beta ratio.', ...
                'Theta/Beta Ratio', valStr1, st1, sc1);

            % --- Row 2: Dementia-associated slowing ---
            if isfield(idx,'Delta') && isfield(idx,'Theta') && isfield(idx,'Alpha') && ...
               ~isnan(idx.Delta) && ~isnan(idx.Theta) && ~isnan(idx.Alpha)
                slowPct = idx.Delta + idx.Theta;
                alphaPct = idx.Alpha;
                tSlow = app.PatternThresholds.DementiaSlowingRel;
                tAlpha = app.PatternThresholds.DementiaAlphaLowRel;
                if slowPct > tSlow && alphaPct < tAlpha
                    st2 = 'Both elevated'; sc2 = red;
                elseif slowPct > tSlow || alphaPct < tAlpha
                    st2 = 'Partial'; sc2 = org;
                else
                    st2 = 'Normal'; sc2 = grn;
                end
                valStr2 = sprintf('D+T = %.0f%%, A = %.0f%%', slowPct, alphaPct);
            else
                valStr2 = 'N/A'; st2 = 'N/A'; sc2 = [0.6 0.6 0.6];
            end
            y = drawPatternRow(app, y, true, ...
                'Dementia-associated slowing pattern', ...
                'Research context only: slow-wave power and alpha.', ...
                'Delta + Theta / Alpha (%)', valStr2, st2, sc2);

            % --- Row 3: Seizure-associated transients ---
            if ~isnan(transRate)
                thr3 = app.PatternThresholds.SeizureTransientRateFlag;
                valStr3 = sprintf('%.0f/min', transRate);
                if transRate >= thr3
                    st3 = 'Flagged'; sc3 = red;
                else
                    st3 = 'Not flagged'; sc3 = grn;
                end
            else
                valStr3 = 'N/A'; st3 = 'N/A'; sc3 = [0.6 0.6 0.6];
            end
            y = drawPatternRow(app, y, false, ...
                'Seizure-associated transient activity', ...
                'Research context only: transient rate for waveform review.', ...
                'Transient Rate', valStr3, st3, sc3);

            % --- Row 4: Depression-associated frontal alpha asymmetry ---
            [li,ri,pairLabel] = app.findFrontalPair();
            if ~isempty(li) && ~isempty(ri)
                try
                    [~,rLpow,fLf,~,~] = app.bandPowersPSD(li);
                    [~,rRpow,fRf,~,~] = app.bandPowersPSD(ri);
                    aL = rLpow(strcmp(fLf,'Alpha'));
                    aR = rRpow(strcmp(fRf,'Alpha'));
                    if ~isempty(aL) && ~isempty(aR) && ~isnan(aL) && ~isnan(aR)
                        asym = abs(aL-aR);
                        thr4 = app.PatternThresholds.DepressionAsymmetryPct;
                        valStr4 = sprintf('%.1f%% (%s)', asym, pairLabel);
                        if asym > thr4
                            st4 = 'Present'; sc4 = org;
                        else
                            st4 = 'Not prominent'; sc4 = grn;
                        end
                    else
                        valStr4 = 'N/A'; st4 = 'N/A'; sc4 = [0.6 0.6 0.6];
                    end
                catch
                    valStr4 = 'Error'; st4 = 'N/A'; sc4 = [0.6 0.6 0.6];
                end
            else
                valStr4 = 'No suitable channel pair'; st4 = 'N/A'; sc4 = [0.6 0.6 0.6];
            end
            y = drawPatternRow(app, y, true, ...
                'Frontal alpha asymmetry (Depression-associated)', ...
                'Research context only: frontal alpha balance.', ...
                'Alpha L-R Asymmetry', valStr4, st4, sc4);

            % Table outer border
            rectangle(ax,'Position',[colX(1) tblTop colX(end)-colX(1) y-tblTop], ...
                'FaceColor','none','EdgeColor',bdr,'LineWidth',1)
            for c = 2:numel(colX)-1
                line(ax,[colX(c) colX(c)],[tblTop y],'Color',bdr,'LineWidth',0.4)
            end

            y = y + 0.018;

            % --- Prominent disclaimer box ---
            dH = 0.088;
            rectangle(ax,'Position',[0.025 y 0.95 dH], ...
                'FaceColor',[0.99 0.96 0.90],'EdgeColor',[0.85 0.65 0.20],'LineWidth',1.5)
            text(ax,0.045,y+0.018,'IMPORTANT DISCLAIMER', ...
                'FontSize',8.5,'FontWeight','bold','Color',[0.55 0.30 0.05])
            text(ax,0.045,y+0.038, ...
                'The patterns above are SPECTRAL FEATURE OBSERVATIONS only, referenced against published EEG', ...
                'FontSize',7.5,'Color',[0.40 0.25 0.05])
            text(ax,0.045,y+0.054, ...
                'research literature. This system is NOT a clinical diagnostic tool. These results do NOT', ...
                'FontSize',7.5,'Color',[0.40 0.25 0.05])
            text(ax,0.045,y+0.070, ...
                'confirm or exclude any medical condition and must NOT be used for clinical decision-making.', ...
                'FontSize',7.5,'FontWeight','bold','Color',[0.55 0.30 0.05])

            % Footer
            text(ax,0.025,0.978, ...
                'Elevated-X EEG Analysis Tool - Descriptive, non-diagnostic report', ...
                'FontSize',6.5,'FontAngle','italic','Color',[0.55 0.55 0.55])
            text(ax,0.975,0.978,sprintf('Page %d',pageNum), ...
                'FontSize',6.5,'Color',[0.55 0.55 0.55],'HorizontalAlignment','right')
        end

        function reportIdx = getReportChannelIndices(app,maxChannels)
            % Prefer familiar 10-20 electrodes. Bipolar/other EDF montages
            % fall back to their first channels in recorded order.
            nAvailable = min(size(app.EEGData,2),numel(app.ChannelNames));
            preferred = {'Fp1','Fp2','F7','F8','F3','F4','T3','T4','C3','C4','O1','O2'};
            reportIdx = [];
            for k = 1:numel(preferred)
                hit = find(strcmpi(strtrim(app.ChannelNames(1:nAvailable)),preferred{k}),1);
                if ~isempty(hit) && ~ismember(hit,reportIdx)
                    reportIdx(end+1) = hit; %#ok<AGROW>
                end
            end
            for k = 1:nAvailable
                if numel(reportIdx) >= min(maxChannels,nAvailable)
                    break
                end
                if ~ismember(k,reportIdx)
                    reportIdx(end+1) = k; %#ok<AGROW>
                end
            end
        end

        %% ================= Export Analysis Report (PDF): orchestrator =================
        % Validates input, runs all shared per-channel/per-report data
        % preparation ONCE (PSD results, asymmetry, clinical flags, table
        % rows, summary strings), then hands off to one drawing method per
        % PDF section (drawReportCoverPage / drawReportSection1 / ... /
        % drawReportSection4). Each section method creates its own
        % figure(s), draws, exports, and self-closes via onCleanup - this
        % function no longer needs to track a shared list of open figures
        % for cleanup, and a section's figures are freed as soon as that
        % section finishes rather than staying open for the whole export.
        function exportReport(app)
            if isempty(app.EEGData)
                uialert(app.UIFigure,'Upload patient EEG first','Error', 'Icon','error');
                return
            end

            % Processing indicator: shown for the whole export, closed
            % automatically (success, error, or early return) once this
            % function exits, via onCleanup.
            progDlg = uiprogressdlg(app.UIFigure,'Title','Please Wait', ...
                'Message','Generating analysis report...','Indeterminate','on');
            progCleanup = onCleanup(@() close(progDlg)); %#ok<NASGU>

            ts = char(datetime('now','Format','yyyyMMdd_HHmmss'));
            fname = [ts '_EEG_Report.pdf'];

            nAvailable = min(size(app.EEGData,2), length(app.ChannelNames));
            reportIdx = app.getReportChannelIndices(12);
            % Always retain the currently selected channel in the PDF.
            % Appended (not substituted for an existing preferred channel)
            % so no standard 10-20 electrode silently disappears from the
            % report just because the live-view channel wasn't already
            % in the preferred list.
            if ~ismember(app.SelectedChannel,reportIdx)
                reportIdx(end+1) = app.SelectedChannel; %#ok<AGROW>
            end
            nCh = numel(reportIdx);
            selectedReportPos = find(reportIdx == app.SelectedChannel,1);
            fieldsRef = fieldnames(app.Bands);
            nBands = numel(fieldsRef);

            % --- Precompute per-channel results once, reused across pages ---
            chanResults = struct('absPower',{},'relPower',{},'fields',{},'peakAlphaFreq',{}, ...
                'pctBad',{},'patterns',{},'isSlow',{},'slowPct',{},'nTrans',{},'transRate',{});
            for ch = 1:nCh
                try
                    [absP,relP,flds,paf,pb] = app.bandPowersPSD(reportIdx(ch));
                catch
                    % A single channel's PSD failing (e.g. malformed data
                    % for that column) shouldn't abort the whole report -
                    % fall back to all-NaN so this channel just shows as
                    % unavailable everywhere it's used below.
                    absP = nan(1,nBands); relP = nan(1,nBands); flds = fieldsRef; paf = NaN; pb = NaN;
                end
                pats = app.detectPatterns(relP,flds);
                [isSlowC,slowPctC] = app.assessSlowing(relP,flds);
                [nTr,trRate] = app.assessTransients(reportIdx(ch));
                chanResults(ch).absPower = absP; %#ok<AGROW>
                chanResults(ch).relPower = relP;
                chanResults(ch).fields = flds;
                chanResults(ch).peakAlphaFreq = paf;
                chanResults(ch).pctBad = pb;
                chanResults(ch).patterns = pats;
                chanResults(ch).isSlow = isSlowC;
                chanResults(ch).slowPct = slowPctC;
                chanResults(ch).nTrans = nTr;
                chanResults(ch).transRate = trRate;
            end

            % --- Inter-hemispheric asymmetry: real computation, same
            % function the live UI's Analyze panel uses. PSD results per
            % channel are cached (see bandPowersPSD), so this reuses
            % whatever was already computed for the report channels and
            % only computes fresh for any additional hemispheric-pair
            % channels not already in the report set - a bounded, small
            % extra cost, not a full re-analysis. ---
            asymLinesFull = app.assessAsymmetry(fieldsRef);
            asymIsInformational = numel(asymLinesFull)==1 && ...
                (contains(asymLinesFull{1},'No inter-hemispheric') || ...
                 contains(asymLinesFull{1},'Insufficient channel data'));
            if asymIsInformational
                asymFlagCount = 0;
                asymLinesDisplay = asymLinesFull;
            else
                asymFlagCount = numel(asymLinesFull);
                maxAsymLines = 10;
                if asymFlagCount > maxAsymLines
                    asymLinesDisplay = asymLinesFull(1:maxAsymLines);
                    asymLinesDisplay{end+1} = sprintf( ...
                        '...and %d more asymmetry observation(s) - see Multi-Channel View for the full list.', ...
                        asymFlagCount - maxAsymLines);
                else
                    asymLinesDisplay = asymLinesFull;
                end
            end
            if asymIsInformational && contains(asymLinesFull{1},'Insufficient channel data')
                asymSummaryBullet = 'Inter-hemispheric asymmetry: insufficient channel pairing for this montage (see Section 2).';
            elseif asymFlagCount > 0
                asymSummaryBullet = sprintf('%d inter-hemispheric asymmetry observation(s) flagged (see Section 2).', asymFlagCount);
            else
                asymSummaryBullet = 'No inter-hemispheric asymmetry exceeded threshold.';
            end

            % --- Clinical EEG pattern flags for the report (computed on the
            % selected channel, same basis as the live UI, so GUI/PDF/Excel
            % all agree on terminology and values) ---
            selRes = chanResults(selectedReportPos);
            clinFlagsReport = app.computeClinicalPatternFlags(selRes.relPower, selRes.fields, selRes.transRate);
            clinLinesReport = app.formatClinicalPatternFlags(clinFlagsReport);

            % --- Build the all-channel x all-band row data once (used by
            % both the cover-page tally and the Section 1 table) ---
            allRows = cell(nCh*nBands,7);
            r = 0;
            for ch = 1:nCh
                res = chanResults(ch);
                for b = 1:nBands
                    bandName = fieldsRef{b};
                    nrB = app.NormalRangesRel.(bandName);
                    idxB = strcmp(res.fields, bandName);
                    if any(idxB) && ~isnan(res.relPower(idxB))
                        relV = res.relPower(idxB); absV = res.absPower(idxB);
                        relStr = sprintf('%.1f %%',relV);
                        absStr = sprintf('%.2f',absV);
                        if relV < nrB(1)
                            statusStr='Below'; statusColor=[0.80 0.55 0.10];
                        elseif relV > nrB(2)
                            statusStr='Above'; statusColor=[0.75 0.20 0.20];
                        else
                            statusStr='Within'; statusColor=[0.20 0.55 0.30];
                        end
                    else
                        relStr='N/A'; absStr='N/A'; statusStr='N/A'; statusColor=[0.55 0.55 0.55];
                    end
                    refRangeStr = sprintf('%d-%d %%', nrB(1), nrB(2));
                    r = r+1;
                    allRows(r,:) = {app.ChannelNames{reportIdx(ch)}, bandName, relStr, absStr, refRangeStr, statusStr, statusColor};
                end
            end
            statuses = allRows(:,6);
            withinCount = sum(strcmp(statuses,'Within'));
            aboveCount  = sum(strcmp(statuses,'Above'));
            belowCount  = sum(strcmp(statuses,'Below'));
            naCount     = sum(strcmp(statuses,'N/A'));

            % --- Build the condensed Channel Overview rows once (used by
            % both the cover-page state summary and the Section 2 table) ---
            ovRows = cell(nCh,7);
            totalFlagCount = 0;
            for ch = 1:nCh
                res = chanResults(ch);
                validMask = ~isnan(res.relPower);
                if ~any(validMask)
                    stateShort = 'Undetermined';
                else
                    relValid = res.relPower; relValid(~validMask) = -Inf;
                    [~,idxMax] = max(relValid);
                    labelMapShort = containers.Map({'Delta','Theta','Alpha','Beta','Gamma'}, ...
                        {'Delta-dominant','Theta-dominant','Alpha-dominant','Beta-dominant','Gamma-dominant'});
                    stateShort = labelMapShort(res.fields{idxMax});
                end
                if isnan(res.peakAlphaFreq)
                    alphaPkStr = 'N/A';
                else
                    alphaPkStr = sprintf('%.1f Hz', res.peakAlphaFreq);
                end
                if res.pctBad > 5
                    qualStr = sprintf('Warn %.0f%%',res.pctBad);
                else
                    qualStr = 'OK';
                end
                if isnan(res.slowPct)
                    slowStr = 'N/A';
                else
                    if res.isSlow, yn = 'Yes'; else, yn = 'No'; end
                    slowStr = sprintf('%s (%.0f%%)', yn, res.slowPct);
                end
                transStr = sprintf('%.0f', res.transRate);

                tags = cellfun(@(p) app.shortenPatternTag(p), res.patterns, 'UniformOutput', false);
                tags = unique(tags,'stable');
                if numel(tags) > 3
                    flagsStr = [strjoin(tags(1:3), ', ') sprintf(' +%d more', numel(tags)-3)];
                else
                    flagsStr = strjoin(tags, ', ');
                end
                if length(flagsStr) > 34
                    flagsStr = [flagsStr(1:32) '..'];
                end

                if ~(numel(res.patterns)==1 && strcmp(res.patterns{1},'No patterns flagged'))
                    totalFlagCount = totalFlagCount + numel(res.patterns);
                end

                ovRows(ch,:) = {app.ChannelNames{reportIdx(ch)}, stateShort, alphaPkStr, qualStr, slowStr, transStr, flagsStr};
            end

            % --- Dominant-state tally sentence for the cover page ---
            states = ovRows(:,2);
            [uStates,~,ic] = unique(states);
            counts = accumarray(ic,1);
            [~,order] = sort(counts,'descend');
            stateParts = cell(1,numel(order));
            for i = 1:numel(order)
                stateParts{i} = sprintf('%d/%d %s', counts(order(i)), nCh, uStates{order(i)});
            end
            stateSummaryStr = strjoin(stateParts, '; ');

            if naCount > 0
                naPart = sprintf(', %d N/A', naCount);
            else
                naPart = '';
            end
            statusSentence = sprintf('%d Within, %d Above, %d Below%s (of %d channel-band measurements).', ...
                withinCount, aboveCount, belowCount, naPart, numel(statuses));

            % --- Draw every section. Each drawX method returns the
            % updated running page count; if any section throws, the
            % outer catch reports it and whatever was written earlier in
            % the file (prior successful exportgraphics calls) remains
            % on disk, matching the previous single-function behavior. ---
            totalPages = 0;
            try
                totalPages = app.drawReportCoverPage(fname, nCh, nAvailable, fieldsRef, ...
                    stateSummaryStr, statusSentence, totalFlagCount, asymSummaryBullet, ...
                    clinLinesReport, totalPages);
                totalPages = app.drawReportSection1(fname, allRows, totalPages);
                totalPages = app.drawReportSection2(fname, ovRows, nCh, asymLinesDisplay, totalPages);
                totalPages = app.drawReportSection2_5(fname, clinFlagsReport, selRes, totalPages);
                totalPages = app.drawReportSection3(fname, fieldsRef, totalPages);
                totalPages = app.drawReportSection4(fname, chanResults, fieldsRef, reportIdx, nCh, totalPages);

                uialert(app.UIFigure, sprintf('PDF report saved: %s (%d pages, %d channel(s) x %d band(s))', ...
                    fname, totalPages, nCh, nBands), 'Export Complete', 'Icon','success');
            catch ME
                uialert(app.UIFigure, ['Export failed: ' ME.message], 'Export Error', 'Icon','error');
            end

            figure(app.UIFigure) % keep main UI visible
        end

        %% --- PDF Cover Page ---
        % Always the first page written (Append=false creates/overwrites
        % the file); every other section always appends.
        function totalPages = drawReportCoverPage(app, fname, nCh, nAvailable, fieldsRef, ...
                stateSummaryStr, statusSentence, totalFlagCount, asymSummaryBullet, ...
                clinLinesReport, totalPages)
            nBands = numel(fieldsRef);
            [fig,ax] = app.newPdfPage();
            figGuard = onCleanup(@() close(fig)); %#ok<NASGU>
            totalPages = totalPages + 1;

            y = 0.13;
            text(ax,0.025,y,'EEG Band Power Report','FontSize',20,'FontWeight','bold','Color',app.ReportNavy)
            y = y + 0.028;
            text(ax,0.025,y,'Multi-Channel Spectral Analysis Summary','FontSize',11, ...
                'Color',app.ReportGray,'FontAngle','italic')
            y = y + 0.020;
            line(ax,[0.025 0.975],[y y],'Color',app.ReportBorder,'LineWidth',1)
            y = y + 0.035;

            durationSec = size(app.EEGData,1)/app.fs;
            metaRows = {
                'Generated', char(datetime('now','Format','dd-MMM-yyyy HH:mm')), 'Sampling Rate', sprintf('%d Hz', app.fs)
                'Recording Duration', sprintf('%.1f s', durationSec), 'Notch Filter', sprintf('%d Hz', app.NotchFreq)
                'Bands Analyzed', strjoin(fieldsRef', ', '), 'Waveform Channel', app.ChannelNames{app.SelectedChannel}
                'Waveform Bands', strjoin(fieldsRef', ', '), '', ''
            };
            boxTop = y; rh = 0.032; boxH = rh*size(metaRows,1);
            rectangle(ax,'Position',[0.025 boxTop 0.95 boxH],'FaceColor',app.ReportLtGray,'EdgeColor',app.ReportBorder)
            for rIdx = 1:size(metaRows,1)
                ry = boxTop + (rIdx-0.5)*rh;
                text(ax,0.045,ry,metaRows{rIdx,1},'FontSize',8.5,'Color',app.ReportGray,'VerticalAlignment','middle')
                text(ax,0.25,ry,metaRows{rIdx,2},'FontSize',7.8,'FontWeight','bold','Color',[0.1 0.1 0.1],'VerticalAlignment','middle')
                text(ax,0.62,ry,metaRows{rIdx,3},'FontSize',7.8,'Color',app.ReportGray,'VerticalAlignment','middle')
                text(ax,0.79,ry,metaRows{rIdx,4},'FontSize',7.8,'FontWeight','bold','Color',[0.1 0.1 0.1],'VerticalAlignment','middle')
                if rIdx < size(metaRows,1)
                    line(ax,[0.025 0.975],[boxTop+rIdx*rh boxTop+rIdx*rh],'Color',app.ReportBorder,'LineWidth',0.4)
                end
            end
            line(ax,[0.60 0.60],[boxTop boxTop+boxH],'Color',app.ReportBorder,'LineWidth',0.4)
            y = boxTop + boxH + 0.040;

            y = app.drawSectionTitle(ax,y,'OVERALL SUMMARY');
            summaryBullets = {
                sprintf('%d essential channel(s) included from %d available, across %d frequency band(s) (%s).', nCh, nAvailable, nBands, strjoin(fieldsRef',', '))
                sprintf('Dominant spectral state by channel: %s.', stateSummaryStr)
                sprintf('Band-power reference comparison: %s', statusSentence)
                sprintf('%d heuristic pattern observation(s) flagged across the report channels (see Section 2).', totalFlagCount)
                asymSummaryBullet
            };
            y = app.drawBulletList(ax,y,summaryBullets,app.ReportAccent);
            y = y + 0.018;

            y = app.drawSectionTitle(ax,y,'CLINICAL EEG PATTERN FLAGS (research/educational only - not a diagnosis)');
            y = app.drawBulletList(ax,y,clinLinesReport,app.ReportAccent);
            y = y + 0.018;

            y = app.drawSectionTitle(ax,y,'REPORT CONTENTS');
            contentsList = {
                '1. Band Power Summary - relative and absolute power for report channels'
                '2. Channel Overview - state, signal quality, and key observations'
                '2.5. Spectral Pattern Review - research context only, not a diagnosis'
                '3. Band Waveforms - selected-channel time-domain traces'
                '4. Band Power Charts - report-channel comparison against reference ranges'
            };
            y = app.drawBulletList(ax,y,contentsList,app.ReportAccent); %#ok<NASGU>

            app.drawPageFooter(ax,totalPages);
            exportgraphics(fig,fname,'ContentType','vector','Append',false);
        end

        %% --- PDF Section 1: Band Power Summary table (auto-paginated) ---
        function totalPages = drawReportSection1(app, fname, allRows, totalPages)
            colX = [0.025 0.19 0.35 0.55 0.72 0.90 0.975];
            colHdr = {'Channel','Band','Relative %','Absolute Power (uV^2)','Reference Range','Status'};
            rowH = 0.024;
            bottomLimit = 0.93;
            idx = 1; secPageNum = 0;
            while idx <= size(allRows,1)
                secPageNum = secPageNum + 1;
                [fig,ax] = app.newPdfPage();
                figGuard = onCleanup(@() close(fig)); %#ok<NASGU>
                totalPages = totalPages + 1;
                titleStr = 'SECTION 1 - BAND POWER SUMMARY (ESSENTIAL CHANNELS)';
                if secPageNum > 1, titleStr = [titleStr ' (cont.)']; end
                y = app.drawSectionTitle(ax,0.085,titleStr);
                tblTop = y;
                rectangle(ax,'Position',[colX(1) tblTop colX(end)-colX(1) rowH],'FaceColor',app.ReportNavy,'EdgeColor',app.ReportBorder)
                for c = 1:numel(colHdr)
                    text(ax,colX(c)+0.008,tblTop+rowH/2,colHdr{c},'FontSize',7.2,'FontWeight','bold','Color','w','VerticalAlignment','middle')
                end
                curY = tblTop + rowH;
                stripe = 0;
                while idx <= size(allRows,1) && curY+rowH <= bottomLimit
                    row = allRows(idx,:);
                    if mod(stripe,2)==1
                        rectangle(ax,'Position',[colX(1) curY colX(end)-colX(1) rowH],'FaceColor',app.ReportLtGray,'EdgeColor','none')
                    end
                    text(ax,colX(1)+0.008,curY+rowH/2,row{1},'FontSize',7.2,'VerticalAlignment','middle')
                    text(ax,colX(2)+0.008,curY+rowH/2,row{2},'FontSize',7.2,'VerticalAlignment','middle')
                    text(ax,colX(3)+0.008,curY+rowH/2,row{3},'FontSize',7.2,'VerticalAlignment','middle')
                    text(ax,colX(4)+0.008,curY+rowH/2,row{4},'FontSize',7.2,'VerticalAlignment','middle')
                    text(ax,colX(5)+0.008,curY+rowH/2,row{5},'FontSize',7.2,'VerticalAlignment','middle')
                    rectangle(ax,'Position',[colX(6)+0.01 curY+0.003 colX(7)-colX(6)-0.02 rowH-0.006], ...
                        'FaceColor',row{7},'EdgeColor','none','Curvature',0.3)
                    text(ax,(colX(6)+colX(7))/2,curY+rowH/2,row{6},'FontSize',6.6,'FontWeight','bold', ...
                        'Color','w','HorizontalAlignment','center','VerticalAlignment','middle')
                    curY = curY + rowH;
                    idx = idx + 1;
                    stripe = stripe + 1;
                end
                rectangle(ax,'Position',[colX(1) tblTop colX(end)-colX(1) curY-tblTop],'FaceColor','none','EdgeColor',app.ReportBorder,'LineWidth',1)
                for c = 2:numel(colX)-1
                    line(ax,[colX(c) colX(c)],[tblTop curY],'Color',app.ReportBorder,'LineWidth',0.4)
                end
                if idx > size(allRows,1)
                    text(ax,0.025,curY+0.02,'Method: Welch PSD estimation. Reference ranges illustrative, not clinically validated.', ...
                        'FontSize',7,'FontAngle','italic','Color',[0.5 0.5 0.5])
                end
                app.drawPageFooter(ax,totalPages);
                exportgraphics(fig,fname,'ContentType','vector','Append',true);
            end
        end

        %% --- PDF Section 2: Channel Overview table + Inter-Hemispheric
        %% Asymmetry (fitted below the last table page, or its own page
        %% if it doesn't fit) ---
        function totalPages = drawReportSection2(app, fname, ovRows, nCh, asymLinesDisplay, totalPages)
            colX2 = [0.025 0.145 0.345 0.455 0.565 0.675 0.785 0.975];
            colHdr2 = {'Channel','Dominant State','Alpha Peak','Quality','Slowing','Trans./min','Key Observations'};
            rowH2 = 0.036;
            ovBottomLimit = 0.80; % leave room to try to fit asymmetry below the table
            idx2 = 1; secPageNum2 = 0;
            while idx2 <= nCh
                secPageNum2 = secPageNum2 + 1;
                [fig,ax] = app.newPdfPage();
                figGuard = onCleanup(@() close(fig)); %#ok<NASGU>
                totalPages = totalPages + 1;
                titleStr2 = 'SECTION 2 - CHANNEL OVERVIEW (ESSENTIAL CHANNELS)';
                if secPageNum2 > 1, titleStr2 = [titleStr2 ' (cont.)']; end
                y = app.drawSectionTitle(ax,0.085,titleStr2);
                tblTop2 = y;
                rectangle(ax,'Position',[colX2(1) tblTop2 colX2(end)-colX2(1) rowH2],'FaceColor',app.ReportNavy,'EdgeColor',app.ReportBorder)
                for c = 1:numel(colHdr2)
                    text(ax,colX2(c)+0.008,tblTop2+rowH2/2,colHdr2{c},'FontSize',7.2,'FontWeight','bold','Color','w','VerticalAlignment','middle')
                end
                curY2 = tblTop2 + rowH2;
                stripe2 = 0;
                while idx2 <= nCh && curY2+rowH2 <= ovBottomLimit
                    row2 = ovRows(idx2,:);
                    if mod(stripe2,2)==1
                        rectangle(ax,'Position',[colX2(1) curY2 colX2(end)-colX2(1) rowH2],'FaceColor',app.ReportLtGray,'EdgeColor','none')
                    end
                    for c = 1:numel(colHdr2)
                        text(ax,colX2(c)+0.008,curY2+rowH2/2,row2{c},'FontSize',6.5,'VerticalAlignment','middle')
                    end
                    curY2 = curY2 + rowH2;
                    idx2 = idx2 + 1;
                    stripe2 = stripe2 + 1;
                end
                rectangle(ax,'Position',[colX2(1) tblTop2 colX2(end)-colX2(1) curY2-tblTop2],'FaceColor','none','EdgeColor',app.ReportBorder,'LineWidth',1)
                for c = 2:numel(colX2)-1
                    line(ax,[colX2(c) colX2(c)],[tblTop2 curY2],'Color',app.ReportBorder,'LineWidth',0.4)
                end

                isLastChannelPage = idx2 > nCh;
                fitsAsymHere = isLastChannelPage && (curY2 + 0.14 <= 0.90);
                if fitsAsymHere
                    y2 = app.drawSectionTitle(ax,curY2+0.025,'INTER-HEMISPHERIC ASYMMETRY');
                    app.drawBulletList(ax,y2,asymLinesDisplay,app.ReportAccent);
                end
                app.drawPageFooter(ax,totalPages);
                exportgraphics(fig,fname,'ContentType','vector','Append',true);

                if isLastChannelPage && ~fitsAsymHere
                    % Asymmetry didn't fit under the last table page - give
                    % it its own page. Explicitly clear the previous page's
                    % figGuard first so that page closes now rather than
                    % staying open until this one also finishes.
                    clear figGuard
                    [fig,ax] = app.newPdfPage();
                    figGuard = onCleanup(@() close(fig)); %#ok<NASGU>
                    totalPages = totalPages + 1;
                    y3 = app.drawSectionTitle(ax,0.085,'SECTION 2 (cont.) - INTER-HEMISPHERIC ASYMMETRY');
                    app.drawBulletList(ax,y3,asymLinesDisplay,app.ReportAccent);
                    app.drawPageFooter(ax,totalPages);
                    exportgraphics(fig,fname,'ContentType','vector','Append',true);
                end
            end
        end

        %% --- PDF Section 2.5: Clinical Pattern Analysis (single page) ---
        function totalPages = drawReportSection2_5(app, fname, clinFlagsReport, selRes, totalPages)
            [fig,ax] = app.newPdfPage();
            figGuard = onCleanup(@() close(fig)); %#ok<NASGU>
            totalPages = totalPages + 1;
            app.drawClinicalPatternsPage(ax, clinFlagsReport, ...
                selRes.relPower, selRes.fields, selRes.transRate, totalPages);
            exportgraphics(fig,fname,'ContentType','vector','Append',true);
        end

        %% --- PDF Section 3: all-band waveforms (2 per page, stacked) ---
        function totalPages = drawReportSection3(app, fname, fieldsRef, totalPages)
            % If the waveform pages fail (e.g. signal too short), pages
            % already written by earlier sections remain saved on disk -
            % this section's own failure is caught and swallowed here,
            % matching the prior (pre-refactor) behavior exactly.
            try
                rawCh = app.EEGData(:,app.SelectedChannel);
                rawCh = rawCh(1:min(numel(rawCh),round(app.LiveFilterSeconds*app.fs)));
                sigCh = app.preprocessSignal(double(rawCh));
                refRawCol = [];
                if ~isempty(app.GreenLine)
                    gCh = min(app.SelectedChannel, size(app.GreenLine,2));
                    refRawCol = app.GreenLine(:,gCh);
                end

                legendStr = 'Patient EEG (red)';
                if ~isempty(refRawCol)
                    legendStr = [legendStr ' vs. Normal EEG (green)'];
                end

                stackPos = {[0.09 0.55 0.85 0.36],[0.09 0.10 0.85 0.36]}; % top, bottom
                wavePageNum = 0;
                for pStart = 1:2:numel(fieldsRef)
                    wavePageNum = wavePageNum + 1;
                    grp = pStart:min(pStart+1,numel(fieldsRef));

                    waveFig = figure('Visible','off','Position',[100 100 700 780],'Color','w');
                    figGuard = onCleanup(@() close(waveFig)); %#ok<NASGU>
                    totalPages = totalPages + 1;

                    for gi = 1:numel(grp)
                        axW = axes(waveFig,'Position',stackPos{gi});
                        app.drawBandWaveformAxes(axW,sigCh,refRawCol,fieldsRef{grp(gi)});
                    end

                    titleStr3 = sprintf('SECTION 3 - All-Band Waveforms - %s', app.ChannelNames{app.SelectedChannel});
                    if wavePageNum > 1, titleStr3 = [titleStr3 ' (cont.)']; end

                    annotation(waveFig,'rectangle',[0 0.945 1 0.055],'FaceColor',app.ReportNavy,'EdgeColor','none')
                    annotation(waveFig,'textbox',[0.02 0.945 0.7 0.05],'String','Elevated-X EEG Analysis Tool', ...
                        'Color','w','FontSize',12,'FontWeight','bold','EdgeColor','none','VerticalAlignment','middle')
                    annotation(waveFig,'textbox',[0.02 0.895 0.9 0.04],'String',titleStr3, ...
                        'Color',app.ReportNavy,'FontSize',9.5,'FontWeight','bold','EdgeColor','none')
                    annotation(waveFig,'textbox',[0.85 0.005 0.13 0.025],'String',sprintf('Page %d',totalPages), ...
                        'FontSize',7,'EdgeColor','none','HorizontalAlignment','right','Color',app.ReportGray)
                    annotation(waveFig,'textbox',[0.02 0.005 0.8 0.025], ...
                        'String',[legendStr, '. Band-filtered time-domain traces. Descriptive visualization only.'], ...
                        'FontAngle','italic','FontSize',7.3,'EdgeColor','none','Color',app.ReportGray)

                    exportgraphics(waveFig,fname,'ContentType','vector','Append',true);
                end
            catch
                % If the waveform pages fail (e.g. signal too short),
                % earlier pages are already saved.
            end
        end

        %% --- PDF Section 4: band-power charts, 4 channels/page ---
        function totalPages = drawReportSection4(app, fname, chanResults, fieldsRef, reportIdx, nCh, totalPages)
            quadPos = {[0.09 0.55 0.39 0.32],[0.57 0.55 0.39 0.32], ...
                       [0.09 0.14 0.39 0.32],[0.57 0.14 0.39 0.32]};
            chIdx = 1; chartPageNum = 0;
            while chIdx <= nCh
                chartPageNum = chartPageNum + 1;
                grp = chIdx:min(chIdx+3,nCh);
                chartFig = figure('Visible','off','Position',[100 100 700 780],'Color','w');
                figGuard = onCleanup(@() close(chartFig)); %#ok<NASGU>
                totalPages = totalPages + 1;
                for qi = 1:numel(grp)
                    ch = grp(qi);
                    axQ = axes(chartFig,'Position',quadPos{qi});
                    app.drawChannelBarAxes(axQ,chanResults(ch),fieldsRef);
                    title(axQ,app.ChannelNames{reportIdx(ch)},'FontSize',9,'FontWeight','bold')
                end
                titleStr4 = 'SECTION 4 - Band Power Charts by Channel';
                if chartPageNum > 1
                    titleStr4 = [titleStr4 ' (cont.)'];
                end
                annotation(chartFig,'rectangle',[0 0.945 1 0.055],'FaceColor',app.ReportNavy,'EdgeColor','none')
                annotation(chartFig,'textbox',[0.02 0.945 0.7 0.05],'String','Elevated-X EEG Analysis Tool', ...
                    'Color','w','FontSize',12,'FontWeight','bold','EdgeColor','none','VerticalAlignment','middle')
                annotation(chartFig,'textbox',[0.02 0.895 0.9 0.04],'String',titleStr4, ...
                    'Color',app.ReportNavy,'FontSize',9.5,'FontWeight','bold','EdgeColor','none')
                annotation(chartFig,'textbox',[0.85 0.005 0.13 0.025],'String',sprintf('Page %d',totalPages), ...
                    'FontSize',7,'EdgeColor','none','HorizontalAlignment','right','Color',app.ReportGray)
                annotation(chartFig,'textbox',[0.02 0.005 0.8 0.025], ...
                    'String','Shaded green band = illustrative reference range (not clinical). Descriptive only.', ...
                    'FontAngle','italic','FontSize',7.3,'EdgeColor','none','Color',app.ReportGray)
                exportgraphics(chartFig,fname,'ContentType','vector','Append',true);
                chIdx = chIdx + 4;
            end
        end

        %% --- Simple character-count based text wrapper (no dependency on
        %% textwrap/graphics-handle context - splits on word boundaries) ---
        function linesOut = wrapTextLocal(~, str, maxChars)
            words = strsplit(str, ' ');
            linesOut = {};
            cur = '';
            for i = 1:numel(words)
                w = words{i};
                if isempty(cur)
                    cand = w;
                else
                    cand = [cur ' ' w];
                end
                if length(cand) > maxChars && ~isempty(cur)
                    linesOut{end+1} = cur; %#ok<AGROW>
                    cur = w;
                else
                    cur = cand;
                end
            end
            if ~isempty(cur)
                linesOut{end+1} = cur;
            end
            if isempty(linesOut)
                linesOut = {''};
            end
        end

        %% --- Export Data Sheet ---
        % Writes a structured .xlsx workbook: a title/info block, then a
        % clean per-channel/per-band data table (readable headers, rounded
        % values), then a short note. This works identically on every
        % platform. On Windows with Microsoft Excel installed, an
        % additional pass (styleExcelSheet) adds visual polish - bold
        % colored header, borders, zebra striping, column auto-fit, a
        % frozen header row, and color-coded Status cells. That pass is
        % best-effort only: if Excel/ActiveX isn't available, it's
        % skipped silently and the plain structured file is still saved.
        function exportExcelData(app)
            if isempty(app.EEGData)
                uialert(app.UIFigure,'Upload patient EEG first','Error', 'Icon','error');
                return
            end

            progDlg = uiprogressdlg(app.UIFigure,'Title','Please Wait', ...
                'Message','Generating data sheet...','Indeterminate','on');
            progCleanup = onCleanup(@() close(progDlg)); %#ok<NASGU>

            nCh = min(size(app.EEGData,2), length(app.ChannelNames));
            fieldsRef = fieldnames(app.Bands);
            nBands = numel(fieldsRef);

            colHdr = {'Channel','Band','Relative Power (%)','Absolute Power (uV2)', ...
                'Ref Range Low (%)','Ref Range High (%)','Status','Data Quality (% outliers)'};
            nCols = numel(colHdr);

            dataRows = {};
            r = 0;
            for ch = 1:nCh
                try
                    [absPower,relPower,fields,~,pctBad] = app.bandPowersPSD(ch);
                catch
                    % A single channel's PSD failing shouldn't abort the
                    % whole export - it simply contributes no rows to the
                    % data sheet, and export continues for the rest.
                    continue
                end
                for b = 1:nBands
                    idxB = strcmp(fields, fieldsRef{b});
                    if ~any(idxB), continue; end
                    val = relPower(idxB);
                    absVal = absPower(idxB);
                    nr = app.NormalRangesRel.(fieldsRef{b});
                    if isnan(val)
                        status = 'N/A';
                        relOut = 'N/A'; absOut = 'N/A';
                    else
                        if val < nr(1)
                            status = 'Below';
                        elseif val > nr(2)
                            status = 'Above';
                        else
                            status = 'Within';
                        end
                        relOut = round(val,1);
                        absOut = round(absVal,2);
                    end
                    r = r+1;
                    dataRows(r,:) = {app.ChannelNames{ch}, fieldsRef{b}, relOut, absOut, ...
                        nr(1), nr(2), status, round(pctBad,1)}; %#ok<AGROW>
                end
            end

            if r == 0
                uialert(app.UIFigure,'No data available to export','Error', 'Icon','error');
                return
            end

            ts = char(datetime('now','Format','yyyyMMdd_HHmmss'));
            fname = [ts '_EEG_BandPower_Data.xlsx'];
            sheetName = 'Band Power Data';

            titleBlock = {
                'EEG Band Power - Data Export'
                sprintf('Generated: %s', char(datetime('now','Format','dd-MMM-yyyy HH:mm')))
                sprintf('Channels: %d   |   Sampling Rate: %d Hz   |   Notch Filter: %d Hz', nCh, app.fs, app.NotchFreq)
                ''
            };
            headerRow = numel(titleBlock) + 1;
            firstDataRow = headerRow + 1;
            lastDataRow = headerRow + r;

            % --- Brain State + Clinical EEG Pattern Flags block (selected
            % channel, same basis/terminology as the live UI and PDF) ---
            selCh = min(app.SelectedChannel,nCh);
            try
                [~,relSel,fieldsSel,~,~] = app.bandPowersPSD(selCh);
                validMaskSel = ~isnan(relSel);
                if any(validMaskSel)
                    relValidSel = relSel; relValidSel(~validMaskSel) = -Inf;
                    [~,idxMaxSel] = max(relValidSel);
                    stateLabelMap = containers.Map({'Delta','Theta','Alpha','Beta','Gamma'}, ...
                        {'Delta-dominant','Theta-dominant','Alpha-dominant','Beta-dominant','Gamma-dominant'});
                    brainStateStr = stateLabelMap(fieldsSel{idxMaxSel});
                else
                    brainStateStr = 'Undetermined';
                end
                [~,transRateSel] = app.assessTransients(selCh);
                clinFlagsXl = app.computeClinicalPatternFlags(relSel,fieldsSel,transRateSel);
                clinLinesXl = app.formatClinicalPatternFlags(clinFlagsXl);
            catch
                brainStateStr = 'Undetermined';
                clinLinesXl = {'Seizure-like activity: Insufficient evidence'; ...
                               'Dementia-associated slowing pattern: Insufficient evidence'; ...
                               'ADHD-associated Theta/Beta pattern: Insufficient evidence'; ...
                               'Frontal alpha asymmetry: Insufficient evidence'};
            end

            summaryBlock = [
                {sprintf('Brain State (Channel %s): %s', app.ChannelNames{selCh}, brainStateStr)}
                {''}
                {'CLINICAL EEG PATTERN FLAGS (research/educational only - not a diagnosis)'}
                clinLinesXl(:)
                {''}
                {'Note: reference ranges are illustrative benchmarks, not clinically validated.'}
                {'Disclaimer: findings are descriptive/heuristic EEG patterns only and are not a clinical diagnosis.'}
            ];

            try
                writecell(titleBlock, fname, 'Sheet', sheetName, 'Range', 'A1');
                writecell(colHdr, fname, 'Sheet', sheetName, 'Range', sprintf('A%d', headerRow));
                writecell(dataRows, fname, 'Sheet', sheetName, 'Range', sprintf('A%d', firstDataRow));
                writecell(summaryBlock, fname, 'Sheet', sheetName, 'Range', sprintf('A%d', lastDataRow+2));
            catch ME
                uialert(app.UIFigure, ['Export failed: ' ME.message], 'Export Error', 'Icon','error');
                return
            end

            app.styleExcelSheet(fname, sheetName, headerRow, firstDataRow, lastDataRow, nCols);

            uialert(app.UIFigure, ['Data sheet saved: ' fname], 'Export Complete', 'Icon','success');
        end

        %% --- Optional Excel visual polish (Windows + Microsoft Excel only) ---
        % Applied as a best-effort second pass after the plain data has
        % already been written and saved successfully. Any failure here
        % (wrong platform, Excel not installed, ActiveX unavailable) is
        % caught and ignored - the underlying data file is unaffected.
        function styleExcelSheet(app,fname,sheetName,headerRow,firstDataRow,lastDataRow,nCols)
            if ~ispc
                return
            end
            excelApp = [];
            try
                excelApp = actxserver('Excel.Application');
                excelApp.Visible = false;
                fullPath = fullfile(pwd, fname);
                wb = excelApp.Workbooks.Open(fullPath);
                sh = wb.Sheets.Item(sheetName);
                lastColLetter = char('A' + nCols - 1);

                % --- Title + info rows ---
                titleRange = sh.Range(sprintf('A1:%s1', lastColLetter));
                titleRange.Merge;
                titleRange.Font.Bold = true;
                titleRange.Font.Size = 14;
                titleRange.Font.Color = app.rgbToExcelColor(app.ReportNavy);

                for rr = 2:3
                    infoRange = sh.Range(sprintf('A%d:%s%d', rr, lastColLetter, rr));
                    infoRange.Merge;
                    infoRange.Font.Italic = true;
                    infoRange.Font.Size = 9;
                    infoRange.Font.Color = app.rgbToExcelColor(app.ReportGray);
                end

                % --- Header row ---
                hdrRange = sh.Range(sprintf('A%d:%s%d', headerRow, lastColLetter, headerRow));
                hdrRange.Font.Bold = true;
                hdrRange.Font.Color = app.rgbToExcelColor([1 1 1]);
                hdrRange.Interior.Color = app.rgbToExcelColor(app.ReportNavy);
                hdrRange.HorizontalAlignment = -4108; % xlCenter
                hdrRange.VerticalAlignment = -4108;   % xlCenter
                hdrRange.WrapText = true;
                hdrRange.RowHeight = 32;

                % --- Freeze panes just below the header row ---
                sh.Activate();
                excelApp.ActiveWindow.SplitRow = headerRow;
                excelApp.ActiveWindow.FreezePanes = true;

                % --- Table borders ---
                tableRange = sh.Range(sprintf('A%d:%s%d', headerRow, lastColLetter, lastDataRow));
                tableRange.Borders.LineStyle = 1;
                tableRange.Borders.Weight = 2;

                % --- Zebra striping on data rows ---
                for rr = firstDataRow:lastDataRow
                    if mod(rr-firstDataRow,2)==1
                        rowRange = sh.Range(sprintf('A%d:%s%d', rr, lastColLetter, rr));
                        rowRange.Interior.Color = app.rgbToExcelColor(app.ReportLtGray);
                    end
                end

                % --- Number formats (columns: 3=RelPower, 4=AbsPower, 8=Quality) ---
                relCol = char('A'+2); absCol = char('A'+3); qualCol = char('A'+7);
                sh.Range(sprintf('%s%d:%s%d',relCol,firstDataRow,relCol,lastDataRow)).NumberFormat = '0.0"%"';
                sh.Range(sprintf('%s%d:%s%d',absCol,firstDataRow,absCol,lastDataRow)).NumberFormat = '0.00';
                sh.Range(sprintf('%s%d:%s%d',qualCol,firstDataRow,qualCol,lastDataRow)).NumberFormat = '0.0"%"';

                % --- Status column color-coding (column 7) ---
                statusCol = char('A'+6);
                for rr = firstDataRow:lastDataRow
                    cell = sh.Range(sprintf('%s%d',statusCol,rr));
                    val = cell.Value;
                    cell.Font.Bold = true;
                    switch val
                        case 'Within'
                            cell.Font.Color = app.rgbToExcelColor([0.20 0.55 0.30]);
                        case 'Above'
                            cell.Font.Color = app.rgbToExcelColor([0.75 0.20 0.20]);
                        case 'Below'
                            cell.Font.Color = app.rgbToExcelColor([0.80 0.55 0.10]);
                        otherwise
                            cell.Font.Bold = false;
                            cell.Font.Color = app.rgbToExcelColor([0.55 0.55 0.55]);
                    end
                end

                % Wide, readable worksheet layout. Fixed minimum widths
                % prevent long headers/statuses being squeezed into narrow
                % columns after Excel's AutoFit pass.
                sh.Columns.AutoFit();
                sh.Range('A:A').ColumnWidth = 19; % Channel
                sh.Range('B:B').ColumnWidth = 14; % Band
                sh.Range('C:C').ColumnWidth = 21; % Relative power
                sh.Range('D:D').ColumnWidth = 23; % Absolute power
                sh.Range('E:F').ColumnWidth = 19; % Reference range
                sh.Range('G:G').ColumnWidth = 16; % Status
                sh.Range('H:H').ColumnWidth = 27; % Signal quality
                tableRange.VerticalAlignment = -4108; % xlCenter
                tableRange.WrapText = true;
                tableRange.EntireRow.AutoFit();

                % Print the full analysis table across one landscape page
                % width, with margins and scaling suited to wide reports.
                sh.PageSetup.Orientation = 2; % xlLandscape
                sh.PageSetup.Zoom = false;
                sh.PageSetup.FitToPagesWide = 1;
                sh.PageSetup.FitToPagesTall = false;
                sh.PageSetup.CenterHorizontally = true;
                sh.PageSetup.LeftMargin = 0.25;
                sh.PageSetup.RightMargin = 0.25;
                sh.PageSetup.TopMargin = 0.4;
                sh.PageSetup.BottomMargin = 0.4;

                wb.Save();
                wb.Close(false);
                excelApp.Quit();
                delete(excelApp);
            catch
                if ~isempty(excelApp)
                    try
                        excelApp.Quit();
                        delete(excelApp);
                    catch
                    end
                end
                % Styling unavailable - the plain data file is already saved.
            end
        end

        % Converts a [R G B] triplet (0-1 range) to the BGR-packed integer
        % Excel/VBA expects for Font.Color / Interior.Color properties.
        function colorVal = rgbToExcelColor(~,rgbTriplet)
            c = round(rgbTriplet*255);
            colorVal = c(1) + c(2)*256 + c(3)*65536;
        end

        %% --- Button Callbacks ---
        function UploadButtonPushed(app,~)
            [file,path] = uigetfile({'*.mat;*.csv;*.edf'});
            if isequal(file,0), return; end
            app.loadEEG(fullfile(path,file));
        end

        function LoadGreenButtonPushed(app,~)
            [file,path] = uigetfile({'*.mat;*.csv;*.edf'});
            if isequal(file,0), return; end

            progDlg = uiprogressdlg(app.UIFigure,'Title','Please Wait', ...
                'Message','Loading normal EEG...','Indeterminate','on');
            progCleanup = onCleanup(@() close(progDlg)); %#ok<NASGU>

            try
                [data,~,~] = app.readAnyEEGFile(fullfile(path,file),false);
            catch ME
                uialert(app.UIFigure, ['Could not read normal EEG file: ' ME.message], 'Error', 'Icon','error');
                return
            end
            if isempty(data) || ~isnumeric(data)
                uialert(app.UIFigure,'Normal EEG file is empty or non-numeric','Error', 'Icon','error');
                return
            end
            app.GreenLine = data;
            uialert(app.UIFigure,'Normal EEG loaded','Success', 'Icon','success');
            figure(app.UIFigure)
        end

        function AnalyzeButtonPushed(app,~)
            if isempty(app.EEGData)
                uialert(app.UIFigure,'Upload patient EEG first','Error', 'Icon','error'); return
            end
            app.analyzeEEG();
        end

        function ExportButtonPushed(app,~)
            app.exportReport();
        end

        function MultiChannelButtonPushed(app,~)
            app.showMultiChannelSummary();
        end

        function ExportExcelButtonPushed(app,~)
            app.exportExcelData();
        end

        function BandDropDownChanged(app,~)
            app.SelectedBand = string(app.BandDropDown.Value);
        end

        function ChannelDropDownChanged(app,~)
            % Selecting a channel changes only the single-channel live
            % display/analysis target. Multi-channel summaries and both
            % exports intentionally continue to include every channel.
            if isempty(app.EEGData) || isempty(app.ChannelNames)
                return
            end

            selectedName = app.ChannelDropDown.Value;
            selectedIndex = find(strcmp(app.ChannelNames, selectedName), 1, 'first');
            if isempty(selectedIndex)
                return
            end

            app.SelectedChannel = selectedIndex;
            app.plotRaw();
        end
    end

    methods (Access = private)
        %% --- UI Components (unchanged layout) ---
        function createComponents(app)
            app.UIFigure = uifigure('Name','EEG Clinical Analysis','Position',[100 100 1100 680]);
            grid = uigridlayout(app.UIFigure,[3 1]);
            grid.RowHeight = {'1x',165,70};

            % EEG Plot
            app.UIAxes = uiaxes(grid);
            title(app.UIAxes,'EEG Signal');

            % Analysis Results Panel (side-by-side)
            rp = uipanel(grid,'Title','Analysis Results');
            rpL = uigridlayout(rp,[1 2]);
            rpL.ColumnWidth = {'1x','1x'};

            commentPanel = uipanel(rpL,'Title','Band Power Summary');
            commentPanelL = uigridlayout(commentPanel,[1 1]);
            commentPanelL.Padding = [0 0 0 0];
            app.CommentLabel = uitextarea(commentPanelL,'Editable','off');

            statePanel = uipanel(rpL,'Title','Brain State & Observations');
            statePanelL = uigridlayout(statePanel,[1 1]);
            statePanelL.Padding = [0 0 0 0];
            app.StateLabel = uitextarea(statePanelL,'Editable','off');

            % Controls Panel
            cp = uipanel(grid,'Title','Controls');
            % One horizontal row: the channel selector is deliberately
            % placed between the data-sheet export and band selector.
            cpL = uigridlayout(cp,[1 8]);
            app.UploadButton = uibutton(cpL,'Text','Upload Patient EEG','ButtonPushedFcn',@(btn,event)UploadButtonPushed(app));
            app.LoadGreenButton = uibutton(cpL,'Text','Load Normal EEG','ButtonPushedFcn',@(btn,event)LoadGreenButtonPushed(app));
            app.AnalyzeButton = uibutton(cpL,'Text','Analyze','ButtonPushedFcn',@(btn,event)AnalyzeButtonPushed(app));
            app.MultiChannelButton = uibutton(cpL,'Text','Multi-Channel View','ButtonPushedFcn',@(btn,event)MultiChannelButtonPushed(app));
            app.ExportButton = uibutton(cpL,'Text','Export Analysis Report','ButtonPushedFcn',@(btn,event)ExportButtonPushed(app));
            app.ExportExcelButton = uibutton(cpL,'Text','Export Data Sheet','ButtonPushedFcn',@(btn,event)ExportExcelButtonPushed(app));
            app.ChannelDropDown = uidropdown(cpL,'Items',{'Load EEG first'},'Value','Load EEG first', ...
                'Enable','off','Tooltip','Channel','ValueChangedFcn',@(dd,event)ChannelDropDownChanged(app));
            app.BandDropDown = uidropdown(cpL,'Items',{'Delta','Theta','Alpha','Beta','Gamma'},'Value','Theta','ValueChangedFcn',@(dd,event)BandDropDownChanged(app));
        end
    end

    methods (Access = public)
        function [data,fsOut] = validateCsvAutoDetection(app,file)
            % Public test hook: exercises the exact CSV importer used by the
            % app without showing the normal file-selection dialog.
            [data,fsOut] = app.readCsvWithAutoSamplingRate(file,true);
        end

        function app = EEGAppBands
            createComponents(app)
        end
    end

    % ================= Shared, independently-validated algorithm =================
    % These are Static methods (no app instance required) so the EXACT
    % same code the app uses can also be called directly from outside -
    % e.g. by runEEGValidation.m via EEGAppBands.computeBandPowerPSD(...).
    % This keeps the app and its validation script using one single
    % implementation instead of two copies that could drift apart, while
    % avoiding the need for separate standalone .m files.
    methods (Static)
        function sig = preprocessEEGSignal(sigRaw, fs, notchFreq)
            %PREPROCESSEEGSIGNAL Detrend and notch-filter a raw EEG signal.
            %   Removes linear drift (detrend) and, if notchFreq is within
            %   (0, fs/2), removes power-line interference using a narrow
            %   IIR notch filter (Q~35), applied zero-phase via filtfilt.
            sig = detrend(double(sigRaw(:)),'linear');
            nyq = fs/2;
            if notchFreq > 0 && notchFreq < nyq
                wo = notchFreq/nyq;
                bw = wo/35; % ~narrow notch, Q~35
                try
                    [bn,an] = iirnotch(wo,bw);
                    sig = filtfilt(bn,an,sig);
                catch
                    % If the notch filter can't be designed (e.g. extremely
                    % short signal), just skip it rather than failing.
                end
            end
        end

        function [absPower,relPower,fields,peakAlphaFreq,pctBad] = computeBandPowerPSD(sigPreprocessed, fs, bands, broadBand, artifactSD)
            %COMPUTEBANDPOWERPSD Welch-PSD-based absolute/relative EEG band power.
            %   This is the CORE analysis algorithm the app uses. It is a
            %   Static method (rather than inline instance code) so the
            %   exact same code path can be independently validated by
            %   runEEGValidation.m against synthetic signals with known
            %   ground truth - see that script for methodology.
            %
            %   Inputs:
            %     sigPreprocessed - signal AFTER preprocessEEGSignal
            %     fs              - sampling rate (Hz)
            %     bands           - struct, fields=band names, values=[lowHz highHz]
            %     broadBand       - [lowHz highHz], total-power denominator
            %     artifactSD      - SD threshold for the quality check
            %
            %   Outputs:
            %     absPower      - 1xN absolute band power (uV^2)
            %     relPower      - 1xN relative band power (%)
            %     fields        - Nx1 cell array of band names
            %     peakAlphaFreq - frequency (Hz) of max PSD in the Alpha band
            %     pctBad        - % of samples beyond artifactSD*std (quality metric)
            sig = double(sigPreprocessed(:));

            mu = mean(sig); sd = std(sig);
            pctBad = 100 * sum(abs(sig-mu) > artifactSD*sd) / numel(sig);

            n = numel(sig);
            winLen = min(n, round(4*fs));
            if winLen < round(2*fs)
                winLen = n;
            end
            winLen = max(winLen,8);

            [pxx,f] = pwelch(sig, hamming(winLen), round(winLen/2), max(winLen,1024), fs);

            bbMask = f>=broadBand(1) & f<=broadBand(2);
            totalPower = trapz(f(bbMask), pxx(bbMask));

            fields = fieldnames(bands);
            absPower = nan(1,numel(fields));
            relPower = nan(1,numel(fields));
            nyq = fs/2;
            for i = 1:numel(fields)
                br = bands.(fields{i});
                if br(2) >= nyq
                    continue % band not resolvable at this sample rate
                end
                m = f>=br(1) & f<=br(2);
                if ~any(m), continue; end
                absPower(i) = trapz(f(m), pxx(m));
                if totalPower > 0
                    relPower(i) = 100 * absPower(i) / totalPower;
                end
            end

            peakAlphaFreq = NaN;
            if isfield(bands,'Alpha')
                aBand = bands.Alpha;
                if aBand(2) < nyq
                    aMask = f>=aBand(1) & f<=aBand(2);
                    if any(aMask)
                        fA = f(aMask); pA = pxx(aMask);
                        [~,ix] = max(pA);
                        peakAlphaFreq = fA(ix);
                        if ix > 1 && ix < numel(pA)
                            y1 = pA(ix-1); y2 = pA(ix); y3 = pA(ix+1);
                            denom = (y1 - 2*y2 + y3);
                            if denom ~= 0
                                delta = 0.5*(y1 - y3)/denom;
                                df = fA(ix+1) - fA(ix);
                                peakAlphaFreq = fA(ix) + delta*df;
                            end
                        end
                    end
                end
            end
        end
    end
end