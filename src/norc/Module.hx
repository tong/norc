package norc;

import xmpp.Jid;
import xmpp.Response;
import xmpp.XML;
import xmpp.client.Stream;

/**
	Emits an event: runs its hooks and sends it to the API clients.
	`args` are the arguments of the hooks, `values` the data of the API event (JSON values) and the environment
	variables of the hooks (as strings, booleans as `1` or `0`).
**/
typedef Emit = (event:String, args:Array<String>, values:haxe.DynamicAccess<Dynamic>) -> Void;

/** What the client provides to its modules **/
typedef Context = {
	final emit:Emit;

	/** Runs a callback on the main thread, e.g. of another thread or a socket **/
	final post:(() -> Void)->Void;
}

/**
	A feature of the client (e.g. file transfer): its commands, and its part of each session.

	Modules live as long as the client; each connection gets a new stream (`attach`), which ends with `detach`.
	The defaults do nothing: a module overrides what it needs.
**/
abstract class Module {
	final context:Context;

	/** The stream of the session, `null` while disconnected **/
	var stream:Null<Stream>;

	function new(context:Context)
		this.context = context;

	/** Commands, registered once **/
	public function commands():Array<Commands.Command>
		return [];

	/** Protocols to advertise for service discovery, in addition to those of registered request handlers **/
	public function features():Array<String>
		return [];

	/** A new stream: register request handlers (before login, they are part of the capabilities) **/
	public function attach(stream:Stream)
		this.stream = stream;

	/** Logged in (not after resuming a session) **/
	public function online() {}

	/** The stream ended (disconnected or quit) **/
	public function detach()
		stream = null;

	inline function emit(event:String, args:Array<String>, values:haxe.DynamicAccess<Dynamic>)
		context.emit(event, args, values);

	/** The bare jid is the own one **/
	function isOwn(bare:String):Bool
		return stream?.jid != null && Jid.parseBare(stream.jid) == bare;

	/** Sets (`null`: removes) the value of `key`; returns `true` if it changed, e.g. to show only changes **/
	function change(map:Map<String, String>, key:String, value:Null<String>):Bool {
		if (map.get(key) == value)
			return false;
		if (value == null)
			map.remove(key);
		else
			map.set(key, value);
		return true;
	}

	/**
		Sends a request with `send` (which passes the response to its callback), the command waits for the response:
		`result` gets its payload, an error is written to `out` after `failed` (e.g. `cannot block alice@example.org`).
	**/
	function request(out:Output, failed:String, send:(Response<XML>->Void)->Void, result:Null<XML>->Void) {
		final done = out.wait();
		send(res -> {
			switch res {
				case Result(payload): result(payload);
				case Error(e): out.error('$failed: ${Term.errorText(e)}');
			}
			done();
		});
	}
}
