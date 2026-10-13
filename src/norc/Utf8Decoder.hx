package norc;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
	Decodes a byte stream into strings without splitting multi-byte UTF-8 sequences:
	an incomplete sequence at the end of the received data is held back until the rest arrives.
**/
class Utf8Decoder {
	var pending:Null<Bytes>;

	public function new() {}

	public function decode(bytes:Bytes, len:Int):String {
		var data = bytes;
		if (pending != null) {
			final b = new BytesBuffer();
			b.add(pending);
			b.addBytes(bytes, 0, len);
			data = b.getBytes();
			len = data.length;
			pending = null;
		}
		final complete = completeLength(data, len);
		if (complete < len)
			pending = data.sub(complete, len - complete);
		return data.getString(0, complete, UTF8);
	}

	/**
		Returns the length of `data` without an incomplete UTF-8 sequence at its end.
	**/
	public static function completeLength(data:Bytes, len:Int):Int {
		// A sequence is at most 4 bytes: look back for its lead byte
		var i = len - 1;
		final min = len > 4 ? len - 4 : 0;
		while (i >= min) {
			final c = data.get(i);
			if (c & 0xC0 != 0x80) {
				final size = if (c & 0x80 == 0) 1 else if (c & 0xE0 == 0xC0) 2 else if (c & 0xF0 == 0xE0) 3 else if (c & 0xF8 == 0xF0) 4 else 1;
				return (i + size > len) ? i : len;
			}
			i--;
		}
		return len;
	}
}
