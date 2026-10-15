package norc;

import norc.Output;
import sys.FileSystem;

using StringTools;

/**
	A command, e.g. `/msg <jid> <text...>`.
**/
typedef Command = {
	var name:String;
	var ?aliases:Array<String>;

	/**
		Arguments: `<name>` required, `[name]` optional, `...` after the last one takes the rest of the line
		(spaces included), `#` before the name an integer (an optional integer is skipped if the word is none).
		Words with spaces can be quoted (`"…"`).
	**/
	var ?args:String;

	var description:String;

	/** Only available while connected, `false` by default **/
	var ?online:Bool;

	/** Ends the client: no more input is read after it **/
	var ?exit:Bool;

	/**
		Subcommands, selected by the first word (e.g. `/contacts add <jid>`).
		Without a subcommand, `run` is called (if set, else the help of the command is shown).
	**/
	var ?subcommands:Array<Command>;

	/**
		Called with the arguments in the order of `args` (`null` for missing optional ones), and where to write
		the output (also later, e.g. for responses of the server).
	**/
	var ?run:(args:Array<Null<String>>, out:Output) -> Void;

	/** Completions of arguments by name, in addition to (or instead of) those of `Commands.completers` **/
	var ?complete:Map<String, Completion>;

	/** `false`: a left out first `jid` argument is not the contact of the chat mode (see `Target`) **/
	var ?target:Bool;
}

/**
	The contact of the chat mode: a first argument `jid` left out is its jid.
	A required one is left out if the first word is no jid (with `@`) or contact (`known`), an optional one without arguments.
**/
typedef Target = {
	var jid:String;
	var known:(word:String) -> Bool;
}

/**
	Candidates for the argument being typed (`arg`, the rest of the line for an argument taking it): values replacing
	it, those not starting with `arg` are left out. A value ending with `/` is not complete (e.g. a directory).
**/
typedef Completion = (arg:String) -> Array<String>;

private typedef Param = {
	var name:String;
	var optional:Bool;
	var rest:Bool;
	var integer:Bool;
}

private typedef Entry = {
	var command:Command;
	var params:Array<Param>;

	/** Usage prefix, e.g. `/contacts add` **/
	var path:String;

	/** Subcommands by name and alias **/
	var subs:Map<String, Entry>;
}

/**
	Registry of the `/commands`: modules register their commands, input lines are parsed and dispatched here.
**/
class Commands {
	final entries = new Map<String, Entry>();

	/** Names, without aliases, in the order of registration **/
	final names = new Array<String>();

	/** Returns `true` if connected (for commands requiring a connection) **/
	public final isOnline:() -> Bool;

	/**
		Aliases (`alias.<name>` in the config): the name, without `/`, and the command it runs with its first
		arguments (e.g. `h` → `help`, `away` → `presence away`). A command of the same name is run instead.
	**/
	public final aliases = new Map<String, String>();

	/** Completions of arguments by name for all commands (e.g. `jid`), unless a command has its own **/
	public final completers = new Map<String, Completion>();

	public function new(isOnline:() -> Bool) {
		this.isOnline = isOnline;
		register({
			name: "help",
			args: "[command...]",
			description: "list the commands, or show the usage of one",
			run: (args, out) -> help(args[0], out),
			complete: ["command" => completeCommand]
		});
		completers.set("path", completePath);
	}

	/**
		Registers `command`; throws if its name or an alias is taken or the arguments are invalid.
		A group of subcommands (without `run` and arguments) with the name of a registered group adds its subcommands
		to it (e.g. `/file upload` of another module).
	**/
	public function register(command:Command) {
		final existing = entries.get(command.name);
		if (existing != null && isGroup(existing.command) && isGroup(command)) {
			for (sub in command.subcommands) {
				addSub(existing, sub);
				existing.command.subcommands.push(sub);
			}
			return;
		}
		add(entries, createEntry(command, '/${command.name}'), "/");
		names.push(command.name);
	}

	/** Adds `entry` by its name and aliases to `map`; throws if one is taken **/
	static function add(map:Map<String, Entry>, entry:Entry, parent:String)
		for (name in [entry.command.name].concat(entry.command.aliases ?? [])) {
			if (map.exists(name))
				throw 'command $parent$name already registered';
			map.set(name, entry);
		}

	static function addSub(entry:Entry, sub:Command)
		add(entry.subs, createEntry(sub, '${entry.path} ${sub.name}'), entry.path + " ");

	static function isGroup(command:Command):Bool
		return command.run == null && command.args == null && command.subcommands != null;

