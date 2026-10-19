package norc;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;
using haxe.macro.Tools;
#end

class Macros {
	/** The values of an enum abstract over `String`, e.g. `Macros.values(xmpp.Pep.Mood)` **/
	public static macro function values(type:Expr):ExprOf<Array<String>> {
		switch Context.getType(type.toString()) {
			case TAbstract(t, _) if (t.get().impl != null):
				final values = [
					for (f in t.get().impl.get().statics.get())
						if (f.meta.has(":enum")) {
							final name = f.name;
							macro($type.$name:String);
						}
				];
				return macro $a{values};
			case _:
				return Context.error('${type.toString()} is no enum abstract', type.pos);
		}
	}

	#if macro
	/**
		HashLink/C: registers the names of fields in the order of their hashes (`--macro norc.Macros.sortHashes()`).
		The start of the program registers each name of a field in a table sorted by hash (`hl_init_hashes`), an
		insertion moving the entries after it: in the order of the generated code that took most of the start
		(3.7 of 4.3 ms with 1873 names), in order nothing moves. Names with the same hash get another one in the
		order registered: unchanged then.
	**/
	public static function sortHashes() {
		Context.onAfterGenerate(() -> {
			final path = haxe.io.Path.directory(haxe.macro.Compiler.getOutput()) + "/hl/hashes.c";
			if (!sys.FileSystem.exists(path))
				return;
			final call = ~/^\thl_hash\(\(vbyte\*\)USTR\("([^"\\]*)"\)\);$/;
			final lines = sys.io.File.getContent(path).split("\n");
			final calls = [for (l in lines) if (call.match(l)) {line: l, hash: hash(call.matched(1))}];
			final hashes = [for (c in calls) c.hash];
			for (h in hashes)
				if (hashes.indexOf(h) != hashes.lastIndexOf(h))
					return;
			calls.sort((a, b) -> Reflect.compare(a.hash, b.hash));
			var i = 0;
			sys.io.File.saveContent(path, [for (l in lines) call.match(l) ? calls[i++].line : l].join("\n"));
		});
	}

	/** The hash of a field name, as HashLink's `hl_hash_gen` (32 bits, with overflow) **/
	static function hash(name:String):Int {
		var h = 0;
		for (i in 0...name.length)
			h = 223 * h + name.fastCodeAt(i);
		return h % 0x1FFFFF7B;
	}
	#end
}
