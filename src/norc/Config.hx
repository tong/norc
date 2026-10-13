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
}

/**
	Configuration files (`key = value` lines, `#` comments):

	- `$XDG_CONFIG_HOME/norc/accounts/<name>`: one file per account
	- `$XDG_STATE_HOME/norc/<name>/`: runtime state of an account (pid file)
**/
class Config {
	public static final DEFAULT_RESOURCE = "norc";

	public static function configDir():String
		return xdg("XDG_CONFIG_HOME", ".config") + "/norc";

	public static function accountsDir():String
		return configDir() + "/accounts";

	public static function stateDir(account:String):String
		return xdg("XDG_STATE_HOME", ".local/state") + '/norc/$account';

	/** Names of the configured accounts **/
	public static function listAccounts():Array<String> {
		final dir = accountsDir();
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return [];
		final names = FileSystem.readDirectory(dir).filter(f -> !f.startsWith(".") && !FileSystem.isDirectory('$dir/$f'));
		names.sort(Reflect.compare);
		return names;
	}

	public static function loadAccount(name:String):Account {
		final path = accountsDir() + '/$name';
		if (!FileSystem.exists(path))
			throw 'no such account: $name ($path)';
		final values = parse(File.getContent(path), path);
		final jid = values.get("jid");
		if (jid == null)
			throw '$path: missing jid';
		final account = createAccount(name, jid);
		for (key => value in values) {
			switch key {
				case "jid":
				case "host":
					account.host = value;
				case "port":
					account.port = parsePort(value, path);
				case "resource":
					account.resource = value;
				case "password_cmd":
					account.passwordCmd = value;
				case _:
					throw '$path: unknown key: $key';
			}
		}
		return account;
	}

	public static function createAccount(name:String, jid:String):Account {
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

	static function xdg(env:String, fallback:String):String {
		final dir = Sys.getEnv(env);
		return (dir != null && dir.length > 0) ? dir : Sys.getEnv("HOME") + '/$fallback';
	}
}
