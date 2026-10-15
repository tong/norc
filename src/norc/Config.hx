package norc;

import sys.FileSystem;
import sys.io.File;
import xmpp.Jid;

using StringTools;

typedef Account = {
	/** Name of the account (file name of its config, or the bare jid) **/
	var name:String;

	var jid:Jid;
	var ?host:String;
	var port:Int;
	var resource:String;
	var ?passwordCmd:String;

	/** Directory for received files **/
	var ?downloadDir:String;

	/** Seconds without data from the server before pinging it, `0` to disable **/
	var ?keepalive:Float;

	/** Socket interface for other programs (`Api`) **/
	var ?api:Bool;

	/** Answer last activity requests with the idle time **/
	var ?lastActivity:Bool;

	/** Address of the socket interface, `127.0.0.1` if not set **/
	var ?apiHost:String;

	/** Port of the socket interface, a free port if not set **/
	var ?apiPort:Int;

	/** Receive copies of the messages of the other clients of the account (Message Carbons), `true` if not set **/
	var ?carbons:Bool;

	/** Send chat states (typing, …), `true` if not set **/
	var ?chatStates:Bool;

	/** Answer entity time requests (reveals the time zone) **/
	var ?entityTime:Bool;

	/** Stream management (acknowledgements, resuming the session after a disconnection), `true` if not set **/
	var ?streamManagement:Bool;

	/** Receive attention requests (`/buzz`), `true` if not set **/
	var ?attention:Bool;

	/** Program for the media of calls with its options, `norc-rtc` if not set **/
	var ?callHelper:String;

	/** Keep the history of the input line (`-i`) in the state directory, `true` if not set **/
	var ?persistentCommandHistory:Bool;

	/** Prompt of the input line (`-i`), `> ` if not set **/
	var ?prompt:String;

	/**
		Prompt in chat mode (`/chat`): `{name}` is the contact's name, `{jid}` its jid, `{state}` its chat state unless
		active (e.g. ` (typing)`); `{name}{state}> ` if not set
	**/
	var ?chatPrompt:String;

	/** Prompt in group chat mode (in a room): `{name}` is the room's local part, `{jid}` its jid, `{nick}` the own nick; `#{name}> ` if not set **/
	var ?roomPrompt:String;
}

/** A config key: its value in the config of an account **/
private typedef Key = {
	var name:String;

	/** The value as written in the config, `null` if not set **/
	var get:Account->Null<String>;

	/** Sets the value; throws a message if it is invalid **/
	var set:(Account, String) -> Void;
}

/**
	Configuration files (`key = value` lines, `#` comments) in the config directory
	(`$XDG_CONFIG_HOME/norc`, Windows: `%APPDATA%\norc`, or `--config`):

	- `conf`: base config, the defaults of all accounts, and `account`: the account to use without `-a`
	- `accounts/<name>`: one file per account, overriding values of the base config; or a directory with the config
	  in `conf`, and hooks (`hooks/`) and scripts (`scripts/`) only of this account, in addition to those of the
	  config directory

	Keys: `jid`, `host`, `port`, `resource`, `password_cmd`, `download_dir` (`~/` is the home directory),
	`keepalive` (seconds without data before pinging the server, `0` to disable),
	`api` (`1`: socket interface for other programs), `api_host`, `api_port`,
	`last_activity` (`1`: answer last activity requests with the idle time),
	`carbons` (`0`: no copies of the messages of your other clients),
	`chat_states` (`0`: don't send chat states),
	`entity_time` (`1`: answer time requests, revealing your time zone),
	`attention` (`0`: ignore attention requests),
	`stream_management` (`0`: no acknowledgements and resumption of the session),
	`call_helper` (program for the media of calls, with options),
	`persistent_command_history` (`0`: the history of the input line is not kept),
	`prompt` (of the input line, in `"` to keep spaces at the start or end),
	`chat_prompt` (in chat mode, `{name}`, `{jid}` and `{state}` of the contact),
	`room_prompt` (in a room, `{name}`, `{jid}` and `{nick}`).

	The runtime state of an account (pid file) is in `$XDG_STATE_HOME/norc/<name>/` (Windows: `%LOCALAPPDATA%\norc\<name>\`).
**/
class Config {
	public static final DEFAULT_RESOURCE = "norc";

