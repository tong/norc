package norc;

import haxe.io.Bytes;

/**
	A Unix domain socket (stream): for the socket interface (`Api`), where the file permissions decide who may connect
	instead of a token, and the user id of the connecting process can be checked (`peerUid`).

	Only in the single binary on Linux and macOS (natives of `lib/hl/unix.c`, `-D norc_unix`): `available` is
	`false` elsewhere (e.g. the bytecode, Windows), the API uses TCP only then.
**/
class UnixSocket {
	/** Unix sockets can be used **/
	public static var available(get, never):Bool;

	public final input:haxe.io.Input;
	public final output:haxe.io.Output;

	final fd:Int;
	var closed = false;

	function new(fd:Int) {
		this.fd = fd;
		input = new SocketInput(fd);
		output = new SocketOutput(fd);
	}

	static function get_available():Bool
		return #if (hl && norc_unix) Sys.systemName() != "Windows" && uid() >= 0 #else false #end;

	/** Listens at `path` (a socket file left there before is replaced), readable only by the user; throws on errors **/
	public static function listen(path:String):UnixSocket {
		final fd = #if (hl && norc_unix) _listen(cString(path)) #else -1 #end;
		if (fd < 0)
			throw 'cannot listen at $path';
		return new UnixSocket(fd);
	}

	/** Connects to the socket at `path`; throws on errors **/
	public static function connect(path:String):UnixSocket {
		final fd = #if (hl && norc_unix) _connect(cString(path)) #else -1 #end;
		if (fd < 0)
			throw 'cannot connect to $path';
		return new UnixSocket(fd);
	}

	/** Waits for the next connection; throws once closed **/
	public function accept():UnixSocket {
		final c = #if (hl && norc_unix) _accept(fd) #else -1 #end;
		if (c < 0)
			throw "closed";
		return new UnixSocket(c);
	}

	/** Reads time out after `seconds` (`0`: never): the input ends then **/
	public function setTimeout(seconds:Float) {
		#if (hl && norc_unix)
		_timeout(fd, seconds);
		#end
	}

	/** The user id of the connected process, -1 if unknown **/
	public function peerUid():Int
		return #if (hl && norc_unix) _peerUid(fd) #else -1 #end;

	/** The user id of this process, -1 if unknown **/
	public static function uid():Int
		return #if (hl && norc_unix) _uid() #else -1 #end;

	/** Ends reading and writing (a thread reading returns), then closes **/
	public function close() {
		if (closed)
			return;
		closed = true;
		#if (hl && norc_unix)
		_shutdown(fd);
		_close(fd);
		#end
	}

	#if (hl && norc_unix)
	/** `s` as UTF-8, NUL-terminated **/
	static function cString(s:String):hl.Bytes
		return @:privateAccess Bytes.ofString(s + "\x00").b;

	@:hlNative("norc", "unix_listen") static function _listen(path:hl.Bytes):Int
		return -1;

	@:hlNative("norc", "unix_accept") static function _accept(fd:Int):Int
		return -1;

	@:hlNative("norc", "unix_connect") static function _connect(path:hl.Bytes):Int
		return -1;

	@:hlNative("norc", "unix_read") static function _read(fd:Int, buf:hl.Bytes, pos:Int, len:Int):Int
		return -1;

	@:hlNative("norc", "unix_write") static function _write(fd:Int, buf:hl.Bytes, pos:Int, len:Int):Int
		return -1;

	@:hlNative("norc", "unix_timeout") static function _timeout(fd:Int, seconds:Float):Int
		return -1;

	@:hlNative("norc", "unix_shutdown") static function _shutdown(fd:Int):Void {}

	@:hlNative("norc", "unix_close") static function _close(fd:Int):Void {}

	@:hlNative("norc", "unix_peer_uid") static function _peerUid(fd:Int):Int
		return -1;

	@:hlNative("norc", "unix_uid") static function _uid():Int
		return -1;
	#end
}

private class SocketInput extends haxe.io.Input {
	final fd:Int;

	public function new(fd:Int)
		this.fd = fd;

	override public function readByte():Int {
		final b = Bytes.alloc(1);
		if (readBytes(b, 0, 1) == 0)
			throw new haxe.io.Eof();
		return b.get(0);
	}

	override public function readBytes(buf:Bytes, pos:Int, len:Int):Int {
		if (len == 0)
			return 0;
		final n = #if (hl && norc_unix) @:privateAccess UnixSocket._read(fd, buf.b, pos, len) #else -1 #end;
		if (n <= 0)
			throw new haxe.io.Eof();
		return n;
	}
}

private class SocketOutput extends haxe.io.Output {
	final fd:Int;

	public function new(fd:Int)
		this.fd = fd;

	override public function writeByte(c:Int) {
		final b = Bytes.alloc(1);
		b.set(0, c);
		writeBytes(b, 0, 1);
	}

	override public function writeBytes(buf:Bytes, pos:Int, len:Int):Int {
		final n = #if (hl && norc_unix) @:privateAccess UnixSocket._write(fd, buf.b, pos, len) #else -1 #end;
		if (n < 0)
			throw haxe.io.Error.Custom("write failed");
		return n;
	}
}