	static function createEntry(command:Command, path:String):Entry {
		final entry:Entry = {
			command: command,
			params: parseParams(command.args ?? "", path),
			path: path,
			subs: new Map()
		};
		for (sub in command.subcommands ?? [])
			addSub(entry, sub);
		return entry;
	}

	/**
		The command of `line` (without `/`) and its arguments, descending into subcommands; `null` if unknown.
	**/
	function resolve(line:String):Null<{entry:Entry, args:String}> {
		line = expand(line);
		var i = line.indexOf(" ");
		var entry = entries.get((i == -1) ? line : line.substr(0, i));
		var args = (i == -1) ? "" : line.substr(i + 1).ltrim();
		while (entry != null && args.length > 0) {
			i = args.indexOf(" ");
			final sub = entry.subs.get((i == -1) ? args : args.substr(0, i));
			if (sub == null)
				break;
			entry = sub;
			args = (i == -1) ? "" : args.substr(i + 1).ltrim();
		}
		return (entry == null) ? null : {entry: entry, args: args};
	}

	/** `command` (e.g. `room`) has the subcommand `name` (or alias) **/
	public function hasSubcommand(command:String, name:String):Bool
		return entries.get(command)?.subs.exists(name) == true;

	/** `line` (without `/`) with an alias as first word replaced by its command **/
	function expand(line:String):String {
		final i = line.indexOf(" ");
		final name = (i == -1) ? line : line.substr(0, i);
		final command = entries.exists(name) ? null : aliases.get(name);
		return (command == null) ? line : command + ((i == -1) ? "" : line.substr(i));
	}

	/** Registers several commands **/
	public function registerAll(commands:Array<Command>)
		for (c in commands)
			register(c);

	/**
		Parses and runs an input line, e.g. `/msg juliet@example.com hi`, writing its output to `out`
		(the terminal by default). With `slash` `false` the `/` is optional, with `target` a jid argument can be left out.
		Returns `false` if the command could not run (unknown, invalid arguments, not connected).
	**/
	public function run(line:String, ?out:Output, slash = true, ?target:Target):Bool {
		out ??= TermOutput.instance;
		line = line.trim();
		if (line.length == 0)
			return true;
		if (line.startsWith("/"))
			line = line.substr(1);
		else if (slash) {
			out.error("commands start with / (/help for the commands)");
			return false;
		}
		final resolved = resolve(line);
		if (resolved == null) {
			final i = line.indexOf(" ");
			out.error('unknown command: /${(i == -1) ? line : line.substr(0, i)} (/help for the commands)');
			return false;
		}
		return execute(resolved.entry, (target != null && leavesOut(resolved.entry, resolved.args, target)) ? '${target.jid} ${resolved.args}' : resolved.args, null, out);
	}

	/**
		Runs `command` (e.g. `contacts add`, without `/`) with the arguments `args`, one per parameter, a parameter taking
		the rest of the line gets the remaining ones joined with spaces. The first arguments can select subcommands.
		Returns `false` if the command could not run.
	**/
	public function call(command:String, args:Array<Null<String>>, ?out:Output):Bool {
		out ??= TermOutput.instance;
		final resolved = resolve(command.trim().startsWith("/") ? command.trim().substr(1) : command.trim());
		if (resolved == null) {
			out.error('unknown command: /$command (/help for the commands)');
			return false;
		}
		var entry = resolved.entry;
		args = args.copy();
		if (resolved.args.length > 0) {
			out.error('${entry.path}: unknown subcommand: ${resolved.args.split(" ")[0]}');
			return false;
		}
		while (args.length > 0 && args[0] != null && entry.subs.exists(args[0]))
			entry = entry.subs.get(args.shift());
		return execute(entry, "", args, out);
	}

	/** Runs `entry` with its arguments as a line (`input`), or as a list (`list`) **/
	function execute(entry:Entry, input:String, list:Null<Array<Null<String>>>, out:Output):Bool {
		final command = entry.command;
		final hasArgs = list != null ? list.length > 0 : input.length > 0;
		final first = list != null ? list[0] : input.split(" ")[0];
		if (command.run == null) {
			// a command with subcommands only
			if (hasArgs) {
				out.error('${entry.path}: unknown subcommand: $first');
				return false;
			}
			help(entry.path, out);
			return true;
		}
		if (entry.params.length == 0 && command.subcommands != null && hasArgs) {
			out.error('${entry.path}: unknown subcommand: $first (/help ${entry.path.substr(1)})');
			return false;
		}
		if (command.online == true && !isOnline()) {
			out.error('${entry.path}: not connected');
			return false;
		}
		final args = try (list != null ? mapArgs(entry.params, list) : parseArgs(entry.params, input)) catch (e:String) {
			out.error('${entry.path}: $e, usage: ${usage(entry)}'
				+ (entry.command.subcommands != null ? ' (/help ${entry.path.substr(1)} for its subcommands)' : ''));
			return false;
		}
		command.run(args, out);
		return true;
	}

