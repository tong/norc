package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.module.Messages;
import xmpp.Jid;
import xmpp.MessageArchiveManagement;
import xmpp.MessageReply;
import xmpp.MessageRetraction;
import xmpp.client.Stream;

/**
	Message Archive Management (XEP-0313): `/history` shows the last messages with a contact (from the archive of the
	server), or of a joined room (from the archive of the room). The messages shown can be reacted and replied to.
**/
class History extends Module {
	/** Messages shown without a count, and at most **/
	static inline var DEFAULT = 20;

	static inline var MAX = 100;

	final contacts:Contacts;
	final rooms:Rooms;
	final messages:Messages;

	/** The archive queries of the session **/
	var mam:Null<MessageArchiveManagement>;

	public function new(context:Context, contacts:Contacts, rooms:Rooms, messages:Messages) {
		super(context);
		this.contacts = contacts;
		this.rooms = rooms;
		this.messages = messages;
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "history",
				args: "<jid> [#count]",
				description: 'show the last messages with a contact or in a room, from the archive of the server ($DEFAULT, at most $MAX)',
				online: true,
				run: (args, out) -> history(args[0], (args[1] != null) ? Std.parseInt(args[1]) : DEFAULT, out)
			}
		];

	override public function attach(stream:Stream) {
		super.attach(stream);
		mam = new MessageArchiveManagement(stream);
		// the results of queries, before the messages
		final message = stream.onMessage;
		stream.onMessage = m -> if (!mam.handleMessage(m)) message(m);
	}

	override public function detach() {
		mam = null;
		super.detach();
	}

	/** Shows the last `count` messages with a contact, quietly nothing while disconnected or without archive **/
	public function recent(jid:String, count:Int, out:Output)
		if (mam != null && count > 0)
			history(jid, Std.int(Math.min(count, MAX)), out, true);

	function history(input:String, count:Int, out:Output, quiet = false) {
		if (count < 1 || count > MAX) {
			out.error('invalid count: $count (1 to $MAX)');
			return;
		}
		final room = rooms.resolve(input);
		final jid = room ?? contacts.resolve(input, out);
		if (jid == null)
			return;
		final own = Jid.parseBare(stream.jid);
		final query:MamQuery = {page: {max: count, before: ""}};
		if (room == null)
			query.with = Jid.parseBare(jid);
		final done = out.wait();
		mam.query(query, room, res -> {
			switch res {
				case Page(r):
					// without retractions and the messages they retract
					final retracted = retractedIds(r.items, room);
					final items = r.items.filter(i -> i.message.body != null && MessageRetraction.getRetraction(i.message) == null
						&& !retracted.exists(idOf(i, room)));
					final messages = [
						for (i in items)
							{
								id: i.id,
								from: i.message.from,
								to: i.message.to,
								body: MessageReply.getBody(i.message),
								date: (i.date != null) ? xmpp.DelayedDelivery.formatStamp(i.date) : null,
								own: (room != null) ? Jid.parseResource(i.message.from) == rooms.nickIn(room) : Jid.parseBare(i.message.from
									?? own) == own,
								reply_id: MessageReply.getReply(i.message)?.id
							}
					];
					remember(jid, room, items, [for (m in messages) m.own]);
					out.data({jid: jid, messages: messages, complete: r.complete}, () -> {
						if (items.length == 0 && !quiet)
							out.info('no messages with $jid in the archive');
						for (i in 0...items.length)
							show(jid, items[i], messages[i].own, room, out);
					});
				case Failed(e) if (!quiet):
					out.error('cannot get the history of $jid: ${Term.errorText(e)}');
				case Failed(_):
			}
			done();
		});
	}

	/**
		Keeps the messages of the archive of `jid` in the recent messages, to refer to them: in rooms by their archive id
		(the `stanza-id` of the room), else by their id.
	**/
	function remember(jid:String, room:Null<String>, items:Array<MamItem>, own:Array<Bool>) {
		final chat = Jid.parseBare(jid);
		final older = [];
		for (i in 0...items.length) {
			final m = items[i].message;
			final id = idOf(items[i], room);
			final body = MessageReply.getBody(m);
			if (id == null || body == null)
				continue;
			final name = (room != null) ? Jid.parseResource(m.from) ?? "" : own[i] ? "you" : contacts.name(chat);
			older.push({id: id, from: m.from, name: name, body: body, own: own[i], messageId: (m.id != id) ? m.id : null, stanzaId: room != null});
		}
		messages.recent.addOlder(chat, older);
	}

	/** The id messages refer to a message of the archive by: in rooms its archive id (the `stanza-id` of the room) **/
	static function idOf(item:MamItem, room:Null<String>):Null<String>
		return (room != null) ? item.id : item.message.id ?? item.id;

	/** The ids of the messages retracted in `items`: by their sender, or by the room (moderated) **/
	static function retractedIds(items:Array<MamItem>, room:Null<String>):Map<String, Bool> {
		function sender(m:xmpp.Message):String
			return (room != null) ? Jid.parseResource(m.from ?? "") ?? "" : Jid.parseBare(m.from ?? "").toLowerCase();
		final by = new Map<String, String>();
		for (i in items) {
			final r = MessageRetraction.getRetraction(i.message);
			if (r == null)
				continue;
			if (!r.moderated)
				by.set(r.id, sender(i.message));
			else if (room != null && Jid.parseResource(i.message.from ?? "") == null)
				by.set(r.id, "");
		}
		return [
			for (i in items) {
				final id = idOf(i, room);
				if (id != null && by.exists(id) && (by.get(id) == "" || by.get(id) == sender(i.message)))
					id => true;
			}
		];
	}

	/** A message of the archive of `jid`, as received or sent messages are shown **/
	function show(jid:String, item:MamItem, own:Bool, room:Null<String>, out:Output) {
		final m = item.message;
		final text = messages.text(Jid.parseBare(jid), m);
		if (room != null) {
			final nick = Jid.parseResource(m.from) ?? "";
			final label = Rooms.label(room);
			Messages.show('<$nick>', own ? null : '$room/$nick', text, item.date, Term.style(label, 2) + ' ', label.length + 1);
		} else if (own) {
			final to = Jid.parseBare(m.to ?? "");
			Messages.show('→ <${contacts.name(to)}>', null, text, item.date);
		} else {
			final from = Jid.parseBare(m.from);
			Messages.show('<${contacts.name(from)}>', from, text, item.date);
		}
	}
}
