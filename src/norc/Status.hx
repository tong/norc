package norc;

/** A chat with unread messages **/
typedef UnreadChat = {
	/** Bare jid of the contact or room **/
	var jid:String;

	var name:String;
	var unread:Int;

	/** Messages mentioning your nick (rooms) **/
	var mentions:Int;

	var room:Bool;
}

typedef StatusCall = {
	var id:Int;

	/** Bare jid of the other side **/
	var jid:String;

	var name:String;

	/** `ringing` (incoming), `calling` (outgoing), `connecting`, `connected` **/
	var state:String;

	var incoming:Bool;

	/** `audio` or `video` **/
	var media:String;

	/** When the media connected (seconds since 1970), `null` before **/
	var since:Null<Float>;

	/** Muted media of your side (`audio`, `video`) **/
	var muted:Array<String>;

	var recording:Bool;
}

typedef StatusTransfer = {
	var id:Int;

	/** Bare jid of the other side **/
	var jid:String;

	var file:String;

	/** `send` or `receive` **/
	var direction:String;

	/** `offered` (to you, not accepted yet), `preparing` (your file being read), `active` **/
	var state:String;

	var size:Null<Float>;
	var bytes:Float;
}

/**
	What is going on, in one object: for the prompt, the terminal title, a status bar, and other programs (the
	`status` event, `/overview`). Lists are empty when there is nothing.
**/
typedef StatusData = {
	/** `online`, `connecting`, `reconnecting` or `offline` **/
	var connection:String;

	/** Your presence: `available`, `chat`, `away`, `xa`, `dnd`, and its status message **/
	var presence:String;

	var status:Null<String>;

	/** Unread messages of contacts (not rooms) **/
	var unread:Int;

	/** Unread messages of rooms, and of them mentioning your nick **/
	var unread_rooms:Int;

	var mentions:Int;

	/** The chats with unread messages, the most recent first **/
	var chats:Array<UnreadChat>;

	var calls:Array<StatusCall>;
	var transfers:Array<StatusTransfer>;

	/** Who asked to see your presence (bare jids) **/
	var requests:Array<String>;

	/** The rooms you are in **/
	var rooms:Array<{jid:String, name:String, nick:Null<String>}>;

	/** Contacts typing (`composing`) or paused **/
	var typing:Array<{jid:String, name:String, state:String}>;

	/** An ad-hoc command waiting for your input (`/command submit`) **/
	var command:Null<{jid:String, node:String, name:Null<String>}>;
}

/**
	The status of the client: collected after each event (`update`), and sent as the `status` event when it changed.
	Progress of file transfers alone changes it at most once a second.
**/
class Status {
	/** Seconds between events for the progress of file transfers only **/
	static inline var PROGRESS_INTERVAL = 1.0;

	final collect:() -> StatusData;
	final changed:StatusData->Void;

	/** The last status sent, without the progress of transfers; and with it **/
	var lastKey = "";

	var lastFull = "";
	var lastSent = 0.0;

	/** `collect` the status, `changed` gets it when it changed **/
	public function new(collect:() -> StatusData, changed:StatusData->Void) {
		this.collect = collect;
		this.changed = changed;
	}

	/** The current status **/
	public function get():StatusData
		return collect();

	/** Collects the status, calls `changed` if it changed (after each event) **/
	public function update() {
		final s = collect();
		final full = haxe.Json.stringify(s);
		final key = haxe.Json.stringify(withoutProgress(s));
		final now = Sys.time();
		if (key == lastKey && (full == lastFull || now - lastSent < PROGRESS_INTERVAL))
			return;
		lastKey = key;
		lastFull = full;
		lastSent = now;
		changed(s);
	}

	static function withoutProgress(s:StatusData):Dynamic {
		final copy:Dynamic = Reflect.copy(s);
		copy.transfers = [for (t in s.transfers) {id: t.id, state: t.state}];
		return copy;
	}

	/**
		The status in a few words, e.g. for the prompt or a title: `☎ alice · 4 unread · #norc @1 · ⇣ 1 · +1`;
		empty if nothing is going on (online, nothing unread, no calls, …).
	**/
	public static function summary(s:StatusData):String {
		final parts = [];
		if (s.connection != "online")
			parts.push(s.connection);
		for (c in s.calls)
			parts.push('☎ ${c.name}' + switch c.state {
				case "ringing": " ringing";
				case "calling": " calling";
				case "connecting": " connecting";
				case _: (c.since != null) ? ' ${duration(Sys.time() - c.since)}' : "";
			});
		if (s.unread > 0)
			parts.push('${s.unread} unread');
		if (s.mentions > 0)
			parts.push('@${s.mentions}');
		final offers = s.transfers.filter(t -> t.state == "offered").length;
		final active = s.transfers.length - offers;
		if (active > 0)
			parts.push('⇅ $active');
		if (offers > 0)
			parts.push('$offers file offer' + (offers > 1 ? "s" : ""));
		if (s.requests.length > 0)
			parts.push('+${s.requests.length} request' + (s.requests.length > 1 ? "s" : ""));
		if (s.command != null)
			parts.push("command waiting");
		return parts.join(" · ");
	}

	/** `3:07`, `1:02:03` **/
	static function duration(seconds:Float):String {
		final s = Std.int(seconds);
		final h = Std.int(s / 3600), m = Std.int(s % 3600 / 60), sec = s % 60;
		final two = (n:Int) -> StringTools.lpad(Std.string(n), "0", 2);
		return (h > 0) ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
	}
}

/**
	Unread messages per chat: messages arriving in a chat that isn't the current chat mode; entering the chat, or
	writing in it (also from another of your clients), reads it. Not the history sent when joining a room.
**/
class Unread {
	final chats = new Map<String, {unread:Int, mentions:Int, room:Bool, last:Float}>();

	public function new() {}

	/** A message arrived in `chat` (bare jid) **/
	public function add(chat:String, room:Bool, mention:Bool) {
		final key = chat.toLowerCase();
		final c = chats.get(key) ?? {unread: 0, mentions: 0, room: room, last: 0.0};
		c.unread++;
		if (mention)
			c.mentions++;
		c.last = Sys.time();
		chats.set(key, c);
	}

	/** `chat` was read **/
	public function clear(chat:String)
		chats.remove(chat.toLowerCase());

	/** The chats with unread messages, the most recent first; `name` gives their names **/
	public function list(name:(jid:String, room:Bool) -> String):Array<UnreadChat> {
		final keys = [for (k in chats.keys()) k];
		keys.sort((a, b) -> Reflect.compare(chats.get(b).last, chats.get(a).last));
		return [
			for (k in keys) {
				final c = chats.get(k);
				{jid: k, name: name(k, c.room), unread: c.unread, mentions: c.mentions, room: c.room};
			}
		];
	}
}