	/**
		Completes the end of `before` (the input up to the cursor): the command, a subcommand or an argument.
		Returns the text being completed (the end of `before`) and the sorted candidates replacing it,
		`null` if there is nothing to complete.
	**/
	public function complete(before:String, target = false):Null<{word:String, candidates:Array<String>}> {
		if (!before.startsWith("/"))
			return null;
		final text = before.substr(1);
		var i = text.indexOf(" ");
		if (i == -1)
			return result(before, [for (name in entries.keys()) '/$name'].concat([for (name in aliases.keys()) '/$name']));
		// the arguments of an alias: those of its command
		if (expand(text) != text) {
			final c = complete('/' + expand(text), target);
			return (c == null) ? null : {word: c.word, candidates: c.candidates};
		}
		var entry = entries.get(text.substr(0, i));
		var args = text.substr(i + 1).ltrim();
		while (entry != null && entry.command.subcommands != null) {
			i = args.indexOf(" ");
			if (i == -1) {
				// a subcommand, or the first argument of the command
				final c = result(args, [for (name in entry.subs.keys()) name]);
				final a = completeArgs(entry, args, target);
				if (a != null)
					for (v in a.candidates)
						c.candidates.push(v);
				c.candidates.sort(Reflect.compare);
				return c;
			}
			final sub = entry.subs.get(args.substr(0, i));
			if (sub == null)
				break;
			entry = sub;
			args = args.substr(i + 1).ltrim();
		}
		return (entry == null) ? null : completeArgs(entry, args, target);
	}

	/** The first argument `jid` of `entry` is left out in `args`, to be the jid of `target` **/
	static function leavesOut(entry:Entry, args:String, target:Target):Bool {
		final p = entry.params[0];
		if (p == null || p.name != "jid" || entry.command.target == false)
			return false;
		return args.length == 0 || (!p.optional && !target.known(args.split(" ")[0]));
	}

	/**
		Completes the argument at the end of `args` (the arguments of `entry`); with `target` (chat mode) also as if
		a first `jid` argument was left out.
	**/
	function completeArgs(entry:Entry, args:String, target = false):Null<{word:String, candidates:Array<String>}> {
		final c = completeParams(entry, entry.params, args);
		if (!target || entry.params[0]?.name != "jid" || entry.command.target == false)
			return c;
		final left = completeParams(entry, entry.params.slice(1), args);
		if (c == null || c.candidates.length == 0)
			return left;
		if (left != null && left.word == c.word)
			return result(c.word, c.candidates.concat(left.candidates));
		return c;
	}

	function completeParams(entry:Entry, params:Array<Param>, args:String):Null<{word:String, candidates:Array<String>}> {
		// start of each word, the last one is being typed (empty after a space)
		final starts = new Array<Int>();
		var i = 0;
		while (i < args.length) {
			starts.push(i);
			while (i < args.length && args.charCodeAt(i) != " ".code)
				i++;
			while (i < args.length && args.charCodeAt(i) == " ".code)
				i++;
		}
		if (starts.length == 0 || args.endsWith(" "))
			starts.push(args.length);
		var w = 0;
		for (p in 0...params.length) {
			final param = params[p];
			if (w == starts.length - 1 || param.rest) {
				final arg = args.substr(starts[w]);
				final candidates = completeParam(entry, param, arg);
				// an optional number can be left out: or the next argument
				if (param.integer && param.optional && p + 1 < params.length)
					for (v in completeParam(entry, params[p + 1], arg))
						candidates.push(v);
				return result(arg, candidates);
			}
			final word = args.substring(starts[w], starts[w + 1]).rtrim();
			if (param.integer && param.optional && Std.parseInt(word.startsWith("#") ? word.substr(1) : word) == null)
				continue;
			w++;
		}
		return null;
	}

	function completeParam(entry:Entry, param:Param, arg:String):Array<String> {
		final f = entry.command.complete?.get(param.name) ?? completers.get(param.name);
		return (f == null) ? [] : f(arg);
	}

