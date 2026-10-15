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
import xmpp.JingleRtp;
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

private typedef Call = {
	var id:Int;

	/** Full jid of the other side **/
	var peer:String;

	var incoming:Bool;
	var video:Bool;
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

	public function new(context:Context, contacts:Contacts, sessions:JingleSessions, helper:String) {
		super(context);
		this.contacts = contacts;
		this.sessions = sessions;
		final command = words(helper);
		final path = Files.which(command[0] ?? "");
		this.helper = (path != null) ? [path].concat(command.slice(1)) : null;
		sessions.handle(JingleRtp.XMLNS, incoming);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "call",
				args: "<jid> [media...]",
				description: "call a contact (audio; with video: /call <jid> video; playing a file instead of the microphone: /call <jid> <file>)",
				online: true,
				run: (args, out) -> call(args[0], args[1], out),
				complete: ["media" => arg -> ["video"].concat(Commands.completePath(arg))],
				subcommands: [
					{
						name: "accept",
						args: "[#id] [path...]",
						description: "accept a call (the only one if no number is given), playing the file at path instead of the microphone",
						online: true,
						run: (args, out) -> accept(find(args[0], Ringing, out), args[1], out)
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
				run: (args, out) -> list(out)
			}
		];

	override public function features():Array<String>
		return (helper != null) ? JingleRtp.FEATURES : [];

	override public function detach() {
		for (c in calls.copy())
			finish(c, "disconnected");
		super.detach();
	}

	function call(input:String, media:Null<String>, out:Output) {
		if (helper == null) {
			out.error("calls need norc-rtc (not found, see call_helper)");
			return;
		}
		// a file to play, else the media
		final file = (media != null && media != "video" && media != "audio") ? audioFile(media, out) : null;
		if (file == null && media != null && media != "video" && media != "audio")
			return;
		if (calls.length > 0) {
			out.error("already in a call (/calls, /call hangup)");
			return;
		}
		final jid = contacts.resolve(input, out);
		if (jid == null)
			return;
		final video = media == "video";
		final done = out.wait();
		findCallee(jid, video, out, peer -> {
			done();
			if (peer == null || calls.length > 0)
				return;
			final c = add(peer, false, video, Calling, out);
			c.file = file;
			out.info('#${c.id} calling ${name(c)} (${describeMedia(c)})');
			event(c, "calling");
			start(c);
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
		final c = add(session.peer, true, media.contains("video"), Ringing, TermOutput.instance);
		c.session = session;
		listen(c);
		session.info([XML.create("ringing").set("xmlns", JingleRtp.XMLNS_INFO)]);
		// with the terminal bell
		Term.notice('#${c.id} ${name(c)} is calling (${c.video ? "video" : "audio"}): /call accept ${c.id} or /call decline ${c.id}\x07', 1);
		event(c, "ringing");
	}

	function accept(c:Null<Call>, path:Null<String>, out:Output) {
		if (c == null)
			return;
		if (path != null && (c.file = audioFile(path, out)) == null)
			return;
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
		final muted = !c.muted.remove(media);
		if (muted)
			c.muted.push(media);
		c.rtc.send({type: "mute", media: media, muted: muted});
		out.info('$media ${muted ? "muted" : "unmuted"}');
	}

	/** Starts the media of `c`: the caller creates an offer, the callee answers the offer of the peer **/
	function start(c:Call) {
		try {
			final options = (c.video ? ["--video"] : []).concat(c.file != null ? ["--audio-file", c.file] : []);
			c.rtc = new Rtc(helper.concat(options), context.post, msg -> media(c, msg), code -> stopped(c, code));
		} catch (e) {
			c.out.error('cannot start ${helper[0]}: $e');
			end(c, failed_application, "failed");
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

	function add(peer:String, incoming:Bool, video:Bool, state:CallState, out:Output):Call {
		final c:Call = {
			id: nextId++,
			peer: peer,
			incoming: incoming,
			video: video,
			state: state,
			local: [],
			localCandidates: [],
			remoteCandidates: [],
			described: false,
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
					media: c.video ? "video" : "audio",
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
		v.set("media", c.video ? "video" : "audio");
		v.set("incoming", c.incoming);
		emit("call", [Jid.parseBare(c.peer), state], v);
	}

	function name(c:Call):String
		return contacts.name(Jid.parseBare(c.peer));

	/** The file at `path` (`~/` is the home directory) to play in a call, `null` with an error if there is none **/
	static function audioFile(path:String, out:Output):Null<String> {
		final file = Config.expandHome(path);
		if (!FileSystem.exists(file) || FileSystem.isDirectory(file)) {
			out.error('no such file: $path (media: video, or a file to play)');
			return null;
		}
		return FileSystem.absolutePath(file);
	}

	static function describeMedia(c:Call):String
		return (c.video ? "video" : "audio") + (c.file != null ? ', playing ${Path.withoutDirectory(c.file)}' : '');

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
