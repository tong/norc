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

	/** Prompt of the input line (`-i`), `> ` if not set **/
	var ?prompt:String;
}

/**
	Configuration files (`key = value` lines, `#` comments) in the config directory
	(`$XDG_CONFIG_HOME/norc`, Windows: `%APPDATA%\norc`, or `--config`):

	- `conf`: base config, the defaults of all accounts, and `account`: the account to use without `-a`
	- `accounts/<name>`: one file per account, overriding values of the base config

	Keys: `jid`, `host`, `port`, `resource`, `password_cmd`, `download_dir` (`~/` is the home directory),
	`keepalive` (seconds without data before pinging the server, `0` to disable),
	`api` (`1`: socket interface for other programs), `api_host`, `api_port`,
	`last_activity` (`1`: answer last activity requests with the idle time),
	`carbons` (`0`: no copies of the messages of your other clients),
	`chat_states` (`0`: don't send chat states),
	`prompt` (of the input line, in `"` to keep spaces at the start or end).

	The runtime state of an account (pid file) is in `$XDG_STATE_HOME/norc/<name>/` (Windows: `%LOCALAPPDATA%\norc\<name>\`).
**/
class Config {
	public static final DEFAULT_RESOURCE = "norc";

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
		final names = FileSystem.readDirectory(dir).filter(f -> !f.startsWith(".") && !FileSystem.isDirectory('$dir/$f'));
		names.sort(Reflect.compare);
		return names;
	}

	/** Directory for received files: `$XDG_DOWNLOAD_DIR` or `Downloads` in the home directory **/
	public static function downloadDir():String
		return windows() ? home() + "/Downloads" : env("XDG_DOWNLOAD_DIR", "Downloads");

	public static function accountPath(name:String):String
		return accountsDir() + '/$name';

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
	public static function values(account:Account):Array<{key:String, value:Null<String>}> {
		inline function str<T>(v:Null<T>):Null<String>
			return v != null ? Std.string(v) : null;
		inline function bool(v:Null<Bool>):Null<String>
			return v != null ? (v ? "1" : "0") : null;
		return [
			{key: "jid", value: Jid.parseBare(account.jid)},
			{key: "host", value: account.host},
			{key: "port", value: str(account.port)},
			{key: "resource", value: account.resource},
			{key: "password_cmd", value: account.passwordCmd},
			{key: "download_dir", value: account.downloadDir != null ? contractHome(account.downloadDir) : null},
			{key: "keepalive", value: str(account.keepalive)},
			{key: "api", value: bool(account.api)},
			{key: "api_host", value: account.apiHost},
			{key: "api_port", value: str(account.apiPort)},
			{key: "last_activity", value: bool(account.lastActivity)},
			{key: "carbons", value: bool(account.carbons)},
			{key: "chat_states", value: bool(account.chatStates)},
			{key: "prompt", value: account.prompt != null ? '"${account.prompt}"' : null}
		];
	}

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
		for (key => value in values) {
			switch key {
				case "account":
					// the default account, only in the base config
					if (source != basePath())
						throw '$source: account is only allowed in ${basePath()}';
				case "jid":
				case "host":
					account.host = value;
				case "port":
					account.port = parsePort(value, source);
				case "resource":
					// the base config doesn't override a resource given with the jid
					if (source != basePath() || account.jid.resource == null)
						account.resource = value;
				case "password_cmd":
					account.passwordCmd = value;
				case "download_dir":
					account.downloadDir = expandHome(value);
				case "api":
					account.api = parseBool(value, key, source);
				case "chat_states":
					account.chatStates = parseBool(value, key, source);
				case "carbons":
					account.carbons = parseBool(value, key, source);
				case "last_activity":
					account.lastActivity = parseBool(value, key, source);
				case "api_host":
					account.apiHost = value;
				case "api_port":
					account.apiPort = parsePort(value, source);
				case "prompt":
					// quoted to keep spaces
					account.prompt = (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) ? value.substr(1, value.length - 2) : value;
				case "keepalive":
					final v = Std.parseFloat(value);
					if (Math.isNaN(v) || v < 0)
						throw '$source: invalid keepalive: $value (seconds, 0 to disable)';
					account.keepalive = v;
				case _:
					throw '$source: unknown key: $key';
			}
		}
	}

	static function parseBool(value:String, key:String, source:String):Bool
		return switch value.toLowerCase() {
			case "1", "true", "yes", "on": true;
			case "0", "false", "no", "off": false;
			case _: throw '$source: invalid $key: $value (1 or 0)';
		}

	public static function parsePort(value:String, ?source:String):Int {
		final port = Std.parseInt(value);
		if (port == null || port < 1 || port > 65535)
			throw(source != null ? '$source: ' : '') + 'invalid port: $value';
		return port;
	}

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
