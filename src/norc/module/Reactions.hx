package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Jid;
import xmpp.Message;
import xmpp.MessageReactions;

using xmpp.DelayedDelivery;

/**
	Message Reactions (XEP-0444): `/react` reacts to a message with emojis; the reactions of contacts and in rooms are
	shown (`<alice> reacted 👍 to "text"`), the `reaction` event.

	A message is referred to as for replies: the last of the contact or in the room (not your own), `^2` the one before.
	Each reactions message holds all reactions of its sender to a message, so `/react` adds to (or removes from) your
	reactions sent before.
**/
class Reactions extends Module {
	final messages:Messages;
	final contacts:Contacts;
	final rooms:Rooms;

	/** The own reactions by chat (bare jid, lowercase) and id of the message (`chat id`) **/
	final own = new Map<String, Array<String>>();

	public function new(context:Context, messages:Messages, contacts:Contacts, rooms:Rooms) {
		super(context);
		this.messages = messages;
		this.contacts = contacts;
		this.rooms = rooms;
		// first: other handlers take messages without body (e.g. with a chat state); a carbon copy comes again unwrapped
		messages.incoming.unshift(receive);
		rooms.incoming.push(receiveInRoom);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "react",
				args: "<jid> <reactions...>",
				description: "react to the last message of a contact or in a room with emojis (^2 first: the message before it); "
					+ "a reaction again removes it, - removes all",
				online: true,
				run: (args, out) -> react(args[0], args[1], out)
			}
		];

	override public function features():Array<String>
		return [MessageReactions.XMLNS];

	function react(input:String, text:String, out:Output) {
		final chat = rooms.resolve(input) ?? contacts.resolve(input, out);
		if (chat == null)
			return;
		final ref = Recent.reference(text);
		if (ref.n == 0) {
			out.error('invalid message: ${text.split(" ")[0]} (^2: the one before the last)');
			return;
		}
		final words = [for (w in ref.rest.split(" ")) if (w.length > 0) w];
		if (words.length == 0) {
			out.error("no reaction (e.g. 👍, - removes all)");
			return;
		}
		final target = messages.recent.last(chat, ref.n);
		if (target == null) {
			out.error('no message ${ref.n > 1 ? '^${ref.n} ' : ''}of ${name(chat)} to react to');
			return;
		}
		final key = '${chat.toLowerCase()} ${target.id}';
		final reactions = (own.get(key) ?? []).copy();
		if (words.length == 1 && words[0] == "-")
			reactions.resize(0);
		else
			for (w in words)
				if (!reactions.remove(w))
					reactions.push(w);
		final room = rooms.joined(chat);
		final m = new Message(chat, null, null, room ? groupchat : chat);
		MessageReactions.react(m, target.id, reactions);
		stream.send(m);
		own.set(key, reactions);
		// a room sends it back to all occupants
		if (!room)
			show(chat, '→ <${contacts.name(chat)}>', null, false, target.id, reactions, null);
		out.data({chat: chat, id: target.id, reactions: reactions}, () -> {});
		if (!room)
			event(chat, stream.jid, "you", null, target.id, reactions, true, m);
	}

	/** Reactions of a contact, or own reactions sent by another client of the account **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		final r = MessageReactions.getReactions(m);
		if (r == null)
			return false;
		final date = m.delay()?.date;
		if (i.carbon == sent) {
			if (m.to == null)
				return true;
			final chat = Jid.parseBare(m.to);
			own.set('${chat.toLowerCase()} ${r.id}', r.reactions);
			show(chat, '→ <${contacts.name(chat)}>', null, false, r.id, r.reactions, date);
			event(chat, m.from, "you", null, r.id, r.reactions, true, m, true);
		} else {
			final chat = (m.from != null) ? Jid.parseBare(m.from) : stream.domain;
			show(chat, '<${contacts.name(chat)}>', chat, false, r.id, r.reactions, date);
			event(chat, m.from ?? chat, contacts.name(chat), null, r.id, r.reactions, false, m, i.carbon == received);
		}
		return true;
	}

	/** Reactions of an occupant of a room, also the own (sent back by the room) **/
	function receiveInRoom(room:String, m:Message):Bool {
		final r = MessageReactions.getReactions(m);
		if (r == null)
			return false;
		final nick = Jid.parseResource(m.from) ?? "";
		final isOwn = nick == rooms.nickIn(room);
		if (isOwn)
			own.set('${room.toLowerCase()} ${r.id}', r.reactions);
		final label = Rooms.label(room);
		show(room, '<$nick>', isOwn ? null : '$room/$nick', true, r.id, r.reactions, m.delay()?.date, Term.style(label, 2) + ' ', label.length + 1);
		event(room, m.from, nick, room, r.id, r.reactions, isOwn, m);
		return true;
	}

	/** `12:03:41 <alice> reacted 👍 to "text"`; in rooms with the author of the message **/
	function show(chat:String, label:String, from:Null<String>, inRoom:Bool, id:String, reactions:Array<String>, date:Null<Date>, prefix = "",
			prefixLength = 0) {
		final target = messages.recent.find(chat, id);
		final what = (target == null) ? "a message" : (inRoom ? '<${target.name}> ' : '') + '"${Recent.excerpt(target.body, 40)}"';
		final text = (reactions.length > 0) ? 'reacted ${reactions.join(" ")} to $what' : 'removed the reactions to $what';
		Messages.show(label, from, text, date, prefix, prefixLength);
	}

	/** The `reaction` event: `chat` the contact or room (bare jid), `reactions` all of the sender (none: removed) **/
	function event(chat:String, from:Null<String>, name:String, room:Null<String>, id:String, reactions:Array<String>, isOwn:Bool, m:Message,
			carbon = false)
		emit("reaction", [chat, reactions.join(" ")], {
			chat: chat,
			from: from,
			name: name,
			room: room,
			id: id,
			reactions: reactions.join(" "),
			text: messages.recent.find(chat, id)?.body,
			own: isOwn,
			carbon: carbon,
			delayed: m.delay() != null
		});

	function name(chat:String):String
		return rooms.joined(chat) ? Rooms.label(chat) : contacts.name(chat);
}
