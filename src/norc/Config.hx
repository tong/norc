package norc;

import sys.FileSystem;
import sys.io.File;
import xmpp.Jid;

using StringTools;

/** When a changed config value takes effect in a running norc, see `Config.applies` **/
enum abstract ConfigApplies(String) to String {
	var Now = "now";
	var Call = "with the next call";
	var Reconnect = "after /reconnect";
	var Restart = "after a restart of norc";
}

/** Where the socket interface listens: a Unix socket (its path), TCP (host and port, `0`: a free one) **/
typedef ApiEndpoints = {
	var ?socket:String;
	var ?tcp:{host:String, port:Int};
}

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

	/** Where the socket interface listens (`api = socket,9990`, see `Config.parseApi`), `null`: by the other keys **/
	var ?apiSpec:String;

	/** The socket interface also at a Unix socket (`<state dir>/api.sock`, where supported), `true` if not set **/
	var ?apiSocket:Bool;

	/** The socket interface also over TCP (`api_host`, `api_port`, with a token), `true` if not set **/
	var ?apiTcp:Bool;

	/** Receive copies of the messages of the other clients of the account (Message Carbons), `true` if not set **/
	var ?carbons:Bool;

	/** Send chat states (typing, …), `true` if not set **/
	var ?chatStates:Bool;

	/** OMEMO end-to-end encryption (`module.Omemo`), `false` if not set **/
	var ?omemo:Bool;

	/** Answer entity time requests (reveals the time zone) **/
	var ?entityTime:Bool;

	/** Stream management (acknowledgements, resuming the session after a disconnection), `true` if not set **/
	var ?streamManagement:Bool;

	/** Small avatars of contacts: before their names, `{avatar}` in prompts (in terminals showing images), `false` if not set **/
	var ?inlineAvatars:Bool;

	/** Images shared in messages shown after them: `contacts` (default), `all` or `off` (see `module.InlineImages`) **/
	var ?inlineImages:String;

	/** A local log of the chats with contacts (`Chatlog`), `false` if not set **/
	var ?chatlog:Bool;

	/** Modules not loaded (see `Config.MODULES`): their commands, features and handling of stanzas **/
	var ?disableModules:Array<String>;

	/** Receive attention requests (`/attention`), `true` if not set **/
	var ?attention:Bool;

	/** Show images (e.g. avatars) in terminals supporting the kitty graphics protocol, `true` if not set **/
	var ?terminalImages:Bool;

	/** Aliases of commands (`alias.h = help`): the name without `/`, the command it runs with its first arguments **/
	var ?aliases:Map<String, String>;

	/** Shared directories (`share.music = ~/Music`, XEP-0329): the name contacts see, the directory **/
	var ?shares:Map<String, String>;

	/** Who may list and download the shared directories: `roster` (default), `none`, `group:<name>`, jids (`,`) **/
	var ?shareAccess:String;

	/** Priority of the presence (-128 to 127), none (0) if not set **/
	var ?priority:Int;

	/** Join the rooms bookmarked with autojoin after the login, `true` if not set **/
	var ?autojoinBookmarks:Bool;

	/** STUN server for calls (`stun://host:port`), in addition to those of the server **/
	var ?stun:String;

	/** TURN servers for calls (`turn://user:password@host:port`, `turns://…`), in addition to those of the server **/
	var ?turn:Array<String>;

	/** Devices of calls: their names or parts of them (`/calls devices`), the default devices if not set **/
	var ?callMicrophone:String;

	var ?callSpeaker:String;
	var ?callCamera:String;

	/** Size of the sent video in calls (`1280x720`), of the camera if not set **/
	var ?callVideoSize:String;

	/** Frames per second of the sent video in calls, of the camera if not set **/
	var ?callVideoFps:Int;

	/** Bitrates of the sent video and audio in calls (kbit/s), the defaults of the codecs if not set **/
	var ?callVideoBitrate:Int;

	var ?callAudioBitrate:Int;

	/** Echo cancellation and noise suppression of the microphone in calls, `true` if not set **/
	var ?callEchoCancel:Bool;

	/** A window with the own video in video calls, `true` if not set **/
	var ?callSelfView:Bool;

	/** Program for the media of calls with its options, `norc-rtc` if not set **/
	var ?callHelper:String;

	/** Directory of the recordings of calls, `Config.recordingsDir()` if not set **/
	var ?callRecordDir:String;

	/** Calls can be recorded (`/call record`), `false` if not set **/
	var ?callRecording:Bool;

	/** PubSub service of shared documents (`/share`), discovered on the server if not set **/
	var ?shareService:String;

	/** Keep the history of the input line (`-i`) in the state directory, `true` if not set **/
	var ?persistentCommandHistory:Bool;

	/** Messages of the archive shown when the chat mode starts with a contact, `10` if not set, `0`: none **/
	var ?chatHistory:Int;

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
	`api` (`1`: socket interface for other programs, at the Unix socket and over TCP; or where: `socket`, `tcp`, a
	port, `host:port`, a path of a Unix socket, several separated by `,`, see `parseApi`), `api_host`, `api_port`,
	`api_socket` and `api_tcp` (`0`: not at the Unix socket, not over TCP) for `api = 1`,
	`last_activity` (`1`: answer last activity requests with the idle time),
	`carbons` (`0`: no copies of the messages of your other clients),
	`omemo` (`1`: OMEMO end-to-end encryption),
	`chat_states` (`0`: don't send chat states),
	`entity_time` (`1`: answer time requests, revealing your time zone),
	`attention` (`0`: ignore attention requests),
	`stream_management` (`0`: no acknowledgements and resumption of the session),
	`call_helper` (program for the media of calls, with options),
	`call_microphone`, `call_speaker`, `call_camera` (devices of calls by name, see `/calls devices`),
	`call_echo_cancel` (`0`: no echo cancellation and noise suppression in calls),
	`call_self_view` (`0`: no window with the own video in video calls),
	`call_video_size` (`1280x720`), `call_video_fps`, `call_video_bitrate`, `call_audio_bitrate` (kbit/s) of the sent media,
	`call_recording` (`1`: calls can be recorded, `/call record`), `call_record_dir` (the recordings),
	`stun`, `turn` (servers for calls, `stun://host:port`, `turn://user:password@host:port`, several separated by `,`),
	`autojoin_bookmarks` (`0`: don't join bookmarked rooms after the login),
	`priority` (of the presence, -128 to 127),
	`alias.<name>` (an alias of a command, e.g. `alias.h = help`, `alias.away = presence away`),
	`share.<name>` (a directory shared with contacts, e.g. `share.music = ~/Music`, see `/file shared`),
	`share_access` (who may list and download them: `roster` (contacts seeing your presence, the default), `none`,
	`group:<name>` (a roster group), jids; several separated by `,`),
	`persistent_command_history` (`0`: the history of the input line is not kept),
	`chat_history` (messages of the chatlog, else of the archive, shown when the chat mode starts, `0`: none),
	`chatlog` (`1`: a local log of the chats with contacts, see `/chatlog`),
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
		{name: "api", get: a -> a.apiSpec ?? ((a.api == null) ? null : a.api ? "1" : "0"), set: (a, v) -> setApi(a, v)},
		{name: "api_host", get: a -> a.apiHost, set: (a, v) -> a.apiHost = v},
		flag("api_socket", a -> a.apiSocket, (a, v) -> a.apiSocket = v),
		flag("api_tcp", a -> a.apiTcp, (a, v) -> a.apiTcp = v),
		{name: "api_port", get: a -> (a.apiPort != null) ? Std.string(a.apiPort) : null, set: (a, v) -> a.apiPort = parsePort(v)},
		flag("last_activity", a -> a.lastActivity, (a, v) -> a.lastActivity = v),
		flag("carbons", a -> a.carbons, (a, v) -> a.carbons = v),
		flag("omemo", a -> a.omemo, (a, v) -> a.omemo = v),
		flag("terminal_images", a -> a.terminalImages, (a, v) -> a.terminalImages = v),
		flag("inline_avatars", a -> a.inlineAvatars, (a, v) -> a.inlineAvatars = v),
		flag("chat_states", a -> a.chatStates, (a, v) -> a.chatStates = v),
		flag("entity_time", a -> a.entityTime, (a, v) -> a.entityTime = v),
		flag("attention", a -> a.attention, (a, v) -> a.attention = v),
		flag("stream_management", a -> a.streamManagement, (a, v) -> a.streamManagement = v),
		{name: "priority", get: a -> (a.priority != null) ? Std.string(a.priority) : null, set: (a, v) -> a.priority = parsePriority(v)},
		flag("autojoin_bookmarks", a -> a.autojoinBookmarks, (a, v) -> a.autojoinBookmarks = v),
		{name: "share_access", get: a -> a.shareAccess, set: (a, v) -> a.shareAccess = v},
		{name: "call_microphone", get: a -> a.callMicrophone, set: (a, v) -> a.callMicrophone = v},
		{name: "call_speaker", get: a -> a.callSpeaker, set: (a, v) -> a.callSpeaker = v},
		{name: "call_camera", get: a -> a.callCamera, set: (a, v) -> a.callCamera = v},
		{
			name: "call_video_size",
			get: a -> a.callVideoSize,
			set: (a, v) -> a.callVideoSize = ~/^[1-9]\d*x[1-9]\d*$/.match(v) ? v : throw 'invalid call_video_size: $v (e.g. 1280x720)'
		},
		{name: "call_video_fps", get: a -> number(a.callVideoFps), set: (a, v) -> a.callVideoFps = positive("call_video_fps", v)},
		{name: "call_video_bitrate", get: a -> number(a.callVideoBitrate), set: (a, v) -> a.callVideoBitrate = positive("call_video_bitrate", v)},
		{name: "call_audio_bitrate", get: a -> number(a.callAudioBitrate), set: (a, v) -> a.callAudioBitrate = positive("call_audio_bitrate", v)},
		flag("call_echo_cancel", a -> a.callEchoCancel, (a, v) -> a.callEchoCancel = v),
		flag("call_self_view", a -> a.callSelfView, (a, v) -> a.callSelfView = v),
		{
			name: "stun",
			get: a -> a.stun,
			set: (a, v) -> a.stun = serverUri(v, ["stun"])
		},
		{
			name: "turn",
			get: a -> (a.turn != null) ? a.turn.join(", ") : null,
			set: (a, v) -> a.turn = [for (s in v.split(",")) if (s.trim().length > 0) serverUri(s.trim(), ["turn", "turns"])]
		},
		{name: "call_helper", get: a -> a.callHelper, set: (a, v) -> a.callHelper = v},
		flag("call_recording", a -> a.callRecording, (a, v) -> a.callRecording = v),
		{
			name: "call_record_dir",
			get: a -> (a.callRecordDir != null) ? contractHome(a.callRecordDir) : null,
			set: (a, v) -> a.callRecordDir = expandHome(v)
		},
		{
			name: "inline_images",
			get: a -> a.inlineImages,
			set: (a, v) -> a.inlineImages = switch v.trim().toLowerCase() {
				case p = "contacts" | "all" | "off": p;
				case _: throw 'invalid value: $v (contacts, all, off)';
			}
		},
		{
			name: "disable_modules",
			get: a -> (a.disableModules != null) ? a.disableModules.join(", ") : null,
			set: (a, v) -> a.disableModules = [for (s in v.split(",")) if (s.trim().length > 0) module(s.trim().toLowerCase())]
		},
		{name: "share_service", get: a -> a.shareService, set: (a, v) -> a.shareService = v},
		flag("chatlog", a -> a.chatlog, (a, v) -> a.chatlog = v),
		{name: "chat_history", get: a -> (a.chatHistory != null) ? Std.string(a.chatHistory) : null, set: (a, v) -> a.chatHistory = parseCount(v)},
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

	/**
		The Unix socket of the socket interface of `account`: `$XDG_RUNTIME_DIR/norc/<account>.sock` (the place of
		sockets, only the user may access it; paths of sockets are limited to 107 bytes), else `<state dir>/api.sock`.
	**/
	public static function socketPath(account:String):String {
		final runtime = Sys.getEnv("XDG_RUNTIME_DIR");
		return (runtime != null && runtime.length > 0 && FileSystem.exists(runtime)) ? '$runtime/norc/$account.sock' : '${stateDir(account)}/api.sock';
	}

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

	/** Directory for cached data of all accounts (e.g. avatars): `$XDG_CACHE_HOME/norc` **/
	public static function cacheDir():String
		return (windows() ? env("LOCALAPPDATA", "AppData/Local") + "/norc/cache" : env("XDG_CACHE_HOME", ".cache") + "/norc");

	/** Directory of the chatlog of `account` (`Chatlog`): `$XDG_DATA_HOME/norc/chatlog/<account>` **/
	public static function chatlogDir(account:String):String
		return (windows() ? env("APPDATA", "AppData/Roaming") : env("XDG_DATA_HOME", ".local/share")) + '/norc/chatlog/$account';

	/** Directory for the recordings of calls: `$XDG_DATA_HOME/norc/calls` **/
	public static function recordingsDir():String
		return (windows() ? env("APPDATA", "AppData/Roaming") : env("XDG_DATA_HOME", ".local/share")) + "/norc/calls";

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
	public static function values(account:Account):Array<{key:String, value:Null<String>}> {
		final aliases = [for (name => command in account.aliases ?? []) {key: 'alias.$name', value: command}];
		aliases.sort((a, b) -> Reflect.compare(a.key, b.key));
		final shares = [for (name => dir in account.shares ?? []) {key: 'share.$name', value: contractHome(dir)}];
		shares.sort((a, b) -> Reflect.compare(a.key, b.key));
		return [for (k in KEYS) {key: k.name, value: k.get(account)}].concat(aliases).concat(shares);
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
		final base = source == basePath();
		for (name => value in values) {
			// the default account, only in the base config
			if (name == "account") {
				if (!base)
					throw '$source: account is only allowed in ${basePath()}';
				continue;
			}
			// the base config doesn't override a resource given with the jid
			if (name == "resource" && base && account.jid.resource != null)
				continue;
			try
				set(account, name, value)
			catch (e:String)
				throw '$source: $e';
		}
	}

	/** Sets the value of key `name` (also `alias.<name>`, `share.<name>`); throws a message if it is invalid **/
	public static function set(account:Account, name:String, value:String) {
		if (name.startsWith("alias.")) {
			final alias = name.substr("alias.".length);
			final command = value.startsWith("/") ? value.substr(1) : value;
			if (!~/^[^\s\/]+$/.match(alias) || command.trim().length == 0)
				throw 'invalid alias: $name = $value (alias.<name> = <command>)';
			(account.aliases ??= new Map()).set(alias, command);
			return;
		}
		if (name.startsWith("share.")) {
			// the name is the first part of the paths contacts see
			final share = name.substr("share.".length);
			if (!~/^[^\s\/.][^\s\/]*$/.match(share) || value.trim().length == 0)
				throw 'invalid share: $name = $value (share.<name> = <directory>)';
			(account.shares ??= new Map()).set(share, expandHome(value.trim()));
			return;
		}
		final key = Lambda.find(KEYS, k -> k.name == name);
		if (key == null)
			throw 'unknown key: $name';
		key.set(account, value);
	}

	/** The value of key `name` (also `alias.<name>`, `share.<name>`), `null` if not set **/
	public static function get(account:Account, name:String):Null<String> {
		final v = Lambda.find(values(account), v -> v.key == name);
		return v?.value;
	}

	/** The names of the keys (not `alias.<name>` and `share.<name>`) **/
	public static function keyNames():Array<String>
		return [for (k in KEYS) k.name];

	/**
		When a changed value of key `name` takes effect in a running norc: `now`, with the `call` started next, after
		`reconnect` (the next login), or after a `restart` (read when norc starts).
	**/
	public static function applies(name:String):ConfigApplies {
		if (name.startsWith("alias."))
			return Now;
		if (name.startsWith("call_") && name != "call_helper" || name == "stun" || name == "turn")
			return Call;
		return switch name {
			case "keepalive", "priority", "inline_avatars", "chat_history", "chatlog", "prompt", "chat_prompt", "room_prompt": Now;
			// not resource: /reconnect resumes the session, with its resource
			case "host", "port", "stream_management": Reconnect;
			case _: Restart;
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

	/** `api = <value>` (also `--api <value>`): `1`, `0`, or where it listens (`parseApi`); throws a message if invalid **/
	public static function setApi(a:Account, value:String) {
		switch value.trim().toLowerCase() {
			case "1", "true", "yes", "on":
				a.api = true;
				a.apiSpec = null;
			case "0", "false", "no", "off":
				a.api = false;
				a.apiSpec = null;
			case _:
				parseApi(value, a.name ?? "account");
				a.api = true;
				a.apiSpec = value.trim();
		}
	}

	/** `value` is where the socket interface listens (`--api` takes the next argument then): see `parseApi` **/
	public static function isApiSpec(value:String):Bool
		return try {
			parseApi(value, "account");
			true;
		} catch (_)
			false;

	/**
		Where the socket interface listens, by `spec` (`api = …`, `--api …`), separated by `,`: `socket` (the Unix
		socket, `socketPath`), a path (a Unix socket there: with `/`, or starting with `~`), `tcp` (`127.0.0.1`, a free
		port), a port (`9990`, on `127.0.0.1`), `host:port` (`0.0.0.0:9990`, `[::1]:9990`, port `0`: a free one). At most
		one Unix socket and one TCP address. Throws a message if invalid.
	**/
	public static function parseApi(spec:String, account:String):ApiEndpoints {
		final e:ApiEndpoints = {};
		for (part in spec.split(",")) {
			final w = part.trim();
			if (w.length == 0)
				continue;
			final unix = (w == "socket" || w == "unix") ? socketPath(account) : (w.contains("/") || w.startsWith("~")) ? expandHome(w) : null;
			if (unix != null) {
				if (e.socket != null)
					throw 'invalid api: several Unix sockets: $spec';
				e.socket = unix;
				continue;
			}
			final tcp = if (w == "tcp") {host: "127.0.0.1", port: 0} else if (~/^[0-9]+$/.match(w)) {host: "127.0.0.1", port: parsePort(w)} else {
				final i = w.lastIndexOf(":");
				if (i <= 0)
					throw 'invalid api: $w (socket, tcp, a port, host:port, the path of a Unix socket)';
				var host = w.substr(0, i);
				if (host.startsWith("[") && host.endsWith("]"))
					host = host.substr(1, host.length - 2);
				final port = w.substr(i + 1);
				{host: host, port: (port == "0") ? 0 : parsePort(port)};
			}
			if (e.tcp != null)
				throw 'invalid api: several TCP addresses: $spec';
			e.tcp = tcp;
		}
		if (e.socket == null && e.tcp == null)
			throw 'invalid api: $spec';
		return e;
	}

	/**
		Where the socket interface of `a` listens: by `api = <where>` (`--api <where>`), else (`api = 1`, `--api`) at the
		Unix socket (unless `api_socket = 0`) and over TCP on `api_host:api_port` (unless `api_tcp = 0`).
	**/
	public static function apiEndpoints(a:Account):ApiEndpoints {
		if (a.apiSpec != null)
			return parseApi(a.apiSpec, a.name);
		return {
			socket: (a.apiSocket != false) ? socketPath(a.name) : null,
			tcp: (a.apiTcp != false) ? {host: a.apiHost ?? "127.0.0.1", port: a.apiPort ?? 0} : null
		};
	}

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

	/** A server URI with one of `schemes` (e.g. `stun://host:port`) **/
	/**
		The modules that can be disabled (`disable_modules`), by name; contacts, messages and service discovery are always
		loaded.
	**/
	public static final MODULES = [
		"rooms", "history", "carbons", "receipts", "chat-states", "profile", "moods", "tunes", "corrections", "reactions", "replies",
		"retractions", "avatars", "attention", "time", "ping", "adhoc", "blocking", "file-transfers", "calls", "upload", "images",
		"share"
	];

	static function module(name:String):String {
		if (!MODULES.contains(name))
			throw 'unknown module: $name (${MODULES.join(", ")})';
		return name;
	}

	static function serverUri(value:String, schemes:Array<String>):String {
		final i = value.indexOf("://");
		if (i == -1 || !schemes.contains(value.substr(0, i)) || value.length <= i + 3)
			throw 'invalid server: $value (${[for (s in schemes) '$s://…'].join(", ")})';
		return value;
	}

	static function number(v:Null<Int>):Null<String>
		return (v != null) ? Std.string(v) : null;

	/** A positive integer, the value of `name` **/
	static function positive(name:String, value:String):Int {
		final v = Std.parseInt(value);
		if (v == null || v <= 0 || Std.string(v) != value.trim())
			throw 'invalid $name: $value (a positive number)';
		return v;
	}

	static function parsePriority(value:String):Int {
		final v = Std.parseInt(value);
		if (v == null || v < -128 || v > 127 || Std.string(v) != value.trim())
			throw 'invalid priority: $value (-128 to 127)';
		return v;
	}

	static function parseCount(value:String):Int {
		final v = Std.parseInt(value);
		if (v == null || v < 0 || Std.string(v) != value.trim())
			throw 'invalid chat_history: $value (messages, 0 for none)';
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
	public static function contractHome(path:String):String
		return path.startsWith(home() + "/") ? "~" + path.substr(home().length) : path;

	static function home():String
		return Sys.getEnv(windows() ? "USERPROFILE" : "HOME");

	static inline function windows():Bool
		return Sys.systemName() == "Windows";
}