	/** The keys of an account, in the order they are shown and written (`account` is only in the base config) **/
	static final KEYS:Array<Key> = [
		{name: "jid", get: a -> Jid.parseBare(a.jid), set: (a, v) -> {}},
		{name: "host", get: a -> a.host, set: (a, v) -> a.host = v},
		{name: "port", get: a -> Std.string(a.port), set: (a, v) -> a.port = parsePort(v)},
		{name: "resource", get: a -> a.resource, set: (a, v) -> a.resource = v},
		{name: "password_cmd", get: a -> a.passwordCmd, set: (a, v) -> a.passwordCmd = v},
		{name: "download_dir", get: a -> (a.downloadDir != null) ? contractHome(a.downloadDir) : null, set: (a, v) -> a.downloadDir = expandHome(v)},
		{name: "keepalive", get: a -> (a.keepalive != null) ? Std.string(a.keepalive) : null, set: (a, v) -> a.keepalive = parseSeconds(v)},
		flag("api", a -> a.api, (a, v) -> a.api = v),
		{name: "api_host", get: a -> a.apiHost, set: (a, v) -> a.apiHost = v},
		{name: "api_port", get: a -> (a.apiPort != null) ? Std.string(a.apiPort) : null, set: (a, v) -> a.apiPort = parsePort(v)},
		flag("last_activity", a -> a.lastActivity, (a, v) -> a.lastActivity = v),
		flag("carbons", a -> a.carbons, (a, v) -> a.carbons = v),
		flag("chat_states", a -> a.chatStates, (a, v) -> a.chatStates = v),
		flag("entity_time", a -> a.entityTime, (a, v) -> a.entityTime = v),
		flag("attention", a -> a.attention, (a, v) -> a.attention = v),
		flag("stream_management", a -> a.streamManagement, (a, v) -> a.streamManagement = v),
		{name: "call_helper", get: a -> a.callHelper, set: (a, v) -> a.callHelper = v},
		flag("persistent_command_history", a -> a.persistentCommandHistory, (a, v) -> a.persistentCommandHistory = v),
		// in quotes: spaces at the start or end are kept
		{name: "prompt", get: a -> (a.prompt != null) ? '"${a.prompt}"' : null, set: (a, v) -> a.prompt = unquote(v)},
		{name: "chat_prompt", get: a -> (a.chatPrompt != null) ? '"${a.chatPrompt}"' : null, set: (a, v) -> a.chatPrompt = unquote(v)},
		{name: "room_prompt", get: a -> (a.roomPrompt != null) ? '"${a.roomPrompt}"' : null, set: (a, v) -> a.roomPrompt = unquote(v)}
	];

	/** Overrides the config directory (`--config`) **/
	public static var dir:Null<String>;

	public static function configDir():String
		return dir ?? (windows() ? env("APPDATA", "AppData/Roaming") : env("XDG_CONFIG_HOME", ".config")) + "/norc";

	public static function accountsDir():String
		return configDir() + "/accounts";

	/** The base config, defaults of all accounts **/
	public static function basePath():String
		return configDir() + "/conf";

	public static function stateDir(account:String):String
		return (windows() ? env("LOCALAPPDATA", "AppData/Local") : env("XDG_STATE_HOME", ".local/state")) + '/norc/$account';

	/** Names of the configured accounts **/
	public static function listAccounts():Array<String> {
		final dir = accountsDir();
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return [];
		// a file, or a directory with the config in conf
		final names = FileSystem.readDirectory(dir)
			.filter(f -> !f.startsWith(".") && (!FileSystem.isDirectory('$dir/$f') || FileSystem.exists('$dir/$f/conf')));
		names.sort(Reflect.compare);
		return names;
	}

	/** Directory for received files: `$XDG_DOWNLOAD_DIR` or `Downloads` in the home directory **/
	public static function downloadDir():String
		return windows() ? home() + "/Downloads" : env("XDG_DOWNLOAD_DIR", "Downloads");

	/** The config file of the account `name`: `accounts/<name>`, or `accounts/<name>/conf` of an account directory **/
	public static function accountPath(name:String):String {
		final dir = accountDir(name);
		return (dir != null) ? '$dir/conf' : accountsDir() + '/$name';
	}

