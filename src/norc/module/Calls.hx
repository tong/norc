package norc.module;

import haxe.Json;
import haxe.io.Path;
import norc.Commands;
import norc.Config;
import norc.Files;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import sys.FileSystem;
import sys.io.Process;
import sys.thread.Thread;
import xmpp.Jid;
import xmpp.Jingle;
import xmpp.ExternalServices;
import xmpp.JingleMessage;
import xmpp.JingleRtp;
import xmpp.ServiceDiscovery;
import xmpp.XML;

using Lambda;
using StringTools;

private enum CallState {
	/** Requested by the peer, not yet accepted **/
	Ringing;

	/** Requested, waiting for the peer to accept **/
	Calling;

	/** Accepted, connecting the media **/
	Connecting;

	Connected;
}

/** The direction of a media, from the own side (also the values of norc-rtc) **/
private enum abstract Direction(String) to String {
	var both;
	var send;
	var receive;
	var none;

	public function sends():Bool
		return this == both || this == send;

	/** What both directions allow, e.g. `both` and `receive`: `receive` **/
	public function and(other:Direction):Direction
		return (this == other || other == both) ? cast this : (this == both) ? other : none;
}

private typedef Call = {
	var id:Int;

	/** Full jid of the other side **/
	var peer:String;

	var incoming:Bool;

	/** The own directions of the media (the callee: what the caller offers, until accepted) **/
	var audio:Direction;

	var video:Direction;

	var state:CallState;

	/** The session, once requested **/
	var ?session:JingleSession;

	/** The media, once started **/
	var ?rtc:Rtc;

	/** The own contents (of the offer or answer), with the credentials for the own candidates **/
	var local:Array<JingleContent>;

	/** Own candidates before the session is requested (caller) or accepted (callee) **/
	var localCandidates:Array<{mline:Int, candidate:String}>;

	/** Candidates of the peer, before the media got the description of the peer **/
	var remoteCandidates:Array<{name:String, candidate:String}>;

	/** The media got the description of the peer **/
	var described:Bool;

	/** Time the media connected **/
	var ?connected:Float;

	/** Why the own side ended the call **/
	var ?ending:String;

	/** Muted media (`audio`, `video`) **/
	var muted:Array<String>;

	/** A file played instead of the microphone, and of the camera if it has video (also a named pipe) **/
	var ?file:String;

	/** The file of the recording, requested or running **/
	var ?record:String;

	/** The call is initiated by messages (XEP-0353): their id, the id of the session **/
	var ?jmi:String;

	/** Calling by messages: the jid the call is proposed to (bare: to all clients of the contact), until one accepts **/
	var ?proposed:String;

	/** The call initiated by messages was accepted (`proceed`): it ends with a `finish` message **/
	var proceeded:Bool;

	/** A client of the peer rings (calling by messages) **/
	var rang:Bool;

	/** The media share one connection (BUNDLE): the peer supports grouping **/
	var bundle:Bool;

	/** Where status messages go: of the command which started or accepted the call **/
	var out:Output;
}

/**
	Audio and video calls with Jingle RTP (XEP-0167, ICE-UDP, DTLS-SRTP), compatible with WebRTC clients.
	The media run in a separate program (`norc-rtc`, set with `call_helper`), which gets the session descriptions
	and candidates converted from and to Jingle. Without it, calls are not available (and not advertised).

	One call at a time: other requests are answered with `busy`. Only contacts can call (the media reveal the address).

	Calls are also initiated by messages (Jingle Message Initiation, XEP-0353), as Conversations, Monal and Dino do: a
	proposal rings all clients of the callee, the one accepting it gets the session. Calls go this way to contacts
	with a client supporting it, else the session is requested directly.
**/
class Calls extends Module {
	final contacts:Contacts;
	final sessions:JingleSessions;

	/** The command of the media program, `null` if it is not found **/
	final helper:Null<Array<String>>;

	/** The program of `call_helper` (default `norc-rtc`), also when not found **/
	final helperName:String;

	/** Seconds a call rings before it is given up **/
	static inline var ANSWER_TIMEOUT = 60;

	/** Seconds after accepting a call proposed by message until the caller starts it **/
	static inline var SESSION_TIMEOUT = 30;

	/** Proposals delivered later (from the offline storage) are calls which are over **/
	static inline var PROPOSAL_MAX_AGE = 60;

	final calls = new Array<Call>();
	var nextId = 1;

	/** The settings of calls (call_* keys, stun, turn) **/
	final account:Config.Account;

	/** The server offers its STUN and TURN servers (XEP-0215), `null` while unknown **/
	var externalServices:Null<Bool>;

