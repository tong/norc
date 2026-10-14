package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import norc.module.Messages;
import xmpp.ChatState;
import xmpp.Jid;
import xmpp.Message;
import xmpp.client.Stream;

/**
	Chat State Notifications (XEP-0085): whether a contact is typing, paused, or left the conversation.
	Received states are events (`chatstate`), not printed; sent messages carry the `active` state, other programs
	(e.g. an editor) send states with `/chatstate`. Disabled with `chat_states = 0`.
**/
class ChatStates implements Module {
	static final STATES:Array<String> = ["active", "composing", "paused", "inactive", "gone"];

	final messages:Messages;
	final emit:Emit;
	final enabled:Bool;

	/** The jid of a contact given by name or jid, `null` (with an error) if unknown **/
	final resolve:(input:String, out:Output) -> Null<String>;

	/** The name of a contact (bare jid), or the jid **/
	final name:String->String;

	var stream:Null<Stream>;

	/** Last state sent to each jid, a state is not sent twice in a row **/
	final sent = new Map<String, String>();

	public function new(messages:Messages, emit:Emit, resolve:(input:String, out:Output) -> Null<String>, name:String->String, enabled:Bool) {
		this.messages = messages;
		this.emit = emit;
		this.resolve = resolve;
		this.name = name;
		this.enabled = enabled;
		messages.outgoing.push(m -> {
			if (this.enabled && m.body != null && m.type == chat) {
				ChatState.setChatState(m, active);
				sent.set(m.to, "active");
			}
		});
		messages.incoming.push(receive);
	}

	public function commands():Array<Commands.Command>
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

	public function features():Array<String>
		return enabled ? [ChatState.XMLNS] : [];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach() {
		stream = null;
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
		final to = resolve(input, out);
		if (to == null)
			return;
		if (sent.get(to) == state)
			return;
		sent.set(to, state);
		stream.send(ChatState.createChatStateMessage(to, state));
	}

	/** The state of a contact (not of copies of messages of other own clients) **/
	function receive(i:Incoming):Bool {
		final m = i.message;
		final state = ChatState.getChatState(m);
		if (state == null || i.carbon != null || m.from == null || m.type == groupchat)
			return false;
		final from = Jid.parseBare(m.from);
		emit("chatstate", [from, state], {from: m.from, name: name(from), state: state});
		return m.body == null;
	}
}
