package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.module.Messages;
import xmpp.Jid;
import xmpp.Mam;
import xmpp.client.Stream;

/**
	Message Archive Management (XEP-0313): `/history` shows the last messages with a contact (from the archive of the
	server), or of a joined room (from the archive of the room).
**/
class History extends Module {
	/** Messages shown without a count, and at most **/
	static inline var DEFAULT = 20;

	static inline var MAX = 100;

	final contacts:Contacts;
	final rooms:Rooms;

	/** The archive queries of the session **/
	var mam:Null<Mam>;

	public function new(context:Context, contacts:Contacts, rooms:Rooms) {
		super(context);
		this.contacts = contacts;
		this.rooms = rooms;
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
		mam = new Mam(stream);
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
					final items = r.items.filter(i -> i.message.body != null);
					final messages = [
						for (i in items)
							{
								id: i.id,
								from: i.message.from,
								to: i.message.to,
								body: i.message.body,
								date: (i.date != null) ? xmpp.DelayedDelivery.formatStamp(i.date) : null,
								own: (room != null) ? Jid.parseResource(i.message.from) == rooms.nickIn(room) : Jid.parseBare(i.message.from
									?? own) == own
							}
					];
					out.data({jid: jid, messages: messages, complete: r.complete}, () -> {
						if (items.length == 0 && !quiet)
							out.info('no messages with $jid in the archive');
						for (i in 0...items.length)
							show(items[i], messages[i].own, room, out);
					});
				case Failed(e) if (!quiet):
					out.error('cannot get the history of $jid: ${Term.errorText(e)}');
				case Failed(_):
			}
			done();
		});
	}

	/** A message of the archive, as received or sent messages are shown **/
	function show(item:MamItem, own:Bool, room:Null<String>, out:Output) {
		final m = item.message;
		if (room != null) {
			final nick = Jid.parseResource(m.from) ?? "";
			final label = Rooms.label(room);
			Messages.show('<$nick>', own ? null : '$room/$nick', m.body, item.date, Term.style(label, 2) + ' ', label.length + 1);
		} else if (own) {
			final to = Jid.parseBare(m.to ?? "");
			Messages.show('→ <${contacts.name(to)}>', null, m.body, item.date);
		} else {
			final from = Jid.parseBare(m.from);
			Messages.show('<${contacts.name(from)}>', from, m.body, item.date);
		}
	}
}
