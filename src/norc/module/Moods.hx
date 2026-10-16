package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Pep;

/**
	User Mood (XEP-0107): publish your mood (`/mood`), receive the moods of contacts via PEP (`mood` event).
**/
class Moods extends Module {
	static final MOODS = Macros.values(xmpp.Pep.Mood);

	final contacts:Contacts;

	/** The own mood, as last published **/
	var mood:Null<MoodData>;

	/** Last received mood of each contact (bare jid), to show only changes **/
	final moods = new Map<String, String>();

	public function new(context:Context, messages:Messages, contacts:Contacts) {
		super(context);
		this.contacts = contacts;
		messages.incoming.push(i -> Messages.pep(i, Pep.XMLNS_MOOD, receive));
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "mood",
				requires: "pep",
				args: "[mood] [text...]",
				description: "show or publish your mood (e.g. happy, tired, …) with an optional text (- stops publishing it)",
				online: true,
				run: (args, out) -> publish(args[0], args[1], out),
				complete: ["mood" => _ -> MOODS.concat(["-"])]
			}
		];

	override public function features():Array<String>
		return [Pep.XMLNS_MOOD + "+notify"];

	override public function detach() {
		super.detach();
		moods.clear();
		contacts.moods.clear();
	}

	function publish(value:Null<String>, text:Null<String>, out:Output) {
		if (value == null) {
			out.data({mood: mood?.mood, text: mood?.text}, () -> out.info('mood: ${describe(mood)}'));
			return;
		}
		if (value != "-" && !MOODS.contains(value)) {
			out.error('unknown mood: $value (/help mood, or tab to complete)');
			return;
		}
		final data:Null<MoodData> = (value == "-") ? null : {mood: value, text: text};
		request(out, "cannot publish the mood", handler -> Pep.publishMood(stream, data?.mood, data?.text, handler), _ -> {
			mood = data;
			out.info('mood: ${describe(data)}');
		});
	}

	function receive(from:String, payload:Null<xmpp.XML>) {
		if (payload == null)
			return;
		final data = Pep.parseMood(payload);
		final current = (data.mood != null) ? data : null;
		if (isOwn(from)) {
			mood = current;
			return;
		}
		if (current != null)
			contacts.moods.set(from, {mood: current.mood, text: current.text});
		else
			contacts.moods.remove(from);
		if (!change(moods, from, (current != null) ? describe(current) : null))
			return;
		if (current != null)
			Term.notice('${contacts.name(from)} is ${describe(current)}');
		emit("mood", [from, data.mood ?? "", data.text ?? ""], {
			from: from,
			name: contacts.name(from),
			mood: data.mood,
			text: data.text
		});
	}

	/** e.g. `happy (sun is shining)`, `-` without mood **/
	static function describe(data:Null<MoodData>):String
		return (data?.mood == null) ? "-" : StringTools.replace(data.mood, "_", " ") + (data.text != null
			&& data.text.length > 0 ? ' (${data.text})' : '');
}
