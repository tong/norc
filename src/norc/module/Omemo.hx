package norc.module;

#if norc_omemo
import haxe.Json;
import haxe.io.Bytes;
import norc.Commands;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import omemo.Account;
import omemo.KeyPair;
import sys.FileSystem;
import sys.io.File;
import xmpp.DataForm;
import xmpp.Jid;
import xmpp.Message;
import xmpp.Omemo as Xep;
import xmpp.PubSub;
import xmpp.Response;
import xmpp.XML;
import xmpp.client.Stream;

/** What is stored: the device (keys, sessions, identities of other devices), and the chats with OMEMO on or off **/
private typedef State = {
	var account:Dynamic;
	var chats:haxe.DynamicAccess<Bool>;
}

/**
	OMEMO end-to-end encryption (XEP-0384, version 0.3, as Conversations, Dino, Gajim, Monal, Profanity): `omemo = 1`.

	This client is a device of the account: its id is in the account's device list, its bundle (public keys)
	published. Messages to a contact are encrypted for all its devices and the own other ones, if the contact has OMEMO
	(it publishes devices), unless turned off for the chat (`/omemo off`); `/omemo on` makes encryption required for
	the chat: a message is not sent if it can't be encrypted. Only the body is encrypted. Received messages are
	decrypted; encrypted messages are marked `🔒`.

	Trust: devices are trusted when first seen (blind trust before verification), until one of the contact's devices
	is verified (`/omemo trust`): then new devices are not used until verified too. `/omemo distrust` excludes a device.

	The state (private keys, sessions) is in `<state dir>/omemo/`, readable only by you, written after each change.
	Not yet: rooms, encrypted file uploads (`aesgcm://`), the messages of the server archive.
**/
class Omemo extends Module {
	/** A session receiving this many messages without sending one gets an empty message (a new ratchet step) **/
	static inline var STALE = 53;

	final messages:Messages;
	final contacts:Contacts;
	final dir:String;
	final path:String;

	var account:Null<Account>;

	/** Chats with OMEMO turned on (required) or off, by bare jid **/
	var chats = new Map<String, Bool>();

	/** The device lists of contacts and the own account (bare jid), as last received **/
	final deviceLists = new Map<String, Array<Int>>();

	/** Messages received in a session since the last one sent to it, to keep sessions fresh (`STALE`) **/
	final received = new Map<String, Int>();

	public function new(context:Context, messages:Messages, contacts:Contacts, stateDir:String) {
		super(context);
		this.messages = messages;
		this.contacts = contacts;
		dir = '$stateDir/omemo';
		path = '$dir/state.json';
		load();
		messages.incoming.push(receive);
		messages.transmit = transmit;
		messages.isEncrypted = m -> Lambda.exists(m.properties, e -> e.name == "encrypted" && e.is(Xep.XMLNS));
	}