	/** The candidates starting with `word` (ignoring case), sorted and without duplicates **/
	static function result(word:String, candidates:Array<String>) {
		final lower = word.toLowerCase();
		final matches = new Array<String>();
		for (c in candidates)
			if (c.toLowerCase().startsWith(lower) && !matches.contains(c))
				matches.push(c);
		matches.sort(Reflect.compare);
		return {word: word, candidates: matches};
	}

	/** A command for `/help`, e.g. `contacts add` **/
	function completeCommand(arg:String):Array<String> {
		final line = '/$arg';
		final c = complete(line);
		if (c == null)
			return [];
		final prefix = line.substr(0, line.length - c.word.length);
		return [for (v in c.candidates) (prefix + v).substr(1)];
	}

	/** Files and directories (`~/` is the home directory), hidden ones if `arg` starts their name with `.` **/
	public static function completePath(arg:String):Array<String> {
		if (arg == "~")
			return ["~/"];
		final i = arg.lastIndexOf("/");
		final dir = arg.substr(0, i + 1);
		final path = (dir.length == 0) ? "." : Config.expandHome(dir);
		final hidden = arg.substr(i + 1).startsWith(".");
		final names = try FileSystem.readDirectory(path) catch (_) [];
		return [
			for (name in names)
				if (hidden || !name.startsWith(".")) dir + name + (FileSystem.isDirectory(haxe.io.Path.join([path, name])) ? "/" : "")
		];
	}

	/**
		Returns `true` if `line` runs a command ending the client. Called by the input thread
		(the commands are not changed after the start).
	**/
	public function exits(line:String):Bool {
		line = line.trim();
		if (!line.startsWith("/"))
			return false;
		final resolved = resolve(line.substr(1));
		if (resolved == null || resolved.entry.command.exit != true)
			return false;
		// only if it will run
		return try {
			parseArgs(resolved.entry.params, resolved.args);
			true;
		} catch (_:String)
			false;
	}

	/**
		Lists the commands, or shows the usage of command `name` (e.g. `contacts` or `contacts add`).
	**/
	public function help(?name:String, ?out:Output) {
		out ??= TermOutput.instance;
		if (name != null) {
			final resolved = resolve(name.startsWith("/") ? name.substr(1) : name);
			if (resolved == null || resolved.args.length > 0) {
				out.error('unknown command: $name');
				return;
			}
			final e = resolved.entry;
			final c = e.command;
			out.data({commands: [describe(e)].concat(c.subcommands != null ? [for (sub in c.subcommands) describe(e.subs.get(sub.name))] : [])}, () -> {
				if (c.run != null)
					out.print('  ${styledUsage(e)}\n    ${c.description}');
				else
					out.print('  ${Term.style(e.path, 36)}: ${c.description}');
				if (c.aliases != null)
					out.print(Term.style('    aliases: ${c.aliases.join(", ")}', 2));
				if (c.subcommands != null)
					printTable([for (sub in c.subcommands) e.subs.get(sub.name)], out);
			});
			return;
		}
		final sorted = names.copy();
		sorted.sort(Reflect.compare);
		final list = [];
		for (n in sorted) {
			final e = entries.get(n);
			if (e.command.run != null)
				list.push(e);
			if (e.command.subcommands != null)
				for (sub in e.command.subcommands)
					list.push(e.subs.get(sub.name));
		}
		final names = [for (name in aliases.keys()) if (!entries.exists(name)) name];
		names.sort(Reflect.compare);
		out.data({commands: [for (e in list) describe(e)], aliases: [for (n in names) {alias: n, command: aliases.get(n)}]}, () -> {
			printTable(list, out);
			if (names.length > 0)
				out.print(Term.style('  aliases: ', 2) + [for (n in names) Term.style('/$n', 36) + Term.style(' → /${aliases.get(n)}', 2)].join(Term.style(", ", 2)));
		});
	}

	static function describe(e:Entry)
		return {
			command: e.path.substr(1),
			args: e.command.args,
			description: e.command.description,
			aliases: e.command.aliases ?? [],
			online: e.command.online == true
		};

	static function printTable(list:Array<Entry>, out:Output) {
		// aligned by the usage without styles
		var width = 0;
		for (e in list)
			if (usage(e).length > width)
				width = usage(e).length;
		for (e in list)
			out.print('  ${styledUsage(e)}${"".rpad(" ", width + 2 - usage(e).length)}${e.command.description}');
	}

