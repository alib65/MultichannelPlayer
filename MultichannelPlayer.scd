/*
=====================================================================================
   MULTICHANNEL PLAYER  for SuperCollider (3.12 or newer, tested on 3.13)   v0.1 Beta
   Ali Balighi © 2026  ·  alibalighi.com
=====================================================================================

   Plays multichannel pieces that are stored as separate MONO files
   (for example 4 mono files = one 4-channel piece) and keeps a playlist of them.

   HOW TO START
     1. Open this file in the SuperCollider IDE.
     2. Select everything (Cmd+A on macOS, Ctrl+A on Windows / Linux) and press
           Cmd + Return   (macOS)      or      Ctrl + Return   (Windows / Linux)
     3. The player window opens and the audio server boots by itself.
        (Running it again simply replaces the window – nothing is lost.)

   FIRST TIME
     - Top bar: set "Outputs" (4 for quadraphonic), "First output" (1 = the first
       output of your interface), the Device, then press  "Apply / Reboot".
     - "+ Piece (files)…": select the mono files of ONE piece (hold Cmd/Ctrl or Shift
       to select several). Track 1 -> output 1, track 2 -> output 2 ... (sorted by
       file name). You can change the output of each track in its strip.
     - "+ Piece (folder)…": choose a folder that contains the mono files of one piece.
     - "+ Many pieces…": choose a folder that contains one sub-folder per piece –
       the fastest way to build a whole playlist (e.g. 10 pieces at once).

   LEVELS ARE REMEMBERED
     Every fader, mute, output assignment, piece trim and the master volume are saved
     automatically (about one second after you change them) together with the
     playlist. Next time you open the player everything comes back exactly as you
     left it. Use "Save as…" / "Open…" to keep several playlists.

   AUTO-LEVEL
     "Analyse + Auto-Level whole playlist" measures every track (EBU R128 loudness
     in LUFS, plus the peak level), then sets a "piece trim" for every piece so that
     all pieces play equally loud and none of them clips. Your own track faders are
     kept (unless you tick "Also balance the tracks inside each piece"). The
     analysis is cached, so the second time is instant. "Undo" restores the levels
     you had before.

   SPEAKER TEST
     "Speaker Test…" opens a window to send pink noise / band-limited pink noise /
     white noise / a sine tone to each speaker, all at once, or cycling through them,
     with level meters for every output.

   LISTENING FORMATS
     A piece can have ANY number of tracks (2, 4, 8, 16, 18, 24 …). Each piece has a
     "Source format": multichannel speaker feeds (placed with a layout: ring, pairs,
     5.1 / 7.1, two rings, dome, sphere or your own angles) or 3D Ambisonics (AmbiX
     or FuMa; 4 files = 1st order, 9 = 2nd, 16 = 3rd, 25 = 4th, 36 = 5th).
     The "Listening format" (bar under the top bar) decides how you hear it:
       - Multichannel direct: track N -> output N (bit-exact)
       - 3D Ambisonics -> my speakers: any piece on any speaker setup (AllRAD decoder)
       - Amplitude panning (VBAP) -> my speakers
       - Binaural -> headphones (spherical-head model + optional room)
       - Stereo downmix -> 2 speakers
       - Ambisonics B-format out (AmbiX) for an external decoder or for recording
     "My speakers…" tells the player where your own speakers are.

   KEYS:  Space = play / pause.   Double-click a piece = play it.
          Double-click a fader = back to 0 dB.
   Cmd+. / Ctrl+. (stop everything) is safe: the player rebuilds itself.

=====================================================================================
*/

