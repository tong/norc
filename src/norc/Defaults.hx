package norc;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import sys.FileSystem;
import sys.io.File;
#else
import sys.FileSystem;
import sys.io.File;
#end

using StringTools;

/**
	The default config (`config/` of the sources: `conf`, the example hooks and scripts), embedded in the binary and
	written to the config directory when norc runs the first time (`install`).

	The example accounts are not installed (norc would use the only configured account), and the hooks and scripts
	are disabled (not executable): they are enabled with `chmod +x`.
**/
#if !macro
@:build(norc.Defaults.embed())
#end
class Defaults {
	/** Prefix of the names of the embedded files **/
	static inline var PREFIX = "config/";

	#if !macro
	/**
		Writes the default config to `dir` if it doesn't exist; returns the written files (relative to `dir`),
		empty if `dir` exists.
	**/
	public static function install(dir:String):Array<String> {
		if (FileSystem.exists(dir))
			return [];
		final names = [for (name in haxe.Resource.listNames()) if (name.startsWith(PREFIX)) name.substr(PREFIX.length)];
		names.sort(Reflect.compare);
		for (name in names) {
			final path = '$dir/$name';
			FileSystem.createDirectory(haxe.io.Path.directory(path));
			File.saveBytes(path, haxe.Resource.getBytes(PREFIX + name));
		}
		return names;
	}
	#end

	#if macro
	/** Embeds `config/conf`, `config/hooks/*` and `config/scripts/*` as resources `config/…` **/
	public static function embed():Array<Field> {
		final src = haxe.io.Path.directory(Context.getPosInfos(Context.currentPos()).file);
		final dir = haxe.io.Path.normalize('$src/../../config');
		final files = ["conf"];
		for (sub in ["hooks", "scripts"]) {
			final d = '$dir/$sub';
			if (FileSystem.exists(d))
				for (f in FileSystem.readDirectory(d))
					if (!f.startsWith(".") && !FileSystem.isDirectory('$d/$f'))
						files.push('$sub/$f');
		}
		for (f in files) {
			final path = '$dir/$f';
			if (!FileSystem.exists(path))
				continue;
			Context.addResource(PREFIX + f, File.getBytes(path));
			Context.registerModuleDependency(Context.getLocalModule(), path);
		}
		return Context.getBuildFields();
	}
	#end
}
