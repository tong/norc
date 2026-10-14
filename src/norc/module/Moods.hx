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

/**
	User Mood (XEP-0107): publish your mood (`/mood`), receive the moods of contacts via PEP (`mood` event).
**/
class Moods implements Module {
	static final MOODS:Array<String> = [
		"afraid", "amazed", "amorous", "angry", "annoyed", "anxious", "aroused", "ashamed", "bored", "brave", "calm",
		"cautious", "cold", "confident", "confused", "contemplative", "contented", "cranky", "crazy", "creative",
		"curious", "dejected", "depressed", "disappointed", "disgusted", "dismayed", "distracted", "embarrassed",
		"envious", "excited", "flirtatious", "frustrated", "grateful", "grieving", "grumpy", "guilty", "happy", "hopeful",
		"hot", "humbled", "humiliated", "hungry", "hurt", "impressed", "in_awe", "in_love", "indignant", "interested",
		"intoxicated", "invincible", "jealous", "lonely", "lost", "lucky", "mean", "moody", "nervous", "neutral",
		"offended", "outraged", "playful", "proud", "relaxed", "relieved", "remorseful", "restless", "sad", "sarcastic",
		"satisfied", "serious", "shocked", "shy", "sick", "sleepy", "spontaneous", "stressed", "strong", "surprised",
		"thankful", "thirsty", "tired", "undefined", "weak", "worried"
	];

	final emit:Emit;

	/** The name of a contact (bare jid), or the jid **/
	final name:String->String;

	var stream:Null<Stream>;

	/** The own mood, as last published **/
	var mood:Null<MoodData>;

	/** Last received mood of each contact (bare jid), to show only changes **/
	final moods = new Map<String, String>();

	public function new(messages:Messages, emit:Emit, name:String->String) {
		this.emit = emit;
		this.name = name;
		messages.incoming.push(receive);
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "mood",
				args: "[mood] [text...]",
				description: "show or publish your mood (e.g. happy, tired, …) with an optional text (- stops publishing it)",
				online: true,
				run: (args, out) -> publish(args[0], args[1], out),
				complete: ["mood" => _ -> MOODS.concat(["-"])]
			}
		];

	public function features():Array<String>
		return [Pep.XMLNS_MOOD + "+notify"];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach() {
		stream = null;
		moods.clear();
	}

	function publish(value:Null<String>, text:Null<String>, out:Output) {
		if (value == null) {
			out.data({mood: mood?.mood, text: mood?.text}, () -> out.info('mood: ' + (mood?.mood != null ? describe(mood) : "-")));
			return;
		}
		if (value != "-" && !MOODS.contains(value)) {
			out.error('unknown mood: $value (/help mood, or tab to complete)');
			return;
		}
		final data:Null<MoodData> = (value == "-") ? null : {mood: value, text: text};
		final done = out.wait();
		Pep.publishMood(stream, data?.mood, data?.text, res -> {
			switch res {
				case Result(_):
					mood = data;
					out.info('mood: ' + (data != null ? describe(data) : "-"));
				case Error(e):
					out.error('cannot publish the mood: ${e.condition}');
			}
			done();
		});
	}

	function receive(i:Incoming):Bool {
		final m = i.message;
		final event = (m.from == null) ? null : PubSub.getEvent(m);
		switch event {
			case Items(node, items, _) if (node == Pep.XMLNS_MOOD):
				final from = Jid.parseBare(m.from);
				for (item in items) {
					final e = item.firstElement;
					if (e == null)
						continue;
					final data = Pep.parseMood(e);
					if (stream != null && stream.jid != null && from == Jid.parseBare(stream.jid)) {
						mood = (data.mood != null) ? data : null;
						continue;
					}
					final text = (data.mood != null) ? describe(data) : null;
					if (moods.get(from) == text)
						continue;
					if (text == null)
						moods.remove(from);
					else
						moods.set(from, text);
					if (text != null)
						Term.println(Term.timestamp(Date.now()) + ' ' + Term.style('${name(from)} is $text', 2));
					emit("mood", [from, data.mood ?? "", data.text ?? ""], {from: from, name: name(from), mood: data.mood, text: data.text});
				}
				return true;
			case _:
				return false;
		}
	}

	/** e.g. `happy (sun is shining)` **/
	static function describe(data:MoodData):String
		return StringTools.replace(data.mood, "_", " ") + (data.text != null && data.text.length > 0 ? ' (${data.text})' : '');
}