(
var s = Server.default;
var appName = "Multichannel Player";
var appVersion = "0.1 Beta";
var appDir = Platform.userAppSupportDir +/+ "MultichannelPlayer";
var cacheDir = appDir +/+ "analysis-cache";
var prefsPath = appDir +/+ "prefs.scd";
var autosavePath = appDir +/+ "Autosave.mcplist";
var platformName = thisProcess.platform.name;
var diskBufFrames = 131072;
var minDb = -60, maxDb = 12;
var dbSpec = ControlSpec(minDb, maxDb, \lin, 0.1, 0);
var masterSpec = ControlSpec(minDb, 12, \lin, 0.1, 0);
var trimSpec = ControlSpec(-30, 24, \lin, 0.1, 0);
var testSpec = ControlSpec(-60, -6, \lin, 0.5, -20);
var testNames = ["Pink noise (full range)", "Pink noise 500 Hz - 2 kHz (calibration)", "White noise", "Sine tone"];
var targetNames = ["Auto: loudest equal level without clipping", "-16 LUFS", "-18 LUFS", "-20 LUFS", "-23 LUFS (EBU R128)", "-27 LUFS (quiet room)"];
var targetValues = [nil, -16, -18, -20, -23, -27];
var sampleRates = [0, 44100, 48000, 88200, 96000];
var formatNames = ["Multichannel – direct (track N → output N)", "3D Ambisonics → my speakers (AllRAD decoder)",
	"Amplitude panning (VBAP) → my speakers", "Binaural → headphones", "Stereo downmix → 2 speakers",
	"Ambisonics B-format out (AmbiX ACN/SN3D)"];
var srcFormats = [\multi, \ambix, \fuma];
var layoutNames = ["Ring – clockwise, 1 = front-left", "Ring – clockwise, 1 = front centre",
	"Pairs – 1 front-L, 2 front-R, 3 L, 4 R …", "Standard – stereo, quad, 5.1, 7.1 (ITU order)",
	"Two rings – ear height + upper ring 35°", "Dome – ring + upper ring + top", "Sphere – evenly spread (3D)", "Custom angles"];
var cText = Color.gray(0.92), cDim = Color.gray(0.62), cPanel = Color.gray(0.19), cStrip = Color.gray(0.24);
var cGreen = Color.new255(70, 200, 110), cYellow = Color.new255(245, 205, 60), cRed = Color.new255(240, 75, 65), cOrange = Color.new255(245, 150, 50), cBlue = Color.new255(90, 170, 255);

// ---------------- state
var prefs, plSet, pieces = [], playlistPath;
var selIdx, curIdx, transport = \stopped, posSec = 0, playToken = 0, gapLeft = 0;
var trackNodes = [], clockNode, playBufs = [], advanceTask;
var mixBus, playGroup, testGroup, masterGroup, masterSynth, serverReady = false, booting = false;
var nOuts = 4, outOff = 0, trackDefs = Set.new;
var trkPeak = [], trkRms = [], trkHold = [], trkTime = [];
var outPeak = [], outRms = [], outHold = [], outTime = [];
var dirtyCount = 0, analysisCache = Dictionary.new, analyzing = false, undoSnapshot;
var testNodes = [], testCycleTask, posDragging = false, posMoved = false, dragCount = 0;
var guiJack, cmdPeriodFunc, treeFunc, quitFunc, statusTime = 0, lastCpu = 0, lastStateStr = "";
var devices = [], instanceId = UniqueID.next, oscKeys;
var vBus, binNode, renderSig, decCache = Dictionary.new, vbapCache = Dictionary.new;

// ---------------- GUI objects
var win, testWin, helpWin;
var plList, plNameText, plInfoText, mixerScroll, strips = [];
var masterFader, masterNum, limiterBox, outScroll, outMeters = [], testScroll, testMeters = [];
var titleField, pieceInfoText, trimSlider, trimNum, posSlider, timeText, stateText, statusText;
var autoAdvBox, gapBox, targetPop, ceilBox, balanceBox, analyzeBtn, undoBtn, anaText;
var numOutsBox, offsetBox, srPop, devPop;
var testButtons = [], testTypePop, testFreqBox, testLevelSlider, testLevelNum, testCycleBtn, testCycleBox;
var formatPop, orderPop, spkInfoText, roomSlider, formatInfoText, srcPop, layoutPop, spkWin, mapView;

// ---------------- functions
var fmtTime, fmtDb, natKey, isAudio, fileInfo, makeTracksFromFiles, guessTitle, pieceSecs;
var gainAmp, onAmp, outFor, ampToMeter, defaultPlSet;
var loadPrefs, savePrefs, serialize, loadPlaylist, savePlaylist, markDirty, newPlaylist, afterDirty;
var bootServer, onBooted, makeDefs, makeTrackDef, makeTree, applySettings;
var startPiece, releasePlayback, stopPlayback, pausePlayback, resumePlayback, togglePlay, playPressed;
var nextPiece, prevPiece, seekTo, onPieceEnd, cancelAdvance, liveTrack, liveAllTracks, liveMaster;
var cacheKey, analyzeFile, readAnalysis, analyzeAll, gatedLoudness, pieceStats, balancePiece, autoLevel, undoAutoLevel;
var buildWindow, refreshPlaylist, buildMixer, refreshPieceHeader, makeStrip, buildOutMeters, makeMeterRow, refreshGui;
var openTestWindow, testOn, testOff, testAllOff, testUpdateButtons, startCycle, stopCycle, showHelp;
var addPieceFromFiles, addFolderPiece, addFolderOfPieces, addTracksToPiece, removeTrack, selectPiece;
var setStatus, refreshDevices, refreshSettingsWidgets, mkBtn, label, panel, playingPiece;
var layoutPreset, spkSplit, srcOrder, trackAcn, acnLabel, spatialMath;
var renderPiece, applyRenderLive, ensureSpeakerLayout, applyLayoutToPiece, formatChanged, spkChanged;
var afterSourceChange, positionEdited, detectSource, drawMap, refreshFormatWidgets, openSpeakerWindow, makeBinDef;

// =====================================================================================
//  UTILITIES
// =====================================================================================

fmtTime = { |sec|
	var t = (sec ? 0).max(0).floor.asInteger, m = t div: 60, ss = t % 60;
	m.asString ++ ":" ++ (if(ss < 10) { "0" } { "" }) ++ ss.asString
};

fmtDb = { |db|
	var r;
	if(db.isNil) { "--" } {
		if(db < -99) { "-inf" } {
			r = db.round(0.1);
			(if(r > 0) { "+" } { "" }) ++ r.asString
		}
	}
};

ampToMeter = { |a| (((a ? 0).max(0.000001).ampdb + 60) / 60).clip(0, 1) };

natKey = { |str|
	var out = String.new, num = String.new;
	str.toLower.do { |ch|
		if(ch.isDecDigit) { num = num ++ ch.asString } {
			if(num.size > 0) { out = out ++ ("0000000000" ++ num).keep(-10); num = String.new };
			out = out ++ ch.asString;
		};
	};
	if(num.size > 0) { out = out ++ ("0000000000" ++ num).keep(-10) };
	out
};

isAudio = { |path|
	["wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "w64", "rf64", "bwf", "ogg", "snd", "au"]
	.includesEqual(path.asString.splitext[1].asString.toLower)
};

fileInfo = { |path|
	var sf, res;
	if(File.exists(path)) {
		sf = SoundFile.openRead(path);
		if(sf.notNil) {
			res = (nch: sf.numChannels, sr: sf.sampleRate, secs: sf.duration);
			sf.close;
		};
	};
	res
};

defaultPlSet = { (autoAdvance: true, gapSec: 3.0, targetIdx: 0, ceilDb: -1.0, balance: false) };

pieceSecs = { |p| (p.tracks.collect { |t| t.secs ? 0 }.maxItem) ? 0 };

gainAmp = { |p, t| if(t.db <= minDb) { 0 } { (t.db + (p.trimDb ? 0)).dbamp } };

onAmp = { |p, t|
	var anySolo = p.tracks.any { |x| x.solo == true };
	if((t.mute == true) or: { anySolo and: { t.solo != true } }) { 0 } { 1 }
};

outFor = { |t| (t.outCh ? 0).clip(0, nOuts - 1) };

playingPiece = { if(curIdx.notNil and: { (transport == \playing) or: { transport == \paused } }) { pieces[curIdx] } };

makeTracksFromFiles = { |paths, startOut = 0|
	var tracks = [], k = startOut;
	paths = paths.select(isAudio).sort { |a, b| natKey.(a.basename) <= natKey.(b.basename) };
	paths.do { |path|
		var info = fileInfo.(path);
		if(info.isNil) { ("Multichannel Player: could not open " ++ path).warn } {
			info.nch.do { |c|
				tracks = tracks.add((path: path, chan: c, nch: info.nch, sr: info.sr, secs: info.secs,
					outCh: k % max(nOuts, 1), db: 0.0, mute: false, solo: false, missing: false));
				k = k + 1;
			};
		};
	};
	tracks
};

guessTitle = { |paths|
	var names = paths.collect { |p| p.basename.splitext[0] }, pre;
	if(names.size == 0) { "Untitled" } {
		if(names.size == 1) { names[0] } {
			pre = names[0];
			names.do { |n| while { (pre.size > 0) and: { n.beginsWith(pre).not } } { pre = pre.drop(-1) } };
			while { (pre.size > 0) and: { "_-. (".includes(pre.last) } } { pre = pre.drop(-1) };
			if(pre.size >= 2) { pre } { paths[0].dirname.basename }
		}
	}
};

setStatus = { |str, color|
	{
		if(statusText.notNil and: { statusText.isClosed.not }) {
			statusText.string = str;
			statusText.stringColor = color ? cText;
		};
		statusTime = Main.elapsedTime;
	}.defer;
	str.postln;
};

// =====================================================================================
//  SAVING / LOADING
// =====================================================================================

loadPrefs = {
	var d;
	prefs = (numOuts: 4, outOffset: 0, device: "", sampleRate: 0, masterDb: 0.0, limiter: true,
		limCeilDb: -0.5, lastPlaylist: "", testType: 0, testDb: -20.0, testFreq: 1000, cycleSec: 2.0,
		listen: 0, ambiOrder: 0, spkPreset: 0, room: 0.2);
	if(File.exists(prefsPath)) {
		d = try { File.readAllString(prefsPath).interpret };
		if(d.isKindOf(Event)) { d.keysValuesDo { |k, v| prefs[k] = v } };
	};
	prefs.spk !? { prefs.spk = prefs.spk.collect { |dd| dd.copy } };
};

savePrefs = {
	try { File.use(prefsPath, "w", { |f| f.write(prefs.asCompileString) }) } { "Multichannel Player: could not save preferences".warn };
};

serialize = {
	(format: "MultichannelPlayer-playlist", version: 1, settings: plSet.copy,
		pieces: pieces.collect { |p|
			(title: p.title, trimDb: p.trimDb, lufs: p.lufs, peakDb: p.peakDb, limited: p.limited,
				srcFormat: p.srcFormat, layoutIdx: p.layoutIdx,
				tracks: p.tracks.collect { |t|
					(path: t.path, chan: t.chan, nch: t.nch, sr: t.sr, secs: t.secs, outCh: t.outCh,
						db: t.db, mute: t.mute, solo: t.solo, lufs: t.lufs, peakDb: t.peakDb,
						az: t.az, el: t.el, lfe: t.lfe)
			})
	})
};

savePlaylist = { |path|
	var str = serialize.().asCompileString;
	try {
		File.use(path, "w", { |f| f.write(str) });
		playlistPath = path;
		prefs.lastPlaylist = path;
		savePrefs.();
	} { ("Multichannel Player: could not save playlist " ++ path).warn };
};

loadPlaylist = { |path|
	var d = if(path.notNil and: { File.exists(path) }) { try { File.readAllString(path).interpret } };
	if(d.isKindOf(Event) and: { d[\pieces].notNil }) {
		plSet = defaultPlSet.();
		d[\settings] !? { |st| st.keysValuesDo { |k, v| plSet[k] = v } };
		pieces = d[\pieces].collect { |p|
			var q = (title: p[\title] ? "Untitled", trimDb: p[\trimDb] ? 0.0, lufs: p[\lufs], peakDb: p[\peakDb], limited: p[\limited] ? false,
				srcFormat: p[\srcFormat] ? \multi, layoutIdx: p[\layoutIdx] ? 0);
			q.tracks = (p[\tracks] ? []).collect { |t|
				var u = t.copy, info;
				u.db = u.db ? 0.0; u.mute = u.mute ? false; u.solo = u.solo ? false;
				u.outCh = u.outCh ? 0; u.chan = u.chan ? 0; u.nch = u.nch ? 1; u.sr = u.sr ? 48000; u.secs = u.secs ? 0;
				info = fileInfo.(u.path ? "");
				if(info.notNil) {
					u.nch = info.nch; u.sr = info.sr; u.secs = info.secs; u.missing = false;
					if(u.chan >= u.nch) { u.chan = 0 };
				} { u.missing = true };
				u
			};
			if(q.tracks.any { |t| t.az.isNil }) { applyLayoutToPiece.(q, if(q.layoutIdx == 7) { 0 } { q.layoutIdx }) };
			q
		};
		playlistPath = path;
		prefs.lastPlaylist = path;
		true
	} { false }
};

// changes are saved ~1 s after the last edit
markDirty = {
	var c;
	dirtyCount = dirtyCount + 1;
	c = dirtyCount;
	AppClock.sched(0.8, {
		if(c == dirtyCount) { savePlaylist.(playlistPath); afterDirty.() };
		nil
	});
};

// after edits: refresh loudness read-outs if analysis data is in memory
afterDirty = {
	var p = if(selIdx.notNil) { pieces[selIdx] };
	if(p.notNil and: { p.tracks.any { |t| analysisCache[t.path].notNil } }) {
		pieceStats.(p);
		refreshPieceHeader.();
		refreshPlaylist.();
	};
};

newPlaylist = {
	stopPlayback.();
	savePlaylist.(playlistPath);
	pieces = [];
	selIdx = nil;
	plSet = defaultPlSet.();
	playlistPath = appDir +/+ ("Playlist " ++ Date.getDate.stamp ++ ".mcplist");
	undoSnapshot = nil;
	refreshSettingsWidgets.();
	buildMixer.();
	refreshPlaylist.();
	markDirty.();
};

// =====================================================================================
//  SERVER, SYNTHDEFS
// =====================================================================================

makeTrackDef = { |nch, vari, k = 1|
	var name = ("mcpTrk" ++ (if(vari) { "V" } { "D" }) ++ nch ++ "x" ++ k).asSymbol;
	if(trackDefs.includes(name).not) {
		SynthDef(name, { |out = 0, buf = 0, chan = 0, rate = 1, gain = 0, on = 1, pmul = 1, gate = 1, fadeIn = 0.005, id = 0|
			var sig, env, gains = \gains.kr(1 ! k);
			sig = if(vari) { VDiskIn.ar(nch, buf, rate) } { DiskIn.ar(nch, buf) };
			if(nch > 1) { sig = Select.ar(chan, sig) };
			env = EnvGen.kr(Env.asr(fadeIn, 1, 0.08), gate, doneAction: 2);
			sig = sig * Lag.kr(gain, 0.05) * env;
			SendPeakRMS.kr(sig, 20, 3, '/mcpTrk', id);         // meter: after fader, before mute
			// one gain per output bus: the listening format (direct, Ambisonics, VBAP, stereo …)
			Out.ar(out, (sig * Lag.kr(on * pmul, 0.03)) * Lag.kr(gains, 0.05));
		}).add;
		trackDefs.add(name);
	};
	name
};

makeDefs = {
	var n = nOuts;
	trackDefs = Set.new;
	[1, 2].do { |k| makeTrackDef.(k, false, 1) };

	SynthDef(\mcpClock, { |start = 0, secs = 1, token = 0|
		var t = Sweep.kr(0, 1) + start;
		SendReply.kr(Impulse.kr(15), '/mcpPos', t, token);
		SendReply.kr(t >= secs, '/mcpEnd', t, token);
	}).add;

	SynthDef(\mcpMaster, { |in = 0, out = 0, amp = 1, lim = 1, ceil = 0.944|
		var sig = In.ar(in, n) * Lag.kr(amp, 0.1);
		var l = Lag.kr(lim, 0.05);
		sig = (DelayN.ar(sig, 0.02, 0.01) * (1 - l)) + (Limiter.ar(sig, ceil, 0.005) * l);
		SendPeakRMS.kr(sig, 20, 3, '/mcpOut', 0);
		Out.ar(out, sig);
	}).add;

	// levels are RMS dBFS: every signal is normalised to RMS = amp
	SynthDef(\mcpTest, { |out = 0, amp = 0.1, type = 0, freq = 1000, gate = 1|
		var env = EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);
		var pink = PinkNoise.ar * 15.66.dbamp;
		var band = LPF.ar(LPF.ar(HPF.ar(HPF.ar(PinkNoise.ar, 500), 500), 2000), 2000) * 28.21.dbamp;
		var white = WhiteNoise.ar * 4.77.dbamp;
		var sine = SinOsc.ar(freq) * 2.sqrt;
		var sig = Select.ar(type, [pink, band, white, sine]);
		Out.ar(out, sig * Lag.kr(amp, 0.05) * env);
	}).add;
};

makeTree = {
	playGroup = Group.head(s.defaultGroup);
	testGroup = Group.after(playGroup);
	masterGroup = Group.tail(RootNode(s));
	masterSynth = Synth(\mcpMaster, [\in, mixBus.index, \out, outOff,
		\amp, if(prefs.masterDb <= minDb) { 0 } { prefs.masterDb.dbamp },
		\lim, if(prefs.limiter == true) { 1 } { 0 }, \ceil, prefs.limCeilDb.dbamp], masterGroup);
	testNodes = Array.newClear(nOuts);
};

onBooted = {
	fork({
		mixBus = Bus.audio(s, nOuts);
		vBus = Bus.audio(s, 128);      // virtual sources for binaural
		ensureSpeakerLayout.();
		makeDefs.();
		s.sync;
		makeTree.();
		s.sync;
		serverReady = true;
		booting = false;
		outPeak = 0 ! nOuts; outRms = 0 ! nOuts; outHold = 0 ! nOuts; outTime = 0 ! nOuts;
		setStatus.("Audio server running: % Hz, % output(s) starting at hardware output %"
			.format(s.sampleRate.round, nOuts, outOff + 1), cGreen);
		buildOutMeters.();
		buildMixer.();
		if(spkWin.notNil and: { spkWin.isClosed.not }) { spkWin.close; openSpeakerWindow.() };
		if(testWin.notNil and: { testWin.isClosed.not }) { testWin.close; openTestWindow.() };
	}, AppClock);
};

bootServer = {
	if(booting.not) {
		booting = true;
		serverReady = false;
		stopPlayback.();
		stopCycle.();
		testNodes = [];
		setStatus.("Booting audio server…", cYellow);
		fork({
			var o = s.options;
			if(s.serverRunning) {
				s.quit;
				0.5.wait;
				40.do { if(s.serverRunning) { 0.1.wait } };
			};
			nOuts = prefs.numOuts.asInteger.clip(1, 128);
			outOff = prefs.outOffset.asInteger.clip(0, 255);
			ensureSpeakerLayout.();
			o.numOutputBusChannels = max(nOuts + outOff, 2);
			o.numInputBusChannels = 0;
			o.memSize = max(o.memSize, 65536);
			o.numBuffers = max(o.numBuffers, 4096);
			o.numWireBufs = max(o.numWireBufs, 256);
			o.sampleRate = if((prefs.sampleRate ? 0) > 0) { prefs.sampleRate } { nil };
			if(platformName != \linux) {
				o.device = nil;
				o.inDevice = nil;
				o.outDevice = if((prefs.device ? "").size > 0) { prefs.device } { nil };
			};
			s.waitForBoot({ onBooted.() }, 60, {
				booting = false;
				setStatus.("The audio server did not boot. Check the device / sample rate and press Apply / Reboot.", cRed);
			});
		}, AppClock);
	};
};

applySettings = {
	prefs.numOuts = numOutsBox.value.asInteger;
	prefs.outOffset = offsetBox.value.asInteger - 1;
	prefs.sampleRate = sampleRates[srPop.value] ? 0;
	prefs.device = if(devPop.value == 0) { "" } { devices[devPop.value - 1] ? "" };
	savePrefs.();
	bootServer.();
};

refreshDevices = {
	devices = if(platformName == \linux) { [] } { (try { ServerOptions.outDevices }) ? [] };
	devPop.items = [if(platformName == \linux) { "System default (JACK)" } { "System default" }] ++ devices;
	devPop.value = (devices.indexOfEqual(prefs.device) !? { |i| i + 1 }) ? 0;
};

// =====================================================================================
//  SPATIAL RENDERING  (listening formats)
//  Directions: azimuth 0 = front, +90 = left, -90 = right, 180 = back; elevation +90 = top.
//  All gains are calculated here once; the server only applies fixed gain matrices
//  (plus head-model filters for binaural), so every format costs very little CPU.
// =====================================================================================

{
	// helper functions only used by the spatial code live in this inner scope
	var wrapAz, dirVec, dot3, cross3, legendreP, shSN3D, maxReWeights, fibSphere, isLayout2D;
	var vbapSetup, vbapGains, allradDecoder, decoder2D, virtualDecoder, binCoefs, binArgs, stereoGains, effectiveOrder, fumaMap;

	// FuMa channel (W X Y Z R S T U V K L M N O P Q) -> [ACN index, gain to SN3D]
	fumaMap = [[0, 2.sqrt], [3, 1], [1, 1], [2, 1], [6, 1], [7, 2 / 3.sqrt], [5, 2 / 3.sqrt], [8, 2 / 3.sqrt], [4, 2 / 3.sqrt],
		[12, 1], [13, (45 / 32).sqrt], [11, (45 / 32).sqrt], [14, 3 / 5.sqrt], [10, 3 / 5.sqrt], [15, (8 / 5).sqrt], [9, (8 / 5).sqrt]];

	wrapAz = { |a| ((a + 180) % 360) - 180 };
	dirVec = { |az, el| var a = az.degrad, e = el.degrad; [cos(a) * cos(e), sin(a) * cos(e), sin(e)] };
	dot3 = { |a, b| (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2]) };
	cross3 = { |a, b| [(a[1] * b[2]) - (a[2] * b[1]), (a[2] * b[0]) - (a[0] * b[2]), (a[0] * b[1]) - (a[1] * b[0])] };

	legendreP = { |n, x|
		var p0 = 1.0, p1 = x, p2;
		if(n == 0) { 1.0 } {
			(n - 1).do { |k|
				var kk = k + 1;
				p2 = ((((2 * kk) + 1) * x * p1) - (kk * p0)) / (kk + 1);
				p0 = p1;
				p1 = p2;
			};
			p1
		}
	};

	// real spherical harmonics in ACN order with SN3D normalisation (AmbiX), no Condon-Shortley phase
	shSN3D = { |order, az, el|
		var x = sin(el.degrad), c = cos(el.degrad).max(0), a = az.degrad, res = 0.0 ! ((order + 1).squared);
		(order + 1).do { |m|
			var p = 0.0 ! (order + 1), dfact = 1;
			m.do { |q| dfact = dfact * ((2 * q) + 1) };
			p[m] = dfact * (c ** m);
			if(m < order) { p[m + 1] = x * ((2 * m) + 1) * p[m] };
			if((m + 2) <= order) {
				for(m + 2, order) { |n| p[n] = ((((2 * n) - 1) * x * p[n - 1]) - ((n + m - 1) * p[n - 2])) / (n - m) };
			};
			for(m, order) { |n|
				var norm = ((if(m == 0) { 1 } { 2 }) * ((n - m).factorial / (n + m).factorial)).sqrt;
				res[(n * n) + n + m] = norm * p[n] * cos(m * a);
				if(m > 0) { res[(n * n) + n - m] = norm * p[n] * sin(m * a) };
			};
		};
		res
	};

	// max-rE weights (3D)
	maxReWeights = { |order|
		var x = cos((137.9 / (order + 1.51)).degrad);
		(order + 1).collect { |n| legendreP.(n, x) }
	};

	// n nearly uniform directions on the sphere
	fibSphere = { |n|
		var ga = pi * (3 - 5.sqrt);
		n.collect { |i|
			var z = 1 - (((2 * i) + 1) / n), r = (1 - (z * z)).max(0).sqrt, ph = i * ga;
			[atan2(r * sin(ph), r * cos(ph)).raddeg, asin(z).raddeg]
		}
	};

	// speaker / track positions for the layout presets: [az, el] or [az, el, \lfe]
	layoutPreset = { |idx, n|
		var res, lower, upper, m;
		n = n.max(1);
		res = case
		{ idx == 7 } { nil }
		{ n == 1 } { [[0, 0]] }
		{ idx == 0 } { n.collect { |i| [(180 / n) - (i * 360 / n), 0] } }
		{ idx == 1 } { n.collect { |i| [(i * 360 / n).neg, 0] } }
		{ idx == 2 } {
			m = (n div: 2).max(1);
			n.collect { |i|
				if(n.odd and: { i == (n - 1) }) { [180, 0] } {
					[(((2 * (i div: 2)) + 1) * 180 / (2 * m)) * (if(i.even) { 1 } { -1 }), 0]
				}
			}
		}
		{ idx == 3 } {
			switch(n)
			{ 2 } { [[30, 0], [-30, 0]] }
			{ 3 } { [[30, 0], [-30, 0], [0, 0]] }
			{ 4 } { [[45, 0], [-45, 0], [135, 0], [-135, 0]] }
			{ 5 } { [[30, 0], [-30, 0], [0, 0], [110, 0], [-110, 0]] }
			{ 6 } { [[30, 0], [-30, 0], [0, 0], [0, 0, \lfe], [110, 0], [-110, 0]] }
			{ 7 } { [[30, 0], [-30, 0], [0, 0], [90, 0], [-90, 0], [150, 0], [-150, 0]] }
			{ 8 } { [[30, 0], [-30, 0], [0, 0], [0, 0, \lfe], [90, 0], [-90, 0], [150, 0], [-150, 0]] }
			{ layoutPreset.(2, n) }
		}
		{ idx == 4 } {
			lower = (n / 2).ceil.asInteger;
			upper = n - lower;
			layoutPreset.(0, lower) ++ (if(upper > 0) { layoutPreset.(0, upper).collect { |d| [d[0], 35] } } { [] })
		}
		{ idx == 5 } {
			if(n < 5) { layoutPreset.(4, n) } {
				m = n - 1;
				lower = (m * 2 / 3).round.asInteger.max(3);
				upper = m - lower;
				layoutPreset.(0, lower) ++ (if(upper > 0) { layoutPreset.(0, upper).collect { |d| [d[0], 40] } } { [] }) ++ [[0, 90]]
			}
		}
		{ idx == 6 } { fibSphere.(n) }
		{ nil };
		res !? { res.collect { |d| [wrapAz.(d[0]).round(0.1), d[1].round(0.1)] ++ (if(d[2] == \lfe) { [\lfe] } { [] }) } }
	};

	isLayout2D = { |dirs| dirs.every { |d| d[1].abs < 10 } };

	// indices of my full-range speakers and of my subwoofers (LFE)
	spkSplit = {
		var real = [], lfe = [];
		nOuts.do { |k| if((prefs.spk[k] ? [0, 0])[2] == \lfe) { lfe = lfe.add(k) } { real = real.add(k) } };
		if(real.isEmpty) { real = (0 .. (nOuts - 1)); lfe = [] };
		[real, lfe]
	};

	ensureSpeakerLayout = {
		if(prefs.spk.isNil or: { prefs.spk.size != nOuts }) {
			if((prefs.spkPreset ? 0) == 7) { prefs.spkPreset = 0 };
			prefs.spk = layoutPreset.(prefs.spkPreset ? 0, nOuts);
		};
	};

	applyLayoutToPiece = { |p, idx|
		var lay = layoutPreset.(idx, p.tracks.size);
		if(lay.notNil) {
			p.tracks.do { |t, i| var d = lay[i]; t.az = d[0]; t.el = d[1]; t.lfe = d[2] == \lfe };
		};
		p.layoutIdx = idx;
	};

	// ---------------- VBAP (Pulkki), with imaginary speakers where the layout leaves holes
	vbapSetup = { |dirs|
		var key = dirs.asCompileString, real, pts, cands = [], facets = [], np, nReal, res;
		vbapCache[key] ?? {
			real = dirs.collect { |d| dirVec.(d[0], d[1]) };
			nReal = real.size;
			pts = real.copy;
			[-1, 0, 1].do { |x| [-1, 0, 1].do { |y| [-1, 0, 1].do { |z|
				var l;
				if((x != 0) or: { y != 0 } or: { z != 0 }) {
					l = ((x * x) + (y * y) + (z * z)).sqrt;
					cands = cands.add([x / l, y / l, z / l]);
				};
			} } };
			cands = cands.sort { |a, b| a[2].abs >= b[2].abs };
			cands.do { |c|
				if(pts.collect { |q| dot3.(q, c).clip(-1, 1).acos }.minItem > 70.degrad) { pts = pts.add(c) };
			};
			np = pts.size;
			// convex hull: every triangle with all other points on one side
			for(0, np - 3) { |i| for(i + 1, np - 2) { |j| for(j + 1, np - 1) { |k|
				var a = pts[i], b = pts[j], c = pts[k], nrm, det, side = 0, ok = true, m = 0, bc, ca, ab;
				det = dot3.(a, cross3.(b, c));
				if(det.abs > 0.0001) {
					nrm = cross3.(b - a, c - a);
					while { ok and: { m < np } } {
						var d;
						if((m != i) and: { m != j } and: { m != k }) {
							d = dot3.(nrm, pts[m] - a);
							if(d > 0.000001) { if(side < 0) { ok = false } { side = 1 } };
							if(d < -0.000001) { if(side > 0) { ok = false } { side = -1 } };
						};
						m = m + 1;
					};
					if(ok) {
						bc = cross3.(b, c) / det; ca = cross3.(c, a) / det; ab = cross3.(a, b) / det;
						facets = facets.add([i, j, k, [bc, ca, ab]]);
					};
				};
			} } };
			res = (pts: pts, nReal: nReal, facets: facets);
			vbapCache[key] = res;
			res
		}
	};

	// gains for the real speakers. Imaginary speakers (holes in the layout) are discarded;
	// with renorm the remaining gains are scaled back to unit power (a source in a hole is "projected").
	vbapGains = { |setup, az, el, renorm = true|
		var p = dirVec.(az, el), best, bestMin = -inf, g, out, nReal = setup.nReal, norm;
		if(nReal <= 1) { [1.0] } {
			setup.facets.do { |f|
				var gi = f[3].collect { |v| dot3.(p, v) }, mn = gi.minItem;
				if(mn > bestMin) { bestMin = mn; best = [f, gi] };
			};
			g = 0.0 ! setup.pts.size;
			if(best.notNil) { 3.do { |q| g[best[0][q]] = best[1][q].max(0) } };
			norm = g.squared.sum.sqrt;
			if(norm > 0) { g = g / norm };
			out = g.keep(nReal);
			if(renorm) {
				norm = out.squared.sum.sqrt;
				if(norm > 0.000001) { out / norm } { (1 / nReal.sqrt) ! nReal }
			} { out }
		}
	};

	// Horizontal layouts (rings): 2D max-rE decoder of the sectoral components to a virtual ring of 72 points,
	// then pairwise panning to the real speakers. Elevated sources become wider; a source straight above
	// reaches all speakers equally. Returns [real speaker][ACN].
	decoder2D = { |dirs, order|
		var nsh = (order + 1).squared, setup = vbapSetup.(dirs), w, cn, dm, e;
		w = (order + 1).collect { |n| cos(n * pi / ((2 * order) + 2)) };
		cn = (order + 1).collect { |n|
			var df = 1;
			n.do { |q| df = df * ((2 * q) + 1) };
			if(n == 0) { 1 } { (2 / (2 * n).factorial).sqrt * df }   // SN3D sectoral gain at ear height
		};
		dm = dirs.collect { 0.0 ! nsh };
		72.do { |i|
			var az = i * 5, gv = vbapGains.(setup, az, 0), row = 0.0 ! nsh;
			row[0] = 1;
			for(1, order) { |n|
				row[(n * n) + n + n] = 2 * w[n] / cn[n] * cos(n * az.degrad);
				row[(n * n) + n - n] = 2 * w[n] / cn[n] * sin(n * az.degrad);
			};
			gv.do { |gk, k| if(gk != 0) { dm[k] = dm[k] + (row * gk) } };
		};
		e = 72.collect { |i| var y = shSN3D.(order, i * 5, 0); dm.collect { |r| (r * y).sum.squared }.sum }.mean;
		if(e > 0) { dm * e.sqrt.reciprocal } { dm }
	};

	// AllRAD decoder (Zotter & Frank): max-rE sampling decoder to 240 virtual speakers, then VBAP to the real ones.
	// Returns [real speaker][ACN] gains for SN3D signals, normalised to unit average energy.
	allradDecoder = { |dirs, order|
		var key = dirs.asCompileString ++ "/" ++ order, setup, w, nsh = (order + 1).squared, dm, test, e;
		decCache[key] ?? {
			if(isLayout2D.(dirs) and: { dirs.size > 1 }) { dm = decoder2D.(dirs, order); decCache[key] = dm; dm } {
			setup = vbapSetup.(dirs);
			w = maxReWeights.(order);
			dm = dirs.collect { 0.0 ! nsh };
			fibSphere.(240).do { |v|
				var y = shSN3D.(order, v[0], v[1]), gv = vbapGains.(setup, v[0], v[1], false), row;
				row = nsh.collect { |acn| var n = acn.sqrt.floor.asInteger; w[n] * ((2 * n) + 1) * y[acn] };
				gv.do { |gk, k| if(gk != 0) { dm[k] = dm[k] + (row * gk) } };
			};
			test = fibSphere.(200);
			e = test.collect { |d| var y = shSN3D.(order, d[0], d[1]); dm.collect { |r| (r * y).sum.squared }.sum }.mean;
			if(e > 0) { dm = dm * e.sqrt.reciprocal };
			decCache[key] = dm;
			dm
			}
		}
	};

	// max-rE sampling decoder to a set of virtual speakers (used for binaural and stereo of Ambisonic pieces)
	virtualDecoder = { |vpts, order|
		var w = maxReWeights.(order), nsh = (order + 1).squared, dm, e;
		dm = vpts.collect { |v|
			var y = shSN3D.(order, v[0], v[1]);
			nsh.collect { |acn| var n = acn.sqrt.floor.asInteger; w[n] * ((2 * n) + 1) * y[acn] }
		};
		e = fibSphere.(100).collect { |d| var y = shSN3D.(order, d[0], d[1]); dm.collect { |r| (r * y).sum.squared }.sum }.mean;
		if(e > 0) { dm * e.sqrt.reciprocal } { dm }
	};

	// spherical-head HRTF model (Brown & Duda 1998): interaural delay + head-shadow filter per ear,
	// plus a gentle high-frequency cut for sources behind the listener (front/back cue)
	binCoefs = { |az, el|
		var sr = (s.sampleRate ? 48000).max(8000), p = dirVec.(az, el), a = 0.0875, c = 343, beta = 2 * c / a, k = 2 * sr;
		var res = (), back = p[0].neg.max(0), g = 1 - (0.45 * back), wc = 2pi * 3000;
		[[\l, [0, 1, 0]], [\r, [0, -1, 0]]].do { |pair|
			var th = dot3.(p, pair[1]).clip(-1, 1).acos, alpha, dl;
			alpha = 1.05 + (0.95 * cos((th / 150.degrad) * pi));
			dl = if(th < 0.5pi) { (a / c) * (1 - cos(th)) } { (a / c) * (1 + (th - 0.5pi)) };
			res[pair[0]] = [dl, (beta + (alpha * k)) / (beta + k), (beta - (alpha * k)) / (beta + k), (k - beta) / (beta + k)];
		};
		res[\shelf] = [((g * k) + wc) / (k + wc), (wc - (g * k)) / (k + wc), (k - wc) / (k + wc)];
		res
	};

	binArgs = { |pos|
		var cs = pos.collect { |d| binCoefs.(d[0], d[1]) }, col = { |key, q| cs.collect { |c| c[key][q] } };
		[\dl, col.(\l, 0), \la, col.(\l, 1), \lb, col.(\l, 2), \lc, col.(\l, 3),
			\dr, col.(\r, 0), \ra, col.(\r, 1), \rb, col.(\r, 2), \rc, col.(\r, 3),
			\sa, col.(\shelf, 0), \sb, col.(\shelf, 1), \sc, col.(\shelf, 2)]
	};

	// constant-power stereo: sources at ±30° or wider go fully to one side, rear sources fold to the front
	stereoGains = { |az, el|
		var a = wrapAz.(az), rear = (cos(az.degrad) * cos(el.degrad)).neg.max(0), f, x;
		f = case { a > 90 } { 180 - a } { a < -90 } { -180 - a } { a };
		x = ((f * cos(el.degrad)) / 30).clip(-1, 1);
		[cos((1 - x) * 0.25pi), sin((1 - x) * 0.25pi)] * (1 - (0.16 * rear))
	};

	srcOrder = { |p|
		var o = ((p.tracks.size.max(1).sqrt.floor.asInteger) - 1).clip(0, 5);
		if(p.srcFormat == \fuma) { o.min(3) } { o }
	};

	// [ACN index, gain to SN3D] of track i of an Ambisonic piece
	trackAcn = { |p, i|
		if(p.srcFormat == \fuma) { fumaMap[i] ? [nil, 0] } { if(i < 36) { [i, 1.0] } { [nil, 0] } }
	};

	acnLabel = { |p, i|
		var am = trackAcn.(p, i), n, m;
		if(am[0].isNil) { "not used" } {
			n = am[0].sqrt.floor.asInteger;
			m = am[0] - (n * n) - n;
			if(p.srcFormat == \fuma) { "FuMa " ++ "WXYZRSTUVKLMNOPQ"[i] ++ "\n(ACN " ++ am[0] ++ ")" } {
				"ACN %\n(order %, m %)".format(am[0], n, m)
			}
		}
	};

	effectiveOrder = { |p, mode|
		var want = prefs.ambiOrder ? 0, sp = spkSplit.(), dirs, nl, so, lim;
		dirs = sp[0].collect { |k| prefs.spk[k] };
		nl = dirs.size.max(1);
		so = if(p.notNil and: { (p.srcFormat ? \multi) != \multi }) { srcOrder.(p) } { 5 };
		lim = if(mode == 5) { ((nOuts.sqrt.floor.asInteger) - 1).clip(0, 5) } {
			if(isLayout2D.(dirs)) { ((nl - 1) div: 2).clip(1, 5) } { ((nl.sqrt.floor.asInteger) - 1).clip(1, 5) }
		};
		if(mode == 5) { (if(want > 0) { want } { 3 }).min(lim).min(so) } { (if(want > 0) { want } { lim }).min(so) }
	};

	// how every track of piece p is sent to the outputs for the current listening format.
	// For every track: (out: first bus, gains: [one gain per bus]).
	renderPiece = { |p|
		var mode = prefs.listen ? 0, fmt = p.srcFormat ? \multi, n = p.tracks.size, sp = spkSplit.(), realIdx, lfeIdx;
		var base = if(mixBus.notNil) { mixBus.index } { 0 }, vb = if(vBus.notNil) { vBus.index } { 0 };
		var tr, note = "", order, nv = 0, binPos, dirs, lfeVec, dm, setup, vpts, dv, nsh, m2, e;
		realIdx = sp[0];
		lfeIdx = sp[1];
		if(((mode == 3) or: { mode == 4 }) and: { nOuts < 2 }) { mode = 1; note = "(only 1 output) " };
		if((mode == 2) and: { fmt != \multi }) { mode = 1; note = "VBAP needs speaker feeds, so this Ambisonic piece is decoded: " };
		lfeVec = 0.0 ! nOuts;
		if(lfeIdx.notEmpty) { lfeIdx.do { |k| lfeVec[k] = lfeIdx.size.sqrt.reciprocal } } {
			realIdx.do { |k| lfeVec[k] = realIdx.size.sqrt.reciprocal }
		};
		dirs = realIdx.collect { |k| prefs.spk[k].keep(2) };
		case
		{ mode == 0 } {
			tr = p.tracks.collect { |t| (out: base + outFor.(t), gains: [1.0]) };
			note = "Direct: track N → output N (bit-exact)" ++
			(if(n > nOuts) { ".  This piece has % tracks but only % outputs – choose an Ambisonics, VBAP, binaural or stereo format.".format(n, nOuts) } { "" });
		}
		{ mode == 1 } {
			order = effectiveOrder.(p, 1);
			nsh = (order + 1).squared;
			dm = allradDecoder.(dirs, order);
			tr = p.tracks.collect { |t, i|
				var g = 0.0 ! nOuts, y, am;
				if(fmt == \multi) {
					if(t.lfe == true) { g = lfeVec.copy } {
						y = shSN3D.(order, t.az ? 0, t.el ? 0);
						realIdx.do { |k, r| g[k] = (dm[r] * y).sum };
					};
				} {
					am = trackAcn.(p, i);
					if(am[0].notNil and: { am[0] < nsh }) { realIdx.do { |k, r| g[k] = dm[r][am[0]] * am[1] } };
				};
				(out: base, gains: g)
			};
			note = note ++ "3D Ambisonics order % (AllRAD decoder) → % speaker(s)".format(order, realIdx.size);
		}
		{ mode == 2 } {
			setup = vbapSetup.(dirs);
			tr = p.tracks.collect { |t|
				var g = 0.0 ! nOuts, v;
				if(t.lfe == true) { g = lfeVec.copy } {
					v = vbapGains.(setup, t.az ? 0, t.el ? 0);
					realIdx.do { |k, r| g[k] = v[r] };
				};
				(out: base, gains: g)
			};
			note = "Amplitude panning (VBAP) → % speaker(s)".format(realIdx.size);
		}
		{ mode == 3 } {
			if(fmt == \multi) {
				binPos = [];
				tr = p.tracks.collect { |t|
					if(t.lfe == true) { (out: base, gains: [0.7, 0.7]) } {
						binPos = binPos.add([t.az ? 0, t.el ? 0]);
						(out: vb + (binPos.size - 1), gains: [1.0])
					}
				};
				note = "Binaural (spherical-head model): % virtual source(s) → outputs 1–2, use headphones".format(binPos.size);
			} {
				order = srcOrder.(p);
				vpts = fibSphere.((2 * (order + 1).squared).clip(8, 50));
				dv = virtualDecoder.(vpts, order);
				binPos = vpts;
				nsh = (order + 1).squared;
				tr = p.tracks.collect { |t, i|
					var am = trackAcn.(p, i);
					(out: vb, gains: if(am[0].notNil and: { am[0] < nsh }) { dv.collect { |row| row[am[0]] * am[1] } } { 0.0 ! vpts.size })
				};
				note = "Binaural: Ambisonics order % → % virtual speakers → outputs 1–2, use headphones".format(order, vpts.size);
			};
			nv = binPos.size;
		}
		{ mode == 4 } {
			if(fmt == \multi) {
				tr = p.tracks.collect { |t| (out: base, gains: if(t.lfe == true) { [0.7, 0.7] } { stereoGains.(t.az ? 0, t.el ? 0) }) };
			} {
				order = srcOrder.(p);
				vpts = fibSphere.((2 * (order + 1).squared).clip(8, 50));
				dv = virtualDecoder.(vpts, order);
				nsh = (order + 1).squared;
				m2 = [0.0 ! nsh, 0.0 ! nsh];
				vpts.do { |v, q|
					var sg = stereoGains.(v[0], v[1]);
					2.do { |ch| m2[ch] = m2[ch] + (dv[q] * sg[ch]) };
				};
				e = fibSphere.(100).collect { |d| var y = shSN3D.(order, d[0], d[1]); m2.collect { |row| (row * y).sum.squared }.sum }.mean;
				if(e > 0) { m2 = m2 * e.sqrt.reciprocal };
				tr = p.tracks.collect { |t, i|
					var am = trackAcn.(p, i);
					(out: base, gains: if(am[0].notNil and: { am[0] < nsh }) { [m2[0][am[0]], m2[1][am[0]]] * am[1] } { [0.0, 0.0] })
				};
			};
			note = note ++ "Stereo downmix → outputs 1–2";
		}
		{ mode == 5 } {
			order = effectiveOrder.(p, 5);
			nsh = (order + 1).squared;
			tr = p.tracks.collect { |t, i|
				var g = 0.0 ! nsh, am;
				if(fmt == \multi) {
					if(t.lfe == true) { g[0] = 1.0 } { g = shSN3D.(order, t.az ? 0, t.el ? 0) };
				} {
					am = trackAcn.(p, i);
					if(am[0].notNil and: { am[0] < nsh }) { g[am[0]] = am[1] };
				};
				(out: base, gains: g)
			};
			note = "Ambisonics B-format (AmbiX: ACN order, SN3D), order % → outputs 1–%".format(order, nsh);
		};
		(mode: mode, tracks: tr, nv: nv, binPos: binPos, note: note, order: order, binArgs: if(nv > 0) { binArgs.(binPos) })
	};

	// apply a changed format / position to the piece that is playing (seamlessly if possible)
	applyRenderLive = { |p|
		var r, sig;
		if(p.notNil and: { playingPiece.() === p }) {
			r = renderPiece.(p);
			sig = [r.mode, r.nv, r.tracks.collect { |x| x.gains.size }];
			if(sig == renderSig) {
				s.makeBundle(nil, {
					r.tracks.do { |x, i| trackNodes[i] !? { |nd| nd.set(\out, x.out, \gains, x.gains) } };
					if(binNode.notNil and: { r.nv > 0 }) { binNode.set(*r.binArgs) };
				});
			} { startPiece.(curIdx, posSec) };
		};
		refreshFormatWidgets.();
	};

	formatChanged = {
		buildMixer.();
		playingPiece.() !? { |p| applyRenderLive.(p) };
		pieces.do { |p| if(p.tracks.any { |t| analysisCache[t.path].notNil }) { pieceStats.(p) } };
		refreshPieceHeader.();
		refreshPlaylist.();
		markDirty.();
	};

	spkChanged = {
		playingPiece.() !? { |p| applyRenderLive.(p) };
		refreshFormatWidgets.();
		markDirty.();
	};

	afterSourceChange = { |p|
		buildMixer.();
		applyRenderLive.(p);
		if(p.tracks.any { |t| analysisCache[t.path].notNil }) { pieceStats.(p); refreshPieceHeader.() };
		refreshPlaylist.();
		markDirty.();
	};

	positionEdited = { |p|
		p.layoutIdx = 7;
		if(selIdx.notNil and: { pieces[selIdx] === p }) { layoutPop.value = 7 };
		applyRenderLive.(p);
		markDirty.();
	};

	// guess the source format / layout from the file names
	detectSource = { |p, paths|
		var names = paths.collect { |x| x.basename.toLower }.join(" "), n = p.tracks.size, sq = n.sqrt.frac == 0;
		case
		{ sq and: { n >= 4 } and: { n <= 16 } and: { ["fuma", "bformat", "b-format", "wxyz"].any { |w| names.contains(w) } } } {
			p.srcFormat = \fuma
		}
		{ sq and: { n >= 4 } and: { ["ambix", "acn", "hoa", "foa", "ambisonic"].any { |w| names.contains(w) } } } {
			p.srcFormat = \ambix
		};
		applyLayoutToPiece.(p, if((n == 2) or: { names.contains("lfe") }) { 3 } { 0 });
	};

	// top-down map: my speakers (squares) and the tracks of the selected piece (blue dots)
	drawMap = { |v|
		var w = v.bounds.width, h = v.bounds.height, cx = w / 2, cy = (h / 2) + 5, rad, pt, p, f9 = Font.sansSerif(9, true), lfeN = 0;
		rad = ((w.min(h) / 2) - 24).max(10);
		pt = { |az, el| var r = rad * cos(el.degrad); Point(cx - (r * sin(az.degrad)), cy - (r * cos(az.degrad))) };
		Pen.width = 1;
		Pen.strokeColor = Color.gray(0.38);
		Pen.addOval(Rect(cx - rad, cy - rad, 2 * rad, 2 * rad));
		Pen.stroke;
		Pen.strokeColor = Color.gray(0.26);
		Pen.addOval(Rect(cx - (rad * 0.5), cy - (rad * 0.5), rad, rad));
		Pen.line(Point(cx - rad, cy), Point(cx + rad, cy));
		Pen.line(Point(cx, cy - rad), Point(cx, cy + rad));
		Pen.stroke;
		"FRONT".drawCenteredIn(Rect(cx - 30, cy - rad - 17, 60, 14), Font.sansSerif(9), cDim);
		"L".drawCenteredIn(Rect(cx - rad - 18, cy - 7, 14, 14), Font.sansSerif(9), cDim);
		"R".drawCenteredIn(Rect(cx + rad + 4, cy - 7, 14, 14), Font.sansSerif(9), cDim);
		Pen.fillColor = Color.gray(0.55);
		Pen.addOval(Rect(cx - 5, cy - 5, 10, 10));
		Pen.fill;
		(prefs.spk ? []).do { |d, k|
			var q, rect;
			if(d[2] == \lfe) { q = Point(12 + (lfeN * 19), h - 12); lfeN = lfeN + 1 } { q = pt.(d[0], d[1]) };
			rect = Rect(q.x - 8, q.y - 8, 16, 16);
			Pen.fillColor = case { d[2] == \lfe } { Color.gray(0.6) } { d[1].abs > 10 } { cYellow } { cOrange };
			Pen.fillRect(rect);
			(k + 1).asString.drawCenteredIn(rect, f9, Color.black);
		};
		p = if(selIdx.notNil) { pieces[selIdx] };
		if(p.notNil and: { (p.srcFormat ? \multi) == \multi }) {
			p.tracks.do { |t, i|
				var q, rect;
				if(t.lfe != true) {
					q = pt.(t.az ? 0, t.el ? 0);
					rect = Rect(q.x - 7, q.y - 7, 14, 14);
					Pen.fillColor = Color.new255(70, 150, 255, 215);
					Pen.addOval(rect);
					Pen.fill;
					(i + 1).asString.drawCenteredIn(rect, f9, Color.white);
				};
			};
		};
	};

	refreshFormatWidgets = {
		var mode = prefs.listen ? 0, p, sp;
		if(win.notNil and: { win.isClosed.not }) {
			formatPop.value = mode;
			orderPop.value = prefs.ambiOrder ? 0;
			orderPop.enabled = [1, 2, 5].includes(mode);
			roomSlider.enabled = mode == 3;
			sp = spkSplit.();
			spkInfoText.string = "% speaker(s)%  ·  %".format(sp[0].size, if(sp[1].notEmpty) { " + sub" } { "" }, layoutNames[prefs.spkPreset ? 0]);
			p = playingPiece.() ?? { if(selIdx.notNil) { pieces[selIdx] } };
			formatInfoText.string = if(p.notNil) { "\"" ++ p.title ++ "\":  " ++ renderPiece.(p).note } { "" };
			mapView !? { mapView.refresh };
			if(spkWin.notNil and: { spkWin.isClosed.not }) { spkWin.refresh };
		};
	};

	openSpeakerWindow = {
		var presetPop, rowsScroll, rebuildRows, map, spkEdited;
		if(spkWin.notNil and: { spkWin.isClosed.not }) { spkWin.front } {
			spkWin = Window("My speakers – " ++ appName, Rect(180, 120, 760, 600));
			map = UserView().minSize_(Size(300, 300)).background_(Color.gray(0.12)).drawFunc_({ |v| drawMap.(v) });
			rowsScroll = ScrollView().hasBorder_(false);
			rebuildRows = {
				var c = View();
				c.layout = VLayout(*(nOuts.collect { |k|
					var d = prefs.spk[k];
					HLayout(
						StaticText().string_("Out " ++ (k + 1)).fixedWidth_(52).font_(Font.sansSerif(11, true)),
						label.("Az"),
						NumberBox().clipLo_(-180).clipHi_(180).decimals_(1).step_(5).scroll_step_(5).value_(d[0]).fixedWidth_(58)
						.action_({ |b| prefs.spk[k] = [b.value, prefs.spk[k][1]] ++ prefs.spk[k].drop(2); spkEdited.() }),
						label.("El"),
						NumberBox().clipLo_(-90).clipHi_(90).decimals_(1).step_(5).scroll_step_(5).value_(d[1]).fixedWidth_(58)
						.action_({ |b| prefs.spk[k] = [prefs.spk[k][0], b.value] ++ prefs.spk[k].drop(2); spkEdited.() }),
						CheckBox().string_("Subwoofer").value_(d[2] == \lfe)
						.action_({ |cb| prefs.spk[k] = prefs.spk[k].keep(2) ++ (if(cb.value) { [\lfe] } { [] }); spkEdited.() }),
						nil
					).spacing_(6)
				} ++ [nil])).spacing_(4).margins_(4);
				rowsScroll.canvas = c;
			};
			spkEdited = { prefs.spkPreset = 7; presetPop.value = 7; map.refresh; spkChanged.() };
			presetPop = PopUpMenu().items_(layoutNames).value_(prefs.spkPreset ? 0)
			.action_({ |m|
				prefs.spkPreset = m.value;
				if(m.value != 7) { prefs.spk = layoutPreset.(m.value, nOuts); rebuildRows.() };
				map.refresh;
				spkChanged.();
			});
			rebuildRows.();
			spkWin.layout = VLayout(
				HLayout(label.("Where are my % speakers?".format(nOuts)).font_(Font.sansSerif(13, true)), presetPop, nil),
				StaticText().stringColor_(cDim).font_(Font.sansSerif(10)).string_(
					"Azimuth: 0 = front, 90 = left, -90 = right, 180 = back.    Elevation: 0 = ear height, 90 = straight up.\n" ++
					"Used by the '3D Ambisonics' and 'VBAP' listening formats. The number of speakers is 'Outputs' in the top bar.\n" ++
					"Squares = your speakers (yellow = elevated).  Blue dots = the tracks of the selected piece."),
				[HLayout([rowsScroll, stretch: 1], [map, stretch: 1]).spacing_(10), stretch: 1]
			).margins_(10).spacing_(8);
			spkWin.front;
		};
	};

	makeBinDef = { |v|
		var name = ("mcpBin" ++ v).asSymbol;
		if(trackDefs.includes(name).not) {
			SynthDef(name, { |in = 0, out = 0, room = 0.2, gate = 1|
				var sig = In.ar(in, v).asArray, l = 0, r = 0, wet, env;
				var dl = \dl.kr(0 ! v), dr = \dr.kr(0 ! v), la = \la.kr(1 ! v), lb = \lb.kr(0 ! v), lc = \lc.kr(0 ! v);
				var ra = \ra.kr(1 ! v), rb = \rb.kr(0 ! v), rc = \rc.kr(0 ! v), sa = \sa.kr(1 ! v), sb = \sb.kr(0 ! v), sc = \sc.kr(0 ! v);
				v.do { |q|
					var x = FOS.ar(sig[q], sa[q], sb[q], sc[q]);
					l = l + FOS.ar(DelayC.ar(x, 0.003, dl[q]), la[q], lb[q], lc[q]);
					r = r + FOS.ar(DelayC.ar(x, 0.003, dr[q]), ra[q], rb[q], rc[q]);
				};
				wet = FreeVerb2.ar(l, r, 1, 0.7, 0.4);
				env = EnvGen.kr(Env.asr(0.01, 1, 0.1), gate, doneAction: 2);
				Out.ar(out, ([l, r] + (wet * Lag.kr(room, 0.1) * 0.5)) * env);
			}).add;
			trackDefs.add(name);
		};
		name
	};

	spatialMath = (sh: shSN3D, layout: layoutPreset, allrad: allradDecoder, vbapSetup: vbapSetup, vbapGains: vbapGains,
		stereo: stereoGains, bin: binCoefs, fib: fibSphere);
	nil
}.value;

