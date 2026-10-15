package norc.module;

/** A message shown in a chat, to refer to it (reactions, replies) **/
typedef RecentMessage = {
	/** The id other clients refer to it by: the `stanza-id` of the room in rooms, else the id of the message **/
	var id:String;

	/** The author: full jid, the occupant jid in rooms (`null` if unknown) **/
	var from:Null<String>;

	/** The author as shown: contact name or nick **/
	var name:String;

	/** The text, without the quote of a reply **/
	var body:String;

	/** Sent by the user (by any of their clients) **/
	var own:Bool;

	/** The id of the message, if `id` is another (the `stanza-id` of a room) **/
	var ?messageId:String;

	/** `id` is the `stanza-id` of the room (needed for moderation) **/
	var ?stanzaId:Bool;
}

/**
	The last messages of each chat (contact or room, by bare jid), in the order shown: the messages reactions and
	replies refer to (`^1` the last of the contact, `^2` the one before).
**/
class Recent {
	/** Messages kept per chat **/
	static inline var MAX = 200;

	final chats = new Map<String, Array<RecentMessage>>();

	/** Ids of retracted messages (`chat id`), also their message ids **/
	final retracted = new Map<String, Bool>();

	public function new() {}

	/** Adds a message shown last, replacing one with the same id **/
	public function add(chat:String, m:RecentMessage) {
		final list = messages(chat);
		remove(list, m.id);
		list.push(m);
		if (list.length > MAX)
			list.shift();
	}

	/** Adds messages of the archive (oldest first) before the messages shown since, those not known yet **/
	public function addOlder(chat:String, older:Array<RecentMessage>) {
		final list = messages(chat);
		final known = [for (m in list) m.id => true];
		final add = older.filter(m -> !known.exists(m.id));
		for (i in 0...add.length)
			list.insert(i, add[i]);
		while (list.length > MAX)
			list.shift();
	}

	/** The message with `id` in `chat`, `null` if unknown **/
	public function find(chat:String, id:String):Null<RecentMessage> {
		for (m in messages(chat))
			if (m.id == id)
				return m;
		return null;
	}

	/** Replaces the text of the message with `id` (a correction) **/
	public function correct(chat:String, id:String, body:String) {
		final m = find(chat, id);
		if (m != null)
			m.body = body;
	}

	/**
		The `n`-th last message of the others in `chat` (`own`: of the user), 1 the last; `null` if there is none.
	**/
	public function last(chat:String, n = 1, own = false):Null<RecentMessage> {
		final list = messages(chat);
		var i = list.length;
		while (--i >= 0)
			if (list[i].own == own && --n == 0)
				return list[i];
		return null;
	}

	/** Removes the retracted message with `id`; returns it, `null` if unknown **/
	public function retract(chat:String, id:String):Null<RecentMessage> {
		final key = chat.toLowerCase();
		retracted.set('$key $id', true);
		final m = find(chat, id);
		if (m == null)
			return null;
		messages(chat).remove(m);
		if (m.messageId != null)
			retracted.set('$key ${m.messageId}', true);
		return m;
	}

	/** The message with `id` (also its message id) in `chat` was retracted **/
	public function isRetracted(chat:String, id:String):Bool
		return retracted.exists('${chat.toLowerCase()} $id');

	public function clear() {
		chats.clear();
		retracted.clear();
	}

	/** The first line of `text`, at most `max` characters (with `…` if shortened) **/
	public static function excerpt(text:String, max:Int):String {
		final lines = StringTools.trim(text).split("\n");
		final line = truncate(StringTools.trim(lines[0]), max);
		return (lines.length > 1 && !StringTools.endsWith(line, "…")) ? line + "…" : line;
	}

	/** `text` with at most `max` characters (Unicode code points), with `…` if shortened **/
	public static function truncate(text:String, max:Int):String {
		final chars = [for (c in new haxe.iterators.StringIteratorUnicode(text)) c];
		if (chars.length <= max)
			return text;
		final b = new StringBuf();
		for (i in 0...max)
			b.addChar(chars[i]);
		return StringTools.rtrim(b.toString()) + "…";
	}

	/**
		The message a command refers to by `^n` at the start of `text` (`n` 1 without: the last), and the rest of the
		text; `n` is 0 for an invalid number.
	**/
	public static function reference(text:String):{n:Int, rest:String} {
		final text = StringTools.ltrim(text);
		if (!StringTools.startsWith(text, "^"))
			return {n: 1, rest: text};
		final end = text.indexOf(" ");
		final word = (end < 0) ? text : text.substr(0, end);
		final n = Std.parseInt(word.substr(1));
		return {n: (n != null && n > 0 && Std.string(n) == word.substr(1)) ? n : 0, rest: (end < 0) ? "" : StringTools.ltrim(text.substr(end))};
	}

	function messages(chat:String):Array<RecentMessage> {
		final key = chat.toLowerCase();
		var list = chats.get(key);
		if (list == null)
			chats.set(key, list = []);
		return list;
	}

	static function remove(list:Array<RecentMessage>, id:String) {
		for (m in list)
			if (m.id == id) {
				list.remove(m);
				return;
			}
	}
}
