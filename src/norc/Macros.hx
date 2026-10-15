package norc;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

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
}