// =====================================================================================
//  TRANSPORT
// =====================================================================================

releasePlayback = {
	var nodes = trackNodes, bufs = playBufs, clk = clockNode, bn = binNode, wasPaused = (transport == \paused);
	binNode = nil;
	trackNodes = [];
	playBufs = [];
	clockNode = nil;
	if(serverReady) {
		s.makeBundle(nil, {
			if(wasPaused) { nodes.do { |n| n !? { n.set(\pmul, 0) } }; playGroup.run(true) };
			nodes.do { |n| n !? { n.set(\gate, 0) } };
			bn !? { bn.set(\gate, 0) };
			clk !? { clk.free };
		});
		AppClock.sched(0.4, { bufs.do { |b| b !? { b.close; b.free } }; nil });
	};
};

cancelAdvance = {
	advanceTask !? { advanceTask.stop };
	advanceTask = nil;
	if(transport == \gap) { transport = \stopped };
};

startPiece = { |idx, startSec = 0|
	var p;
	if(serverReady.not) {
		setStatus.("The audio server is not running – press Apply / Reboot.", cRed)
	} {
		if(idx.notNil and: { idx >= 0 } and: { idx < pieces.size }) {
			p = pieces[idx];
			cancelAdvance.();
			releasePlayback.();
			playToken = playToken + 1;
			fork({
				var token = playToken, secs = pieceSecs.(p), defs, bufs, fade, nTr = p.tracks.size, missing, r, binDef;
				startSec = startSec.clip(0, max(secs - 0.1, 0));
				missing = p.tracks.select { |t| t.missing == true }.size;
				r = renderPiece.(p);
				defs = p.tracks.collect { |t, i|
					if(t.missing == true) { nil } { makeTrackDef.(t.nch, (t.sr - s.sampleRate).abs > 1, r.tracks[i].gains.size) }
				};
				binDef = if(r.nv > 0) { makeBinDef.(r.nv) };
				bufs = p.tracks.collect { |t, i|
					defs[i] !? { Buffer.cueSoundFile(s, t.path, (startSec * t.sr).round.asInteger, t.nch, diskBufFrames) }
				};
				s.sync;
				if(token == playToken) {
					fade = if(startSec > 0) { 0.03 } { 0.003 };
					s.makeBundle(0.1, {
						playGroup.run(true);
						trackNodes = p.tracks.collect { |t, i|
							bufs[i] !? { |b|
								Synth(defs[i], [\out, r.tracks[i].out, \gains, r.tracks[i].gains, \buf, b.bufnum, \chan, t.chan,
									\rate, t.sr / s.sampleRate, \gain, gainAmp.(p, t), \on, onAmp.(p, t),
									\fadeIn, fade, \id, i], playGroup)
							}
						};
						binNode = binDef !? { |bd|
							Synth.tail(playGroup, bd, [\in, vBus.index, \out, mixBus.index, \room, prefs.room ? 0.2] ++ r.binArgs)
						};
						clockNode = Synth.tail(playGroup, \mcpClock, [\start, startSec, \secs, secs, \token, token]);
					});
					renderSig = [r.mode, r.nv, r.tracks.collect { |x| x.gains.size }];
					playBufs = bufs;
					curIdx = idx;
					transport = \playing;
					posSec = startSec;
					trkPeak = 0 ! nTr; trkRms = 0 ! nTr; trkHold = 0 ! nTr; trkTime = 0 ! nTr;
					if(missing > 0) { setStatus.("% file(s) of this piece are missing and are skipped.".format(missing), cOrange) };
					if(selIdx != idx) { selectPiece.(idx) } { refreshPlaylist.() };
					refreshFormatWidgets.();
				} {
					bufs.do { |b| b !? { b.close; b.free } };
				};
			}, AppClock);
		};
	};
};

