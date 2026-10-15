package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.module.Messages;
import xmpp.ChatState;
import xmpp.Jid;

/**
	Chat State Notifications (XEP-0085): whether a contact is typing, paused, or left the conversation.
	Received states are events (`chatstate`), not printed; sent messages carry the `active` state, other programs
	(e.g. an editor) send states with `/chatstate`. Disabled with `chat_states = 0`.
**/
class ChatStates extends Module {
	static final STATES:Array<String> = ["active", "composing", "paused", "inactive", "gone"];

	final contacts:Contacts;
	final enabled:Bool;

	/** Called with the chat states of contacts (bare jid): received states, `active` for a message without state **/
	public var received:Null<(from:String, state:String) -> Void>;

	/** The jid is a room: states are sent to its occupants (groupchat) **/
	public var isRoom:String->Bool = _ -> false;

	/** Last state sent to each jid, a state is not sent twice in a row **/
	final sent = new Map<String, String>();

	public function new(context:Context, messages:Messages, contacts:Contacts, enabled:Bool) {
		super(context);
		this.contacts = contacts;
		this.enabled = enabled;
		messages.outgoing.push(m -> {
			if (enabled && m.body != null && m.type == chat) {
				ChatState.setChatState(m, active);
				sent.set(m.to, "active");
			}
		});
		messages.incoming.push(receive);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "chatstate",
				args: "<jid> <state>",
				description: "send your chat state to a contact: active, composing, paused, inactive, gone (for editors and other programs)",
				online: true,
				run: (args, out) -> send(args[0], args[1], out),
				complete: ["state" => _ -> STATES]
			}
		];

	override public function features():Array<String>
		return enabled ? [ChatState.XMLNS] : [];

	override public function detach() {
		super.detach();
		sent.clear();
	}

	function send(input:String, state:String, out:Output) {
		if (!enabled) {
			out.error("chat states are disabled (chat_states = 0)");
			return;
		}
		if (!STATES.contains(state)) {
			out.error('unknown chat state: $state (${STATES.join(", ")})');
			return;
		}
		final to = contacts.resolve(input, out);
		if (to != null)
			set(to, state);
	}

	/** The last state sent to `to` (a jid) **/
	public function last(to:String):Null<String>
		return sent.get(to);

	/** Sends `state` to `to` (a jid) while online, unless disabled or it was the last state sent to it **/
	public function set(to:String, state:String) {
		if (!enabled || sent.get(to) == state)
			return;
		sent.set(to, state);
		stream.send(ChatState.createChatStateMessage(to, state, isRoom(to) ? groupchat : chat));
	}

	/** The state of a contact (not of copies of messages of other own clients) **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		if (i.carbon != null || m.from == null || m.type == groupchat)
			return false;
		final from = Jid.parseBare(m.from);
		final state = ChatState.getChatState(m);
		if (state == null) {
			// a message of a client without chat states: not typing anymore
			if (m.body != null && received != null)
				received(from, "active");
			return false;
		}
		emit("chatstate", [from, state], {from: m.from, name: contacts.name(from), state: state});
		if (received != null)
			received(from, state);
		return m.body == null;
	}
}
