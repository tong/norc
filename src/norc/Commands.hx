package norc;

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

	/** Called with the arguments in the order of `args`, `null` for missing optional ones **/
	var run:(args:Array<Null<String>>) -> Void;
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
			args: "[command]",
			description: "list the commands, or show the usage of one",
			run: args -> help(args[0])
		});
	}

	/**
		Registers `command`; throws if its name or an alias is taken or the arguments are invalid.
	**/
	public function register(command:Command) {
		final entry = {command: command, params: parseParams(command.args ?? "", command.name)};
		for (name in [command.name].concat(command.aliases ?? [])) {
			if (entries.exists(name))
				throw 'command /$name already registered';
			entries.set(name, entry);
		}
		names.push(command.name);
	}

	/** Registers several commands **/
	public function registerAll(commands:Array<Command>)
		for (c in commands)
			register(c);

	/**
		Parses and runs an input line, e.g. `/msg juliet@example.com hi`.
	**/
	public function run(line:String) {
		line = line.trim();
		if (line.length == 0)
			return;
		if (!line.startsWith("/")) {
			Term.error("commands start with / (/help for the commands)");
			return;
		}
		final i = line.indexOf(" ");
		final name = (i == -1) ? line.substr(1) : line.substring(1, i);
		final entry = entries.get(name);
		if (entry == null) {
			Term.error('unknown command: /$name (/help for the commands)');
			return;
		}
		final command = entry.command;
		if (command.online == true && !isOnline()) {
			Term.error('/${command.name}: not connected');
			return;
		}
		final args = try parseArgs(entry.params, (i == -1) ? "" : line.substr(i + 1)) catch (e:String) {
			Term.error('/${command.name}: $e, usage: ${usage(command)}');
			return;
		}
		command.run(args);
	}

	/**
		Returns `true` if `line` runs a command ending the client. Called by the input thread
		(the commands are not changed after the start).
	**/
	public function exits(line:String):Bool {
		line = line.trim();
		if (!line.startsWith("/"))
			return false;
		final i = line.indexOf(" ");
		final entry = entries.get((i == -1) ? line.substr(1) : line.substring(1, i));
		if (entry == null || entry.command.exit != true)
			return false;
		// only if it will run
		return try {
			parseArgs(entry.params, (i == -1) ? "" : line.substr(i + 1));
			true;
		} catch (_:String) false;
	}

	public function help(?name:String) {
		if (name != null) {
			final entry = entries.get(name.startsWith("/") ? name.substr(1) : name);
			if (entry == null) {
				Term.error('unknown command: /$name');
				return;
			}
			final c = entry.command;
			Sys.println('  ${usage(c)}\n    ${c.description}' + (c.aliases != null ? '\n    aliases: ${c.aliases.map(a -> '/$a').join(", ")}' : ''));
			return;
		}
		final sorted = names.copy();
		sorted.sort(Reflect.compare);
		final lines = [for (n in sorted) usage(entries.get(n).command)];
		var width = 0;
		for (l in lines)
			if (l.length > width)
				width = l.length;
		for (i in 0...sorted.length)
			Sys.println('  ${lines[i].rpad(" ", width + 2)}${entries.get(sorted[i]).command.description}');
	}

	static function usage(command:Command):String
		return '/${command.name}' + (command.args != null && command.args.length > 0 ? ' ${command.args}' : '');

	static function parseParams(spec:String, command:String):Array<Param> {
		final params = new Array<Param>();
		final re = ~/^(<|\[)(#?)([^>\]\s.]+)(\.\.\.)?(>|\])$/;
		for (word in spec.split(" ")) {
			if (word.length == 0)
				continue;
			if (!re.match(word) || (re.matched(1) == "<") != (re.matched(5) == ">"))
				throw 'command /$command: invalid argument $word';
			final param = {
				optional: re.matched(1) == "[",
				integer: re.matched(2) == "#",
				name: re.matched(3),
				rest: re.matched(4) != null
			};
			if (params.length > 0 && params[params.length - 1].rest)
				throw 'command /$command: only the last argument can take the rest of the line';
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