stopPlayback = {
	cancelAdvance.();
	releasePlayback.();
	transport = \stopped;
	curIdx = nil;
	posSec = 0;
	{ refreshPlaylist.() }.defer;
};

pausePlayback = {
	if(transport == \playing) {
		transport = \paused;
		playGroup.set(\pmul, 0);
		AppClock.sched(0.05, { if(transport == \paused) { playGroup.run(false) }; nil });
		refreshPlaylist.();
	};
};

resumePlayback = {
	if(transport == \paused) {
		s.makeBundle(nil, { playGroup.run(true); playGroup.set(\pmul, 1) });
		transport = \playing;
		refreshPlaylist.();
	};
};

playPressed = {
	case
	{ transport == \paused } {
		if(selIdx.notNil and: { selIdx != curIdx }) { startPiece.(selIdx, 0) } { resumePlayback.() }
	}
	{ transport == \playing } {
		if(selIdx.notNil and: { selIdx != curIdx }) { startPiece.(selIdx, 0) }
	}
	{ transport == \gap } { startPiece.(selIdx ? 0, 0) }
	{ pieces.size > 0 } { startPiece.(selIdx ? 0, if(selIdx.notNil) { posSec } { 0 }) };
};

togglePlay = { if(transport == \playing) { pausePlayback.() } { playPressed.() } };

nextPiece = {
	var base;
	if(pieces.size > 0) {
		case
		{ transport == \gap } { startPiece.(selIdx, 0) }
		{ (transport == \playing) or: { transport == \paused } } {
			if(curIdx < (pieces.size - 1)) { startPiece.(curIdx + 1, 0) }
		}
		{ base = selIdx ? -1; posSec = 0; selectPiece.((base + 1).min(pieces.size - 1)) };
	};
};

prevPiece = {
	if(pieces.size > 0) {
		case
		{ (transport == \playing) or: { transport == \paused } } {
			if((posSec > 3) or: { curIdx == 0 }) { startPiece.(curIdx, 0) } { startPiece.(curIdx - 1, 0) }
		}
		{ transport == \gap } { startPiece.((selIdx - 1).max(0), 0) }
		{ posSec = 0; selectPiece.(((selIdx ? 1) - 1).max(0)) };
	};
};

seekTo = { |frac|
	var idx = if((transport == \playing) or: { transport == \paused }) { curIdx } { selIdx }, secs;
	if(idx.notNil) {
		secs = pieceSecs.(pieces[idx]) * frac.clip(0, 1);
		case
		{ transport == \playing } { startPiece.(idx, secs) }
		{ transport == \paused } {
			releasePlayback.();
			transport = \stopped;
			curIdx = nil;
			posSec = secs;
			refreshPlaylist.();
		}
		{ cancelAdvance.(); posSec = secs };
	};
};

