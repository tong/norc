package norc;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;
#end

/**
	Version of norc, set from git at compile time:

	- `TAG`: the tag of the commit (e.g. `v0.1.0`), `null` if it has none
	- `COMMIT`: the commit hash, `null` without git
	- `DIRTY`: `true` if built with uncommitted changes
	- `DATE`: the date of the commit (ISO 8601), not of the build: builds of a commit are the same
	- `VERSION`: semantic version, the last tag without `v` (`0.0.0` without tags), after it the number of commits
	  since the tag, the commit and uncommitted changes as build metadata, e.g. `0.1.0`, `0.1.0+5.g885f830.dirty`

	Each can be set with a define instead (e.g. builds without git): `-D norc_tag=v0.1.0`, `norc_commit`,
	`norc_dirty` (`1`), `norc_date`, `norc_version`.
**/
#if !macro
@:build(norc.Version.build())
#end
class Version {
	#if macro
	public static function build():Array<Field> {
		final fields = Context.getBuildFields();
		final tag = defined("tag") ?? git(["describe", "--tags", "--exact-match"]);
		final commit = defined("commit") ?? git(["rev-parse", "HEAD"]);
		final dirty = (defined("dirty") ?? (commit != null
			&& git(["status", "--porcelain", "--untracked-files=no"]) != "" ? "1" : "0")) == "1";
		final date = defined("date") ?? git(["log", "-1", "--format=%cI"]);
		final version = defined("version") ?? {
			// the last tag, e.g. v0.1.0-5-g885f830: 5 commits after v0.1.0
			final re = ~/^v?(.+)-([0-9]+)-g[0-9a-f]+$/;
			final described = git(["describe", "--tags", "--long"]);
			final tagged = described != null && re.match(described);
			final base = tagged ? re.matched(1) : "0.0.0";
			final since = tagged ? Std.parseInt(re.matched(2)) : 0;
			final build = new Array<String>();
			if (since > 0)
				build.push('$since');
			if (commit != null && (since > 0 || !tagged))
				build.push('g${commit.substr(0, 7)}');
			if (dirty)
				build.push("dirty");
			base + (build.length > 0 ? '+${build.join(".")}' : "");
		}
		final pos = Context.currentPos();
		function add(name:String, doc:String, type:ComplexType, value:Dynamic)
			fields.push({
				name: name,
				doc: doc,
				access: [APublic, AStatic, AInline],
				kind: FVar(type, macro $v{value}),
				pos: pos
			});
		add("TAG", "Git tag of the commit, `null` if it has none", macro :Null<String>, tag);
		add("COMMIT", "Git commit hash, `null` if unknown", macro :Null<String>, commit);
		add("DIRTY", "Built with uncommitted changes", macro :Bool, dirty);
		add("DATE", "Date of the commit (ISO 8601), `null` if unknown", macro :Null<String>, date);
		add("VERSION", "Version, e.g. `0.1.0`, or `0.1.0+5.g885f830` for commits after the tag `v0.1.0`", macro :String, version);
		return fields;
	}

	static function defined(name:String):Null<String>
		return Context.definedValue('norc_$name');

	static function git(args:Array<String>):Null<String> {
		return try {
			final proc = new sys.io.Process("git", args);
			final out = proc.stdout.readAll().toString().trim();
			proc.stderr.readAll();
			final code = proc.exitCode();
			proc.close();
			code == 0 ? out : null;
		} catch (_)
			null;
	}
	#end
}