	/** `usage` for the terminal: the command, required and optional arguments in their colors **/
	static function styledUsage(entry:Entry):String {
		final args = (entry.command.args ?? "").split(" ").filter(a -> a.length > 0);
		return Term.style(entry.path, 36) + [for (a in args) " " + Term.style(a, a.startsWith("<") ? 33 : 2)].join("");
	}

	static function usage(entry:Entry):String {
		final args = entry.command.args;
		return entry.path + (args != null && args.length > 0 ? ' $args' : '');
	}

	static function parseParams(spec:String, command:String):Array<Param> {
		final params = new Array<Param>();
		final re = ~/^(<|\[)(#?)([^>\]\s.]+)(\.\.\.)?(>|\])$/;
		for (word in spec.split(" ")) {
			if (word.length == 0)
				continue;
			if (!re.match(word) || (re.matched(1) == "<") != (re.matched(5) == ">"))
				throw 'command $command: invalid argument $word';
			final param = {
				optional: re.matched(1) == "[",
				integer: re.matched(2) == "#",
				name: re.matched(3),
				rest: re.matched(4) != null
			};
			if (params.length > 0 && params[params.length - 1].rest)
				throw 'command $command: only the last argument can take the rest of the line';
			params.push(param);
		}
		return params;
	}

	/** Assigns the arguments of a list to `params`; throws a message if arguments are missing or invalid **/
	static function mapArgs(params:Array<Param>, list:Array<Null<String>>):Array<Null<String>> {
		final args = new Array<Null<String>>();
		var i = 0;
		for (p in params) {
			var v = (i < list.length) ? list[i] : null;
			if (p.rest) {
				final rest = [for (j in i...list.length) if (list[j] != null) list[j]].join(" ");
				i = list.length;
				if (rest.length == 0 && !p.optional)
					throw 'missing ${p.name}';
				args.push(rest.length > 0 ? rest : null);
				continue;
			}
			if (v != null && p.integer) {
				final n = v.startsWith("#") ? v.substr(1) : v;
				if (Std.parseInt(n) == null) {
					if (!p.optional)
						throw '${p.name} must be a number';
					// an optional number left out: the argument is for the next parameter
					args.push(null);
					continue;
				}
				v = n;
			}
			if (v == null && !p.optional)
				throw 'missing ${p.name}';
			args.push(v);
			i++;
		}
		for (j in i...list.length)
			if (list[j] != null)
				throw 'too many arguments';
		return args;
	}

	/** Splits `input` by `params`; throws a message if arguments are missing or invalid **/
	static function parseArgs(params:Array<Param>, input:String):Array<Null<String>> {
		final args = new Array<Null<String>>();
		var pos = 0;
		function skipSpaces()
			while (pos < input.length && input.charCodeAt(pos) == " ".code)
				pos++;
		/** Reads the next word (quoted with "", \ escapes the next character), `null` at the end **/
		function word():Null<String> {
			skipSpaces();
			if (pos >= input.length)
				return null;
			final b = new StringBuf();
			var quoted = false;
			while (pos < input.length) {
				final c = input.charCodeAt(pos);
				if (c == "\\".code && pos + 1 < input.length) {
					b.addChar(input.charCodeAt(pos + 1));
					pos += 2;
					continue;
				}
				pos++;
				if (c == '"'.code)
					quoted = !quoted;
				else if (c == " ".code && !quoted)
					break;
				else
					b.addChar(c);
			}
			return b.toString();
		}
		// an optional number left out, for a better message if its word is not taken by the next argument
		var skipped:Null<Param> = null;
		for (p in params) {
			if (p.rest) {
				skipSpaces();
				final rest = input.substr(pos).trim();
				pos = input.length;
				if (rest.length == 0 && !p.optional)
					throw 'missing ${p.name}';
				args.push(rest.length > 0 ? rest : null);
				continue;
			}
			final start = pos;
			var w = word();
			if (w != null && p.integer && Std.parseInt(w.startsWith("#") ? w.substr(1) : w) == null) {
				if (!p.optional)
					throw '${p.name} must be a number';
				// an optional number: leave the word to the next argument
				pos = start;
				w = null;
				skipped = p;
			} else if (w != null && p.integer && w.startsWith("#"))
				w = w.substr(1);
			if (w == null && !p.optional)
				throw 'missing ${p.name}';
			args.push(w);
		}
		skipSpaces();
		if (pos < input.length)
			throw(skipped != null && args.length == params.length && args[args.length - 1] == null) ? '${skipped.name} must be a number' : 'too many arguments';
		return args;
	}
}