onPieceEnd = {
	var next = (curIdx ? -1) + 1;
	releasePlayback.();
	curIdx = nil;
	posSec = 0;
	if((plSet.autoAdvance == true) and: { next < pieces.size }) {
		transport = \gap;
		selectPiece.(next);
		advanceTask = Routine({
			var left = (plSet.gapSec ? 0).asFloat.max(0);
			while { left > 0 } { gapLeft = left; 0.1.wait; left = left - 0.1 };
			advanceTask = nil;
			if(transport == \gap) { startPiece.(next, 0) };
		}).play(AppClock);
	} {
		transport = \stopped;
	};
	refreshPlaylist.();
};

liveTrack = { |p, i|
	var t = p.tracks[i], n;
	if(playingPiece.() === p) {
		n = trackNodes[i];
		n !? { n.set(\gain, gainAmp.(p, t), \on, onAmp.(p, t)) };
	};
};

liveAllTracks = { |p| p.tracks.size.do { |i| liveTrack.(p, i) } };

liveMaster = {
	masterSynth !? {
		masterSynth.set(\amp, if(prefs.masterDb <= minDb) { 0 } { prefs.masterDb.dbamp },
			\lim, if(prefs.limiter == true) { 1 } { 0 });
	};
};

// =====================================================================================
//  LOUDNESS ANALYSIS (EBU R128 / ITU-R BS.1770, rendered offline with scsynth NRT)
// =====================================================================================

cacheKey = { |path|
	(path ++ "|" ++ File.mtime(path).asString ++ "|" ++ File.fileSize(path).asString).hash.abs.asString
};

readAnalysis = { |cfile|
	var sf = SoundFile.openRead(cfile), data, nchA, nf, res;
	if(sf.notNil) {
		nchA = sf.numChannels;
		nf = sf.numFrames;
		data = FloatArray.newClear(nf * nchA);
		sf.readData(data);
		sf.close;
		res = (nchA div: 2).collect { |c|
			var ms = FloatArray.newClear(nf), pk = 0, base = c * 2;
			nf.do { |f|
				var i = (f * nchA) + base;
				ms[f] = data[i].max(0);
				pk = max(pk, data[i + 1]);
			};
			(ms: ms, peak: pk)
		};
	};
	res
};

// one offline render per sound file: writes 10 values per second
// (K-weighted mean square of the last 100 ms, and the running sample peak) for every channel
analyzeFile = { |path, info, action|
	var key = cacheKey.(path), cfile = cacheDir +/+ ("ana_" ++ key ++ ".wav");
	var nch, sr, secs, nb, win, def, score, oscPath, outPath, opts;
	if(File.exists(cfile)) {
		{ action.(readAnalysis.(cfile), key) }.defer;
	} {
		nch = info.nch; sr = info.sr.asInteger; secs = info.secs;
		nb = (secs * 10).ceil.asInteger + 3;
		win = (sr * 0.1).round.asInteger.max(1);
		def = SynthDef(\mcpAnalyze, {
			var sig = DiskIn.ar(nch, 0).asArray;
			var trig = Impulse.kr(10);
			var idx = PulseCount.kr(trig) - 1;
			var vals = sig.collect { |x|
				var k = BHiPass.ar(BHiShelf.ar(x, 1681.974, 1, 3.99984), 38.13547, 1.99869);
				[A2K.kr(RunningSum.ar(k.squared, win) / win), A2K.kr(RunningMax.ar(x.abs))]
			}.flatten;
			BufWr.kr(vals, 1, idx, 0);
		});
		oscPath = Platform.defaultTempDir +/+ ("mcp_" ++ key ++ ".osc");
		outPath = if(platformName == \windows) { Platform.defaultTempDir +/+ ("mcp_" ++ key ++ "_null.aiff") } { "/dev/null" };
		opts = ServerOptions.new.numOutputBusChannels_(1).numInputBusChannels_(0).memSize_(65536);
		score = Score([
			[0.0, [\d_recv, def.asBytes]],
			[0.0, [\b_alloc, 0, 65536, nch]],
			[0.0, [\b_read, 0, path, 0, 65536, 0, 1]],
			[0.0, [\b_alloc, 1, nb, nch * 2]],
			[0.0, [\s_new, \mcpAnalyze, 1000, 0, 0]],
			[secs + 0.25, [\b_write, 1, cfile, "wav", "float"]],
			[secs + 0.3, [\c_set, 0, 0]]
		]);
		score.recordNRT(oscPath, outPath, nil, sr, "AIFF", "int8", opts, "", secs + 0.3, {
			{
				try { File.delete(oscPath) };
				if(platformName == \windows) { try { File.delete(outPath) } };
				action.(if(File.exists(cfile)) { readAnalysis.(cfile) }, key);
			}.defer;
		});
	};
};

// integrated loudness with absolute (-70 LUFS) and relative (-10 LU) gating,
// z = mean-square energy per 100 ms (400 ms blocks with 75 % overlap)
gatedLoudness = { |z|
	var n = z.size, blocks, absE, sel, relE;
	if(n == 0) { -inf } {
		blocks = if(n < 4) { [z.sum / n] } {
			(0..(n - 4)).collect { |j| (z[j] + z[j + 1] + z[j + 2] + z[j + 3]) * 0.25 }
		};
		absE = 10 ** ((-70 + 0.691) / 10);
		sel = blocks.select { |e| e > absE };
		if(sel.isEmpty) { -inf } {
			relE = sel.mean * 0.1;
			sel = sel.select { |e| e > relE };
			-0.691 + (10 * sel.mean.log10)
		}
	}
};

// loudness and peak of a whole piece with the current track faders (without the piece trim)
pieceStats = { |p|
	var n = 0, z, acc = Dictionary.new, pk = 0, any = false, anas, r, isMulti = (p.srcFormat ? \multi) == \multi;
	anas = p.tracks.collect { |t|
		var a = analysisCache[t.path];
		if(a.notNil) { a.res[t.chan] }
	};
	p.tracks.do { |t, i|
		var a = anas[i];
		if(a.notNil) {
			t.lufs = gatedLoudness.(a.ms);
			t.peakDb = a.peak.ampdb;
			n = max(n, a.ms.size);
		};
	};
	if(anas.any(_.notNil)) {
		z = FloatArray.newClear(n);
		p.tracks.do { |t, i|
			var a = anas[i], g2, am;
			if(a.notNil and: { t.mute != true } and: { t.db > minDb }) {
				g2 = t.db.dbamp.squared;
				if(isMulti) {
					any = true;
					a.ms.do { |v, k| z[k] = z[k] + (v * g2) };
				} {
					// Ambisonics: the loudness of the sound field is the loudness of W
					am = trackAcn.(p, i);
					if(am[0] == 0) { any = true; g2 = g2 * am[1].squared; a.ms.do { |v, k| z[k] = z[k] + (v * g2) } };
				};
			};
		};
		// peak estimate at the outputs for the current listening format
		r = renderPiece.(p);
		p.tracks.do { |t, i|
			var a = anas[i], amp;
			if(a.notNil and: { t.mute != true } and: { t.db > minDb }) {
				amp = a.peak * t.db.dbamp;
				r.tracks[i].gains.do { |g, j|
					var key = r.tracks[i].out + j;
					acc[key] = (acc[key] ? 0) + (if(r.mode == 0) { g.abs * amp } { (g * amp).squared });
				};
			};
		};
		if(r.mode == 3) { pk = (acc.values.sum ? 0).sqrt * 1.41 } {
			acc.do { |v| pk = max(pk, if(r.mode == 0) { v } { v.sqrt }) };
		};
		p.lufs = if(any) { gatedLoudness.(z) } { -inf };
		p.peakDb = pk.ampdb;
	};
	p
};

balancePiece = { |p|
	var ok = if((p.srcFormat ? \multi) != \multi) { [] } { p.tracks }.select { |t| (t.mute != true) and: { t.lufs.notNil } and: { t.lufs > -70 } }, ref;
	if(ok.size > 1) {
		ref = 10 * (ok.collect { |t| 10 ** (t.lufs / 10) }.mean).log10;
		ok.do { |t| t.db = (ref - t.lufs).clip(-9, 9).round(0.1) };
	};
};

analyzeAll = { |onDone|
	var jobs = [], seen = Set.new, total, finished = 0, running = 0, launch;
	pieces.do { |p|
		p.tracks.do { |t|
			if((t.missing != true) and: { seen.includes(t.path).not }) {
				seen.add(t.path);
				if(analysisCache[t.path].isNil or: { analysisCache[t.path].key != cacheKey.(t.path) }) {
					jobs = jobs.add((path: t.path, info: (nch: t.nch, sr: t.sr, secs: t.secs)));
				};
			};
		};
	};
	total = jobs.size;
	launch = {
		while { (running < 3) and: { jobs.size > 0 } } {
			var job = jobs.removeAt(0);
			running = running + 1;
			analyzeFile.(job.path, job.info, { |res, key|
				running = running - 1;
				finished = finished + 1;
				if(res.notNil) { analysisCache[job.path] = (key: key, res: res) } {
					("Multichannel Player: analysis failed for " ++ job.path).warn
				};
				anaText.string = "Analysing sound files… % / %".format(finished, total);
				if(finished >= total) { onDone.() } { launch.() };
			});
		};
	};
	if(total == 0) { onDone.() } {
		anaText.string = "Analysing sound files… 0 / %".format(total);
		launch.();
	};
};

autoLevel = {
	if(analyzing.not and: { pieces.size > 0 }) {
		analyzing = true;
		analyzeBtn.enabled = false;
		undoSnapshot = pieces.collect { |p| [p, p.trimDb, p.tracks.collect { |t| [t, t.db] }] };
		analyzeAll.({
			var target, ceil = (plSet.ceilDb ? -1).asFloat, limitedCount = 0, ok;
			pieces.do { |p|
				pieceStats.(p);
				if(plSet.balance == true) { balancePiece.(p); pieceStats.(p) };
			};
			ok = pieces.select { |p| p.lufs.notNil and: { p.lufs > -70 } };
			if(ok.isEmpty) {
				anaText.string = "Nothing to level (no readable audio, or only silence).";
			} {
				target = targetValues[plSet.targetIdx ? 0];
				if(target.isNil) { target = ok.collect { |p| p.lufs + (ceil - p.peakDb) }.minItem };
				ok.do { |p|
					var want = target - p.lufs, allowed = ceil - p.peakDb, trim;
					trim = want.min(allowed).clip(-30, 24);
					p.limited = (want - trim) > 0.1;
					if(p.limited) { limitedCount = limitedCount + 1 };
					p.trimDb = trim.round(0.1);
				};
				anaText.string = "Done. Target % LUFS – % piece(s) levelled%. Peaks stay below % dBFS."
				.format(fmtDb.(target), ok.size,
					if(limitedCount > 0) { ", % could not reach the target without clipping".format(limitedCount) } { "" },
					fmtDb.(ceil));
			};
			analyzing = false;
			analyzeBtn.enabled = true;
			playingPiece.() !? { |p| liveAllTracks.(p) };
			buildMixer.();
			refreshPlaylist.();
			markDirty.();
		});
	};
};

undoAutoLevel = {
	if(undoSnapshot.notNil) {
		undoSnapshot.do { |e| e[0].trimDb = e[1]; e[2].do { |tv| tv[0].db = tv[1] } };
		undoSnapshot = nil;
		pieces.do { |p| if(p.tracks.any { |t| analysisCache[t.path].notNil }) { pieceStats.(p) } };
		playingPiece.() !? { |p| liveAllTracks.(p) };
		anaText.string = "Levels restored to how they were before the last auto-level.";
		buildMixer.();
		refreshPlaylist.();
		markDirty.();
	} { anaText.string = "Nothing to undo." };
};

// =====================================================================================
//  PLAYLIST EDITING
// =====================================================================================

addPieceFromFiles = { |paths, title|
	var tracks = makeTracksFromFiles.(paths), p;
	if(tracks.size == 0) { setStatus.("No readable audio files were found.", cOrange); nil } {
		p = (title: title ?? { guessTitle.(paths.select(isAudio)) }, trimDb: 0.0, tracks: tracks, limited: false,
			srcFormat: \multi, layoutIdx: 0);
		detectSource.(p, paths.select(isAudio));
		pieces = pieces.add(p);
		selectPiece.(pieces.size - 1);
		markDirty.();
		case
		{ (tracks.size > nOuts) and: { (prefs.listen ? 0) == 0 } } {
			setStatus.("\"%\" has % tracks but only % output(s): choose a listening format (Ambisonics, VBAP, binaural, stereo) or more outputs."
				.format(p.title, tracks.size, nOuts), cOrange)
		}
		{ p.srcFormat != \multi } {
			setStatus.("Added \"%\" as an Ambisonic piece (%, order %).".format(p.title, p.srcFormat, srcOrder.(p)), cGreen)
		}
		{ serverReady and: { tracks.any { |t| (t.sr - s.sampleRate).abs > 1 } } } {
			setStatus.("Note: some files are not at % Hz and will be resampled while playing.".format(s.sampleRate.round), cOrange)
		}
		{ setStatus.("Added \"%\" (% tracks).".format(p.title, tracks.size), cGreen) };
		p
	};
};

addFolderPiece = { |dir|
	var files = PathName(dir.withTrailingSlash).files.collect(_.fullPath).select(isAudio);
	if(files.isEmpty) { setStatus.("No audio files in " ++ dir, cOrange) } {
		addPieceFromFiles.(files, dir.withoutTrailingSlash.basename)
	};
};

addFolderOfPieces = { |dir|
	var subs = PathName(dir.withTrailingSlash).folders.sort { |a, b| natKey.(a.folderName) <= natKey.(b.folderName) }, n = 0;
	subs.do { |sub|
		var files = sub.files.collect(_.fullPath).select(isAudio);
		if(files.notEmpty) { addPieceFromFiles.(files, sub.folderName); n = n + 1 };
	};
	if(n == 0) { addFolderPiece.(dir) } { setStatus.("Added % pieces.".format(n), cGreen) };
};

addTracksToPiece = { |paths|
	var p = if(selIdx.notNil) { pieces[selIdx] }, tracks;
	if(p.notNil) {
		if(playingPiece.() === p) { setStatus.("Stop this piece before adding tracks to it.", cOrange) } {
			tracks = makeTracksFromFiles.(paths, p.tracks.size);
			p.tracks = p.tracks ++ tracks;
			if((p.layoutIdx ? 0) != 7) { applyLayoutToPiece.(p, p.layoutIdx ? 0) } { tracks.do { |t| t.az = 0; t.el = 0; t.lfe = false } };
			buildMixer.();
			refreshPlaylist.();
			markDirty.();
		};
	};
};

removeTrack = { |p, i|
	if(playingPiece.() === p) { setStatus.("Stop this piece before removing tracks from it.", cOrange) } {
		p.tracks.removeAt(i);
		if((p.layoutIdx ? 0) != 7) { applyLayoutToPiece.(p, p.layoutIdx ? 0) };
		buildMixer.();
		refreshPlaylist.();
		markDirty.();
	};
};

selectPiece = { |idx, updateList = true|
	if(idx != selIdx) {
		selIdx = idx;
		if(transport == \stopped) { posSec = 0 };
		buildMixer.();
	};
	if(updateList) { refreshPlaylist.() };
};

// =====================================================================================
//  GUI
// =====================================================================================

mkBtn = { |str, action| Button().states_([[str]]).action_(action).canFocus_(false) };
label = { |str| StaticText().string_(str) };
panel = { |layout| View().background_(cPanel).layout_(layout) };

refreshPlaylist = {
	var items;
	if(plList.notNil and: { plList.isClosed.not }) {
		items = pieces.collect { |p, i|
			var mark = if(i == curIdx) { if(transport == \paused) { "❚❚ " } { "▶ " } } { "     " };
			var lu = if(p.lufs.notNil and: { p.lufs > -70 }) { "  · % LUFS".format(fmtDb.(p.lufs + (p.trimDb ? 0))) } { "" };
			var warn = if(p.tracks.any { |t| t.missing == true }) { "  ⚠ missing file" } { "" };
			"%%. %   (% tr · %%)%".format(mark, i + 1, p.title, p.tracks.size, fmtTime.(pieceSecs.(p)), lu, warn)
		};
		plList.items = items;
		if(selIdx.notNil and: { selIdx < pieces.size }) { plList.value = selIdx };
		plNameText.string = "PLAYLIST:  " ++ playlistPath.basename.splitext[0];
		plInfoText.string = "% piece(s) · total time %   ·   saved automatically".format(pieces.size, fmtTime.(pieces.collect(pieceSecs).sum));
	};
};

