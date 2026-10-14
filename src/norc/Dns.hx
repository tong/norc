package norc;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.FileSystem;
import sys.io.File;
import sys.net.Address;
import sys.net.Host;
import sys.net.UdpSocket;

using StringTools;

typedef SrvRecord = {
	var target:String;
	var port:Int;
	var priority:Int;
	var weight:Int;
}

/**
	DNS SRV lookups (RFC 2782), e.g. `_xmpp-client._tcp.example.org` for the host and port of an XMPP server.
	Queries the IPv4 name servers of `/etc/resolv.conf` over UDP (none on Windows: no records).
**/
class Dns {
	static inline var TYPE_SRV = 33;

	/**
		The SRV records of `name`, in the order to try them (by priority, then weight); empty if there are none,
		the lookup failed, or the service is decidedly not available (target `.`). Blocking.
	**/
	public static function srv(name:String, timeout = 3.0):Array<SrvRecord> {
		for (server in nameservers()) {
			final records = try query(server, name, timeout) catch (_) null;
			if (records != null) {
				records.sort((a, b) -> (a.priority != b.priority) ? a.priority - b.priority : b.weight - a.weight);
				return records.filter(r -> r.target != "");
			}
		}
		return [];
	}

	static function nameservers():Array<String> {
		final path = "/etc/resolv.conf";
		if (!FileSystem.exists(path))
			return [];
		final re = ~/^\s*nameserver\s+([0-9.]+)\s*$/;
		return [for (line in (try File.getContent(path) catch (_) "").split("\n")) if (re.match(line)) re.matched(1)];
	}

	/** The SRV records of `name` from the name server `server`, `null` if it gave no answer **/
	static function query(server:String, name:String, timeout:Float):Null<Array<SrvRecord>> {
		final id = Std.random(0x10000);
		final q = new BytesBuffer();
		writeShort(q, id);
		writeShort(q, 0x0100); // recursion desired
		writeShort(q, 1); // one question
		for (_ in 0...3)
			writeShort(q, 0);
		for (label in name.split("."))
			if (label.length > 0) {
				q.addByte(label.length);
				q.addString(label);
			}
		q.addByte(0);
		writeShort(q, TYPE_SRV);
		writeShort(q, 1); // class IN
		final packet = q.getBytes();
		final socket = new UdpSocket();
		try {
			socket.setTimeout(timeout);
			final addr = new Address();
			addr.host = new Host(server).ip;
			addr.port = 53;
			socket.sendTo(packet, 0, packet.length, addr);
			final buf = Bytes.alloc(4096);
			final len = socket.readFrom(buf, 0, buf.length, new Address());
			socket.close();
			return parse(buf.sub(0, len), id);
		} catch (e) {
			socket.close();
			return null;
		}
	}

	/** The SRV records of a response, `null` if it is no valid answer to the query `id` **/
	static function parse(b:Bytes, id:Int):Null<Array<SrvRecord>> {
		if (b.length < 12 || u16(b, 0) != id || b.get(2) & 0x80 == 0)
			return null;
		final rcode = b.get(3) & 0x0F;
		// no such name: no records
		if (rcode == 3)
			return [];
		if (rcode != 0)
			return null;
		final questions = u16(b, 4);
		final answers = u16(b, 6);
		var pos = 12;
		for (_ in 0...questions)
			pos = skipName(b, pos) + 4;
		final records = new Array<SrvRecord>();
		for (_ in 0...answers) {
			pos = skipName(b, pos);
			final type = u16(b, pos);
			final length = u16(b, pos + 8);
			pos += 10;
			if (type == TYPE_SRV)
				records.push({
					priority: u16(b, pos),
					weight: u16(b, pos + 2),
					port: u16(b, pos + 4),
					target: readName(b, pos + 6)
				});
			pos += length;
		}
		return records;
	}

	/** The position after the (possibly compressed) name at `pos` **/
	static function skipName(b:Bytes, pos:Int):Int {
		while (true) {
			final len = b.get(pos);
			if (len == 0)
				return pos + 1;
			if (len & 0xC0 == 0xC0)
				return pos + 2;
			pos += len + 1;
		}
	}

	/** The name at `pos`, following compression pointers; `""` for the root (`.`) **/
	static function readName(b:Bytes, pos:Int):String {
		final labels = [];
		var jumps = 0;
		while (true) {
			final len = b.get(pos);
			if (len == 0)
				break;
			if (len & 0xC0 == 0xC0) {
				if (++jumps > 16)
					throw "invalid name";
				pos = ((len & 0x3F) << 8) | b.get(pos + 1);
				continue;
			}
			labels.push(b.getString(pos + 1, len));
			pos += len + 1;
		}
		return labels.join(".");
	}

	static inline function u16(b:Bytes, pos:Int):Int
		return (b.get(pos) << 8) | b.get(pos + 1);

	static inline function writeShort(q:BytesBuffer, v:Int) {
		q.addByte(v >> 8);
		q.addByte(v & 0xFF);
	}
}
