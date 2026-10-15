package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Jid;
import xmpp.Message;
import xmpp.Muc;
import xmpp.Presence;
import xmpp.Response;
import xmpp.XML;
import xmpp.client.Stream;

using StringTools;
using xmpp.DelayedDelivery;

/** A room the user is in (or joining) **/
private typedef Room = {
	/** Bare jid of the room **/
	final jid:String;

	/** The own nick in the room **/
	var nick:String;

	/** The room in the current session, `null` while disconnected **/
	var muc:Null<Muc>;

	/** Occupants by nick, with their presence **/
	final occupants:Map<String, Presence>;

	var ?subject:String;
}

/**
	Multi-User Chat (XEP-0045): `/room join` and `/room leave` enter and leave group chats, `/rooms` lists them.
	Messages of rooms are shown as `12:03:41 room <nick> text` and emitted as `room` events; messages to a joined
	room (`/msg`, chat mode) go to all occupants. Rooms are joined again after a reconnect.
	Invitations to rooms are shown with the command to join (`room-invite` event).
**/
class Rooms extends Module {
	final messages:Messages;
	final contacts:Contacts;

	/** The rooms by bare jid (lowercase) **/
	final rooms = new Map<String, Room>();

	/** Called when a room was joined with `/room join`, with the output of the command **/
	public var entered:Null<(room:String, out:Output) -> Void>;

	/** Called when a room was left (also when removed by the room), or the own nick in it changed **/
	public var changed:Null<(room:String) -> Void>;

	/** The chat service of the server, once found (`null`: not searched yet) **/
	var service:Null<{jid:Null<String>}>;

	public function new(context:Context, messages:Messages, contacts:Contacts) {
		super(context);
		this.messages = messages;
		this.contacts = contacts;
		// before other modules add elements for chats (e.g. receipt requests)
		messages.outgoing.push(m -> if (m.to != null && Jid.parseResource(m.to) == null && joined(m.to)) m.type = groupchat);
		messages.incoming.push(invitation);
	}

	override public function commands():Array<Commands.Command> {
		final complete:Map<String, Completion> = ["jid" => _ -> [for (r in rooms) r.jid], "contact" => _ -> contacts.completions()];
		return [
			{
				name: "rooms",
				description: "list the rooms (group chats) you are in",
				run: (args, out) -> list(out),
				subcommands: [
					{
						name: "leave",
						description: "leave all rooms",
						online: true,
						run: (args, out) -> for (r in [for (r in rooms) r]) leave(r.jid, out)
					}
				]
			},
			{
				name: "room",
				description: "group chats (multi-user chat rooms)",
				subcommands: [
					{
						name: "join",
						args: "<room> [nick]",
						description: "join a room: its jid, or its name on the chat service of your server; nick: default your local part",
						online: true,
						run: (args, out) -> join(args[0], args[1], out)
					},
					{
						name: "leave",
						args: "<jid>",
						description: "leave a room",
						online: true,
						run: (args, out) -> leave(args[0], out),
						complete: complete
					},
					{
						name: "occupants",
						aliases: ["who"],
						args: "<jid>",
						description: "list the occupants of a room",
						run: (args, out) -> occupants(args[0], out),
						complete: complete
					},
					{
						name: "subject",
						args: "<jid> [text...]",
						description: "show or set the subject of a room",
						run: (args, out) -> subject(args[0], args[1], out),
						complete: complete
					},
					{
						name: "nick",
						args: "<jid> <nick>",
						description: "change your nick in a room",
						online: true,
						run: (args, out) -> nick(args[0], args[1], out),
						complete: complete
					},
					{
						name: "invite",
						args: "<jid> <contact> [reason...]",
						description: "invite a contact to a room",
						online: true,
						run: (args, out) -> invite(args[0], args[1], args[2], out),
						complete: complete
					}
				]
			}
		];
	}

	override public function attach(stream:Stream) {
		super.attach(stream);
		// the traffic of rooms, before the contacts and messages
		final presence = stream.onPresence, message = stream.onMessage;
		stream.onPresence = p -> switch find(p.from)?.muc {
			case null: presence(p);
			case muc: muc.handlePresence(p);
		}
		stream.onMessage = m -> switch find(m.from)?.muc {
			case null: message(m);
			case muc: muc.handleMessage(m);
		}
		// after resuming a session, the server kept the rooms
		for (r in rooms)
			r.muc = create(r);
	}

	override public function online() {
		for (r in rooms) {
			r.occupants.clear();
			enter(r, error -> if (error != null) Term.error('cannot join ${r.jid} again: $error'));
		}
	}

	override public function detach() {
		super.detach();
		service = null;
		for (r in rooms)
			r.muc = null;
	}

	/** `jid` is a room the user is in (or joining) **/
	public function joined(jid:String):Bool
		return find(jid) != null;

	/** The jid of a room given by its jid or local part (see `room`), `null` if the user is in none **/
	public function resolve(input:String):Null<String>
		return room(input, null)?.jid;