refreshSettingsWidgets = {
	if(win.notNil and: { win.isClosed.not }) {
		autoAdvBox.value = plSet.autoAdvance == true;
		gapBox.value = plSet.gapSec ? 3;
		targetPop.value = plSet.targetIdx ? 0;
		ceilBox.value = plSet.ceilDb ? -1;
		balanceBox.value = plSet.balance == true;
	};
};

makeStrip = { |p, t, i|
	var box, numT, nameT, outPop, meter, fader, num, peakT, muteB, soloB, anaT, delB, nm, route, azBox, elBox, lfeB;
	nm = t.path.basename.splitext[0] ++ (if(t.nch > 1) { " [ch " ++ (t.chan + 1) ++ "]" } { "" });
	numT = StaticText().string_("" ++ (i + 1)).font_(Font.sansSerif(14, true));
	delB = Button().states_([["✕"]]).fixedSize_(Size(22, 20)).canFocus_(false)
	.toolTip_("Remove this track from the piece").action_({ removeTrack.(p, i) });
	nameT = StaticText().string_(nm).align_(\center).font_(Font.sansSerif(10)).toolTip_(t.path).fixedHeight_(30);
	if(t.missing == true) { nameT.string = "MISSING: " ++ nm; nameT.stringColor = cRed };
	outPop = PopUpMenu().items_(nOuts.collect { |k| "→ out " ++ (k + 1) }).value_(outFor.(t)).font_(Font.sansSerif(10))
	.action_({ |m| t.outCh = m.value; applyRenderLive.(p); markDirty.() });
	route = case
	{ (prefs.listen ? 0) == 0 } { outPop }
	{ (p.srcFormat ? \multi) == \multi } {
		azBox = NumberBox().clipLo_(-180).clipHi_(180).decimals_(0).step_(5).scroll_step_(5).value_(t.az ? 0)
		.font_(Font.sansSerif(9)).align_(\center).toolTip_("Azimuth (degrees): 0 = front, 90 = left, -90 = right, 180 = back")
		.action_({ |b| t.az = b.value; positionEdited.(p) });
		elBox = NumberBox().clipLo_(-90).clipHi_(90).decimals_(0).step_(5).scroll_step_(5).value_(t.el ? 0)
		.font_(Font.sansSerif(9)).align_(\center).toolTip_("Elevation (degrees): 0 = ear height, 90 = straight up")
		.action_({ |b| t.el = b.value; positionEdited.(p) });
		lfeB = Button().states_([["LFE"], ["LFE", Color.black, cOrange]]).value_(if(t.lfe == true) { 1 } { 0 })
		.canFocus_(false).font_(Font.sansSerif(8)).fixedWidth_(28)
		.toolTip_("Low-frequency (subwoofer) channel: not placed in space, sent to your subwoofer(s)")
		.action_({ |b| t.lfe = b.value == 1; positionEdited.(p) });
		View().layout_(VLayout(
			StaticText().string_("  az°        el°").font_(Font.sansSerif(8)).stringColor_(cDim),
			HLayout(azBox, elBox, lfeB).spacing_(2).margins_(0)
		).spacing_(0).margins_(0))
	}
	{ StaticText().string_(acnLabel.(p, i)).align_(\center).font_(Font.sansSerif(9)).stringColor_(cBlue).fixedHeight_(26) };
	meter = LevelIndicator().fixedWidth_(14).drawsPeak_(true).warning_(0.9).critical_(0.99)
	.toolTip_("Level of this track (after its fader). Scale: -60 … 0 dBFS");
	fader = Slider().orientation_(\vertical).value_(dbSpec.unmap(t.db)).minHeight_(140)
	.background_(Color.gray(0.33)).knobColor_(Color.gray(0.85))
	.toolTip_("Track volume. Double-click = 0 dB")
	.action_({ |sl| t.db = dbSpec.map(sl.value).round(0.1); num.value = t.db; liveTrack.(p, i); markDirty.() })
	.mouseDownAction_({ |sl, x, y, mod, bn, cc|
		if(cc == 2) { t.db = 0.0; sl.value = dbSpec.unmap(0); num.value = 0; liveTrack.(p, i); markDirty.(); true } { nil }
	});
	num = NumberBox().value_(t.db).decimals_(1).clipLo_(minDb).clipHi_(maxDb).step_(0.5).scroll_step_(0.5)
	.align_(\center).toolTip_("Track volume in dB (-60 = off)")
	.action_({ |nb| t.db = nb.value; fader.value = dbSpec.unmap(t.db); liveTrack.(p, i); markDirty.() });
	peakT = StaticText().string_("pk --").align_(\center).font_(Font.monospace(10))
	.toolTip_("Highest peak since the piece started (click to reset). Red = clipping")
	.mouseDownAction_({ if(trkHold.size > i) { trkHold[i] = 0 }; nil });
	muteB = Button().states_([["M"], ["M", Color.black, cYellow]]).value_(if(t.mute == true) { 1 } { 0 }).canFocus_(false)
	.toolTip_("Mute").action_({ |b| t.mute = b.value == 1; liveTrack.(p, i); markDirty.() });
	soloB = Button().states_([["S"], ["S", Color.black, cGreen]]).value_(if(t.solo == true) { 1 } { 0 }).canFocus_(false)
	.toolTip_("Solo").action_({ |b| t.solo = b.value == 1; liveAllTracks.(p); markDirty.() });
	anaT = StaticText().string_("").align_(\center).font_(Font.sansSerif(9)).stringColor_(cDim).fixedHeight_(28);
	box = View().background_(cStrip).fixedWidth_(100);
	box.layout = VLayout(
		HLayout(numT, nil, delB),
		nameT, route,
		[HLayout(meter, fader).spacing_(6).margins_(0), stretch: 1],
		num, peakT, HLayout(muteB, soloB).spacing_(2), anaT
	).margins_(5).spacing_(3);
	(box: box, meter: meter, fader: fader, num: num, peakT: peakT, anaT: anaT, lastPk: -1)
};

buildMixer = {
	var canvas, p;
	if(win.notNil and: { win.isClosed.not }) {
		p = if(selIdx.notNil) { pieces[selIdx] };
		canvas = View();
		strips = [];
		if(p.isNil) {
			canvas.layout = VLayout(nil, StaticText().align_(\center).stringColor_(cDim).string_(
				"No piece selected.\n\nAdd a piece with  \"+ Piece (files)…\"  and select the mono files of ONE piece\n" ++
				"(for example the 4 files of a 4-channel piece). Track 1 goes to output 1, track 2 to output 2 …"), nil);
		} {
			strips = p.tracks.collect { |t, i| makeStrip.(p, t, i) };
			canvas.layout = HLayout(*(strips.collect { |st| st[\box] } ++ [nil])).spacing_(5).margins_(5);
		};
		mixerScroll.canvas = canvas;
		if(playingPiece.() !== p) { trkHold = 0 ! strips.size };
		refreshPieceHeader.();
	};
};

refreshPieceHeader = {
	var p = if(selIdx.notNil) { pieces[selIdx] }, info;
	if(win.notNil and: { win.isClosed.not }) {
		[titleField, trimSlider, trimNum, srcPop, layoutPop].do { |v| v.enabled = p.notNil };
		if(p.isNil) {
			titleField.string = "";
			pieceInfoText.string = "";
			trimSlider.value = trimSpec.unmap(0);
			trimNum.value = 0;
		} {
			titleField.string = p.title;
			trimSlider.value = trimSpec.unmap(p.trimDb ? 0);
			trimNum.value = p.trimDb ? 0;
			info = "% track(s) · %".format(p.tracks.size, fmtTime.(pieceSecs.(p)));
			info = info ++ if(p.lufs.notNil and: { p.lufs > -70 }) {
				"   ·   loudness % LUFS, peak % dBFS  →  with trim: % LUFS, peak % dBFS%".format(
					fmtDb.(p.lufs), fmtDb.(p.peakDb), fmtDb.(p.lufs + (p.trimDb ? 0)), fmtDb.(p.peakDb + (p.trimDb ? 0)),
					if(p.limited == true) { "  (limited by peak ceiling)" } { "" })
			} { "   ·   not analysed yet" };
			pieceInfoText.string = info;
			srcPop.value = srcFormats.indexOf(p.srcFormat ? \multi) ? 0;
			layoutPop.value = p.layoutIdx ? 0;
			layoutPop.enabled = (p.srcFormat ? \multi) == \multi;
			strips.do { |st, i|
				var t = p.tracks[i];
				st.anaT.string = if(t.lufs.notNil) { "file: % LUFS\npeak % dBFS".format(fmtDb.(t.lufs), fmtDb.(t.peakDb)) } { "" };
			};
		};
		refreshFormatWidgets.();
	};
};

makeMeterRow = { |n, width, height|
	var ms = n.collect { |k|
		(meter: LevelIndicator().fixedWidth_(width).drawsPeak_(true).warning_(0.9).critical_(0.99).minHeight_(height),
			lab: StaticText().string_("" ++ (k + 1)).align_(\center).font_(Font.sansSerif(9)),
			pkT: StaticText().string_("").align_(\center).font_(Font.monospace(8))
			.toolTip_("Highest peak (click to reset)").mouseDownAction_({ if(outHold.size > k) { outHold[k] = 0 }; nil }),
			lastPk: -1)
	};
	var v = View();
	v.layout = HLayout(*(ms.collect { |o| VLayout([o.meter, stretch: 1], o.lab, o.pkT).spacing_(1).margins_(0) } ++ [nil]))
	.spacing_(if(n > 12) { 2 } { 4 }).margins_(2);
	[v, ms]
};

buildOutMeters = {
	var r;
	if(win.notNil and: { win.isClosed.not }) {
		r = makeMeterRow.(nOuts, if(nOuts > 12) { 8 } { 12 }, 120);
		outScroll.canvas = r[0];
		outMeters = r[1];
	};
};

refreshGui = {
	var now = Main.elapsedTime, live, p, secs, str, col, upd;
	if(win.notNil and: { win.isClosed.not }) {
		live = (curIdx.notNil) and: { curIdx == selIdx } and: { (transport == \playing) or: { transport == \paused } };
		strips.do { |st, i|
			var pk = 0, rms = 0, hold;
			if(live and: { (now - (trkTime[i] ? 0)) < 0.25 }) { pk = trkPeak[i] ? 0; rms = trkRms[i] ? 0 };
			st.meter.value = ampToMeter.(rms);
			st.meter.peakLevel = ampToMeter.(pk);
			hold = if(live) { trkHold[i] ? 0 } { 0 };
			if(hold != st.lastPk) {
				st.lastPk = hold;
				st.peakT.string = if(hold > 0) { "pk " ++ fmtDb.(hold.ampdb) } { "pk --" };
				st.peakT.stringColor = if(hold >= 0.999) { cRed } { cText };
			};
		};
		upd = { |arr|
			arr.do { |o, k|
				var pk = 0, rms = 0, hold = outHold[k] ? 0;
				if((now - (outTime[k] ? 0)) < 0.25) { pk = outPeak[k] ? 0; rms = outRms[k] ? 0 };
				o.meter.value = ampToMeter.(rms);
				o.meter.peakLevel = ampToMeter.(pk);
				if(hold != o.lastPk) {
					o.lastPk = hold;
					o.pkT.string = if(hold > 0) { fmtDb.(hold.ampdb) } { "" };
					o.pkT.stringColor = if(hold >= 0.999) { cRed } { cDim };
				};
			};
		};
		upd.(outMeters);
		if(testWin.notNil and: { testWin.isClosed.not }) { upd.(testMeters) };

		p = if(curIdx.notNil) { pieces[curIdx] } { if(selIdx.notNil) { pieces[selIdx] } };
		secs = if(p.notNil) { pieceSecs.(p) } { 0 };
		if(posDragging.not) {
			posSlider.value = if(secs > 0) { (posSec / secs).clip(0, 1) } { 0 };
			timeText.string = fmtTime.(posSec) ++ " / " ++ fmtTime.(secs);
		};
		case
		{ transport == \playing } { str = "▶  PLAYING  " ++ (curIdx + 1); col = cGreen }
		{ transport == \paused } { str = "❚❚  PAUSED  " ++ (curIdx + 1); col = cYellow }
		{ transport == \gap } { str = "NEXT PIECE IN " ++ gapLeft.round(0.1).asString ++ " s"; col = cBlue }
		{ str = "■  STOPPED"; col = cDim };
		if(str != lastStateStr) { lastStateStr = str; stateText.string = str; stateText.stringColor = col };

		if(serverReady and: { (now - statusTime) > 6 } and: { (now - lastCpu) > 1 }) {
			lastCpu = now;
			statusText.stringColor = cDim;
			statusText.string = "Server: % Hz · % output(s) from hardware out % · CPU % %"
			.format(s.sampleRate.round, nOuts, outOff + 1, s.avgCPU.round(0.1), "%");
		};
	};
};

showHelp = {
	if(helpWin.notNil and: { helpWin.isClosed.not }) { helpWin.front } {
		helpWin = Window("Help – " ++ appName, Rect(220, 160, 640, 560));
		helpWin.layout = VLayout(TextView().editable_(false).font_(Font.sansSerif(12)).string_(
			"MULTICHANNEL PLAYER – QUICK GUIDE\n\n" ++
			"SET UP THE OUTPUTS\n" ++
			"  Outputs = how many speakers (4 for quad). First output = the first interface output to use.\n" ++
			"  Choose the Device and press Apply / Reboot. These settings are remembered.\n\n" ++
			"BUILD A PLAYLIST\n" ++
			"  + Piece (files)…   select the mono files of ONE piece (Cmd/Ctrl- or Shift-click to select several).\n" ++
			"  + Piece (folder)…  a folder holding the mono files of one piece.\n" ++
			"  + Many pieces…     a folder that holds one sub-folder per piece (e.g. 10 folders = 10 pieces).\n" ++
			"  Files are sorted by name (…_1, …_2, …_10 sort correctly). Track N goes to output N; change it\n" ++
			"  with the '→ out' menu of the strip. Stereo / multichannel files are split into one track per channel.\n" ++
			"  Rename a piece in the title field above the mixer. Move up / down changes the order.\n\n" ++
			"PLAY\n" ++
			"  Play / Pause / Stop / Prev / Next, or Space for play-pause. Double-click a piece to play it.\n" ++
			"  Drag the position bar to jump. 'Auto-advance' starts the next piece after the gap (seconds).\n\n" ++
			"VOLUMES (all saved automatically, per piece)\n" ++
			"  Each track has a fader (double-click = 0 dB), a number box, Mute and Solo, and a meter.\n" ++
			"  'pk' shows the highest peak since the piece started (red = clipping, click to reset).\n" ++
			"  Piece trim = one extra volume for the whole piece (this is what Auto-Level sets).\n" ++
			"  Master = overall volume. The safety limiter only acts if the output would clip.\n\n" ++
			"AUTO-LEVEL\n" ++
			"  Measures every file offline (EBU R128 loudness in LUFS + peak). Then every piece gets a trim so\n" ++
			"  that all pieces have the same loudness, and no piece goes above the peak ceiling.\n" ++
			"  'Auto' chooses the loudest level that ALL pieces can reach without clipping.\n" ++
			"  'Also balance the tracks…' additionally evens out the tracks inside each piece (changes faders,\n" ++
			"  max ±9 dB) – leave it off if the balance between channels is part of the composition.\n" ++
			"  Undo restores the previous levels. Analysis results are cached in:\n  " ++ cacheDir ++ "\n\n" ++
			"LISTENING FORMATS (bar under the top bar)\n" ++
			"  Pieces can have any number of tracks. Choose how you listen:\n" ++
			"  • Multichannel – direct: track N → output N, untouched (the '→ out' menu of a strip changes it).\n" ++
			"  • 3D Ambisonics → my speakers: every track is encoded at its position (azimuth / elevation) and decoded\n" ++
			"    to YOUR speakers with an AllRAD decoder (max-rE). An 8-, 16- or 18-channel piece plays on 4, 5, 8 … speakers.\n" ++
			"    Order: Auto uses the highest order your speakers support; you can force 1st – 5th.\n" ++
			"  • Amplitude panning (VBAP) → my speakers: every track is panned between the 2–3 nearest speakers.\n" ++
			"  • Binaural → headphones: spherical-head model (time and level differences between the ears, head\n" ++
			"    shadow, front/back cue); 'Room' adds a little reverberation so the sound is outside the head.\n" ++
			"  • Stereo downmix → 2 speakers: front/back folded, sides go fully left / right.\n" ++
			"  • Ambisonics B-format out: AmbiX (ACN, SN3D) on outputs 1 … (order+1)², for an external decoder or recording.\n" ++
			"  SOURCE FORMAT (above the mixer, per piece):\n" ++
			"  • Multichannel (speaker feeds) + Layout: where the composer's speakers were – ring from front-left,\n" ++
			"    ring from front, pairs (L R L R …), standard stereo / quad / 5.1 / 7.1, two rings, dome, sphere, or\n" ++
			"    your own angles (type az / el in each strip; 'LFE' marks a subwoofer channel).\n" ++
			"  • Ambisonics AmbiX (ACN / SN3D) or FuMa: 4 files = 1st order, 9 = 2nd, 16 = 3rd, 25 = 4th, 36 = 5th,\n" ++
			"    in channel order. Files with 'ambix', 'acn', 'foa', 'hoa' or 'fuma' in the name are recognised.\n" ++
			"  My speakers…: positions of your speakers (presets or your own angles; tick 'Subwoofer' for LFE).\n\n" ++
			"SPEAKER TEST\n" ++
			"  Send pink noise / band-limited pink noise (500 Hz–2 kHz, for SPL calibration) / white noise / sine\n" ++
			"  to single speakers, to all, or cycle through them. Levels are RMS dBFS. A usual calibration:\n" ++
			"  band-limited pink noise at -20 dBFS RMS, then set every speaker to the same SPL with a meter.\n" ++
			"  The test signal goes through the master volume and the output meters.\n\n" ++
			"FILES\n" ++
			"  Playlists: " ++ appDir ++ "\n" ++
			"  If a sound file was moved, the piece shows '⚠ missing file'; add it again with + Tracks….\n\n" ++
			"Cmd+. / Ctrl+. stops all sound; the player recovers by itself."
		)).margins_(8);
		helpWin.front;
	};
};

