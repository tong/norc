package norc;

/**
	Events processed by the main thread.
	Posted by the input threads (network, stdin) and timers.
**/
enum Event {
	/** Event of a network connection; ignored if `conn` is not the current connection **/
	Net(conn:Connection, e:NetEvent);

	/** Line read from stdin **/
	Line(line:String);

	/** Stdin was closed **/
	InputClosed;

	/** Time to reconnect **/
	Reconnect;
}

enum NetEvent {
	Connected;
	ConnectFailed(error:String);
	/** Received raw data, possibly ending within a UTF-8 sequence **/
	Data(bytes:haxe.io.Bytes);
	TlsReady;
	TlsFailed(error:String);
	Disconnected(?error:String);
}
