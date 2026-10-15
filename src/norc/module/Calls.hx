package norc.module;

import haxe.Json;
import haxe.io.Path;
import norc.Commands;
import norc.Config;
import norc.Files;
import norc.Module;
import norc.Output;
import norc.Term;
import sys.FileSystem;
import sys.io.Process;
import sys.thread.Thread;
import xmpp.Jid;
import xmpp.Jingle;
import xmpp.ExternalServices;
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

	/** A file played instead of the microphone **/
	var ?file:String;

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
**/
class Calls extends Module {
	final contacts:Contacts;
	final sessions:JingleSessions;

	/** The command of the media program, `null` if it is not found **/
	final helper:Null<Array<String>>;

	final calls = new Array<Call>();
	var nextId = 1;

	/** The settings of calls (call_* keys, stun, turn) **/
	final account:Config.Account;

	/** The server offers its STUN and TURN servers (XEP-0215), `null` while unknown **/
	var externalServices:Null<Bool>;

	public function new(context:Context, contacts:Contacts, sessions:JingleSessions, account:Config.Account) {
		super(context);
		this.contacts = contacts;
		this.sessions = sessions;
		this.account = account;
		final command = words(account.callHelper ?? "norc-rtc");
		final path = Files.which(command[0] ?? "");
		this.helper = (path != null) ? [path].concat(command.slice(1)) : null;
		sessions.handle(JingleRtp.XMLNS, incoming);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "call",
				args: "<jid> [options...]",
				description: "call a contact; options: video, send or receive (only one direction), a file to play instead of the microphone",
				online: true,
				run: (args, out) -> call(args[0], args[1], out),
				complete: ["options" => completeOptions],
				subcommands: [
					{
						name: "accept",
						args: "[#id] [options...]",
						description: "accept a call (the only one if no number is given); options: audio (without video), send or receive, a file to play",
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
		return (helper != null) ? JingleRtp.FEATURES : [];

	override public function detach() {
		for (c in calls.copy())
			finish(c, "disconnected");
		// another server may offer other services
		externalServices = null;
		super.detach();
	}

	function call(input:String, words:Null<String>, out:Output) {
		if (helper == null) {
			out.error("calls need norc-rtc (not found, see call_helper)");
			return;
		}
		final options = parseOptions(words, out);
		if (options == null)
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
		findCallee(jid, video, out, peer -> {
			done();
			if (peer == null || calls.length > 0)
				return;
			final c = add(peer, false, options.direction, video ? options.direction : none, Calling, out);
			c.file = options.file;
			out.info('#${c.id} calling ${name(c)} (${describeMedia(c)})');
			event(c, "calling");
			// one connection for all media only with clients supporting it (e.g. not Dino)
			ServiceDiscovery.discoInfo(stream, peer, null, res -> {
				c.bundle = res.payload != null && ServiceDiscovery.parseInfo(res.payload).features.contains(JingleRtp.XMLNS_GROUPING);
				if (calls.contains(c))
					start(c);
			});
		});
	}

	/** A call requested by a peer **/
	function incoming(session:JingleSession) {
		final media = [for (c in session.contents) JingleRtp.media(c)];
		if (helper == null || media.contains(null)) {
			session.terminate(unsupported_applications);
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
		// what the caller offers: the senders of each media
		function offered(media:String):Direction {
			final content = session.contents.find(c -> JingleRtp.media(c) == media);
			return (content == null) ? none : switch content.senders ?? JingleSenders.both {
				case JingleSenders.initiator: receive;
				case JingleSenders.responder: send;
				case JingleSenders.none: none;
				case _: both;
			}
		}
		final c = add(session.peer, true, offered("audio"), offered("video"), Ringing, TermOutput.instance);
		c.session = session;
		// as offered
		c.bundle = JingleRtp.group(session.payload) != null;
		listen(c);
		session.info([XML.create("ringing").set("xmlns", JingleRtp.XMLNS_INFO)]);
		// with the terminal bell
		Term.notice('#${c.id} ${name(c)} is calling (${describeMedia(c)}): /call accept ${c.id} or /call decline ${c.id}\x07', 1);
		event(c, "ringing");
	}

	function accept(c:Null<Call>, words:Null<String>, out:Output) {
		if (c == null)
			return;
		final options = parseOptions(words, out);
		if (options == null)
			return;
		// what is offered, as far as wanted
		final audio = c.audio.and(options.direction);
		final video = (options.video == false) ? none : c.video.and(options.direction);
		if (audio == none && video == none) {
			out.error('nothing left to accept: in this call you can only do ${describeMedia(c)}');
			return;
		}
		if (options.file != null && !audio.sends()) {
			out.error("the file can't be played: you don't send audio");
			return;
		}
		c.audio = audio;
		c.video = video;
		c.file = options.file;
		c.out = out;
		c.state = Connecting;
		start(c);
	}

	function hangup(c:Null<Call>)
		if (c != null)
			switch c.state {
				case Ringing: end(c, decline, "declined");
				case Calling: end(c, cancel, "cancelled");
				case _: end(c, success, "hung up");
			}

	/** Ends call `c` from the own side, `text` tells why **/
	function end(c:Null<Call>, condition:JingleReason, text:String) {
		if (c == null)
			return;
		c.ending = text;
		if (c.session != null)
			c.session.terminate(condition);
		else
			finish(c, text);
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
					.concat(c.file != null ? ["--audio-file", c.file] : []);
				c.rtc = new Rtc(helper.concat(options), context.post, msg -> media(c, msg), code -> stopped(c, code));
			} catch (e) {
				c.out.error('cannot start ${helper[0]}: $e');
				end(c, failed_application, "failed");
			}
		});

	/** The options of norc-rtc of the settings (devices, echo cancellation, video size and rate, bitrates) **/
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
			out.error("calls need norc-rtc (not found, see call_helper)");
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
				final services = [for (s in ExternalServices.parse(res.payload)) {type: s.type.toLowerCase(), uri: ExternalServices.uri(s)}];
				callback(options([for (s in services) if (s.type == "stun" && s.uri != null) s.uri], [
					for (s in services)
						if (s.type != "stun" && s.uri != null) s.uri
				]));
			});
		}
		switch externalServices {
			case true: request();
			case false: callback(options([], []));
			case null:
				ServiceDiscovery.discoInfo(stream, stream.domain, null, res -> {
					externalServices = res.payload != null && ServiceDiscovery.parseInfo(res.payload).features.contains(ExternalServices.XMLNS);
					externalServices ? request() : callback(options([], []));
				});
		}
	}

	/** A message of the media of `c` **/
	function media(c:Call, msg:Dynamic) {
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
		final session = sessions.jingle.createSession(c.peer);
		c.session = session;
		listen(c);
		session.onAccept = contents -> {
			c.state = Connecting;
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
					state: (c.state : CallState).getName().toLowerCase(),
					duration: (c.connected != null) ? Std.int(Sys.time() - c.connected) : null
				}
		];
		out.data({calls: list}, () -> {
			if (list.length == 0)
				out.info("no calls");
			for (c in list)
				out.print('  #${c.id} ${c.incoming ? "from" : "to"} ${c.peer} (${c.media}' + (c.file != null ? ', playing ${Path.withoutDirectory(c.file)}' : '')
					+ ') ${c.state}' + (c.duration != null ? ' ${formatDuration(c.duration)}' : ''));
		});
	}

	/** The `call` event: `ringing` (incoming), `calling` (outgoing), `connected`, `ended` **/
	function event(c:Call, state:String, ?values:haxe.DynamicAccess<Dynamic>) {
		final v = values ?? {};
		v.set("from", c.peer);
		v.set("name", name(c));
		v.set("state", state);
		v.set("media", (c.video != none) ? "video" : "audio");
		v.set("audio", (c.audio : String));
		v.set("video", (c.video : String));
		v.set("incoming", c.incoming);
		emit("call", [Jid.parseBare(c.peer), state], v);
	}

	function name(c:Call):String
		return contacts.name(Jid.parseBare(c.peer));

	/** The file at `path` (`~/` is the home directory) to play in a call, `null` with an error if there is none **/
	static function audioFile(path:String, out:Output):Null<String> {
		final file = Config.expandHome(path);
		if (!FileSystem.exists(file) || FileSystem.isDirectory(file)) {
			out.error('no such file: $path (options: video, audio, send, receive, a file to play)');
			return null;
		}
		return FileSystem.absolutePath(file);
	}

	/** e.g. `audio`, `video` (both directions), `audio, receiving video`, `sending audio, playing song.ogg` **/
	static function describeMedia(c:Call):String {
		final media = (c.audio == both && c.video == both) ? ["video"] : [
			for (m in [{name: "audio", d: c.audio}, {name: "video", d: c.video}])
				switch m.d {
					case both: m.name;
					case send: 'sending ${m.name}';
					case receive: 'receiving ${m.name}';
					case none: continue;
				}
		];
		return media.join(", ") + (c.file != null ? ', playing ${Path.withoutDirectory(c.file)}' : '');
	}

	/**
		The options of `/call` and `/call accept`: words (`video`, `audio`: without video, `send`, `receive`), then a file
		to play; `null` with an error if the file doesn't exist
	**/
	static function parseOptions(input:Null<String>, out:Output):Null<{video:Null<Bool>, direction:Direction, file:Null<String>}> {
		final words = (input ?? "").split(" ");
		var video:Null<Bool> = null;
		var direction = both;
		var i = 0;
		while (i < words.length) {
			switch words[i] {
				case "video": video = true;
				case "audio": video = false;
				case "send": direction = send;
				case "receive": direction = receive;
				case "":
				case _: break;
			}
			i++;
		}
		final path = words.slice(i).join(" ");
		final file = (path.length > 0) ? audioFile(path, out) : null;
		if (path.length > 0 && file == null)
			return null;
		if (file != null && direction == receive) {
			out.error("a file is played to the other side: not with receive");
			return null;
		}
		return {video: video, direction: direction, file: file};
	}

	static function completeOptions(arg:String):Array<String> {
		final i = arg.lastIndexOf(" ") + 1;
		final word = arg.substr(i);
		return [for (v in ["video", "audio", "send", "receive"].concat(Commands.completePath(word))) arg.substr(0, i) + v];
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
