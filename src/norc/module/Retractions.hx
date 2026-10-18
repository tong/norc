package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import norc.module.Recent;
import xmpp.Jid;
import xmpp.Message;
import xmpp.MessageModeration;
import xmpp.MessageRetraction;

using xmpp.DelayedDelivery;

/**
	Message Retraction (XEP-0424): `/retract` deletes one of your messages for everyone; retractions of contacts and in
	rooms are shown (`<alice> retracted "text"`), the `retraction` event. Moderated Message Retraction (XEP-0425):
	`/room moderate` removes a message of another occupant, as moderator of a room.

	Retractions are accepted only of the sender of the message (the same bare jid; in rooms the same occupant id if the room adds them, else the same nick), moderations
	only of the room itself. Their clients may have kept the message: a retraction asks to delete it, it can't enforce it.
**/
class Retractions extends Module {
	final messages:Messages;
	final contacts:Contacts;
	final rooms:Rooms;

	public function new(context:Context, messages:Messages, contacts:Contacts, rooms:Rooms) {
		super(context);
		this.messages = messages;
		this.contacts = contacts;
		this.rooms = rooms;
		// first: the fallback body of a retraction is not shown; a carbon copy comes again unwrapped
		messages.incoming.unshift(receive);
		rooms.incoming.push(receiveInRoom);
	}

	override public function commands():Array<Commands.Command> {
		final commands:Array<Commands.Command> = [
			{
				name: "retract",
				args: "<jid> [^n]",
				description: "retract (delete) your last message to a contact or in a room, for everyone (^2: the one before it); " +
				"their clients may have kept it",
				online: true,
				run: (args, out) -> retract(args[0], args[1] ?? "", out)
			}
		];
		// moderation needs rooms (disable_modules)
		if (rooms.handling)
			commands.push({
				name: "room",
				description: "group chats (multi-user chat rooms)",
				subcommands: [
					{
						name: "moderate",
						args: "<jid> [reason...]",
						description: "remove the last message of the others in a room for everyone, as moderator (^2 first: the one before it), " +
						"with an optional reason",
						online: true,
						run: (args, out) -> moderate(args[0], args[1] ?? "", out)
					}
				]
			});
		return commands;
	}

	override public function features():Array<String>
		return [MessageRetraction.XMLNS];

	function retract(input:String, text:String, out:Output) {
		final chat = rooms.resolve(input) ?? contacts.resolve(input, out);
		if (chat == null)
			return;
		final ref = Recent.reference(text);
		if (ref.n == 0 || ref.rest.length > 0) {
			out.error('not a message number: $text (/retract retracts your last message, /retract ^2 the one before it, …)');
			return;
		}
		final target = messages.recent.last(chat, ref.n, true);
		if (target == null) {
			out.error('no message ${ref.n > 1 ? '^${ref.n} ' : ''}of yours to ${name(chat)} to retract');
			return;
		}
		final room = rooms.joined(chat);
		final m = new Message(chat, null, null, room ? groupchat : chat);
		MessageRetraction.retract(m, target.id);
		stream.send(m);
		out.data({chat: chat, id: target.id}, () -> {});
		// a room sends it back to all occupants
		if (!room) {
			messages.recent.retract(chat, target.id);
			for (f in messages.retractions)
				f(chat, target.id, true);
			show('→ <${contacts.name(chat)}>', null, 'retracted ${quote(target)}', null);
			event(chat, stream.jid, "you", null, target, target.id, true, m);
		}
	}

	function moderate(input:String, text:String, out:Output) {
		final room = rooms.resolve(input);
		if (room == null) {
			out.error('not in the room $input (/rooms lists them)');
			return;
		}
		final ref = Recent.reference(text);
		if (ref.n == 0) {
			out.error('invalid message: ${text.split(" ")[0]} (^2: the one before the last)');
			return;
		}
		final target = messages.recent.last(room, ref.n);
		if (target == null) {
			out.error('no message ${ref.n > 1 ? '^${ref.n} ' : ''}in ${Rooms.label(room)} to remove');
			return;
		}
		if (target.stanzaId != true) {
			out.error('${Rooms.label(room)} gives its messages no ids (stanza-id): it does not support moderation');
			return;
		}
		final done = out.wait();
		MessageModeration.moderate(stream, room, target.id, (ref.rest.length > 0) ? ref.rest : null, res -> {
			if (res.error != null)
				out.error('cannot remove the message of ${target.name}: ${Term.errorText(res.error)}');
			else
				out.data({room: room, id: target.id}, () -> {});
			done();
		});
	}