// ---------------- speaker test window
testOn = { |k|
	if(serverReady and: { k < nOuts }) {
		if(testNodes[k].isNil) {
			testNodes[k] = Synth(\mcpTest, [\out, mixBus.index + k, \amp, prefs.testDb.dbamp,
				\type, prefs.testType, \freq, prefs.testFreq], testGroup);
		};
	};
	testUpdateButtons.();
};

testOff = { |k|
	if(k < testNodes.size) {
		testNodes[k] !? { |n| n.set(\gate, 0) };
		testNodes[k] = nil;
	};
	testUpdateButtons.();
};

testAllOff = { testNodes.size.do { |k| testOff.(k) } };

testUpdateButtons = {
	{
		testButtons.do { |b, k|
			if(b.isClosed.not) { b.value = if(testNodes[k].notNil) { 1 } { 0 } };
		};
	}.defer;
};

startCycle = {
	stopCycle.();
	testCycleTask = Routine({
		var k = 0;
		loop {
			testAllOff.();
			testOn.(k);
			(prefs.cycleSec ? 2).max(0.5).wait;
			k = (k + 1) % nOuts;
		};
	}).play(AppClock);
	if(testCycleBtn.notNil and: { testCycleBtn.isClosed.not }) { testCycleBtn.value = 1 };
};

stopCycle = {
	testCycleTask !? { testCycleTask.stop };
	testCycleTask = nil;
	if(testCycleBtn.notNil and: { testCycleBtn.isClosed.not }) { testCycleBtn.value = 0 };
};

openTestWindow = {
	var rows, r, perRow;
	if(testWin.notNil and: { testWin.isClosed.not }) { testWin.front } {
		testWin = Window("Speaker Test – " ++ appName, Rect(160, 140, 680, 560));
		testTypePop = PopUpMenu().items_(testNames).value_(prefs.testType ? 0)
		.action_({ |m| prefs.testType = m.value; if(serverReady) { testGroup.set(\type, m.value) }; markDirty.() });
		testFreqBox = NumberBox().clipLo_(20).clipHi_(20000).decimals_(0).step_(10).scroll_step_(10)
		.value_(prefs.testFreq ? 1000).fixedWidth_(70)
		.action_({ |b| prefs.testFreq = b.value; if(serverReady) { testGroup.set(\freq, b.value) }; markDirty.() });
		testLevelSlider = Slider().orientation_(\horizontal).value_(testSpec.unmap(prefs.testDb ? -20))
		.background_(Color.gray(0.33)).knobColor_(Color.gray(0.85))
		.action_({ |sl|
			prefs.testDb = testSpec.map(sl.value);
			testLevelNum.value = prefs.testDb;
			if(serverReady) { testGroup.set(\amp, prefs.testDb.dbamp) };
			markDirty.();
		});
		testLevelNum = NumberBox().clipLo_(-60).clipHi_(-6).decimals_(1).step_(0.5).scroll_step_(0.5)
		.value_(prefs.testDb ? -20).fixedWidth_(60)
		.action_({ |b|
			prefs.testDb = b.value;
			testLevelSlider.value = testSpec.unmap(b.value);
			if(serverReady) { testGroup.set(\amp, prefs.testDb.dbamp) };
			markDirty.();
		});
		testButtons = nOuts.collect { |k|
			Button().states_([[(if(nOuts > 16) { "" } { "Speaker " }) ++ (k + 1)], [(if(nOuts > 16) { "" } { "Speaker " }) ++ (k + 1), Color.black, cGreen]])
			.canFocus_(false).minHeight_(if(nOuts > 16) { 24 } { 36 })
			.action_({ |b| stopCycle.(); if(b.value == 1) { testOn.(k) } { testOff.(k) } })
		};
		perRow = if(nOuts > 16) { 8 } { 4 };
		rows = testButtons.clump(perRow).collect { |row| HLayout(*(row ++ (nil ! (perRow - row.size)))).spacing_(4) };
		testCycleBtn = Button().states_([["Cycle through speakers ▶"], ["Stop cycling ■", Color.black, cYellow]])
		.canFocus_(false).action_({ |b| if(b.value == 1) { startCycle.() } { stopCycle.(); testAllOff.() } });
		testCycleBox = NumberBox().clipLo_(0.5).clipHi_(60).decimals_(1).step_(0.5).value_(prefs.cycleSec ? 2).fixedWidth_(50)
		.action_({ |b| prefs.cycleSec = b.value; markDirty.() });
		r = makeMeterRow.(nOuts, if(nOuts > 12) { 10 } { 18 }, 150);
		testMeters = r[1];
		testScroll = ScrollView().hasBorder_(false).canvas_(r[0]);
		testWin.layout = VLayout(
			HLayout(label.("Signal"), testTypePop, label.("   Sine frequency (Hz)"), testFreqBox, nil),
			HLayout(label.("Level (RMS dBFS)"), testLevelSlider, testLevelNum),
			VLayout(*rows).spacing_(4),
			HLayout(
				mkBtn.("All speakers on", { stopCycle.(); nOuts.do { |k| testOn.(k) } }),
				mkBtn.("All off", { stopCycle.(); testAllOff.() }),
				testCycleBtn, label.("seconds per speaker"), testCycleBox, nil
			),
			label.("OUTPUT LEVELS").font_(Font.sansSerif(11, true)),
			[testScroll, stretch: 1],
			StaticText().stringColor_(cDim).font_(Font.sansSerif(10)).string_(
				"The test signal passes through the master volume and the safety limiter. Levels are RMS dBFS.\n" ++
				"Calibration: band-limited pink noise at -20 dBFS RMS, set each speaker to the same SPL (e.g. 79–85 dB C, slow).")
		).margins_(10).spacing_(8);
		testWin.onClose = { stopCycle.(); testAllOff.(); testMeters = []; testButtons = [] };
		testWin.front;
	};
};