	override public function features():Array<String>
		return [Xep.XMLNS_DEVICELIST_NOTIFY];

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "omemo",
				description: "OMEMO encryption: your device and fingerprint, the chats with it turned on or off",
				run: (args, out) -> status(out),
				subcommands: [
					{
						name: "on",
						args: "[jid]",
						description: "encrypt the messages to a contact (required: not sent if they can't be)",
						run: (args, out) -> setChat(args[0], true, out)
					},
					{
						name: "off",
						args: "[jid]",
						description: "don't encrypt the messages to a contact",
						run: (args, out) -> setChat(args[0], false, out)
					},
					{
						name: "default",
						args: "[jid]",
						description: "encrypt the messages to a contact if it has OMEMO (the default)",
						run: (args, out) -> setChat(args[0], null, out)
					},
					{
						name: "devices",
						args: "[jid]",
						description: "the devices of a contact (without jid: your own) with their fingerprints and trust",
						online: true,
						run: (args, out) -> devices(args[0], out)
					},
					{
						name: "trust",
						args: "<jid> <device>",
						description: "mark a device of a contact as verified (compare its fingerprint with the contact)",
						run: (args, out) -> trust(args[0], args[1], Verified, out)
					},
					{
						name: "distrust",
						args: "<jid> <device>",
						description: "don't encrypt for a device of a contact anymore",
						run: (args, out) -> trust(args[0], args[1], Untrusted, out)
					}
				]
			}
		];

	// --- the state ---

	function load() {
		if (!FileSystem.exists(path))
			return;
		try {
			final s:State = Json.parse(File.getContent(path));
			account = Account.fromJson(s.account);
			for (jid => on in s.chats ?? {})
				chats.set(jid, on);
		} catch (e) {
			// don't overwrite it: the keys would be lost
			Term.error('omemo: cannot read $path: $e (OMEMO is off)');
			account = null;
			return;
		}
		account.onChange = save;
	}

	/** Creates the device (keys, prekeys) the first time **/
	function create() {
		if (account != null || FileSystem.exists(path))
			return;
		account = Account.create();
		account.onChange = save;
		save();
		Term.info('omemo: new device ${account.deviceId}, fingerprint ${account.fingerprint()}');
	}

	/** Writes the state: to a new file, then renamed, in a directory readable only by you **/
	function save() {
		if (account == null)
			return;
		try {
			if (!FileSystem.exists(dir)) {
				FileSystem.createDirectory(dir);
				if (Sys.systemName() != "Windows")
					Sys.command("chmod", ["700", dir]);
			}
			final c = new haxe.DynamicAccess<Bool>();
			for (jid => on in chats)
				c.set(jid, on);
			final s:State = {account: account.toJson(), chats: c};
			File.saveContent('$path.new', Json.stringify(s));
			FileSystem.rename('$path.new', path);
		} catch (e)
			Term.error('omemo: cannot write $path: $e');
	}

	// --- the own device: device list and bundle ---

	override public function online() {
		create();
		if (account == null)
			return;
		final own = ownJid();
		Xep.loadDeviceList(stream, null, res -> {
			final list = Xep.parseDeviceList(res.payload);
			deviceLists.set(own, list);
			if (!list.contains(account.deviceId))
				publishDeviceList(list.concat([account.deviceId]));
		});
		publishBundle();
	}

	function publishDeviceList(list:Array<Int>)
		publish(handler -> Xep.publishDeviceList(stream, list, handler), Xep.NODE_DEVICELIST, "device list");

	function publishBundle() {
		final b = account.bundle();
		final bundle:xmpp.Omemo.OmemoBundle = {
			identityKey: KeyPair.encode(b.identityKey),
			signedPreKeyId: b.signedPreKeyId,
			signedPreKey: KeyPair.encode(b.signedPreKey),
			signedPreKeySignature: b.signedPreKeySignature,
			preKeys: [for (k in b.preKeys) {id: k.id, key: KeyPair.encode(k.key)}]
		};
		publish(handler -> Xep.publishBundle(stream, account.deviceId, bundle, handler), Xep.NODE_BUNDLES + account.deviceId, "bundle");
	}

	/**
		Publishes with the access model `open`; a node with another one (`precondition-not-met`) is configured to it,
		then published again
	**/
	function publish(send:(Response<XML>->Void)->Void, node:String, what:String, retry = true)
		send(res -> switch res {
			case Error(e) if (retry && e.app?.condition == "precondition-not-met"):
				final form = new DataForm(submit, null, null, [
					{variable: "FORM_TYPE", type: hidden, values: ['${PubSub.XMLNS}#node_config']},
					{variable: "pubsub#access_model", values: ["open"]}
				]);
				PubSub.configNode(stream, null, node, form, r -> if (r.error != null)
					Term.error('omemo: cannot publish the $what: ${Term.errorText(r.error)}')
				else
					publish(send, node, what, false));
			case Error(e):
				Term.error('omemo: cannot publish the $what: ${Term.errorText(e)}');
			case Result(_):
		});

	inline function ownJid():String
		return Jid.parseBare(stream.jid).toLowerCase();

	// --- received messages ---

	function receive(i:Incoming):Bool {
		final m = i.message;
		final encrypted = Xep.getEncrypted(m);
		if (encrypted == null)
			return Messages.pep(i, Xep.NODE_DEVICELIST, (from, payload) -> deviceListChanged(from.toLowerCase(), Xep.parseDeviceList(payload)));
		if (account == null || stream == null)
			return false;
		// a copy of a message of another own client: sent by the own account
		final sender = (m.from == null || i.carbon == sent) ? ownJid() : Jid.parseBare(m.from).toLowerCase();
		if (m.type == groupchat) {
			m.body = "(encrypted with OMEMO: not supported in rooms yet)";
			return false;
		}
		final key = Lambda.find(encrypted.keys, k -> k.rid == account.deviceId);
		if (key == null) {
			if (encrypted.payload == null)
				return true;
			m.body = "(encrypted with OMEMO, not for this device)";
			return false;
		}
		final firstSeen = account.identityOf(sender, encrypted.sid) == null;
		final d = try account.decrypt(sender, encrypted.sid, key.data, key.preKey, encrypted.iv, encrypted.payload) catch (e) {
			Term.error('omemo: cannot decrypt a message of ${contacts.name(sender)} (device ${encrypted.sid}): ${e.message}');
			return true;
		}
		if (firstSeen)
			newDevice(sender, encrypted.sid);
		if (d.preKeyUsed) {
			account.refillPreKeys();
			publishBundle();
		}
		final id = '$sender/${encrypted.sid}';
		received.set(id, (received.get(id) ?? 0) + 1);
		// a new session gets an answer (the sender stops sending its keys), a stale one a new ratchet step
		if (d.newSession || received.get(id) > STALE)
			sendEmpty(sender, encrypted.sid);
		if (d.plaintext == null)
			return true;
		m.body = d.plaintext.toString();
		return false;
	}

	function newDevice(jid:String, device:Int) {
		final i = account.identityOf(jid, device);
		if (i == null || isOwnDevice(jid, device))
			return;
		final who = (jid == ownJid()) ? "you have" : '${contacts.name(jid)} has';
		Term.info('omemo: $who a new device $device, fingerprint ${KeyPair.fingerprint(i.key)}');
	}

	inline function isOwnDevice(jid:String, device:Int):Bool
		return jid == ownJid() && device == account.deviceId;

	/** An empty message to a device (only the key): answers a new session, or a ratchet step **/
	function sendEmpty(jid:String, device:Int) {
		final e = account.encrypt(null, [{jid: jid, device: device}]);
		if (e.keys.length == 0)
			return;
		received.remove('$jid/$device');
		final m = new Message(jid, null);
		Xep.addTo(m, {sid: account.deviceId, keys: [for (k in e.keys) {rid: k.device, data: k.data, preKey: k.preKey}], iv: e.iv});
		stream.send(m);
	}

	function deviceListChanged(jid:String, list:Array<Int>) {
		deviceLists.set(jid, list);
		// another client published the own list without this device
		if (jid == ownJid() && account != null && !list.contains(account.deviceId))
			publishDeviceList(list.concat([account.deviceId]));
	}

	// --- sent messages ---

	/** Whether messages to `jid` are encrypted: on, off, or `null` (if it has OMEMO) **/
	function chatSetting(jid:String):Null<Bool>
		return chats.get(jid);

	/** Sends a message: encrypted (a copy, the shown message stays readable) if the chat is **/
	function transmit(m:Message, done:Bool->Void) {
		if (account == null || m.type == groupchat || m.body == null || m.to == null) {
			stream.send(m);
			done(true);
			return;
		}
		final to = Jid.parseBare(m.to).toLowerCase();
		final setting = chatSetting(to);
		if (setting == false) {
			stream.send(m);
			done(true);
			return;
		}
		deviceListOf(to, list -> {
			if (stream == null) {
				done(false);
				return;
			}
			if (list.length == 0 && to != ownJid()) {
				if (setting == true) {
					Term.error('omemo: ${contacts.name(to)} has no OMEMO devices: not sent (/omemo off ${contacts.name(to)} to send it unencrypted)');
					done(false);
				} else {
					stream.send(m);
					done(true);
				}
				return;
			}
			recipients(to, targets -> {
				if (stream == null) {
					done(false);
					return;
				}
				// to a contact: one of its devices; to yourself: one of your other devices
				final forContact = targets.filter(t -> t.jid == to);
				if (forContact.length == 0) {
					if (to == ownJid() && setting != true) {
						stream.send(m);
						done(true);
						return;
					}
					Term.error('omemo: cannot encrypt for ${contacts.name(to)} (no trusted device with a session, see /omemo devices ${contacts.name(to)}): not sent');
					done(false);
					return;
				}
				final e = account.encrypt(Bytes.ofString(m.body), targets);
				final copy = Message.fromXML(m.toXML());
				// the URL of an upload only in the encrypted body
				copy.properties = copy.properties.filter(p -> !(p.name == "x" && p.is(xmpp.Oob.XMLNS_X)));
				Xep.addTo(copy, {sid: account.deviceId, keys: [for (k in e.keys) {rid: k.device, data: k.data, preKey: k.preKey}], iv: e.iv,
					payload: e.payload});
				stream.send(copy);
				for (k in e.keys)
					received.remove('${k.jid}/${k.device}');
				// marks the shown message as encrypted
				m.properties.push(XML.create("encrypted").set("xmlns", Xep.XMLNS));
				done(true);
			});
		});
	}

	/** The device list of `jid` (bare): as known, else requested (empty if it has none or it can't be loaded) **/
	function deviceListOf(jid:String, handler:Array<Int>->Void) {
		final known = deviceLists.get(jid);
		if (known != null) {
			handler(known);
			return;
		}
		Xep.loadDeviceList(stream, (jid == ownJid()) ? null : jid, res -> {
			final list = Xep.parseDeviceList(res.payload);
			deviceLists.set(jid, list);
			handler(list);
		});
	}

	/**
		The devices to encrypt a message to `jid` for: its trusted ones and the own other ones, with a session (started
		from their bundles if needed)
	**/
	function recipients(jid:String, handler:Array<{jid:String, device:Int}>->Void) {
		final own = ownJid();
		deviceListOf(jid, list -> deviceListOf(own, ownList -> {
			final targets = [for (d in list) {jid: jid, device: d}];
			if (jid != own)
				for (d in ownList)
					targets.push({jid: own, device: d});
			final usable = targets.filter(t -> !isOwnDevice(t.jid, t.device) && trusted(t.jid, t.device));
			var pending = usable.length;
			function next() {
				if (--pending == 0)
					handler(usable.filter(t -> account.hasSession(t.jid, t.device)));
			}
			if (pending == 0) {
				handler([]);
				return;
			}
			for (t in usable)
				if (account.hasSession(t.jid, t.device))
					next();
				else
					startSession(t.jid, t.device, next);
		}));
	}

	/** Trust before verification: devices not decided yet are used until one of the jid's devices is verified **/
	function trusted(jid:String, device:Int):Bool {
		final i = account.identityOf(jid, device);
		if (i == null || i.trust == Undecided)
			return !Lambda.exists(account.identitiesOf(jid), o -> o.trust == Verified);
		return i.trust != Untrusted;
	}

	/** Starts a session with a device from its bundle (with a random prekey of it) **/
	function startSession(jid:String, device:Int, done:() -> Void)
		Xep.loadBundle(stream, (jid == ownJid()) ? null : jid, device, res -> {
			final b = Xep.parseBundle(res.payload);
			if (b == null || b.preKeys.length == 0) {
				Term.info('omemo: no bundle of ${contacts.name(jid)}, device $device' + (res.error != null ? ': ${Term.errorText(res.error)}' : ''));
				done();
				return;
			}
			try {
				final pk = b.preKeys[Std.random(b.preKeys.length)];
				final firstSeen = account.identityOf(jid, device) == null;
				account.startSession(jid, device, {
					identityKey: KeyPair.decode(b.identityKey),
					signedPreKeyId: b.signedPreKeyId,
					signedPreKey: KeyPair.decode(b.signedPreKey),
					signedPreKeySignature: b.signedPreKeySignature,
					preKeyId: pk.id,
					preKey: KeyPair.decode(pk.key)
				});
				if (firstSeen)
					newDevice(jid, device);
			} catch (e:omemo.Account.IdentityError) {
				Term.error('omemo: device $device of ${contacts.name(jid)} has another key than before: not used (it may be reinstalled; see /omemo devices ${contacts.name(jid)})');
			} catch (e) {
				Term.error('omemo: invalid bundle of ${contacts.name(jid)}, device $device: ${e.message}');
			}
			done();
		});

	// --- commands ---

	function status(out:Output) {
		if (account == null) {
			out.error("OMEMO has no device yet (it is created when online)");
			return;
		}
		final on = [for (jid => v in chats) if (v) jid], off = [for (jid => v in chats) if (!v) jid];
		out.data({
			device: account.deviceId,
			fingerprint: account.fingerprint(),
			on: on,
			off: off
		}, () -> {
			out.print('device ${account.deviceId}, fingerprint ${account.fingerprint()}');
			if (on.length > 0)
				out.print('on (required): ${on.map(contacts.name).join(", ")}');
			if (off.length > 0)
				out.print('off: ${off.map(contacts.name).join(", ")}');
			out.info("other chats: encrypted if the contact has OMEMO");
		});
	}

	function setChat(input:Null<String>, on:Null<Bool>, out:Output) {
		if (input == null) {
			out.error("which contact? (/omemo on <jid>, or in the chat mode)");
			return;
		}
		final jid = contacts.resolve(input, out);
		if (jid == null)
			return;
		final bare = Jid.parseBare(jid).toLowerCase();
		if (on == null)
			chats.remove(bare);
		else
			chats.set(bare, on);
		save();
		out.info(switch on {
			case true: 'messages to ${contacts.name(bare)} are encrypted (not sent if they can\'t be)';
			case false: 'messages to ${contacts.name(bare)} are not encrypted';
			case null: 'messages to ${contacts.name(bare)} are encrypted if it has OMEMO';
		});
	}

	function devices(input:Null<String>, out:Output) {
		if (account == null) {
			out.error("OMEMO has no device yet");
			return;
		}
		final jid = (input == null) ? ownJid() : contacts.resolve(input, out)?.toLowerCase();
		if (jid == null)
			return;
		final bare = Jid.parseBare(jid);
		final done = out.wait();
		// the list as published now
		deviceLists.remove(bare);
		deviceListOf(bare, list -> {
			final known = account.identitiesOf(bare);
			// the keys of devices without identity yet: from their bundles
			var pending = 1;
			final keys = new Map<Int, Bytes>();
			function finish() {
				if (--pending > 0)
					return;
				final rows = [
					for (d in list) {
						final i = known.get(d);
						final key = (i != null) ? i.key : keys.get(d);
						{
							device: d,
							fingerprint: (key != null) ? KeyPair.fingerprint(key) : null,
							trust: isOwnDevice(bare, d) ? "this device" : (i != null) ? (i.trust : String) : "unknown",
							session: account.hasSession(bare, d)
						}
					}
				];
				out.data({jid: bare, devices: rows}, () -> {
					if (rows.length == 0)
						out.info('${contacts.name(bare)} has no OMEMO devices');
					for (r in rows)
						out.print('${r.device}  ${r.fingerprint ?? "(no bundle)"}  ${r.trust}' + (r.session ? "" : ", no session"));
				});
				done();
			}
			for (d in list)
				if (!known.exists(d) && !isOwnDevice(bare, d)) {
					pending++;
					Xep.loadBundle(stream, (bare == ownJid()) ? null : bare, d, res -> {
						final b = Xep.parseBundle(res.payload);
						if (b != null)
							try
								keys.set(d, KeyPair.decode(b.identityKey))
							catch (_) {}
						finish();
					});
				}
			if (isOwnDevice(bare, account.deviceId))
				keys.set(account.deviceId, account.identity.pub);
			finish();
		});
	}

	function trust(input:String, device:String, trust:Trust, out:Output) {
		final jid = contacts.resolve(input, out);
		if (jid == null || account == null)
			return;
		final bare = Jid.parseBare(jid).toLowerCase();
		final id = Std.parseInt(device);
		if (id == null || account.identityOf(bare, id) == null) {
			out.error('no device $device of ${contacts.name(bare)} known (see /omemo devices ${contacts.name(bare)})');
			return;
		}
		account.setTrust(bare, id, trust);
		out.info('device $id of ${contacts.name(bare)}: $trust');
	}
}
#end
