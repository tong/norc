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

	/** Callback to run on the main thread, e.g. of the sockets of file transfers **/
	Call(f:() -> Void);
}

enum NetEvent {
	/** Connected to `host:port` (e.g. the target of an SRV record) **/
	Connected(host:String, port:Int);
	ConnectFailed(error:String);

	/** Received raw data, possibly ending within a UTF-8 sequence **/
	Data(bytes:haxe.io.Bytes);

	TlsReady;
	TlsFailed(error:String);
	Disconnected(?error:String);
}
