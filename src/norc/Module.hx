package norc;

import xmpp.client.Stream;

/**
	A feature of the client (e.g. file transfer): its commands, and its part of each session.

	Modules live as long as the client; each connection gets a new stream (`attach`), which ends with `detach`.
**/
interface Module {
	/** Commands, registered once **/
	function commands():Array<Commands.Command>;

	/** Protocols to advertise for service discovery, in addition to those of registered request handlers **/
	function features():Array<String>;

	/** A new stream: register request handlers (before login, they are part of the capabilities) **/
	function attach(stream:Stream):Void;

	/** Logged in **/
	function online():Void;

	/** The stream ended (disconnected or quit) **/
	function detach():Void;
}

/**
	Emits an event: runs its hooks and sends it to the API clients.
	`args` are the arguments of the hooks, `values` their environment variables and the values of the API event.
**/
typedef Emit = (event:String, args:Array<String>, values:Map<String, String>) -> Void;