	/** Retractions of a contact, or own retractions sent by another client of the account **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		final r = MessageRetraction.getRetraction(m);
		if (r == null)
			return false;
		// moderations come from rooms only
		if (r.moderated)
			return true;
		final date = m.delay()?.date;
		if (i.carbon == sent) {
			if (m.to == null)
				return true;
			final chat = Jid.parseBare(m.to);
			final target = messages.recent.find(chat, r.id);
			if (target != null && !target.own)
				return true;
			messages.recent.retract(chat, r.id);
			for (f in messages.retractions)
				f(chat, r.id, true);
			show('→ <${contacts.name(chat)}>', null, 'retracted ${quote(target)}', date);
			event(chat, m.from, "you", null, target, r.id, true, m, true);
		} else {
			final chat = (m.from != null) ? Jid.parseBare(m.from) : stream.domain;
			final target = messages.recent.find(chat, r.id);
			// only of the sender of the message
			if (target != null && (target.own || target.from == null || Jid.parseBare(target.from).toLowerCase() != chat.toLowerCase()))
				return true;
			messages.recent.retract(chat, r.id);
			for (f in messages.retractions)
				f(chat, r.id, false);
			show('<${contacts.name(chat)}>', chat, 'retracted ${quote(target)}', date);
			event(chat, m.from ?? chat, contacts.name(chat), null, target, r.id, false, m, i.carbon == received);
		}
		return true;
	}

	/** Retractions of occupants (also the own, sent back by the room), and moderations of the room **/
	function receiveInRoom(room:String, m:Message):Bool {
		final r = MessageRetraction.getRetraction(m);
		if (r == null)
			return false;
		final nick = Jid.parseResource(m.from);
		final label = Rooms.label(room);
		final prefix = Term.style(label, 2) + ' ';
		final target = messages.recent.find(room, r.id);
		if (r.moderated) {
			// only the room itself
			if (nick != null)
				return true;
			messages.recent.retract(room, r.id);
			final moderator = (r.moderatedBy != null) ? Jid.parseResource(r.moderatedBy) : null;
			final text = ((target != null) ? 'message of ${target.name} ${quote(target)}' : 'a message')
				+ ' removed'
				+ (moderator != null ? ' by $moderator' : '')
				+ (r.reason != null ? ': ${r.reason}' : '');
			Term.println(Term.timestamp(m.delay()?.date ?? Date.now()) + ' $prefix' + Term.style(text, 2));
			event(room, m.from, moderator ?? "", room, target, r.id, target?.own == true, m, false, r);
			return true;
		}
		// only of the author: the same occupant id, else nick
		if (nick == null || target != null && !rooms.isAuthor(room, target, nick, m.properties))
			return true;
		final isOwn = rooms.ownMessage(room, nick, m.properties);
		messages.recent.retract(room, r.id);
		show('<$nick>', isOwn ? null : '$room/$nick', 'retracted ${quote(target)}', m.delay()?.date, prefix, label.length + 1);
		event(room, m.from, nick, room, target, r.id, isOwn, m);
		return true;
	}

	static function show(label:String, from:Null<String>, text:String, date:Null<Date>, prefix = "", prefixLength = 0)
		Messages.show(label, from, text, date, prefix, prefixLength);

	/** The retracted message: `"text"`, `a message` if unknown **/
	static function quote(target:Null<RecentMessage>):String
		return (target == null) ? "a message" : '"${Recent.excerpt(target.body, 40)}"';

	/**
		The `retraction` event: `chat` the contact or room (bare jid), `target` the retracted message if known; for a
		moderation `from` is the room and `name` the moderator.
	**/
	function event(chat:String, from:Null<String>, name:String, room:Null<String>, target:Null<RecentMessage>, id:String, isOwn:Bool, m:Message,
			carbon = false, ?moderation:Retraction)
		emit("retraction", [chat, id], {
			chat: chat,
			from: from,
			name: name,
			room: room,
			id: id,
			text: target?.body,
			author: target?.name,
			own: isOwn,
			carbon: carbon,
			moderated: moderation != null,
			reason: moderation?.reason,
			delayed: m.delay() != null
		});

	function name(chat:String):String
		return rooms.joined(chat) ? Rooms.label(chat) : contacts.name(chat);
}
