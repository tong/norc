package norc;

import haxe.io.Bytes;

/** The type and size of an image, read from its header **/
typedef ImageInfo = {
	/** Content type: `image/png`, `image/jpeg`, `image/gif` or `image/webp` **/
	var type:String;

	var ?width:Int;
	var ?height:Int;
}

/** Recognizes images by their content (not their file name) **/
class Images {
	/** The type and size of the image `data`, `null` if it is no PNG, JPEG, GIF or WebP image **/
	public static function info(data:Bytes):Null<ImageInfo> {
		final n = data.length;
		function at(i:Int):Int
			return (i < n) ? data.get(i) : 0;
		function be16(i:Int):Int
			return (at(i) << 8) | at(i + 1);
		function le16(i:Int):Int
			return at(i) | (at(i + 1) << 8);
		function be32(i:Int):Int
			return (be16(i) << 16) | be16(i + 2);
		function ascii(i:Int, s:String):Bool
			return i + s.length <= n && data.getString(i, s.length) == s;
		if (n >= 24 && at(0) == 0x89 && ascii(1, "PNG") && ascii(12, "IHDR"))
			return {type: "image/png", width: be32(16), height: be32(20)};
		if (n >= 10 && (ascii(0, "GIF87a") || ascii(0, "GIF89a")))
			return {type: "image/gif", width: le16(6), height: le16(8)};
		if (n >= 3 && at(0) == 0xFF && at(1) == 0xD8 && at(2) == 0xFF) {
			// the size is in the start of frame segment (SOF0…SOF15, without DHT, JPG and DAC)
			var i = 2;
			while (i + 9 < n && at(i) == 0xFF) {
				final marker = at(i + 1);
				if (marker == 0xFF) {
					i++;
					continue;
				}
				if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC)
					return {type: "image/jpeg", width: be16(i + 7), height: be16(i + 5)};
				i += 2 + be16(i + 2);
			}
			return {type: "image/jpeg"};
		}
		if (n >= 16 && ascii(0, "RIFF") && ascii(8, "WEBP")) {
			if (ascii(12, "VP8X") && n >= 30)
				return {type: "image/webp", width: 1 + (at(24) | at(25) << 8 | at(26) << 16), height: 1 + (at(27) | at(28) << 8 | at(29) << 16)};
			if (ascii(12, "VP8 ") && n >= 30)
				return {type: "image/webp", width: le16(26) & 0x3FFF, height: le16(28) & 0x3FFF};
			if (ascii(12, "VP8L") && n >= 25) {
				final b = at(21) | at(22) << 8 | at(23) << 16 | at(24) << 24;
				return {type: "image/webp", width: 1 + (b & 0x3FFF), height: 1 + ((b >> 14) & 0x3FFF)};
			}
			return {type: "image/webp"};
		}
		return null;
	}

	/** The file extension of an image type, `img` if unknown **/
	public static function extension(type:Null<String>):String
		return switch type {
			case "image/png": "png";
			case "image/jpeg": "jpg";
			case "image/gif": "gif";
			case "image/webp": "webp";
			case _: "img";
		}
}