	public function new(context:Context, messages:Messages, contacts:Contacts, sessions:JingleSessions, account:Config.Account) {
		super(context);
		this.contacts = contacts;
		this.sessions = sessions;
		this.account = account;
		final command = words(account.callHelper ?? "norc-rtc");
		helperName = command[0] ?? "";
		final path = Files.which(command[0] ?? "");
		this.helper = (path != null) ? [path].concat(command.slice(1)) : null;
		sessions.handle(JingleRtp.XMLNS, incoming);
		messages.incoming.push(message);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "call",
				args: "<jid> [options...]",
				description: "call a contact; options (also before the jid, e.g. for an alias: /call video <jid>): video, audio, send or receive (only one direction), record, a file to play instead of the microphone (and camera, if it has video)",
				online: true,
				run: (args, out) -> {
					final line = optionsFirst(args[0], args[1]);
					call(line.jid, line.options, out);
				},
				complete: [
					"jid" => arg -> [OPTIONS, contacts.completions(arg)],
					"options" => arg -> {
						// only options so far (/call video al): the jid follows, also the contacts
						final before = arg.substr(0, arg.lastIndexOf(" ") + 1);
						final options:Array<Array<String>> = completeOptions(arg);
						if (optionsOnly(Commands.completing))
							options.insert(1, [for (c in contacts.completions(arg.substr(before.length))) before + c]);
						options;
					}
				],
				subcommands: [
					{
						name: "accept",
						args: "[#id] [options...]",
						description: "accept a call (the only one if no number is given); options: audio (without video), send or receive, record, a file to play",
						online: true,
						run: (args, out) -> accept(find(args[0], Ringing, out), args[1], out),
						complete: ["options" => completeOptions]
					},
					{
						name: "decline",
						args: "[#id]",
						description: "decline a call",
						run: (args, out) -> end(find(args[0], Ringing, out), decline, "declined")
					},
					{
						name: "hangup",
						args: "[#id]",
						description: "end a call",
						run: (args, out) -> hangup(find(args[0], null, out))
					},
					{
						name: "record",
						args: "[#id] [state...]",
						description: "record the call into a file (call_record_dir): on or off, without: switched; with a jid: a call recorded (/call record <jid> [options...])",
						run: (args, out) -> switch args[1] {
							case null | "on" | "off": record(find(args[0], null, out), args[1], out);
							// the option record before the jid
							case rest:
								final line = optionsFirst("record", rest);
								call(line.jid, line.options, out);
						},
						complete: [
							"state" => arg -> [["on", "off"], calls.length == 0 ? contacts.completions(arg) : []]
						]
					},
					{
						name: "mute",
						args: "[media]",
						description: "mute or unmute your audio (or video)",
						run: (args, out) -> mute(args[0] ?? "audio", out),
						complete: ["media" => _ -> ["audio", "video"]]
					}
				]
			},
			{
				name: "calls",
				description: "list the calls and their state",
				run: (args, out) -> list(out),
				subcommands: [
					{
						name: "devices",
						description: "list the microphones, speakers and cameras for calls (names for call_microphone, …)",
						run: (args, out) -> devices(out)
					},
					{
						name: "hangup",
						description: "end all calls (ringing calls are declined)",
						run: (args, out) -> {
							if (calls.length == 0)
								out.info("no calls");
							for (c in calls.copy())
								hangup(c);
						}
					}
				]
			}
		];

	override public function features():Array<String>
		return (helper != null) ? JingleRtp.FEATURES.concat([JingleMessage.XMLNS]) : [];

	/** The calls being connected or connected (`active`), and ringing or calling (`pending`), e.g. for the prompt **/
	public function counts():{active:Int, pending:Int} {
		final pending = calls.filter(c -> c.state.match(Ringing | Calling)).length;
		return {active: calls.length - pending, pending: pending};
	}

	/** The calls, for the status (`norc.Status`) **/
	public function status():Array<norc.Status.StatusCall>
		return [
			for (c in calls)
				{
					id: c.id,
					jid: Jid.parseBare(c.peer),
					name: name(c),
					state: switch c.state {
						case Ringing: "ringing";
						case Calling: "calling";
						case Connecting: "connecting";
						case Connected: "connected";
					},
					incoming: c.incoming,
					media: (c.video != none) ? "video" : "audio",
					since: c.connected,
					muted: c.muted.copy(),
					recording: c.record != null
				}
		];

	override public function detach() {
		for (c in calls.copy())
			finish(c, "disconnected");
		// another server may offer other services
		externalServices = null;
		super.detach();
	}

	/** Why calls are not available: the program of `call_helper` was not found **/
	function missingHelper():String
		return (helperName == "norc-rtc") ? "calls need norc-rtc (not found in PATH, see call_helper)" : 'calls need norc-rtc: $helperName not found (call_helper = ${account.callHelper})';

	function call(input:String, words:Null<String>, out:Output) {
		if (helper == null) {
			out.error(missingHelper());
			return;
		}
		final options = parseOptions(words, out);
		if (options == null || (options.record && !recordingAllowed(out)))
			return;
		if (calls.length > 0) {
			out.error("already in a call (/calls, /call hangup)");
			return;
		}
		final jid = contacts.resolve(input, out);
		if (jid == null)
			return;
		final video = options.video == true;
		final done = out.wait();
		function calling(peer:String):Call {
			final c = add(peer, false, options.direction, video ? options.direction : none, Calling, out);
			c.file = options.file;
			if (options.record)
				c.record = recordPath(c, out);
			return c;
		}
		proposable(jid, jmi -> {
			if (calls.length > 0)
				return done();
			if (jmi) {
				// proposed by message to the jid given: without resource all clients of the contact ring
				done();
				final c = calling(jid);
				c.jmi = xmpp.Uuid.make();
				c.proposed = jid;
				stream.send(JingleMessage.create(jid, propose, c.jmi, {media: video ? ["audio", "video"] : ["audio"]}));
				out.info('#${c.id} calling ${name(c)} (${describeMedia(c)})');
				event(c, "calling");
				later(c, ANSWER_TIMEOUT, Calling, () -> if (c.proposed != null) end(c, cancel, "no answer"));
				return;
			}
			findCallee(jid, video, out, peer -> {
				done();
				if (peer == null || calls.length > 0)
					return;
				final c = calling(peer);
				out.info('#${c.id} calling ${name(c)} (${describeMedia(c)})');
				event(c, "calling");
				connect(c);
			});
		});
	}

	/** Starts the media of the outgoing call `c` to its peer (a full jid): one connection for all media only with clients supporting it (e.g. not Dino) **/
	function connect(c:Call)
		ServiceDiscovery.discoInfo(stream, c.peer, null, res -> {
			c.bundle = res.payload != null && ServiceDiscovery.parseInfo(res.payload).features.contains(JingleRtp.XMLNS_GROUPING);
			if (calls.contains(c))
				start(c);
		});

	/** Calls to `jid` are proposed by message: a client of the contact (or `jid` itself, with resource) supports it **/
	function proposable(jid:String, callback:Bool->Void) {
		final candidates = (Jid.parseResource(jid) != null) ? [jid] : contacts.resources(Jid.parseBare(jid));
		Discovery.findFeature(stream, candidates, JingleMessage.XMLNS, peer -> callback(peer != null));
	}

	/** After `seconds`, `f` if call `c` is still in `state` **/
	function later(c:Call, seconds:Float, state:CallState, f:() -> Void)
		Thread.create(() -> {
			Sys.sleep(seconds);
			context.post(() -> if (calls.contains(c) && c.state == state) f());
		});

	/** A call requested by a peer **/
	function incoming(session:JingleSession) {
		final media = [for (c in session.contents) JingleRtp.media(c)];
		if (helper == null || media.contains(null)) {
			session.terminate(unsupported_applications);
			return;
		}
		// the session of a call proposed by message
		final proposed = calls.find(c -> c.jmi == session.sid
			&& c.incoming
			&& c.session == null
			&& Jid.parseBare(c.peer) == Jid.parseBare(session.peer));
		if (proposed != null) {
			proposed.peer = session.peer;
			proposed.session = session;
			proposed.bundle = JingleRtp.group(session.payload) != null;
			listen(proposed);
			// accepted (proceed): with the media offered, as far as accepted; else it rings on
			if (proposed.state == Connecting) {
				proposed.audio = proposed.audio.and(offered(session, "audio"));
				proposed.video = proposed.video.and(offered(session, "video"));
				if (proposed.audio == none && proposed.video == none)
					end(proposed, failed_application, "the call offers nothing accepted");
				else
					start(proposed);
			} else {
				proposed.audio = offered(session, "audio");
				proposed.video = offered(session, "video");
			}
			return;
		}
		if (!contacts.contains(Jid.parseBare(session.peer))) {
			session.terminate(decline);
			return;
		}
		if (calls.length > 0) {
			session.terminate(busy);
			return;
		}
		final c = add(session.peer, true, offered(session, "audio"), offered(session, "video"), Ringing, TermOutput.instance);
		c.session = session;
		// as offered
		c.bundle = JingleRtp.group(session.payload) != null;
		listen(c);
		session.info([XML.create("ringing").set("xmlns", JingleRtp.XMLNS_INFO)]);
		ring(c);
	}

	/** What the caller of `session` offers of `media`: the senders, from the own side **/
	static function offered(session:JingleSession, media:String):Direction {
		final content = session.contents.find(c -> JingleRtp.media(c) == media);
		return (content == null) ? none : switch content.senders ?? JingleSenders.both {
			case JingleSenders.initiator: receive;
			case JingleSenders.responder: send;
			case JingleSenders.none: none;
			case _: both;
		}
	}

	/** The incoming call `c` rings, with the terminal bell **/
	function ring(c:Call) {
		Term.notice('#${c.id} ${name(c)} is calling (${describeMedia(c)}): /call accept ${c.id} or /call decline ${c.id}\x07', 1);
		event(c, "ringing");
	}

	/**
		A message initiating a call (XEP-0353), not shown: a proposal rings; the caller retracting it, a client of the
		callee ringing, accepting or declining it, another own client taking a call ringing here.
	**/
	function message(i:Incoming):Bool {
		final m = i.message;
		final jmi = JingleMessage.parse(m);
		if (jmi == null)
			return false;
		if (helper == null || m.from == null)
			return true;
		final from = Jid.parseBare(m.from);
		final c = calls.find(c -> c.jmi == jmi.id);
		// another own client took or declined the call (its message to the caller, or to the own bare jid)
		if (isOwn(from)) {
			if (c != null && c.incoming && c.state == Ringing && i.carbon != received && m.from != stream.jid)
				switch jmi.action {
					case JingleMessageAction.proceed | JingleMessageAction.accept:
						finish(c, "answered on another client");
					case reject:
						finish(c, "declined on another client");
					case _:
				}
			return true;
		}
		// a copy of the messages of the other own clients
		if (i.carbon != null)
			return true;
		if (jmi.action == propose) {
			proposal(m.from, jmi, m);
			return true;
		}
		if (c == null || Jid.parseBare(c.peer) != from)
			return true;
		switch jmi.action {
			case retract if (c.incoming && c.session == null):
				finish(c, (c.state == Ringing) ? "missed" : "cancelled");
			case ringing if (!c.incoming && c.state == Calling && !c.rang):
				c.rang = true;
				Term.notice('#${c.id} ${name(c)} is ringing');
			case proceed if (!c.incoming && c.proposed != null && (Jid.parseResource(c.proposed) == null || c.proposed == m.from)):
				// the client accepting it gets the session
				c.peer = m.from;
				c.proposed = null;
				c.proceeded = true;
				connecting(c);
				connect(c);
			case reject if (!c.incoming && c.proposed != null):
				finish(c, (jmi.reason?.condition == busy) ? '${name(c)} is busy' : '${name(c)} declined');
			case JingleMessageAction.finish if (c.session == null):
				finish(c, '${name(c)} hung up');
			case _:
		}
		return true;
	}

	/** A call proposed by `from` (a full jid) **/
	function proposal(from:String, jmi:JingleMessageInfo, m:xmpp.Message) {
		// delivered late (offline storage): the call is over
		final delay = xmpp.DelayedDelivery.delay(m)?.date;
		if (delay != null && Date.now().getTime() - delay.getTime() > PROPOSAL_MAX_AGE * 1000)
			return;
		if (calls.exists(c -> c.jmi == jmi.id))
			return;
		final audio = jmi.media.contains("audio"), video = jmi.media.contains("video");
		if ((!audio && !video) || jmi.media.exists(media -> media != "audio" && media != "video")) {
			stream.send(JingleMessage.create(from, reject, jmi.id, {reason: {condition: unsupported_applications}}));
			return;
		}
		if (!contacts.contains(Jid.parseBare(from))) {
			stream.send(JingleMessage.create(from, reject, jmi.id));
			return;
		}
		if (calls.length > 0) {
			stream.send(JingleMessage.create(from, reject, jmi.id, {reason: {condition: busy}}));
			return;
		}
		final c = add(from, true, audio ? both : none, video ? both : none, Ringing, TermOutput.instance);
		c.jmi = jmi.id;
		stream.send(JingleMessage.create(from, ringing, jmi.id));
		ring(c);
		later(c, ANSWER_TIMEOUT, Ringing, () -> end(c, timeout, "missed"));
	}

	function accept(c:Null<Call>, words:Null<String>, out:Output) {
		if (c == null)
			return;
		final options = parseOptions(words, out);
		if (options == null || (options.record && !recordingAllowed(out)))
			return;
		// what is offered, as far as wanted
		final audio = c.audio.and(options.direction);
		final video = (options.video == false) ? none : c.video.and(options.direction);
		if (audio == none && video == none) {
			out.error('nothing left to accept: in this call you can only do ${describeMedia(c)}');
			return;
		}
		if (options.file != null && !audio.sends() && !video.sends()) {
			out.error("the file can't be played: you send nothing");
			return;
		}
		c.audio = audio;
		c.video = video;
		c.file = options.file;
		if (options.record)
			c.record = recordPath(c, out);
		c.out = out;
		connecting(c);
		if (c.session == null) {
			// proposed by message: accepted, the caller requests the session
			c.proceeded = true;
			stream.send(JingleMessage.create(c.peer, proceed, c.jmi));
			later(c, SESSION_TIMEOUT, Connecting, () -> if (c.session == null) end(c, timeout, "the caller didn't start the call"));
			return;
		}
		start(c);
	}

	function hangup(c:Null<Call>)
		if (c != null)
			switch c.state {
				case Ringing:
					end(c, decline, "declined");
				case Calling:
					end(c, cancel, "cancelled");
				case _:
					end(c, success, "hung up");
			}

	/** Ends call `c` from the own side, `text` tells why **/
	function end(c:Null<Call>, condition:JingleReason, text:String) {
		if (c == null)
			return;
		c.ending = text;
		if (c.session != null)
			c.session.terminate(condition);
		else {
			// not accepted yet: the proposal retracted, or declined
			if (c.jmi != null && !c.proceeded)
				stream.send(c.incoming ? JingleMessage.create(c.peer, reject, c.jmi,
					{reason: {condition: condition}}) : JingleMessage.create(c.proposed ?? c.peer, retract, c.jmi, {reason: {condition: cancel}}));
			finish(c, text);
		}
	}

	/** Mutes or unmutes `media` of the connecting or connected call **/
	function mute(media:String, out:Output) {
		final c = calls.find(c -> c.rtc != null);
		if (c == null || (media != "audio" && media != "video")) {
			out.error((c == null) ? "no call" : 'unknown media: $media (audio, video)');
			return;
		}
		if (!(media == "video" ? c.video : c.audio).sends()) {
			out.error('you send no $media');
			return;
		}
		final muted = !c.muted.remove(media);
		if (muted)
			c.muted.push(media);
		c.rtc.send({type: "mute", media: media, muted: muted});
		out.info('$media ${muted ? "muted" : "unmuted"}');
	}

	/** Starts (`on`) or stops (`off`) recording call `c`, without `state` switched **/
	function record(c:Null<Call>, state:Null<String>, out:Output) {
		if (c == null)
			return;
		if (c.rtc == null) {
			out.error('#${c.id} is not accepted yet: /call accept ${c.id} record');
			return;
		}
		final on = switch state {
			case null: c.record == null;
			case "on": true;
			case "off": false;
			case _:
				out.error('on or off, not $state');
				return;
		}
		if (on == (c.record != null)) {
			out.info(on ? 'already recording into ${Config.contractHome(c.record)}' : "not recording");
			return;
		}
		if (on) {
			if (!recordingAllowed(out))
				return;
			c.record = recordPath(c, out);
			if (c.record != null)
				c.rtc.send({type: "record", file: c.record});
		} else
			c.rtc.send({type: "record"});
	}

	/** Recording calls is allowed (`call_recording`), else an error **/
	function recordingAllowed(out:Output):Bool {
		if (account.callRecording != true)
			out.error("recording calls is off: call_recording = 1 in the config allows it");
		return account.callRecording == true;
	}

	/** The file of a new recording of `c`: `<contact>-<time>.webm` in `call_record_dir`, `null` with an error **/
	function recordPath(c:Call, out:Output):Null<String> {
		final dir = account.callRecordDir ?? Config.recordingsDir();
		try
			FileSystem.createDirectory(dir)
		catch (e) {
			out.error('cannot record into $dir: $e');
			return null;
		}
		return '$dir/${Jid.parseBare(c.peer)}-${DateTools.format(Date.now(), "%Y-%m-%d-%H%M%S")}.webm';
	}

	/** A message of the recording of `c` (also after the call: the file is written at its end) **/
	function recording(c:Call, msg:Dynamic) {
		final file:Null<String> = msg.file;
		final shown = (file != null) ? Config.contractHome(file) : "";
		final tracks:Array<String> = (msg.tracks != null) ? msg.tracks : [];
		switch (msg.state : String) {
			case "started":
				c.record = file;
				Term.notice('#${c.id} recording ${[for (t in tracks) t.replace("-", " ")].join(", ")} into $shown');
			case "stopped":
				if (c.record == file)
					c.record = null;
				Term.notice('#${c.id} recording saved: $shown');
			case "failed":
				if (c.record == file)
					c.record = null;
				Term.error('#${c.id} recording failed: ${msg.message ?? "already recording"}');
			case _:
				return;
		}
		emit("recording", [Jid.parseBare(c.peer), msg.state, file ?? ""], {
			from: c.peer,
			name: name(c),
			state: msg.state,
			file: file,
			tracks: tracks.join(" "),
			message: msg.message
		});
	}

	/** Starts the media of `c`: the caller creates an offer, the callee answers the offer of the peer **/
	function start(c:Call)
		servers(servers -> {
			if (!calls.contains(c))
				return;
			try {
				final options = servers.concat(settings())
					.concat(c.bundle ? [] : ["--no-bundle"])
					.concat(['--audio=${c.audio}'])
					.concat(c.video != none ? ['--video=${c.video}'] : [])
					.concat(c.file != null ? ["--file", c.file] : [])
					.concat(c.record != null ? ["--record", c.record] : []);
				c.rtc = new Rtc(helper.concat(options), context.post, msg -> media(c, msg), code -> stopped(c, code));
			} catch (e) {
				c.out.error('cannot start ${helper[0]}: $e');
				end(c, failed_application, "failed");
			}
		});

	/** The options of norc-rtc of the settings (devices, echo cancellation, self view, video size and rate, bitrates) **/
	function settings():Array<String> {
		final options = [];
		for (o in [
			{option: "--microphone", value: account.callMicrophone},
			{option: "--speaker", value: account.callSpeaker},
			{option: "--camera", value: account.callCamera}
		])
			if (o.value != null && o.value.length > 0)
				options.push('${o.option}=${o.value}');
		if (account.callEchoCancel != false)
			options.push("--echo-cancel");
		if (account.callSelfView != false)
			options.push("--self-view");
		for (o in [
			{option: "--video-size", value: account.callVideoSize},
			{option: "--video-fps", value: (account.callVideoFps != null) ? Std.string(account.callVideoFps) : null},
			{option: "--video-bitrate", value: (account.callVideoBitrate != null) ? Std.string(account.callVideoBitrate) : null},
			{option: "--audio-bitrate", value: (account.callAudioBitrate != null) ? Std.string(account.callAudioBitrate) : null}
		])
			if (o.value != null)
				options.push('${o.option}=${o.value}');
		return options;
	}

	/** Lists the devices for calls (of norc-rtc), their names for the settings **/
	function devices(out:Output) {
		if (helper == null) {
			out.error(missingHelper());
			return;
		}
		final lines = try {
			final p = new Process(helper[0], ["--list-devices"]);
			final text = p.stdout.readAll().toString();
			p.close();
			[for (l in text.split("\n")) if (l.trim().length > 0) l];
		} catch (e) {
			out.error('cannot list the devices: $e');
			return;
		}
		out.data({devices: [for (l in lines) {kind: l.substr(0, 11).trim(), name: l.substr(11)}]}, () -> {
			for (l in lines)
				out.print('  $l');
			out.info("use a name (or a part of it): call_microphone, call_speaker, call_camera in the config");
		});
	}

	/**
		The options of norc-rtc for the STUN and TURN servers: of the config, and of the server (XEP-0215, requested
		for each call: TURN credentials expire). Without any, calls connect only on the same network or with a public
		address.
	**/
	function servers(callback:Array<String>->Void) {
		function options(stun:Array<String>, turn:Array<String>):Array<String> {
			final first = (account.stun != null) ? account.stun : stun[0];
			return (first != null ? ["--stun", first] : []).concat([for (t in (account.turn ?? []).concat(turn)) for (o in ["--turn", t]) o]);
		}
		function request() {
			ExternalServices.request(stream, res -> {
				final services = [
					for (s in ExternalServices.parse(res.payload)) {type: s.type.toLowerCase(), uri: ExternalServices.uri(s)}
				];
				callback(options([for (s in services) if (s.type == "stun" && s.uri != null) s.uri], [
					for (s in services)
						if (s.type != "stun" && s.uri != null) s.uri
				]));
			});
		}
		switch externalServices {
			case true:
				request();
			case false:
				callback(options([], []));
			case null:
				ServiceDiscovery.discoInfo(stream, stream.domain, null, res -> {
					externalServices = res.payload != null
						&& ServiceDiscovery.parseInfo(res.payload).features.contains(ExternalServices.XMLNS);
					externalServices ? request() : callback(options([], []));
				});
		}
	}

	/** A message of the media of `c` **/
	function media(c:Call, msg:Dynamic) {
		if (msg.type == "recording")
			return recording(c, msg);
		if (!calls.contains(c))
			return;
		switch (msg.type : String) {
			case "ready":
				if (!c.incoming)
					c.rtc.send({type: "offer"});
				else
					describe(c, "offer", JingleRtp.toSdp(c.session.contents, JingleRtp.group(c.session.payload), true));
			case "sdp" if (!c.incoming):
				initiate(c, msg.sdp);
			case "sdp":
				final answer = JingleRtp.fromSdp(msg.sdp, false);
				c.local = answer.contents;
				c.session.accept(answer.contents, answer.payload);
				flushCandidates(c);
			case "candidate":
				c.localCandidates.push({mline: msg.mline, candidate: msg.candidate});
				flushCandidates(c);
			case "state":
				switch (msg.state : String) {
					case "connected" if (c.state != Connected):
						c.state = Connected;
						c.connected = Sys.time();
						Term.notice('#${c.id} call with ${name(c)} connected');
						event(c, "connected");
					case "failed":
						end(c, connectivity_error, "the connection failed");
					case _:
				}
			case "error":
				c.out.error('#${c.id} ${msg.message}');
				end(c, failed_application, "failed");
			case _:
		}
	}

	/** The offer of the media (caller): the session is requested **/
	function initiate(c:Call, sdp:String) {
		final offer = JingleRtp.fromSdp(sdp, true);
		c.local = offer.contents;
		final session = sessions.jingle.createSession(c.peer, c.jmi);
		c.session = session;
		listen(c);
		session.onAccept = contents -> {
			connecting(c);
			// the directions the callee accepted
			for (media in ["audio", "video"]) {
				final content = contents.find(content -> JingleRtp.media(content) == media);
				final d:Direction = (content == null) ? none : switch content.senders ?? JingleSenders.both {
					case JingleSenders.initiator: send;
					case JingleSenders.responder: receive;
					case JingleSenders.none: none;
					case _: both;
				}
				if (media == "audio")
					c.audio = c.audio.and(d);
				else
					c.video = c.video.and(d);
			}
			describe(c, "answer", JingleRtp.toSdp(contents, JingleRtp.group(session.payload), false));
		}
		session.initiate(offer.contents, offer.payload);
		flushCandidates(c);
	}

	/** Passes the description of the peer to the media, then the candidates of the peer received meanwhile **/
	function describe(c:Call, type:String, sdp:String) {
		c.rtc.send({type: "sdp", sdp_type: type, sdp: sdp});
		c.described = true;
		for (r in c.remoteCandidates)
			c.rtc.send({type: "candidate", mline: mline(c, r.name), candidate: r.candidate});
		c.remoteCandidates.resize(0);
	}

	/** Sends the own candidates once the session is requested (caller) or accepted (callee), with `transport-info` **/
	function flushCandidates(c:Call) {
		if (c.session == null || c.local.length == 0 || c.session.state == ended || (c.incoming && c.session.state == pending))
			return;
		for (l in c.localCandidates) {
			final content = c.local[l.mline];
			final info = (content != null) ? JingleRtp.candidateContent(content, l.candidate) : null;
			if (info != null)
				c.session.send(transport_info, [info]);
		}
		c.localCandidates.resize(0);
	}

	/** Handles the requests of the peer in the session of `c` **/
	function listen(c:Call) {
		final session = c.session;
		session.onTerminate = reason -> finish(c, c.ending ?? peerReason(c, reason));
		// e.g. ringing, mute
		session.onInfo = payload -> true;
		session.onAction = (req, respond) -> switch req.action {
			case transport_info:
				respond();
				for (content in req.contents)
					for (candidate in JingleRtp.candidates(content.transport))
						if (c.described && c.rtc != null)
							c.rtc.send({type: "candidate", mline: mline(c, content.name), candidate: candidate});
						else
							c.remoteCandidates.push({name: content.name, candidate: candidate});
			case _:
				respond(new xmpp.Stanza.Error(cancel, feature_not_implemented));
		}
	}

	/** The index of the media section of content `name` (the order of the contents of the session) **/
	function mline(c:Call, name:String):Int {
		final names = [for (content in c.session.contents) content.name];
		return Std.int(Math.max(0, names.indexOf(name)));
	}

	/** The media program exited **/
	function stopped(c:Call, code:Int) {
		if (!calls.contains(c))
			return;
		end(c, failed_application, 'the media stopped (exit code $code)');
	}

	/** The call ended: stops the media **/
	function finish(c:Call, text:String) {
		if (!calls.remove(c))
			return;
		c.rtc?.close();
		// initiated by message: the end, also for the other clients
		if (c.jmi != null && c.proceeded)
			stream?.send(JingleMessage.create(c.peer, JingleMessageAction.finish, c.jmi, {reason: {condition: success}}));
		final duration = (c.connected != null) ? ' after ${formatDuration(Sys.time() - c.connected)}' : '';
		Term.notice('#${c.id} call with ${name(c)} ended: $text$duration');
		event(c, "ended", {reason: text, duration: (c.connected != null) ? Std.int(Sys.time() - c.connected) : null});
	}

	/** Why the peer ended the call **/
	function peerReason(c:Call, reason:JingleReasonInfo):String
		return switch reason.condition {
			// the caller gave up
			case _ if (c.state == Ringing): "missed";
			case success: '${name(c)} hung up';
			case decline: '${name(c)} declined';
			case busy: '${name(c)} is busy';
			case connectivity_error | failed_transport: "the connection failed";
			case _: (reason.condition : String) + (reason.text != null ? ' (${reason.text})' : '');
		}

	function add(peer:String, incoming:Bool, audio:Direction, video:Direction, state:CallState, out:Output):Call {
		final c:Call = {
			id: nextId++,
			peer: peer,
			incoming: incoming,
			audio: audio,
			video: video,
			state: state,
			local: [],
			localCandidates: [],
			remoteCandidates: [],
			described: false,
			bundle: true,
			muted: [],
			proceeded: false,
			rang: false,
			out: out
		};
		calls.push(c);
		return c;
	}

	/** The call `id` (or the only one) in `state` (any if `null`), else an error **/
	function find(id:Null<String>, state:Null<CallState>, out:Output):Null<Call> {
		final matching = calls.filter(c -> state == null || c.state == state);
		final n = (id != null) ? Std.parseInt(id.startsWith("#") ? id.substr(1) : id) : null;
		final c = (n != null) ? matching.find(c -> c.id == n) : (matching.length == 1 ? matching[0] : null);
		if (c == null)
			out.error((id != null) ? 'no call #$id' : (matching.length == 0) ? "no call" : "several calls: give the number (/calls)");
		return c;
	}

	/** Picks the full jid to call: `jid` itself, or a client of the contact supporting calls **/
	function findCallee(jid:String, video:Bool, out:Output, callback:Null<String>->Void) {
		if (Jid.parseResource(jid) != null)
			return callback(jid);
		final candidates = contacts.resources(Jid.parseBare(jid));
		if (candidates.length == 0) {
			out.error('$jid is not online');
			return callback(null);
		}
		Discovery.findFeature(stream, candidates, video ? JingleRtp.XMLNS_VIDEO : JingleRtp.XMLNS_AUDIO, peer -> {
			if (peer == null)
				out.error('no client of $jid supports ${video ? "video " : ""}calls (${candidates.join(", ")})');
			callback(peer);
		});
	}

	function list(out:Output) {
		final list = [
			for (c in calls)
				{
					id: c.id,
					peer: c.peer,
					incoming: c.incoming,
					media: describeMedia(c),
					file: c.file,
					recording: c.record,
					state: (c.state : CallState).getName().toLowerCase(),
					duration: (c.connected != null) ? Std.int(Sys.time() - c.connected) : null
				}
		];
		out.data({calls: list}, () -> {
			if (list.length == 0)
				out.info("no calls");
			for (c in list)
				out.print('  #${c.id} ${c.incoming ? "from" : "to"} ${c.peer} (${c.media}'
					+ (c.file != null ? ', playing ${Path.withoutDirectory(c.file)}' : '')
					+ ') ${c.state}'
					+ (c.duration != null ? ' ${formatDuration(c.duration)}' : '')
					+ (c.recording != null ? ', recording' : ''));
		});
	}

	/** The `call` event: `ringing` (incoming), `calling` (outgoing), `connecting` (accepted), `connected`, `ended` **/
	function event(c:Call, state:String, ?values:haxe.DynamicAccess<Dynamic>) {
		final v = values ?? {};
		// the peer can change (the client answering a call proposed to all): the id identifies the call
		v.set("id", c.id);
		v.set("from", c.peer);
		v.set("name", name(c));
		v.set("state", state);
		v.set("media", (c.video != none) ? "video" : "audio");
		v.set("audio", (c.audio : String));
		v.set("video", (c.video : String));
		v.set("incoming", c.incoming);
		v.set("recording", c.record);
		emit("call", [Jid.parseBare(c.peer), state], v);
	}

	/** The call was accepted: the media is being connected (the `connecting` event, once) **/
	function connecting(c:Call) {
		if (c.state == Connecting)
			return;
		c.state = Connecting;
		event(c, "connecting");
	}

	function name(c:Call):String
		return contacts.name(Jid.parseBare(c.peer));

	/** The file at `path` (`~/` is the home directory, also a named pipe) to play in a call, `null` with an error if there is none **/
	static function mediaFile(path:String, out:Output):Null<String> {
		final file = Files.resolve(path);
		if (!FileSystem.exists(file) || FileSystem.isDirectory(file)) {
			out.error('no such file: $path (options: video, audio, send, receive, record, a file to play)');
			return null;
		}
		return FileSystem.absolutePath(file);
	}

	/** e.g. `audio`, `video` (both directions), `audio, receiving video`, `sending audio, playing song.ogg` **/
	static function describeMedia(c:Call):String {
		final media = (c.audio == both && c.video == both) ? ["video"] : [
			for (m in [{name: "audio", d: c.audio}, {name: "video", d: c.video}])
				switch m.d {
					case both:
						m.name;
					case send:
						'sending ${m.name}';
					case receive:
						'receiving ${m.name}';
					case none:
						continue;
				}
		];
		return media.join(", ") + (c.file != null ? ', playing ${Path.withoutDirectory(c.file)}' : '');
	}

	/** The words of the options of `/call` **/
	static final OPTIONS = ["video", "audio", "send", "receive", "record"];

	/** The jid and options of `/call <first> <rest>`, also with the options before the jid (`/call video alice`) **/
	static function optionsFirst(first:String, rest:Null<String>):{jid:String, options:Null<String>} {
		if (!OPTIONS.contains(first))
			return {jid: first, options: rest};
		final words = (rest ?? "").split(" ").filter(w -> w.length > 0);
		final options = [first];
		while (words.length > 0 && OPTIONS.contains(words[0]))
			options.push(words.shift());
		// no jid after the options: the first word is the jid (e.g. a contact named "video")
		if (words.length == 0)
			return {jid: first, options: rest};
		final jid = words.shift();
		return {jid: jid, options: options.concat(words).join(" ")};
	}

	/** All words of `arg` but the last are options (the jid may still follow) **/
	static function optionsOnly(arg:String):Bool {
		final words = arg.split(" ");
		words.pop();
		return words.foreach(w -> w.length == 0 || OPTIONS.contains(w));
	}

	/**
		The options of `/call` and `/call accept`: words (`video`, `audio`: without video, `send`, `receive`, `record`),
		then a file to play; `null` with an error if the file doesn't exist
	**/
	static function parseOptions(input:Null<String>, out:Output):Null<{
		video:Null<Bool>,
		direction:Direction,
		record:Bool,
		file:Null<String>
	}> {
		final words = (input ?? "").split(" ");
		var video:Null<Bool> = null;
		var direction = both;
		var record = false;
		var i = 0;
		while (i < words.length) {
			switch words[i] {
				case "video":
					video = true;
				case "audio":
					video = false;
				case "send":
					direction = send;
				case "receive":
					direction = receive;
				case "record":
					record = true;
				case "":
				case _:
					break;
			}
			i++;
		}
		final path = words.slice(i).join(" ");
		final file = (path.length > 0) ? mediaFile(path, out) : null;
		if (path.length > 0 && file == null)
			return null;
		if (file != null && direction == receive) {
			out.error("a file is played to the other side: not with receive");
			return null;
		}
		return {
			video: video,
			direction: direction,
			record: record,
			file: file
		};
	}

	/** The options, then the files **/
	static function completeOptions(arg:String):Commands.Candidates {
		final i = arg.lastIndexOf(" ") + 1;
		final word = arg.substr(i);
		return [
			for (group in [OPTIONS, Commands.completePath(word)]) [for (v in group) arg.substr(0, i) + v]
		];
	}

	/** The words of a command line, `"…"` for words with spaces **/
	static function words(line:String):Array<String> {
		final words = [];
		var word:Null<StringBuf> = null;
		var quoted = false;
		for (c in line.split("")) {
			if (c == '"')
				quoted = !quoted;
			else if (c == " " && !quoted) {
				if (word != null)
					words.push(word.toString());
				word = null;
				continue;
			}
			word ??= new StringBuf();
			if (c != '"')
				word.add(c);
		}
		if (word != null)
			words.push(word.toString());
		return words;
	}

	static function formatDuration(seconds:Float):String {
		final s = Std.int(seconds);
		return '${Std.int(s / 60)}:${StringTools.lpad(Std.string(s % 60), "0", 2)}';
	}
}