	/** The own nick in a room **/
	public function nickIn(jid:String):Null<String>
		return find(jid)?.nick;

	function find(jid:Null<String>):Null<Room>
		return (jid == null) ? null : rooms.get(Jid.parseBare(jid).toLowerCase());

	/** The room given by `input` (its jid, or its local part if unique); writes an error to `out` if there is none **/
	function room(input:String, out:Null<Output>):Null<Room> {
		final r = find(input) ?? {
			final matches = [for (r in rooms) if (Jid.parseNode(r.jid) == input.toLowerCase()) r];
			(matches.length == 1) ? matches[0] : null;
		}
		if (r == null && out != null)
			out.error('not in the room $input (/rooms lists them)');
		return r;
	}

	function join(input:String, nick:Null<String>, out:Output) {
		final done = out.wait();
		jidOf(input, jid -> {
			if (jid == null) {
				out.error('no room $input: give its jid (room@service), your server has no chat service');
				return done();
			}
			if (joined(jid)) {
				out.info('already in $jid');
				return done();
			}
			final r:Room = {
				jid: jid.toLowerCase(),
				nick: nick ?? Jid.parseNode(stream.jid),
				muc: null,
				occupants: new Map()
			};
			// before the presences of the occupants arrive
			rooms.set(r.jid, r);
			r.muc = create(r);
			enter(r, error -> {
				if (error != null) {
					rooms.remove(r.jid);
					out.error('cannot join $jid: $error');
				} else {
					out.info('joined ${r.jid} as ${r.nick} (${Lambda.count(r.occupants)} occupants)');
					if (entered != null)
						entered(r.jid, out);
				}
				done();
			});
		});
	}

	/** Enters room `r` (again), `callback` gets the error or `null` **/
	function enter(r:Room, callback:Null<String>->Void) {
		r.muc.join(r.nick, null, res -> switch res {
			case Result(presence):
				r.nick = r.muc.nick;
				// the own presence, answering the join
				r.occupants.set(r.nick, (presence : Presence));
				if (created(presence))
					unlock(r);
				callback(null);
			case Error(e):
				callback(Term.errorText(e));
		});
	}

	/** The own presence when joining tells that the room was created (status 201) **/
	static function created(presence:Presence):Bool {
		for (x in presence.properties)
			if (x.is(Muc.XMLNS_USER))
				for (e in x.elements)
					if (e.name == "status" && e.get("code") == "201")
						return true;
		return false;
	}

	/** A created room is locked until configured: accepts the default configuration (an instant room) **/
	function unlock(r:Room)
		stream.set(XML.create("query").set("xmlns", '${Muc.XMLNS}#owner').append(XML.create("x").set("xmlns", "jabber:x:data").set("type", "submit")),
			r.jid, res -> switch res {
				case Error(e): Term.error('cannot unlock the new room ${r.jid}: ${Term.errorText(e)}');
				case _:
			});

	/** The jid of a room given by its jid, or by its name on the chat service of the server **/
	function jidOf(input:String, callback:Null<String>->Void) {
		if (input.contains("@"))
			return callback(Jid.parseBare(input));
		if (service != null)
			return callback(service.jid != null ? '$input@${service.jid}' : null);
		Discovery.findService(stream, Muc.XMLNS, jid -> {
			service = {jid: jid};
			callback(jid != null ? '$input@$jid' : null);
		});
	}

	function leave(input:String, out:Output) {
		final r = room(input, out);
		if (r == null)
			return;
		final done = out.wait();
		r.muc.leave(null, () -> {
			rooms.remove(r.jid);
			out.info('left ${r.jid}');
			notify(r);
			done();
		});
	}

	/** The room of `r` for messages and the own occupant, set up for the current stream **/
	function create(r:Room):Muc {
		final muc = new Muc(stream, Jid.parseDomain(r.jid), Jid.parseNode(r.jid));
		muc.onMessage = m -> receive(r, m);
		// private messages of occupants, messages of the room itself
		muc.onPrivateMessage = m -> messages.receive(m);
		muc.onPresence = p -> {
			final nick = Jid.parseResource(p.from);
			if (nick != null && p.type == unavailable)
				r.occupants.remove(nick);
			else if (nick != null)
				r.occupants.set(nick, p);
		}
		muc.onSubject = subject -> {
			// also sent when joining
			if (r.subject != subject && subject.length > 0)
				Term.notice('${label(r.jid)} subject: $subject');
			r.subject = subject;
		}
		// changed by the room (`/room nick` sets it before)
		muc.onNick = nick -> if (r.nick != nick) {
			r.nick = nick;
			Term.notice('${label(r.jid)} your nick is now $nick');
			notify(r);
		}
		muc.onError = e -> {
			Term.error('${r.jid}: ${Term.errorText(e)}');
			// the room doesn't exist anymore (e.g. a temporary room the server removed)
			if (e.condition == item_not_found && rooms.remove(r.jid))
				notify(r);
		}
		muc.onLeave = (reason, ?text) -> {
			// removed by the room (the own leave is handled by `leave`)
			rooms.remove(r.jid);
			final why = switch reason {
				case Kicked: "kicked from";
				case Banned: "banned from";
				case Destroyed(alternate): "destroyed:" + (alternate != null ? ' moved to $alternate,' : '');
				case _: "removed from";
			}
			Term.error('$why ${r.jid}' + (text != null && text.length > 0 ? ': $text' : ''));
			notify(r);
		}
		return muc;
	}

