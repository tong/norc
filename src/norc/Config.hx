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

	/** Address of the socket interface, `127.0.0.1` if not set **/
	var ?apiHost:String;

	/** Port of the socket interface, a free port if not set **/
	var ?apiPort:Int;
}

/**
	Configuration files (`key = value` lines, `#` comments) in the config directory
	(`$XDG_CONFIG_HOME/norc`, Windows: `%APPDATA%\norc`, or `--config`):

	- `conf`: base config, the defaults of all accounts, and `account`: the account to use without `-a`
	- `accounts/<name>`: one file per account, overriding values of the base config

	Keys: `jid`, `host`, `port`, `resource`, `password_cmd`, `download_dir` (`~/` is the home directory),
	`keepalive` (seconds without data before pinging the server, `0` to disable),
	`api` (`1`: socket interface for other programs), `api_host`, `api_port`.

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
		// values of the base config are not repeated
		final defaults = createAccount(account.name, Jid.parseBare(account.jid));
		final lines = ['jid = ${Jid.parseBare(account.jid)}'];
		if (account.host != defaults.host)
			lines.push('host = ${account.host}');
		if (account.port != defaults.port)
			lines.push('port = ${account.port}');
		if (account.resource != defaults.resource)
			lines.push('resource = ${account.resource}');
		if (account.passwordCmd != defaults.passwordCmd)
			lines.push('password_cmd = ${account.passwordCmd}');
		else if (account.passwordCmd == null)
			lines.push('# password_cmd = pass xmpp/${Jid.parseBare(account.jid)}');
		FileSystem.createDirectory(accountsDir());
		File.saveContent(path, lines.join("\n") + "\n");
	}

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
					account.api = switch value.toLowerCase() {
						case "1", "true", "yes", "on": true;
						case "0", "false", "no", "off": false;
						case _: throw '$source: invalid api: $value (1 or 0)';
					}
				case "api_host":
					account.apiHost = value;
				case "api_port":
					account.apiPort = parsePort(value, source);
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

	static function home():String
		return Sys.getEnv(windows() ? "USERPROFILE" : "HOME");

	static inline function windows():Bool
		return Sys.systemName() == "Windows";
}
