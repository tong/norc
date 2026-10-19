package norc;

using StringTools;

/**
	Message styling (XEP-0393): the text of a message with its styles shown on the terminal. The directives stay
	visible (dim), as the XEP asks.

	- Spans, within a line: `*strong*` (bold), `_emphasis_` (italic), `~strike~` (struck through), `` `pre` `` (in the
	  color of code, nothing styled inside). An opening directive is at the start of the line, after a space or after
	  another opening directive, and not followed by a space; the closing one is the first after it not following a
	  space. Spans don't contain spans of the same kind, nor are empty (`**` is no span).
	- Blocks: lines starting with `>` are a quote (the `>` dim, quotes in quotes with `>>`), from a line starting with
	  ```` ``` ```` to one with only ```` ``` ```` (or the end of the quote or message) preformatted text, in the
	  color of code.

	@see [XEP-0393: Message Styling](https://xmpp.org/extensions/xep-0393.html)
**/
class Styling {
	/** The hint of a message not to be styled, and the feature (the client styles) **/
	public static inline var XMLNS = "urn:xmpp:styling:0";

	static inline var CODE = 36;

	/** `text` with the escape sequences of its styles; as it is without colors (`--no-color`) **/
	public static function format(text:String):String
		return Term.colors ? blocks(text.split("\n")).join("\n") : text;

	/** Whether `m` has the hint not to style it (`<unstyled/>`) **/
	public static function unstyled(m:xmpp.Message):Bool {
		for (e in m.properties)
			if (e.name == "unstyled" && e.is(XMLNS))
				return true;
		return false;
	}

	static function blocks(lines:Array<String>):Array<String> {
		final out = [];
		var i = 0;
		while (i < lines.length) {
			final line = lines[i];
			if (line.startsWith(">")) {
				// the quote: its lines without the >, styled as a message of their own
				final quote = [], spaces = [];
				while (i < lines.length && lines[i].startsWith(">")) {
					final l = lines[i++].substr(1);
					final n = l.length - l.ltrim().length;
					spaces.push(l.substr(0, n));
					quote.push(l.substr(n));
				}
				final styled = blocks(quote);
				for (j in 0...styled.length)
					out.push(dim(">") + spaces[j] + styled[j]);
			} else if (line.startsWith("```")) {
				out.push(dim(line));
				i++;
				while (i < lines.length && lines[i].rtrim() != "```")
					out.push(style(lines[i++], CODE, 39));
				if (i < lines.length)
					out.push(dim(lines[i++]));
			} else {
				out.push(spans(line, ""));
				i++;
			}
		}
		return out;
	}

	/**
		The spans of `s` styled; `active` the escape sequence of the styles of the spans around it (renewed after the
		dim directives, which end bold too), `around` their directives (no spans of these inside)
	**/
	static function spans(s:String, active:String, around = ""):String {
		final b = new StringBuf();
		var i = 0;
		while (i < s.length) {
			final c = s.charAt(i);
			final opens = "*_~`".contains(c) && !around.contains(c) && i + 1 < s.length && !isSpace(s.charAt(i + 1))
				&& (i == 0 || isSpace(s.charAt(i - 1)));
			final close = opens ? closing(s, c, i) : -1;
			if (close < 0) {
				b.add(c);
				i++;
				continue;
			}
			final inner = s.substring(i + 1, close);
			final on = switch c {
				case "*": "\x1B[1m";
				case "_": "\x1B[3m";
				case "~": "\x1B[9m";
				case _: '\x1B[${CODE}m';
			}
			final off = switch c {
				case "*": "\x1B[22m";
				case "_": "\x1B[23m";
				case "~": "\x1B[29m";
				case _: "\x1B[39m";
			}
			final styles = active + on;
			b.add(directive(c, active) + on);
			b.add((c == "`") ? inner : spans(inner, styles, around + c));
			b.add(off + directive(c, active));
			i = close + 1;
		}
		return b.toString();
	}

	/** The closing directive `c` of the span opened at `open` in `s`: not after a space, with text before; `-1` if none **/
	static function closing(s:String, c:String, open:Int):Int {
		var j = s.indexOf(c, open + 2);
		while (j >= 0) {
			if (!isSpace(s.charAt(j - 1)))
				return j;
			j = s.indexOf(c, j + 1);
		}
		return -1;
	}

	/** A directive, dim, then the styles around it again **/
	static inline function directive(c:String, active:String):String
		return '\x1B[2m$c\x1B[22m$active';

	static inline function dim(s:String):String
		return style(s, 2, 22);

	static inline function style(s:String, on:Int, off:Int):String
		return '\x1B[${on}m$s\x1B[${off}m';

	static inline function isSpace(c:String):Bool
		return c == " " || c == "\t";
}