// ---------------- main window
buildWindow = {
	var bPrev, bPlay, bPause, bStop, bNext, leftView, right, masterBox, anaBox, headerBox, posAction, formatBox, footer;
	win = Window(appName ++ "  " ++ appVersion, Rect(40, 40, 1260, 880));

	// top bar --------------------------------------------------------------
	numOutsBox = NumberBox().clipLo_(1).clipHi_(128).decimals_(0).step_(1).scroll_step_(1).value_(prefs.numOuts).fixedWidth_(44);
	offsetBox = NumberBox().clipLo_(1).clipHi_(256).decimals_(0).step_(1).scroll_step_(1).value_(prefs.outOffset + 1).fixedWidth_(44);
	srPop = PopUpMenu().items_(["Device default", "44100", "48000", "88200", "96000"])
	.value_(sampleRates.indexOf(prefs.sampleRate ? 0) ? 0).fixedWidth_(118);
	devPop = PopUpMenu().minWidth_(200);
	refreshDevices.();
	statusText = StaticText().string_("").stringColor_(cDim);

	// playlist panel --------------------------------------------------------
	plNameText = StaticText().font_(Font.sansSerif(13, true));
	plInfoText = StaticText().stringColor_(cDim).font_(Font.sansSerif(10));
	plList = ListView().selectionMode_(\single).font_(Font.sansSerif(12))
	.action_({ |v| selectPiece.(v.value, false) })
	.enterKeyAction_({ |v| v.value !? { |i| startPiece.(i, 0) } })
	.mouseDownAction_({ |v, x, y, mod, bn, cc|
		if(cc == 2) { AppClock.sched(0.02, { v.value !? { |i| startPiece.(i, 0) }; nil }) };
		nil
	})
	.keyDownAction_({ |v, char| if(char == Char.space) { togglePlay.(); true } { nil } });

	targetPop = PopUpMenu().items_(targetNames).value_(plSet.targetIdx ? 0)
	.action_({ |m| plSet.targetIdx = m.value; markDirty.() });
	ceilBox = NumberBox().clipLo_(-12).clipHi_(0).decimals_(1).step_(0.5).scroll_step_(0.5).value_(plSet.ceilDb ? -1).fixedWidth_(50)
	.action_({ |b| plSet.ceilDb = b.value; markDirty.() });
	balanceBox = CheckBox().string_("Also balance the tracks inside each piece").value_(plSet.balance == true)
	.action_({ |c| plSet.balance = c.value; markDirty.() });
	analyzeBtn = Button().states_([["Analyse + Auto-Level whole playlist", Color.black, cBlue]]).canFocus_(false).minHeight_(30)
	.action_({ autoLevel.() });
	undoBtn = mkBtn.("Undo", { undoAutoLevel.() });
	anaText = StaticText().stringColor_(cDim).font_(Font.sansSerif(10)).minHeight_(30).string_(
		"Measures the loudness (LUFS) and peak of every track and sets each\npiece's trim so all pieces play equally loud without clipping.");

	anaBox = panel.(VLayout(
		label.("AUTO-LEVEL  (all pieces)").font_(Font.sansSerif(11, true)),
		HLayout(label.("Target"), targetPop),
		HLayout(label.("Peak ceiling (dBFS)"), ceilBox, nil),
		balanceBox,
		HLayout([analyzeBtn, stretch: 1], undoBtn),
		anaText
	).margins_(8).spacing_(5));

	leftView = View().fixedWidth_(400);
	leftView.layout = VLayout(
		plNameText, plInfoText,
		[plList, stretch: 1],
		HLayout(
			mkBtn.("+ Piece (files)…", { FileDialog({ |paths| addPieceFromFiles.(paths) }, nil, 3, 0) }),
			mkBtn.("+ Piece (folder)…", { FileDialog({ |paths| addFolderPiece.(paths[0]) }, nil, 2, 0) }),
			mkBtn.("+ Many pieces…", { FileDialog({ |paths| addFolderOfPieces.(paths[0]) }, nil, 2, 0) })
		),
		HLayout(
			mkBtn.("Move up", {
				if(selIdx.notNil and: { selIdx > 0 }) {
					pieces.swap(selIdx, selIdx - 1);
					case { curIdx == selIdx } { curIdx = selIdx - 1 } { curIdx == (selIdx - 1) } { curIdx = selIdx };
					selIdx = selIdx - 1;
					refreshPlaylist.(); markDirty.();
				};
			}),
			mkBtn.("Move down", {
				if(selIdx.notNil and: { selIdx < (pieces.size - 1) }) {
					pieces.swap(selIdx, selIdx + 1);
					case { curIdx == selIdx } { curIdx = selIdx + 1 } { curIdx == (selIdx + 1) } { curIdx = selIdx };
					selIdx = selIdx + 1;
					refreshPlaylist.(); markDirty.();
				};
			}),
			mkBtn.("Duplicate", {
				var cp;
				if(selIdx.notNil) {
					cp = pieces[selIdx].deepCopy;
					cp.title = cp.title ++ " (copy)";
					pieces = pieces.insert(selIdx + 1, cp);
					if(curIdx.notNil and: { curIdx > selIdx }) { curIdx = curIdx + 1 };
					selectPiece.(selIdx + 1); markDirty.();
				};
			}),
			mkBtn.("Remove", {
				if(selIdx.notNil) {
					if(selIdx == curIdx) { stopPlayback.() };
					pieces.removeAt(selIdx);
					if(curIdx.notNil and: { curIdx > selIdx }) { curIdx = curIdx - 1 };
					selIdx = if(pieces.size == 0) { nil } { selIdx.min(pieces.size - 1) };
					buildMixer.(); refreshPlaylist.(); markDirty.();
				};
			})
		),
		HLayout(
			mkBtn.("New playlist", { newPlaylist.() }),
			mkBtn.("Open…", {
				FileDialog({ |paths|
					savePlaylist.(playlistPath);
					stopPlayback.();
					if(loadPlaylist.(paths[0])) {
						selIdx = if(pieces.size > 0) { 0 };
						undoSnapshot = nil;
						savePrefs.();
						refreshSettingsWidgets.(); buildMixer.(); refreshPlaylist.();
					} { setStatus.("This file is not a Multichannel Player playlist.", cRed) };
				}, nil, 1, 0);
			}),
			mkBtn.("Save as…", {
				FileDialog({ |paths|
					var path = paths[0];
					if(path.splitext[1] != "mcplist") { path = path ++ ".mcplist" };
					savePlaylist.(path);
					refreshPlaylist.();
					setStatus.("Playlist saved: " ++ path, cGreen);
				}, nil, 0, 1);
			})
		),
		anaBox
	).margins_(0).spacing_(6);

	// transport ------------------------------------------------------------
	bPrev = mkBtn.("|◀  Prev", { prevPiece.() }).minHeight_(36);
	bPlay = Button().states_([["▶  Play", Color.black, cGreen]]).canFocus_(false).minHeight_(36).minWidth_(90)
	.action_({ playPressed.() });
	bPause = mkBtn.("❚❚  Pause", { pausePlayback.() }).minHeight_(36);
	bStop = mkBtn.("■  Stop", { stopPlayback.() }).minHeight_(36);
	bNext = mkBtn.("Next  ▶|", { nextPiece.() }).minHeight_(36);
	stateText = StaticText().font_(Font.sansSerif(15, true)).minWidth_(210);
	autoAdvBox = CheckBox().string_("Auto-advance").value_(plSet.autoAdvance == true)
	.action_({ |c| plSet.autoAdvance = c.value; markDirty.() });
	gapBox = NumberBox().clipLo_(0).clipHi_(600).decimals_(1).step_(0.5).scroll_step_(0.5).value_(plSet.gapSec ? 3).fixedWidth_(50)
	.action_({ |b| plSet.gapSec = b.value; markDirty.() });

	posAction = { |sl|
		var c, idx = curIdx ? selIdx, secs;
		secs = if(idx.notNil and: { idx < pieces.size }) { pieceSecs.(pieces[idx]) } { 0 };
		posDragging = true;
		posMoved = true;
		dragCount = dragCount + 1;
		c = dragCount;
		timeText.string = fmtTime.(sl.value * secs) ++ " / " ++ fmtTime.(secs);
		AppClock.sched(0.6, {
			if(posDragging and: { c == dragCount }) { posDragging = false; posMoved = false; seekTo.(sl.value) };
			nil
		});
	};
	posSlider = Slider().orientation_(\horizontal).minHeight_(24).canFocus_(false)
	.background_(Color.gray(0.33)).knobColor_(cBlue)
	.action_(posAction)
	.mouseDownAction_({ posDragging = true; posMoved = false; nil })
	.mouseUpAction_({ |sl|
		if(posMoved) { dragCount = dragCount + 1; seekTo.(sl.value) };
		posDragging = false;
		posMoved = false;
		nil
	});
	timeText = StaticText().font_(Font.monospace(15)).minWidth_(150).align_(\right);

	// piece header ---------------------------------------------------------
	titleField = TextField().font_(Font.sansSerif(15, true))
	.keyUpAction_({ |f| if(selIdx.notNil) { pieces[selIdx].title = f.string; refreshPlaylist.(); markDirty.() } })
	.action_({ |f| if(selIdx.notNil) { pieces[selIdx].title = f.string; refreshPlaylist.(); markDirty.() } });
	pieceInfoText = StaticText().stringColor_(cDim).font_(Font.sansSerif(10));
	trimSlider = Slider().orientation_(\horizontal).fixedWidth_(200).canFocus_(false)
	.background_(Color.gray(0.33)).knobColor_(Color.gray(0.85))
	.toolTip_("Volume of the whole piece (set by Auto-Level). Double-click = 0 dB")
	.action_({ |sl|
		var p = pieces[selIdx];
		p.trimDb = trimSpec.map(sl.value).round(0.1); trimNum.value = p.trimDb;
		liveAllTracks.(p); markDirty.();
	})
	.mouseDownAction_({ |sl, x, y, mod, bn, cc|
		var p;
		if(cc == 2 and: { selIdx.notNil }) {
			p = pieces[selIdx]; p.trimDb = 0.0; sl.value = trimSpec.unmap(0); trimNum.value = 0;
			liveAllTracks.(p); markDirty.(); true
		} { nil }
	});
	trimNum = NumberBox().clipLo_(-30).clipHi_(24).decimals_(1).step_(0.5).scroll_step_(0.5).fixedWidth_(56)
	.action_({ |b|
		var p = pieces[selIdx];
		p.trimDb = b.value; trimSlider.value = trimSpec.unmap(b.value);
		liveAllTracks.(p); markDirty.();
	});
	srcPop = PopUpMenu().items_(["Multichannel (speaker feeds)", "Ambisonics AmbiX (ACN / SN3D)", "Ambisonics FuMa (W X Y Z …)"]).font_(Font.sansSerif(10)).minWidth_(200)
	.toolTip_("What the files of this piece are: speaker feeds, or Ambisonic channels")
	.action_({ |m|
		var p = if(selIdx.notNil) { pieces[selIdx] };
		p !? { p.srcFormat = srcFormats[m.value]; afterSourceChange.(p) };
	});
	layoutPop = PopUpMenu().items_(layoutNames).font_(Font.sansSerif(10)).minWidth_(230)
	.toolTip_("Where the speakers of this piece are meant to be (used by the spatial listening formats)")
	.action_({ |m|
		var p = if(selIdx.notNil) { pieces[selIdx] };
		p !? {
			if(m.value != 7) { applyLayoutToPiece.(p, m.value) } { p.layoutIdx = 7 };
			afterSourceChange.(p);
		};
	});
	headerBox = panel.(VLayout(
		HLayout(label.("Piece").stringColor_(cDim), [titleField, stretch: 1],
			mkBtn.("+ Tracks…", { if(selIdx.notNil) { FileDialog({ |paths| addTracksToPiece.(paths) }, nil, 3, 0) } }),
			mkBtn.("All faders 0 dB", {
				var p = if(selIdx.notNil) { pieces[selIdx] };
				p !? { p.tracks.do { |t| t.db = 0.0 }; liveAllTracks.(p); buildMixer.(); markDirty.() };
			})
		),
		HLayout(label.("Source format").stringColor_(cDim), srcPop, label.("  Layout").stringColor_(cDim), layoutPop, nil),
		HLayout([pieceInfoText, stretch: 1], label.("Piece trim (dB)"), trimSlider, trimNum)
	).margins_(8).spacing_(4));

	// listening format ----------------------------------------------------
	formatPop = PopUpMenu().items_(formatNames).value_(prefs.listen ? 0).minWidth_(330)
	.toolTip_("How you listen to the pieces")
	.action_({ |m| prefs.listen = m.value; formatChanged.() });
	orderPop = PopUpMenu().items_(["Auto", "1st", "2nd", "3rd", "4th", "5th"]).value_(prefs.ambiOrder ? 0).fixedWidth_(70)
	.toolTip_("Ambisonic order (Auto = as high as your speakers allow)")
	.action_({ |m| prefs.ambiOrder = m.value; formatChanged.() });
	spkInfoText = StaticText().stringColor_(cDim).font_(Font.sansSerif(10));
	roomSlider = Slider().orientation_(\horizontal).fixedWidth_(80).value_(prefs.room ? 0.2).canFocus_(false)
	.background_(Color.gray(0.33)).knobColor_(Color.gray(0.85))
	.toolTip_("Binaural only: a little room reverberation helps the sound appear outside the head")
	.action_({ |sl| prefs.room = sl.value; binNode !? { binNode.set(\room, sl.value) }; markDirty.() });
	formatInfoText = StaticText().stringColor_(cBlue).font_(Font.sansSerif(10));
	formatBox = panel.(VLayout(
		HLayout(
			label.("LISTENING FORMAT").font_(Font.sansSerif(11, true)), formatPop,
			label.("  Order"), orderPop,
			label.("  Room"), roomSlider,
			12, mkBtn.("My speakers…", { openSpeakerWindow.() }), spkInfoText, nil
		).spacing_(6),
		formatInfoText
	).margins_(8).spacing_(3));

	// mixer + master -------------------------------------------------------
	mixerScroll = ScrollView().hasBorder_(false);
	masterFader = Slider().orientation_(\vertical).value_(masterSpec.unmap(prefs.masterDb)).minHeight_(140).fixedWidth_(30)
	.background_(Color.gray(0.33)).knobColor_(cOrange)
	.toolTip_("Master volume. Double-click = 0 dB")
	.action_({ |sl| prefs.masterDb = masterSpec.map(sl.value).round(0.1); masterNum.value = prefs.masterDb; liveMaster.(); markDirty.() })
	.mouseDownAction_({ |sl, x, y, mod, bn, cc|
		if(cc == 2) { prefs.masterDb = 0.0; sl.value = masterSpec.unmap(0); masterNum.value = 0; liveMaster.(); markDirty.(); true } { nil }
	});
	masterNum = NumberBox().clipLo_(minDb).clipHi_(12).decimals_(1).step_(0.5).scroll_step_(0.5).value_(prefs.masterDb).fixedWidth_(60)
	.action_({ |b| prefs.masterDb = b.value; masterFader.value = masterSpec.unmap(b.value); liveMaster.(); markDirty.() });
	limiterBox = CheckBox().string_("Safety limiter").value_(prefs.limiter == true)
	.toolTip_("Stops the outputs from clipping (only acts above -0.5 dBFS)")
	.action_({ |c| prefs.limiter = c.value; liveMaster.(); markDirty.() });
	outScroll = ScrollView().hasBorder_(false).minWidth_(110);
	mapView = UserView().fixedHeight_(190).background_(Color.gray(0.12)).drawFunc_({ |v| drawMap.(v) })
	.toolTip_("Seen from above: your speakers (squares, yellow = elevated) and the tracks of the selected piece (blue). Click to edit your speakers.")
	.mouseDownAction_({ openSpeakerWindow.(); nil });
	masterBox = panel.(VLayout(
		label.("MASTER  ·  OUTPUTS").font_(Font.sansSerif(11, true)),
		[HLayout(VLayout([masterFader, stretch: 1], masterNum).spacing_(4), [outScroll, stretch: 1]).spacing_(8), stretch: 1],
		limiterBox,
		mapView
	).margins_(8).spacing_(6));
	masterBox.minWidth_(220);

	right = VLayout(
		HLayout(bPrev, bPlay, bPause, bStop, bNext, 12, stateText, nil, autoAdvBox, label.("Gap (s)").fixedWidth_(56).align_(\right), gapBox).spacing_(6),
		HLayout([posSlider, stretch: 1], timeText),
		headerBox,
		[HLayout([mixerScroll, stretch: 1], masterBox).spacing_(8), stretch: 1]
	).spacing_(8);

	footer = VLayout(
		StaticText().string_("Ali Balighi © 2026").align_(\center).font_(Font.sansSerif(11, true)).stringColor_(cText),
		StaticText().string_("alibalighi.com").align_(\center).font_(Font.sansSerif(10)).stringColor_(cBlue)
		.toolTip_("Open alibalighi.com in your web browser")
		.mouseDownAction_({ try { "https://alibalighi.com".openOS }; nil })
	).spacing_(0).margins_(0);

	win.layout = VLayout(
		HLayout(
			label.("Outputs"), numOutsBox, label.("  First output"), offsetBox,
			label.("  Sample rate"), srPop, label.("  Device"), devPop,
			mkBtn.("Apply / Reboot", { applySettings.() }),
			12, mkBtn.("Speaker Test…", { openTestWindow.() }), mkBtn.("Help", { showHelp.() }),
			12, [statusText, stretch: 1]
		).spacing_(4),
		formatBox,
		[HLayout(leftView, [right, stretch: 1]).spacing_(12), stretch: 1],
		HLayout(nil, footer, nil)
	).margins_(10).spacing_(8);

	win.view.keyDownAction = { |v, char| if(char == Char.space) { togglePlay.(); true } { nil } };
	win.onClose = {
		stopPlayback.();
		stopCycle.();
		testAllOff.();
		savePlaylist.(playlistPath);
		savePrefs.();
		oscKeys.do { |k| OSCdef(k).free };
		CmdPeriod.remove(cmdPeriodFunc);
		ServerTree.remove(treeFunc, s);
		ServerQuit.remove(quitFunc, s);
		guiJack !? { guiJack.stop };
		if(testWin.notNil and: { testWin.isClosed.not }) { testWin.close };
		if(helpWin.notNil and: { helpWin.isClosed.not }) { helpWin.close };
		if(spkWin.notNil and: { spkWin.isClosed.not }) { spkWin.close };
		serverReady = false;
		AppClock.sched(0.6, {
			[playGroup, testGroup, masterGroup].do { |g| g !? { g.free } };
			mixBus !? { mixBus.free };
			vBus !? { vBus.free };
			nil
		});
		// restore the normal colours only if no newer copy of the player has been opened meanwhile
		if(~multichannelPlayerWindow === win) {
			~multichannelPlayerOrigPalette !? { |pal| try { QtGUI.palette = pal } };
			~multichannelPlayerOrigPalette = nil;
		};
	};
	win.front;
};

// =====================================================================================
//  START
// =====================================================================================

File.mkdir(appDir);
File.mkdir(cacheDir);
loadPrefs.();
plSet = defaultPlSet.();
playlistPath = prefs.lastPlaylist ? "";
if((playlistPath.size == 0) or: { loadPlaylist.(playlistPath).not }) {
	playlistPath = autosavePath;
	loadPlaylist.(autosavePath);
};
if(pieces.size > 0) { selIdx = 0 };
nOuts = prefs.numOuts.asInteger.clip(1, 128);
outOff = prefs.outOffset.asInteger.clip(0, 255);
ensureSpeakerLayout.();

// close an older copy of the player if this code is run twice
~multichannelPlayerWindow !? { |w| if(w.isClosed.not) { w.close } };

if(~multichannelPlayerOrigPalette.isNil) { ~multichannelPlayerOrigPalette = try { QtGUI.palette } };
try { QtGUI.palette = QPalette.dark };

oscKeys = [\mcpTrk, \mcpOut, \mcpPos, \mcpEnd].collect { |k| (k ++ "_" ++ instanceId).asSymbol };

OSCdef(oscKeys[0], { |msg|
	var i = msg[2].asInteger, n = trackNodes[i];
	if(n.notNil and: { n.nodeID == msg[1] } and: { i < trkPeak.size }) {
		trkPeak[i] = msg[3];
		trkRms[i] = msg[4];
		trkTime[i] = Main.elapsedTime;
		if(msg[3] > (trkHold[i] ? 0)) { trkHold[i] = msg[3] };
	};
}, '/mcpTrk');

OSCdef(oscKeys[1], { |msg|
	var now = Main.elapsedTime;
	if(masterSynth.notNil and: { msg[1] == masterSynth.nodeID }) {
		nOuts.do { |k|
			var pk = msg[3 + (2 * k)], rms = msg[4 + (2 * k)];
			if(pk.notNil and: { k < outPeak.size }) {
				outPeak[k] = pk; outRms[k] = rms; outTime[k] = now;
				if(pk > (outHold[k] ? 0)) { outHold[k] = pk };
			};
		};
	};
}, '/mcpOut');

OSCdef(oscKeys[2], { |msg|
	if((msg[2].asInteger == playToken) and: { transport == \playing }) { posSec = msg[3] };
}, '/mcpPos');

OSCdef(oscKeys[3], { |msg|
	if((msg[2].asInteger == playToken) and: { transport == \playing }) { { onPieceEnd.() }.defer };
}, '/mcpEnd');

cmdPeriodFunc = {
	transport = \stopped;
	curIdx = nil;
	posSec = 0;
	trackNodes = [];
	clockNode = nil;
	binNode = nil;
	playBufs.do { |b| b !? { b.close; b.free } };
	playBufs = [];
	advanceTask = nil;
	testCycleTask = nil;
	testNodes = Array.newClear(nOuts);
	{ testUpdateButtons.(); stopCycle.(); refreshPlaylist.() }.defer(0.1);
};
treeFunc = { if(serverReady and: { booting.not }) { makeTree.() } };
quitFunc = {
	if(booting.not and: { serverReady }) {
		serverReady = false;
		transport = \stopped;
		curIdx = nil;
		trackNodes = [];
		setStatus.("The audio server was stopped – press Apply / Reboot to start it again.", cRed);
	};
};
CmdPeriod.add(cmdPeriodFunc);
ServerTree.add(treeFunc, s);
ServerQuit.add(quitFunc, s);

buildWindow.();
~multichannelPlayerWindow = win;
buildMixer.();
refreshPlaylist.();
refreshFormatWidgets.();
guiJack = SkipJack({ refreshGui.() }, 0.05, { win.isClosed }, "MultichannelPlayerGUI", AppClock);

if(s.serverRunning and: { s.options.numOutputBusChannels >= (nOuts + outOff) }) {
	booting = true;
	onBooted.();
} {
	bootServer.();
};

// a small scripting interface (optional), e.g.  ~multichannelPlayer[\play].(0)
~multichannelPlayer = (
	play: { |i = 0, sec = 0| startPiece.(i, sec) },
	stop: { stopPlayback.() },
	pause: { pausePlayback.() },
	resume: { resumePlayback.() },
	next: { nextPiece.() },
	addPiece: { |paths, title| addPieceFromFiles.(paths, title) },
	addFolder: { |dir| addFolderPiece.(dir) },
	addFolderOfPieces: { |dir| addFolderOfPieces.(dir) },
	autoLevel: { autoLevel.() },
	speakerTest: { openTestWindow.() },
	testOn: { |k| testOn.(k) },
	testAllOff: { testAllOff.() },
	testCycle: { |on = true| if(on) { startCycle.() } { stopCycle.(); testAllOff.() } },
	select: { |i| selectPiece.(i) },
	setTrackDb: { |pieceIndex, trackIndex, db|
		var p = pieces[pieceIndex];
		p.tracks[trackIndex].db = db;
		liveTrack.(p, trackIndex);
		if(pieceIndex == selIdx) { buildMixer.() };
		markDirty.();
	},
	setMasterDb: { |db| prefs.masterDb = db; masterFader.value = masterSpec.unmap(db); masterNum.value = db; liveMaster.(); markDirty.() },
	analysing: { analyzing },
	setFormat: { |i| prefs.listen = i; formatChanged.() },
	setOrder: { |o| prefs.ambiOrder = o; formatChanged.() },
	setSpeakerPreset: { |idx|
		if(idx.inclusivelyBetween(0, 6)) { prefs.spkPreset = idx; prefs.spk = layoutPreset.(idx, nOuts); spkChanged.() };
	},
	setSourceFormat: { |pieceIndex, fmt, layout|
		var p = pieces[pieceIndex];
		p.srcFormat = fmt;
		layout !? { applyLayoutToPiece.(p, layout) };
		afterSourceChange.(p);
	},
	solo: { |pieceIndex, trackIndex, on = true|
		var p = pieces[pieceIndex];
		p.tracks.do { |t, i| t.solo = (i == trackIndex) and: { on } };
		liveAllTracks.(p);
		if(pieceIndex == selIdx) { buildMixer.() };
	},
	render: { |i| renderPiece.(pieces[i]) },
	math: { spatialMath },
	speakers: { openSpeakerWindow.() },
	pieces: { pieces },
	state: { (transport: transport, current: curIdx, selected: selIdx, position: posSec, serverReady: serverReady,
		trackPeaks: trkHold.collect(_.ampdb), outputPeaks: outHold.collect(_.ampdb)) },
	window: { win }
);
("Multichannel Player " ++ appVersion ++ " is running.").postln;
)
