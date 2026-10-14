package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Jid;
import xmpp.Pep;
import xmpp.PubSub;
import xmpp.Response;
import xmpp.client.Stream;

using StringTools;

/**
	User Tune (XEP-0118): publish the music you are listening to (`/tune`, e.g. from a hook of your music player),
	receive the tunes of contacts via PEP (`tune` event).
**/
class Tunes implements Module {
	static final FIELDS = [
		"artist", "title", "source", "track", "length", "composer", "performer", "lyricist", "genre", "date", "language", "rating", "uri"
	];

	final emit:Emit;

	/** The name of a contact (bare jid), or the jid **/
	final name:String->String;

	var stream:Null<Stream>;

	/** The own tune, as last published **/
	var tune:Null<Tune>;

	/** Last received tune of each contact (bare jid), to show only changes **/
	final tunes = new Map<String, String>();

	public function new(messages:Messages, emit:Emit, name:String->String) {
		this.emit = emit;
		this.name = name;
		messages.incoming.push(receive);
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "tune",
				args: "[tune...]",
				description: 'show or publish the music you are listening to: "artist - title", or fields as key=value '
					+ '(${FIELDS.join(", ")}; length in seconds, values with spaces in quotes); - stops publishing it',
				online: true,
				run: (args, out) -> publish(args[0], out)
			}
		];

	public function features():Array<String>
		return [Pep.XMLNS_TUNE + "+notify"];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach() {
		stream = null;
		tunes.clear();
	}

	function publish(input:Null<String>, out:Output) {
		if (input == null) {
			out.data({tune: tune}, () -> out.info('tune: ' + (tune != null ? describe(tune) : "-")));
			return;
		}
		final data = if (input == "-") null else try parse(input) catch (e:String) {
			out.error(e);
			return;
		}
		final done = out.wait();
		Pep.publishTune(stream, data, res -> {
			switch res {
				case Result(_):
					tune = data;
					out.info('tune: ' + (data != null ? describe(data) : "-"));
				case Error(e):
					out.error('cannot publish the tune: ${e.condition}');
			}
			done();
		});
	}

	/** `artist - title`, or `key=value` fields (values in quotes may contain spaces); throws a message if invalid **/
	static function parse(input:String):Tune {
		final tune:Tune = {};
		if (!~/^[a-z]+=/.match(input)) {
			final i = input.indexOf(" - ");
			if (i == -1)
				tune.title = input;
			else {
				tune.artist = input.substr(0, i).trim();
				tune.title = input.substr(i + 3).trim();
			}
			return tune;
		}
		final re = ~/^([a-z]+)=("([^"]*)"|(\S*))\s*/;
		var rest = input;
		while (rest.length > 0) {
			if (!re.match(rest))
				throw 'invalid field: ${rest.split(" ")[0]} (key=value)';
			final key = re.matched(1);
			final value = re.matched(3) ?? re.matched(4);
			if (!FIELDS.contains(key))
				throw 'unknown field: $key (${FIELDS.join(", ")})';
			switch key {
				case "length", "rating":
					final n = Std.parseInt(value);
					if (n == null || n < 0)
						throw '$key must be a number: $value';
					Reflect.setField(tune, key, n);
				case _:
					Reflect.setField(tune, key, value);
			}
			rest = re.matchedRight();
		}
		return tune;
	}

	function receive(i:Incoming):Bool {
		final m = i.message;
		final event = (m.from == null) ? null : PubSub.getEvent(m);
		switch event {
			case Items(node, items, _) if (node == Pep.XMLNS_TUNE):
				final from = Jid.parseBare(m.from);
				for (item in items) {
					final e = item.firstElement;
					if (e == null)
						continue;
					final data = Pep.parseTune(e);
					final empty = Reflect.fields(data).length == 0;
					if (stream != null && stream.jid != null && from == Jid.parseBare(stream.jid)) {
						tune = empty ? null : data;
						continue;
					}
					final text = empty ? null : describe(data);
					if (tunes.get(from) == text)
						continue;
					if (text == null)
						tunes.remove(from);
					else
						tunes.set(from, text);
					if (text != null)
						Term.println(Term.timestamp(Date.now()) + ' ' + Term.style('${name(from)} is listening to $text', 2));
					emit("tune", [from, data.artist ?? "", data.title ?? ""], {
						from: from,
						name: name(from),
						artist: data.artist,
						title: data.title,
						source: data.source,
						track: data.track,
						length: data.length,
						uri: data.uri
					});
				}
				return true;
			case _:
				return false;
		}
	}

	/** e.g. `Portishead – Glory Box (Dummy, 5:01)` **/
	static function describe(tune:Tune):String {
		final main = [tune.artist, tune.title].filter(s -> s != null && s.length > 0).join(" – ");
		final details = [tune.source].filter(s -> s != null && s.length > 0);
		if (tune.length != null && tune.length > 0)
			details.push('${Std.int(tune.length / 60)}:${Std.string(tune.length % 60).lpad("0", 2)}');
		return (main.length > 0 ? main : tune.uri ?? "?") + (details.length > 0 ? ' (${details.join(", ")})' : '');
	}
}