	/** A message to all occupants: `12:03:41 room <nick> text`, the `room` event **/
	function receive(r:Room, m:Message) {
		final nick = Jid.parseResource(m.from) ?? "";
		final own = nick == r.nick;
		final delay = m.delay();
		final mention = !own && r.nick.length > 0 && m.body.toLowerCase().contains(r.nick.toLowerCase());
		Messages.show('<$nick>', own ? null : '${r.jid}/$nick', m.body, delay?.date, Term.style(label(r.jid), 2) + ' ', label(r.jid).length + 1);
		emit("room", [r.jid, nick, m.body], {
			room: r.jid,
			nick: nick,
			body: m.body,
			id: m.id,
			own: own,
			delayed: delay != null,
			mention: mention
		});
	}

	function notify(r:Room)
		if (changed != null)
			changed(r.jid);

	/** The room in output: its local part **/
	public static function label(jid:String):String
		return Jid.parseNode(jid) ?? jid;

	/** An invitation to a room (direct, or through the room): shown with the command to join **/
	function invitation(i:Incoming):Bool {
		final inv = (i.carbon == null) ? Muc.getInvitation(i.message) : null;
		if (inv == null || joined(inv.room))
			return false;
		final from = (inv.from != null) ? contacts.name(Jid.parseBare(inv.from)) : "someone";
		Term.notice('$from invites you to ${inv.room}' + (inv.reason != null && inv.reason.length > 0 ? ' (${inv.reason})' : '')
			+ ': /room join ${inv.room}', 33);
		emit("room-invite", [inv.room, inv.from ?? ""], {room: inv.room, from: inv.from, reason: inv.reason});
		return i.message.body == null;
	}

	function list(out:Output) {
		final list = [
			for (r in rooms)
				{
					jid: r.jid,
					nick: r.nick,
					occupants: Lambda.count(r.occupants),
					subject: r.subject
				}
		];
		list.sort((a, b) -> Reflect.compare(a.jid, b.jid));
		out.data({rooms: list}, () -> {
			if (list.length == 0)
				out.info("in no rooms (/room join <room>)");
			for (r in list)
				out.print('  ${r.jid}' + Term.style(' as ${r.nick}, ${r.occupants} occupants', 2)
					+ (r.subject != null && r.subject.length > 0 ? ': ${r.subject}' : ''));
		});
	}

	function occupants(input:String, out:Output) {
		final r = room(input, out);
		if (r == null)
			return;
		final nicks = [for (nick in r.occupants.keys()) nick];
		nicks.sort((a, b) -> Reflect.compare(a.toLowerCase(), b.toLowerCase()));
		out.data({room: r.jid, occupants: [for (nick in nicks) {nick: nick, presence: Contacts.describe(state(r.occupants.get(nick)))}]}, () -> {
			out.info('${r.jid}: ${nicks.length} occupants');
			for (nick in nicks)
				out.print('  ' + ((nick == r.nick) ? Term.name(nick) : Term.name(nick, '${r.jid}/$nick'))
					+ Term.style(' ${Contacts.describe(state(r.occupants.get(nick)))}', 2));
		});
	}

	static function state(p:Presence)
		return {state: (p.show : Null<String>) ?? "available", status: p.status};

	function subject(input:String, text:Null<String>, out:Output) {
		final r = room(input, out);
		if (r == null)
			return;
		if (text == null) {
			out.data({room: r.jid, subject: r.subject}, () -> out.info('${r.jid}: ' + ((r.subject ?? "").length > 0 ? r.subject : "no subject")));
			return;
		}
		if (r.muc == null) {
			out.error("not connected");
			return;
		}
		r.muc.changeSubject(text);
	}

	function nick(input:String, nick:String, out:Output) {
		final r = room(input, out);
		if (r == null)
			return;
		final done = out.wait();
		final old = r.nick;
		r.nick = nick;
		r.muc.changeNick(nick, error -> {
			if (error != null) {
				r.nick = old;
				out.error('cannot change your nick in ${r.jid}: ${Term.errorText(error)}');
			} else {
				// the own presence with the new nick answers the change
				r.occupants.set(nick, new Presence());
				out.info('${r.jid}: your nick is now $nick');
				notify(r);
			}
			done();
		});
	}

	function invite(input:String, contact:String, reason:Null<String>, out:Output) {
		final r = room(input, out);
		final to = (r != null) ? contacts.resolve(contact, out) : null;
		if (to == null)
			return;
		r.muc.invite(to, reason);
		out.info('invited ${contacts.name(Jid.parseBare(to))} to ${r.jid}');
	}
}