	/** The directory of the account `name` (with `conf`, `hooks/`, `scripts/`), `null` if its config is a file **/
	public static function accountDir(name:String):Null<String> {
		final path = accountsDir() + '/$name';
		return (FileSystem.exists(path) && FileSystem.isDirectory(path)) ? path : null;
	}

	/**
		Writes the config file of a new account; throws if it exists.
	**/
	public static function saveAccount(account:Account) {
		final path = accountPath(account.name);
		if (FileSystem.exists(path))
			throw 'account config exists: $path';
		storeAccount(account);
	}

	/**
		The config values of `account` in the order of the keys, `null` if not set.
	**/
	public static function values(account:Account):Array<{key:String, value:Null<String>}>
		return [for (k in KEYS) {key: k.name, value: k.get(account)}];

	/**
		The values of `account` differing from its config file (with the base config), `[]` if saved.
		Without config file: the values differing from the base config.
	**/
	public static function unsaved(account:Account):Array<String> {
		final saved = valueMap(FileSystem.exists(accountPath(account.name)) ? loadAccount(account.name) : createAccount(account.name,
			Jid.parseBare(account.jid)));
		return [for (v in values(account)) if (saved.get(v.key) != v.value) v.key];
	}

	/**
		Writes the values of `account` to its config file (created if it doesn't exist), returns its path.
		Comments, the order and the formatting of unchanged values are kept; values of the base config are not repeated.
	**/
	public static function storeAccount(account:Account):String {
		final path = accountPath(account.name);
		final exists = FileSystem.exists(path);
		final changed = unsaved(account);
		final current = valueMap(account);
		final lines = exists ? File.getContent(path).split("\n") : ['jid = ${Jid.parseBare(account.jid)}'];
		while (lines.length > 0 && lines[lines.length - 1].trim() == "")
			lines.pop();
		final written = new Map<String, Bool>();
		for (i in 0...lines.length) {
			final line = lines[i].trim();
			final eq = line.indexOf("=");
			if (line.startsWith("#") || eq == -1)
				continue;
			final key = line.substr(0, eq).trim();
			written.set(key, true);
			if (!changed.contains(key))
				continue;
			final value = current.get(key);
			lines[i] = value != null ? '$key = $value' : '# $key =';
		}
		for (key in changed)
			if (!written.exists(key) && current.get(key) != null)
				lines.push('$key = ${current.get(key)}');
		if (!exists && account.passwordCmd == null)
			lines.push('# password_cmd = pass xmpp/${Jid.parseBare(account.jid)}');
		FileSystem.createDirectory(accountsDir());
		File.saveContent(path, lines.join("\n") + "\n");
		return path;
	}

	static function valueMap(account:Account):Map<String, Null<String>>
		return [for (v in values(account)) v.key => v.value];

	/**
		The account `name`: a config file with this name, else the only configured account whose jid
		has this local part (e.g. `tong` for `tong@example.org`) or bare jid.
	**/
	public static function findAccount(name:String):Account {
		if (FileSystem.exists(accountPath(name)))
			return loadAccount(name);
		final matches = new Array<Account>();
		for (n in listAccounts()) {
			final account = try loadAccount(n) catch (_) continue;
			if (account.jid.node == name || Jid.parseBare(account.jid) == name)
				matches.push(account);
		}
		return switch matches.length {
			case 0: throw 'no such account: $name (${accountPath(name)})';
			case 1: matches[0];
			case _: throw 'several accounts match $name, give the full name: ${[for (a in matches) a.name].join(", ")}';
		}
	}

	public static function loadAccount(name:String):Account {
		final path = accountPath(name);
		if (!FileSystem.exists(path))
			throw 'no such account: $name ($path)';
		final values = parse(File.getContent(path), path);
		final base = loadBase();
		final jid = values.get("jid") ?? base.get("jid");
		if (jid == null)
			throw '$path: missing jid';
		final account = newAccount(name, jid);
		apply(account, base, basePath());
		apply(account, values, path);
		return account;
	}

