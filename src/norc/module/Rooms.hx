package norc.module;

import norc.Commands;
import norc.Forms;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import xmpp.Bookmarks;
import xmpp.DataForm;
import xmpp.Jid;
import xmpp.Message;
import xmpp.MessageReply;
import xmpp.Muc;
import xmpp.Presence;
import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.StanzaId;
import xmpp.XML;
import xmpp.client.Stream;

using Lambda;
using StringTools;
using xmpp.DelayedDelivery;

/** A room the user is in (or joining) **/
private typedef Room = {
	/** Bare jid of the room **/
	final jid:String;

	/** The own nick in the room **/
	var nick:String;

	var ?password:String;

	/** The room in the current session, `null` while disconnected **/
	var muc:Null<Muc>;

	/** Occupants by nick, with their presence **/
	final occupants:Map<String, Presence>;

	var ?subject:String;

	/** Joined (the own presence received): later presences are changes of the occupants **/
	var ?entered:Bool;

	/** New nicks of occupants changing their nick: their presence is no new occupant **/
	var ?renamed:Array<String>;
}

/**
	Multi-User Chat (XEP-0045): `/room join` and `/room leave` enter and leave group chats, `/rooms` lists them.
	Messages of rooms are shown as `12:03:41 room <nick> text` and emitted as `room` events; messages to a joined
	room (`/msg`, chat mode) go to all occupants. Rooms are joined again after a reconnect.
	Invitations to rooms are shown with the command to join (`room-invite` event).

	Bookmarks (XEP-0402, stored on the server, shared with the other clients of the account): `/bookmarks`; rooms
	bookmarked with autojoin are joined after the login, also when another client adds them.
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

	/** The module is enabled: rooms can be joined (else it is only used by other modules, see `new`) **/
	public final handling:Bool;

	/** The room of the room mode (bare jid, lowercase): its occupants entering and leaving are shown **/
	public var active:Null<String>;

	/**
		Called with each groupchat message of a room (bare jid), also without body, before it is shown;
		returning `true` ends its processing (e.g. reactions).
	**/
	public final incoming = new Array<(room:String, m:Message) -> Bool>();

	/** The last configuration form of a room, to complete field names **/
	var configForm:Null<DataForm>;

	/** The bookmarks by room jid (lowercase), loaded after the login **/
	final bookmarks = new Map<String, Bookmark>();

	/** Rooms listed by `/rooms find` at most (each is queried for its information) **/
	static inline var MAX_FOUND = 50;

	/** The chat service of the server, once found (`null`: not searched yet) **/
	var service:Null<{jid:Null<String>}>;

	/** Join the rooms bookmarked with autojoin after the login (`autojoin_bookmarks`) **/
	final autojoinBookmarks:Bool;

	/**
		Without `handling` (the module is disabled), nothing of messages is handled: the rooms are used by other modules
		(there are none).
	**/
	public function new(context:Context, messages:Messages, contacts:Contacts, autojoinBookmarks = true, handling = true) {
		this.handling = handling;
		this.autojoinBookmarks = autojoinBookmarks;
		super(context);
		this.messages = messages;
		this.contacts = contacts;
		if (!handling)
			return;
		// before other modules add elements for chats (e.g. receipt requests)
		messages.outgoing.push(m -> if (m.to != null && Jid.parseResource(m.to) == null && joined(m.to)) m.type = groupchat);
		messages.incoming.push(invitation);
		messages.incoming.push(bookmarkChanges);
	}

	override public function commands():Array<Commands.Command> {
		final complete:Map<String, Completion> = [
			"jid" => _ -> [for (r in rooms) r.jid],
			"contact" => arg -> contacts.completions(arg)
		];
		return [
			{
				name: "rooms",
				description: "list the rooms (group chats) you are in",
				run: (args, out) -> list(out),
				subcommands: [
					{
						name: "find",
						args: "[service]",
						description: "list the public rooms of the chat service of your server, or of another service (e.g. conference.example.org)",
						online: true,
						run: (args, out) -> findRooms(args[0], out)
					},
					{
						name: "leave",
						description: "leave all rooms",
						online: true,
						run: (args, out) -> for (r in [for (r in rooms) r])
							leave(r.jid, out)
					}
				]
			},
			{
				name: "bookmarks",
				description: "list the bookmarked rooms (stored on the server, shared with your other clients)",
				run: (args, out) -> listBookmarks(out),
				subcommands: [
					{
						name: "add",
						requires: "pep",
						args: "<jid> [nick]",
						description: "bookmark a room: joined after the login, by your other clients too",
						online: true,
						run: (args, out) -> addBookmark(args[0], args[1], out),
						complete: complete
					},
					{
						name: "autojoin",
						requires: "pep",
						args: "<jid> <state>",
						description: "join a bookmarked room after the login (on) or not (off), the bookmark is kept",
						online: true,
						run: (args, out) -> setAutojoin(args[0], args[1], out),
						complete: ["jid" => _ -> [for (b in bookmarks) b.jid], "state" => _ -> ["on", "off"]]
					},
					{
						name: "remove",
						requires: "pep",
						aliases: ["rm"],
						args: "<jid>",
						description: "remove the bookmark of a room (the room is not left)",
						online: true,
						run: (args, out) -> removeBookmark(args[0], out),
						complete: ["jid" => _ -> [for (b in bookmarks) b.jid]]
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
						name: "config",
						args: "<jid> [values...]",
						description: "show the configuration form of a room (as its owner), or change it: field=value (e.g. persistentroom=yes)",
						online: true,
						run: (args, out) -> config(args[0], args[1], out),
						complete: ["jid" => _ -> [for (r in rooms) r.jid], "values" => completeConfig]
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

	override public function features():Array<String>
		return [Bookmarks.XMLNS_NOTIFY];

	override public function attach(stream:Stream) {
		super.attach(stream);
		// the traffic of rooms, before the contacts and messages
		final presence = stream.onPresence, message = stream.onMessage;
		stream.onPresence = p -> switch find(p.from)?.muc {
			case null: presence(p);
			case muc: muc.handlePresence(p);
		}
		stream.onMessage = m -> switch find(m.from) {
			case null | {muc: null}: message(m);
			case r:
				if (m.type != groupchat || !Lambda.exists(incoming, f -> f(r.jid, m))) r.muc.handleMessage(m);
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
		// item-not-found: no bookmarks
		Bookmarks.load(stream, res -> {
			bookmarks.clear();
			for (b in Bookmarks.parseItems(res.payload))
				bookmarks.set(b.jid.toLowerCase(), b);
			for (b in bookmarks)
				autojoin(b);
		});
	}

	override public function detach() {
		super.detach();
		service = null;
		for (r in rooms)
			r.muc = null;
	}

	/** The number of rooms the user is in (joined) **/
	public function count():Int
		return Lambda.count(rooms, r -> r.entered == true);

	/** `jid` is a room the user is in (or joining) **/
	public function joined(jid:String):Bool
		return find(jid) != null;

	/** The jid of a room given by its jid or local part (see `room`), `null` if the user is in none **/
	public function resolve(input:String):Null<String>
		return room(input, null)?.jid;

	/** The rooms the user is in, by jid and local part, e.g. to complete input **/
	public function completions():Array<String>
		return [for (r in rooms) r.jid].concat([for (r in rooms) Jid.parseNode(r.jid)]);

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
				// on the terminal: the room mode
				if (entered != null && out == TermOutput.instance)
					entered(find(jid).jid, out);
				else
					out.info('already in $jid');
				return done();
			}
			joinRoom(jid, nick, null, r -> {
				if (r == null)
					return done();
				out.info('joined ${r.jid} as ${r.nick} (${Lambda.count(r.occupants)} occupants)');
				if (entered != null)
					entered(r.jid, out);
				done();
			}, out);
		});
	}

	/** Joins room `jid`; `callback` gets the room, or `null` after an error (written to `out`, else shown) **/
	function joinRoom(jid:String, nick:Null<String>, password:Null<String>, callback:Null<Room>->Void, ?out:Output) {
		final r:Room = {
			jid: jid.toLowerCase(),
			nick: nick ?? Jid.parseNode(stream.jid),
			password: password,
			muc: null,
			occupants: new Map()
		};
		// before the presences of the occupants arrive
		rooms.set(r.jid, r);
		r.muc = create(r);
		enter(r, error -> {
			if (error != null) {
				rooms.remove(r.jid);
				(out ?? TermOutput.instance).error('cannot join $jid: $error');
			}
			callback(error == null ? r : null);
		});
	}

	/** Joins the room of bookmark `b` if it is marked autojoin and not joined **/
	function autojoin(b:Bookmark)
		if (autojoinBookmarks && b.autojoin && !joined(b.jid))
			joinRoom(b.jid, b.nick, b.password, r -> if (r != null) Term.notice('joined ${r.jid} as ${r.nick} (bookmark)'));

	/** Enters room `r` (again), `callback` gets the error or `null` **/
	function enter(r:Room, callback:Null<String>->Void) {
		r.muc.join(r.nick, r.password, res -> switch res {
			case Result(presence):
				r.entered = true;
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

	/** An occupant entered, left or changed the nick (`known`: was in the room) **/
	function showOccupant(r:Room, nick:String, p:Presence, known:Bool) {
		final label = Term.style(label(r.jid), 2) + ' ' + Term.name(nick, '${r.jid}/$nick');
		if (p.type == unavailable) {
			final newNick = changedNick(p);
			if (newNick != null)
				(r.renamed ??= []).push(newNick);
			final status:Null<String> = p.status;
			Term.notice((newNick != null) ? '$label is now $newNick' : '$label left' + (status != null && status.length > 0 ? ' ($status)' : ''));
		} else if (!known && !(r.renamed?.remove(nick) ?? false))
			Term.notice('$label entered');
	}

	/** The new nick of an occupant leaving with a nick change (status 303), else `null` **/
	static function changedNick(p:Presence):Null<String> {
		for (x in p.properties)
			if (x.is(Muc.XMLNS_USER) && x.elements.exists(e -> e.name == "status" && e.get("code") == "303"))
				return x.elements.find(e -> e.name == "item")?.get("nick");
		return null;
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
		stream.set(XML.create("query").set("xmlns", '${Muc.XMLNS}#owner').append(XML.create("x").set("xmlns", "jabber:x:data").set("type", "submit")), r.jid,
			res -> switch res {
				case Error(e): Term.error('cannot unlock the new room ${r.jid}: ${Term.errorText(e)}');
				case _:
			});

	/** The jid of a room given by its jid, or by its name on the chat service of the server **/
	function jidOf(input:String, callback:Null<String>->Void) {
		if (input.contains("@"))
			return callback(Jid.parseBare(input));
		chatService(jid -> callback(jid != null ? '$input@$jid' : null));
	}

	/** The chat service of the server, `null` if it has none **/
	function chatService(callback:Null<String>->Void) {
		if (service != null)
			return callback(service.jid);
		Discovery.findService(stream, Muc.XMLNS, jid -> {
			service = {jid: jid};
			callback(jid);
		});
	}

	/** Lists the public rooms of a chat service (the items), with their names, occupants and descriptions **/
	function findRooms(input:Null<String>, out:Output) {
		final done = out.wait();
		function list(service:Null<String>) {
			if (service == null) {
				out.error("your server has no chat service: give one, e.g. /rooms find conference.example.org");
				return done();
			}
			request(out, 'cannot list the rooms of $service', h -> ServiceDiscovery.discoItems(stream, service, null, h), payload -> {
				final items = (payload == null) ? [] : ServiceDiscovery.parseItems(payload).slice(0, MAX_FOUND);
				final found = new Array<{
					jid:String,
					?name:String,
					?occupants:Int,
					?description:String
				}>();
				// the information of each room, in parallel
				var pending = items.length;
				function show() {
					found.sort((a, b) -> (b.occupants ?? 0) - (a.occupants ?? 0));
					out.data({service: service, rooms: found}, () -> {
						out.info('$service: ${found.length} public rooms' + (found.length > 0 ? " (/room join <jid>)" : ""));
						for (r in found)
							out.print('  ${r.jid}'
								+ (r.name != null && r.name != Jid.parseNode(r.jid) ? ' ${r.name}' : '')
								+ Term.style(r.occupants != null ? ' (${r.occupants} occupants)' : '', 2)
								+ (r.description != null && r.description.length > 0 ? ': ${r.description}' : ''));
					});
					done();
				}
				if (items.length == 0)
					return show();
				for (item in items)
					ServiceDiscovery.discoInfo(stream, item.jid, null, res -> {
						final info = (res.payload == null) ? null : ServiceDiscovery.parseInfo(res.payload);
						final form = info?.forms.find(f -> f.getValues("FORM_TYPE")[0] == "http://jabber.org/protocol/muc#roominfo");
						final occupants = Std.parseInt(form?.getValues("muc#roominfo_occupants")[0] ?? "");
						found.push({
							jid: item.jid,
							name: item.name ?? info?.identities.find(i -> i.category == "conference")?.name,
							occupants: occupants,
							description: form?.getValues("muc#roominfo_description")[0]
						});
						if (--pending == 0)
							show();
					});
			});
		}
		(input != null) ? list(input) : chatService(list);
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
			if (nick == null)
				return;
			final known = r.occupants.exists(nick);
			if (p.type == unavailable)
				r.occupants.remove(nick);
			else
				r.occupants.set(nick, p);
			if (r.entered == true && r.jid == active && nick != r.nick)
				showOccupant(r, nick, p, known);
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
		final body = MessageReply.getBody(m) ?? "";
		final mention = !own && r.nick.length > 0 && body.toLowerCase().contains(r.nick.toLowerCase());
		Messages.show('<$nick>', own ? null : '${r.jid}/$nick', messages.text(r.jid, m), delay?.date, Term.style(label(r.jid), 2) + ' ',
			label(r.jid).length + 1);
		// reactions and replies refer to the id the room gave it
		final id = StanzaId.getStanzaId(m, r.jid);
		messages.remember(r.jid, m, id, own, nick);
		for (f in messages.displayed)
			f(r.jid, m, own, true);
		final reply = MessageReply.getReply(m);
		emit("room", [r.jid, nick, body], {
			room: r.jid,
			nick: nick,
			body: body,
			id: m.id,
			stanza_id: id,
			own: own,
			delayed: delay != null,
			mention: mention,
			reply_id: reply?.id,
			reply_to: reply?.to
		});
	}

	function notify(r:Room)
		if (changed != null)
			changed(r.jid);

	/** The room in output: its local part **/
	public static function label(jid:String):String
		return Jid.parseNode(jid) ?? jid;

	function listBookmarks(out:Output) {
		final list = [for (b in bookmarks) b];
		list.sort((a, b) -> Reflect.compare(a.jid, b.jid));
		out.data({
			bookmarks: [
				for (b in list)
					{
						jid: b.jid,
						name: b.name,
						nick: b.nick,
						autojoin: b.autojoin,
						joined: joined(b.jid)
					}
			]
		}, () -> {
			if (list.length == 0)
				out.info("no bookmarks (/bookmarks add <room>)");
			for (b in list)
				out.print('  ${b.jid}' + (b.name != null ? ' ${b.name}' : '') + Term.style([
					for (s in [
						b.nick != null ? 'as ${b.nick}' : null,
						b.autojoin ? "autojoin" : null,
						joined(b.jid) ? "joined" : null
					])
						if (s != null) s
				].map(s -> ' $s').join(","), 2));
		});
	}

	function addBookmark(input:String, nick:Null<String>, out:Output) {
		final done = out.wait();
		jidOf(input, jid -> {
			if (jid == null) {
				out.error('no room $input: give its jid (room@service)');
				return done();
			}
			// changes of an existing bookmark keep its name and the data of other clients
			final b:Bookmark = Reflect.copy(bookmarks.get(jid.toLowerCase())) ?? {jid: jid, autojoin: true};
			b.autojoin = true;
			b.nick = nick ?? nickIn(jid) ?? b.nick;
			request(out, 'cannot bookmark $jid', h -> Bookmarks.set(stream, b, h), _ -> {
				bookmarks.set(jid.toLowerCase(), b);
				out.info('bookmarked $jid: joined after the login' + (b.nick != null ? ' as ${b.nick}' : ''));
			});
			done();
		});
	}

	/**
		Shows the configuration form of a room (as its owner), or changes it with `field=value` arguments: the form is
		submitted with all its current values and the changed ones (unmentioned settings are not reset).
	**/
	function config(input:String, values:Null<String>, out:Output) {
		final jid = resolve(input) ?? (input.contains("@") ? Jid.parseBare(input) : null);
		if (jid == null) {
			out.error('not in the room $input: give its jid');
			return;
		}
		final owner = '${Muc.XMLNS}#owner';
		request(out, 'cannot get the configuration of $jid', h -> stream.get(XML.create("query").set("xmlns", owner), jid, h), payload -> {
			final x = payload?.elements.first(e -> e.name == "x" && e.is(DataForm.XMLNS));
			if (x == null) {
				out.error('$jid has no configuration form');
				return;
			}
			final form = DataForm.fromXML(x);
			configForm = form;
			if (values == null) {
				out.data({room: jid, form: Forms.data(form)}, () -> {
					Forms.print(form, out);
					out.info('change it: /room config ${label(jid)} field=value … (short field names work, e.g. persistentroom=yes)');
				});
				return;
			}
			final changed = try Forms.parseValues(form, fullFieldNames(form, values)) catch (e:String) {
				out.error(e);
				return;
			}
			final all = [
				for (f in form.fields)
					if (f.variable != null && f.type != fixed) f.variable => f.values ?? []
			];
			for (k => v in changed)
				all.set(k, v);
			request(out, 'cannot change the configuration of $jid',
				h -> stream.set(XML.create("query").set("xmlns", owner).append(form.createSubmit(all)), jid, h),
				_ -> out.info('$jid: changed ${[for (k in changed.keys()) k].join(", ")}'));
		});
	}

	/** `field=value` arguments with short field names (the unique end of a name, e.g. `roomname`) completed **/
	static function fullFieldNames(form:DataForm, input:String):String
		return ~/(^|\s)([^\s=]+)=/g.map(input, re -> {
			final name = re.matched(2);
			final matches = [
				for (f in form.fields)
					if (f.variable != null && (f.variable.endsWith('_$name') || f.variable.endsWith('#$name'))) f.variable
			];
			final known = form.fields.exists(f -> f.variable == name);
			re.matched(1) + ((!known && matches.length == 1) ? matches[0] : name) + "=";
		});

	/** The fields of the last configuration form, to complete `field=` **/
	function completeConfig(arg:String):Array<String> {
		final i = arg.lastIndexOf(" ") + 1;
		return (configForm == null) ? [] : [
			for (f in configForm.fields)
				if (f.variable != null && f.type != fixed && f.type != hidden) arg.substr(0, i) + f.variable + "="
		];
	}

	/** The bookmark of a room given by its jid or local part, else `null` with an error **/
	function findBookmark(input:String, out:Output):Null<Bookmark> {
		final b = bookmarks.get(input.toLowerCase()) ?? [for (b in bookmarks) if (Jid.parseNode(b.jid) == input.toLowerCase()) b][0];
		if (b == null)
			out.error('no bookmark of $input (/bookmarks lists them)');
		return b;
	}

	function setAutojoin(input:String, state:String, out:Output) {
		if (state != "on" && state != "off") {
			out.error('invalid state: $state (on or off)');
			return;
		}
		final current = findBookmark(input, out);
		if (current == null)
			return;
		// only the flag changes: name, nick, password and the data of other clients are kept
		final b:Bookmark = Reflect.copy(current);
		b.autojoin = state == "on";
		request(out, 'cannot change the bookmark of ${b.jid}', h -> Bookmarks.set(stream, b, h), _ -> {
			bookmarks.set(b.jid.toLowerCase(), b);
			out.info('${b.jid}: ' + (b.autojoin ? "joined after the login" : "not joined after the login (still bookmarked)"));
		});
	}

	function removeBookmark(input:String, out:Output) {
		final b = findBookmark(input, out);
		if (b == null)
			return;
		request(out, 'cannot remove the bookmark of ${b.jid}', h -> Bookmarks.remove(stream, b.jid, h), _ -> {
			bookmarks.remove(b.jid.toLowerCase());
			out.info('removed the bookmark of ${b.jid}');
		});
	}

	/** Bookmarks changed (also by other clients): new rooms with autojoin are joined **/
	function bookmarkChanges(i:Incoming):Bool {
		final changes = (i.carbon == null) ? Bookmarks.getChanges(stream, i.message) : null;
		if (changes == null)
			return false;
		for (jid in changes.removed)
			if (jid == "*")
				bookmarks.clear();
			else
				bookmarks.remove(jid.toLowerCase());
		for (b in changes.set) {
			bookmarks.set(b.jid.toLowerCase(), b);
			autojoin(b);
		}
		return true;
	}

	/** An invitation to a room (direct, or through the room): shown with the command to join **/
	function invitation(i:Incoming):Bool {
		final inv = (i.carbon == null) ? Muc.getInvitation(i.message) : null;
		if (inv == null || joined(inv.room))
			return false;
		final from = (inv.from != null) ? contacts.name(Jid.parseBare(inv.from)) : "someone";
		Term.notice('$from invites you to ${inv.room}' + (inv.reason != null
			&& inv.reason.length > 0 ? ' (${inv.reason})' : '') + ': /room join ${inv.room}',
			33);
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
				out.print('  ${r.jid}'
					+ Term.style(' as ${r.nick}, ${r.occupants} occupants', 2)
					+ (r.subject != null && r.subject.length > 0 ? ': ${r.subject}' : ''));
		});
	}

	function occupants(input:String, out:Output) {
		final r = room(input, out);
		if (r == null)
			return;
		final nicks = [for (nick in r.occupants.keys()) nick];
		nicks.sort((a, b) -> Reflect.compare(a.toLowerCase(), b.toLowerCase()));
		out.data({
			room: r.jid,
			occupants: [
				for (nick in nicks)
					{nick: nick, presence: Contacts.describe(state(r.occupants.get(nick)))}
			]
		}, () -> {
			out.info('${r.jid}: ${nicks.length} occupants');
			for (nick in nicks)
				out.print('  '
					+ ((nick == r.nick) ? Term.name(nick) : Term.name(nick, '${r.jid}/$nick'))
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
