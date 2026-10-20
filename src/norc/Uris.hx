package norc;

import xmpp.Jid;
import xmpp.URI;

using StringTools;

/**
	What opening an XMPP URI does (`/open`, `norc <uri>`): the chat to enter, a command run at once (only those
	showing something), and a command or message put into the input line (left to the user to send, so that a link on a
	web page doesn't act on its own).
**/
typedef Opened = {
	/** Enter the chat mode with this jid **/
	var ?chat:String;

	/** A command line run at once **/
	var ?run:String;

	/** Put into the input line: a message (in the chat mode) or a command **/
	var ?input:String;

	/** Parameters of the URI left out (not supported) **/
	var ?ignored:Array<String>;
}

/**
	XMPP URIs (RFC 5122) and their query types (XEP-0147): `xmpp:alice@example.org?message;body=Hi`.

	@see [XEP-0147: XMPP URI Scheme Query Components](https://xmpp.org/extensions/xep-0147.html)
**/
class Uris {
	/** The query types `open` handles **/
	public static final ACTIONS = ["message", "join", "roster", "subscribe", "remove", "vcard", "disco", "command"];

	/** What opening `uri` does; throws (a message) if it can't be opened **/
	public static function open(uri:URI):Opened {
		final jid = uri.jid;
		if (jid == null || jid.length == 0)
			throw 'no jid in the URI';
		if (!Jid.isValid(jid))
			throw 'invalid jid: $jid';
		final params = uri.params ?? [];
		function param(name:String):Null<String> {
			final v = params.get(name);
			return (v == null || v.length == 0) ? null : v;
		}
		// the parameters used, the others are reported
		var used:Array<String> = [];
		final quoted = quote(jid);
		final opened:Opened = switch uri.action {
			case null | "message":
				used = ["body"];
				final body = param("body");
				{chat: jid, input: (body != null) ? message(body) : null};
			case "join":
				{input: '/room join $quoted'};
			case "roster" | "subscribe":
				used = ["name"];
				final name = param("name");
				{input: '/contacts add $quoted' + (name != null ? ' ${name.trim()}' : '')};
			case "remove":
				{input: '/contacts remove $quoted'};
			case "vcard":
				{run: '/vcard $quoted'};
			case "disco":
				used = ["request", "node", "type"];
				final node = param("node");
				{run: '/disco ${param("request") == "items" ? "items" : "info"} $quoted' + (node != null ? ' ${quote(node)}' : '')};
			case "command":
				used = ["node", "action"];
				final node = param("node");
				// the list of commands is shown, running one is left to the user
				(node != null) ? {input: '/command run $quoted ${quote(node)}'} : {run: '/command $quoted'};
			case action:
				throw 'unsupported action: $action (supported: ${ACTIONS.join(", ")})';
		}
		final ignored = [for (k in params.keys()) if (!used.contains(k)) k];
		if (ignored.length > 0) {
			ignored.sort(Reflect.compare);
			opened.ignored = ignored;
		}
		return opened;
	}

	/** `body` as a line of the chat mode: line breaks as `\n`, `//` before a `/` (else it would be a command) **/
	static function message(body:String):String {
		final line = Commands.escape(body.trim());
		return line.startsWith("/") ? '/$line' : line;
	}

	/** A word of a command line: in `"` if it has spaces **/
	static function quote(word:String):String
		return (word.contains(" ") || word.contains("\t")) ? '"$word"' : word;
}