	/**
		An account without config file (e.g. `--jid`), with the values of the base config.
	**/
	public static function createAccount(name:String, jid:String):Account {
		final account = newAccount(name, jid);
		apply(account, loadBase(), basePath());
		return account;
	}

	static function newAccount(name:String, jid:String):Account {
		if (!Jid.isValid(jid))
			throw 'invalid jid: $jid';
		final j:Jid = jid;
		if (j.node == null)
			throw 'jid has no local part: $jid';
		return {
			name: name,
			jid: j,
			port: xmpp.client.Stream.PORT,
			resource: j.resource ?? DEFAULT_RESOURCE
		};
	}

	static function loadBase():Map<String, String> {
		final path = basePath();
		return FileSystem.exists(path) ? parse(File.getContent(path), path) : [];
	}

	/**
		The account to use without `-a`: `account` of the base config, else the only configured account.
		Throws if there is none, or several without default.
	**/
	public static function defaultAccount():Account {
		final name = loadBase().get("account");
		if (name != null)
			return findAccount(name);
		final names = listAccounts();
		return switch names.length {
			case 0: throw 'no account configured: create ${accountsDir()}/<name> or use --jid';
			case 1: loadAccount(names[0]);
			case _: throw 'several accounts configured, select one with -a or set account in ${basePath()}: ${names.join(", ")}';
		}
	}

	/** Sets the config `values` (from file `source`) **/
	static function apply(account:Account, values:Map<String, String>, source:String) {
		final base = source == basePath();
		for (name => value in values) {
			// the default account, only in the base config
			if (name == "account") {
				if (!base)
					throw '$source: account is only allowed in ${basePath()}';
				continue;
			}
			final key = Lambda.find(KEYS, k -> k.name == name);
			if (key == null)
				throw '$source: unknown key: $name';
			// the base config doesn't override a resource given with the jid
			if (name == "resource" && base && account.jid.resource != null)
				continue;
			try
				key.set(account, value)
			catch (e:String)
				throw '$source: $e';
		}
	}

	/** A key of a boolean: `1` or `0` (`true`/`false`, `yes`/`no`, `on`/`off` are read too) **/
	static function flag(name:String, get:Account->Null<Bool>, set:(Account, Bool) -> Void):Key
		return {
			name: name,
			get: a -> {
				final v = get(a);
				(v == null) ? null : v ? "1" : "0";
			},
			set: (a, v) -> set(a, switch v.toLowerCase() {
				case "1", "true", "yes", "on": true;
				case "0", "false", "no", "off": false;
				case _: throw 'invalid $name: $v (1 or 0)';
			})
		};

	public static function parsePort(value:String):Int {
		final port = Std.parseInt(value);
		if (port == null || port < 1 || port > 65535)
			throw 'invalid port: $value';
		return port;
	}

	static function parseSeconds(value:String):Float {
		final v = Std.parseFloat(value);
		if (Math.isNaN(v) || v < 0)
			throw 'invalid keepalive: $value (seconds, 0 to disable)';
		return v;
	}

	static function unquote(value:String):String
		return (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) ? value.substr(1, value.length - 2) : value;

	static function parse(content:String, path:String):Map<String, String> {
		final values = new Map<String, String>();
		var n = 0;
		for (line in content.split("\n")) {
			n++;
			line = line.trim();
			if (line.length == 0 || line.startsWith("#"))
				continue;
			final i = line.indexOf("=");
			if (i == -1)
				throw '$path:$n: expected key = value';
			values.set(line.substr(0, i).trim(), line.substr(i + 1).trim());
		}
		return values;
	}

	/** Directory from environment variable `name`, or `fallback` in the home directory **/
	static function env(name:String, fallback:String):String {
		final dir = Sys.getEnv(name);
		return (dir != null && dir.length > 0) ? dir : home() + '/$fallback';
	}

	public static function expandHome(path:String):String
		return path.startsWith("~/") ? home() + path.substr(1) : path;

	/** `path` with the home directory as `~/` **/
	static function contractHome(path:String):String
		return path.startsWith(home() + "/") ? "~" + path.substr(home().length) : path;

	static function home():String
		return Sys.getEnv(windows() ? "USERPROFILE" : "HOME");

	static inline function windows():Bool
		return Sys.systemName() == "Windows";
}