/**
	The media of a call: a `norc-rtc` process, controlled with JSON lines on stdin and stdout (see `rtc/protocol.md`).
	It exits at the end of its input: `close` ends the media.
**/
private class Rtc {
	final process:Process;

	/** `onMessage` gets the messages of the process, `onExit` its exit code, both called with `post` **/
	public function new(command:Array<String>, post:(() -> Void)->Void, onMessage:Dynamic->Void, onExit:Int->Void) {
		process = new Process(command[0], command.slice(1));
		Thread.create(() -> {
			while (true) {
				final line = try process.stdout.readLine() catch (_) break;
				final msg:Dynamic = try Json.parse(line) catch (_) null;
				if (msg != null)
					post(() -> onMessage(msg));
			}
			final code = process.exitCode();
			process.close();
			post(() -> onExit(code));
		});
		// its own errors are shown, diagnostics of GStreamer not
		Thread.create(() -> while (true) {
			final line = try process.stderr.readLine() catch (_) break;
			if (line.startsWith("norc-rtc:"))
				post(() -> Term.error(line));
		});
	}

	public function send(msg:Dynamic)
		try {
			process.stdin.writeString(Json.stringify(msg) + "\n");
			process.stdin.flush();
		} catch (_) {}

	public function close()
		try
			process.stdin.close()
		catch (_) {}
}
