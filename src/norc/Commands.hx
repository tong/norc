package norc;

import norc.Output;

using StringTools;

/**
	A command, e.g. `/send <jid> <path...>`.
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
		Subcommands, selected by the first word (e.g. `/roster add <jid>`).
		Without a subcommand, `run` is called (if set, else the help of the command is shown).
	**/
	var ?subcommands:Array<Command>;

	/**
		Called with the arguments in the order of `args` (`null` for missing optional ones), and where to write
		the output (also later, e.g. for responses of the server).
	**/
	var ?run:(args:Array<Null<String>>, out:Output) -> Void;
}

private typedef Param = {
	var name:String;
	var optional:Bool;
	var rest:Bool;
	var integer:Bool;
}

private typedef Entry = {
	var command:Command;
	var params:Array<Param>;

	/** Usage prefix, e.g. `/roster add` **/
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
	final isOnline:() -> Bool;

	public function new(isOnline:() -> Bool) {
		this.isOnline = isOnline;
		register({
			name: "help",
			args: "[command...]",
			description: "list the commands, or show the usage of one",
			run: (args, out) -> help(args[0], out)
		});
	}

	/**
		Registers `command`; throws if its name or an alias is taken or the arguments are invalid.
	**/
	public function register(command:Command) {
		final entry = createEntry(command, '/${command.name}');
		for (name in [command.name].concat(command.aliases ?? [])) {
			if (entries.exists(name))
				throw 'command /$name already registered';
			entries.set(name, entry);
		}
		names.push(command.name);
	}

	static function createEntry(command:Command, path:String):Entry {
		final entry:Entry = {
			command: command,
			params: parseParams(command.args ?? "", path),
			path: path,
			subs: new Map()
		};
		if (command.subcommands != null)
			for (sub in command.subcommands) {
				final e = createEntry(sub, '$path ${sub.name}');
				for (name in [sub.name].concat(sub.aliases ?? [])) {
					if (entry.subs.exists(name))
						throw 'command $path $name already registered';
					entry.subs.set(name, e);
				}
			}
		return entry;
	}

	/**
		The command of `line` (without `/`) and its arguments, descending into subcommands; `null` if unknown.
	**/
	function resolve(line:String):Null<{entry:Entry, args:String}> {
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

	/** Registers several commands **/
	public function registerAll(commands:Array<Command>)
		for (c in commands)
			register(c);

	/**
		Parses and runs an input line, e.g. `/msg juliet@example.com hi`, writing its output to `out`
		(the terminal by default). With `slash` `false` the `/` is optional.
		Returns `false` if the command could not run (unknown, invalid arguments, not connected).
	**/
	public function run(line:String, ?out:Output, slash = true):Bool {
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
		final entry = resolved.entry;
		final command = entry.command;
		if (command.run == null) {
			// a command with subcommands only
			if (resolved.args.length > 0) {
				out.error('${entry.path}: unknown subcommand: ${resolved.args.split(" ")[0]}');
				return false;
			}
			help(entry.path, out);
			return true;
		}
		if (entry.params.length == 0 && command.subcommands != null && resolved.args.length > 0) {
			out.error('${entry.path}: unknown subcommand: ${resolved.args.split(" ")[0]} (/help ${entry.path.substr(1)})');
			return false;
		}
		if (command.online == true && !isOnline()) {
			out.error('${entry.path}: not connected');
			return false;
		}
		final args = try parseArgs(entry.params, resolved.args) catch (e:String) {
			out.error('${entry.path}: $e, usage: ${usage(entry)}'
				+ (entry.command.subcommands != null ? ' (/help ${entry.path.substr(1)} for its subcommands)' : ''));
			return false;
		}
		command.run(args, out);
		return true;
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
		} catch (_:String) false;
	}

	/**
		Lists the commands, or shows the usage of command `name` (e.g. `roster` or `roster add`).
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
			if (c.run != null)
				out.print('  ${usage(e)}\n    ${c.description}');
			else
				out.print('  ${e.path}: ${c.description}');
			if (c.aliases != null)
				out.print('    aliases: ${c.aliases.join(", ")}');
			if (c.subcommands != null)
				printTable([for (sub in c.subcommands) e.subs.get(sub.name)], out);
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
		printTable(list, out);
	}

	static function printTable(list:Array<Entry>, out:Output) {
		final lines = [for (e in list) usage(e)];
		var width = 0;
		for (l in lines)
			if (l.length > width)
				width = l.length;
		for (i in 0...list.length)
			out.print('  ${lines[i].rpad(" ", width + 2)}${list[i].command.description}');
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
			throw (skipped != null && args.length == params.length && args[args.length - 1] == null) ? '${skipped.name} must be a number' : 'too many arguments';
		return args;
	}
}
