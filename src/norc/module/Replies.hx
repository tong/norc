package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import xmpp.MessageReply;

/**
	Message Replies (XEP-0461): `/reply` replies to a message, quoting it for clients without replies. Replies of
	contacts and in rooms are shown with a line quoting the message replied to (see `Messages.text`).

	A message is referred to as for reactions: the last of the contact or in the room (not your own), `^2` the one before.
**/
class Replies extends Module {
	/** The quote of the message replied to (for clients without replies) at most, in characters **/
	static inline var MAX_QUOTE = 300;

	final messages:Messages;
	final contacts:Contacts;
	final rooms:Rooms;

	public function new(context:Context, messages:Messages, contacts:Contacts, rooms:Rooms) {
		super(context);
		this.messages = messages;
		this.contacts = contacts;
		this.rooms = rooms;
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "reply",
				args: "<jid> <text...>",
				description: "reply to the last message of a contact or in a room (^2 first: the message before it; \\n for a newline)",
				online: true,
				run: (args, out) -> reply(args[0], args[1], out)
			}
		];

	override public function features():Array<String>
		return [MessageReply.XMLNS];

	function reply(input:String, text:String, out:Output) {
		final chat = rooms.resolve(input) ?? contacts.resolve(input, out);
		if (chat == null)
			return;
		final ref = Recent.reference(text);
		if (ref.n == 0) {
			out.error('invalid message: ${text.split(" ")[0]} (^2: the one before the last)');
			return;
		}
		final body = ref.rest;
		if (StringTools.trim(body).length == 0) {
			out.error("no text to reply");
			return;
		}
		final target = messages.recent.last(chat, ref.n);
		if (target == null) {
			out.error('no message ${ref.n > 1 ? '^${ref.n} ' : ''}of ${rooms.joined(chat) ? Rooms.label(chat) : contacts.name(chat)} to reply to');
			return;
		}
		final m = messages.send(chat, body, null, m -> MessageReply.reply(m, target.id, target.from, Recent.truncate(target.body, MAX_QUOTE)));
		out.data({chat: chat, id: m.id, reply_id: target.id}, () -> {});
	}
}
