package norc;

import norc.Config.Account;
import norc.Event;
import sys.FileSystem;
import sys.thread.Deque;
import xmpp.DataForm;
import xmpp.Jid;
import xmpp.Response;
import xmpp.XML;
import xmpp.client.Account as Registration;
import xmpp.client.Stream;

using StringTools;

typedef AccountOptions = {
	/** Name of the account config **/
	var ?name:String;

	var ?host:String;
	var ?port:Int;
	var ?resource:String;
	var debug:Bool;

	/** register: write the account config **/
	var save:Bool;

	/** unregister: don't ask for confirmation **/
	var yes:Bool;

	/** unregister: also remove the account config and local state **/
	var purge:Bool;
}

/**
	`norc account …`: manage accounts, each with its own short-lived session.

	Registration happens on an unauthenticated stream, so a registered account is used with a new
	session (`norc -a <name>`), not the one it was registered with.
**/
class AccountCommand {
	public static final USAGE = 'Usage: norc account <command>

Commands:
  register <jid>     create the account on the server (in-band registration)
                     --save: write the account config (name: -a, default: the jid)
  unregister [jid]   delete the account on the server
                     --yes: don\'t ask for confirmation
                     --purge: also remove the account config and local state
  passwd [jid]       change the password
  list               configured accounts

Without a jid, unregister and passwd use the account given with -a, the default account (account in conf),
or the only configured one.';

	final options:AccountOptions;
	final events = new Deque<Event>();
	var session:Null<Session>;
	var exitCode:Null<Int>;

	function new(options:AccountOptions) {
		this.options = options;
	}

	/**
		Runs the account command `args[0]`; returns the exit code.
	**/
	public static function run(args:Array<String>, options:AccountOptions):Int {
		final cmd = new AccountCommand(options);
		return try switch args {
			case ["register", jid]: cmd.register(jid);
			case ["unregister"]: cmd.unregister(null);
			case ["unregister", jid]: cmd.unregister(jid);
			case ["passwd"]: cmd.passwd(null);
			case ["passwd", jid]: cmd.passwd(jid);
			case ["list"]: list();
			case [] | ["help"]:
				Sys.println(USAGE);
				0;
			case _:
				Term.error('invalid account command: ${args.join(" ")}\n\n$USAGE');
				1;
		} catch (e) {
			Term.error(Std.string(e));
			1;
		}
	}

	static function list():Int {
		final names = Config.listAccounts();
		if (names.length == 0)
			Term.info('no accounts configured in ${Config.accountsDir()}');
		for (name in names) {
			final account = try Config.loadAccount(name) catch (e) {
				Term.error(Std.string(e));
				continue;
			}
			final jid = Jid.parseBare(account.jid);
			final running = [
				for (i in PidFile.instances(Config.stateDir(name)))
					(i.resource == null ? '' : '${i.resource}, ') + 'pid ${i.pid}'
			];
			Sys.println(name + (jid != name ? '  $jid' : '') + (running.length > 0 ? Term.style('  (running: ${running.join("; ")})', 2) : ''));
		}
		return 0;
	}

	function register(jid:String):Int {
		final account = Config.createAccount(options.name ?? Jid.parseBare(jid), jid);
		applyOptions(account);
		if (options.save && FileSystem.exists(Config.accountPath(account.name)))
			throw 'account config exists: ${Config.accountPath(account.name)}';
		var registered = false;
		final session = connect(account);
		session.onSecured = features -> {
			if (!Registration.isOffered(features))
				Term.info("the server doesn't announce in-band registration, trying anyway");
			Registration.requestRegistrationFields(session.stream, res -> switch res {
				case Result(payload):
					final info = Registration.parseFields(payload);
					if (info.registered) {
						finish(1, 'already registered');
						return;
					}
					if (info.instructions != null)
						Term.info(info.instructions);
					final submitted:Response<XML>->Void = res -> switch res {
						case Result(_):
							registered = true;
							Term.info('registered ${Jid.parseBare(account.jid)}');
							session.close();
						case Error(e):
							finish(1, 'registration failed: ${registrationError(e)}');
					}
					if (info.form != null) {
						final form = info.form;
						// often the same text as the query's instructions
						if (form.instructions != null && info.instructions != null)
							form.instructions = form.instructions.filter(line -> line.trim() != info.instructions);
						final values = fillForm(form, payload, account);
						Registration.submitForm(session.stream, form.createSubmit(values), submitted);
					} else {
						final values = new Map<String, String>();
						for (field in info.fields)
							values.set(field, switch field {
								case "username": account.jid.node;
								case "password": envPassword ?? readNewPassword("Password");
								case _: Term.readLine('$field: ') ?? "";
							});
						Registration.register(session.stream, values, submitted);
					}
				case Error(e):
					finish(1, 'registration failed: ${registrationError(e)}');
			});
		}
		session.onClosed = (?msg) -> {
			if (!registered)
				return closed(false, msg);
			if (options.save) {
				Config.saveAccount(account);
				Term.info('saved account config: ${Config.accountPath(account.name)}');
				if (account.passwordCmd == null)
					Term.info('set password_cmd there, or norc asks for the password');
			}
			Term.info('log in with: norc -a ${account.name}');
			finish(0);
		}
		return loop(session);
	}

	function unregister(jid:Null<String>):Int {
		final account = resolve(jid);
		final code = locked(account, () -> {
			final bare = Jid.parseBare(account.jid);
			if (!options.yes && !Term.confirm('Delete the account $bare on the server? This can not be undone.'))
				return 1;
			return request(account, readPassword(account, "Password"), "unregister failed", (stream, handler) -> Registration.unregister(stream, handler),
				() -> Term.info('deleted $bare'));
		});
		// after the lock is released: purge removes the state directory
		if (code == 0 && options.purge)
			purge(account);
		return code;
	}

	function passwd(jid:Null<String>):Int {
		final account = resolve(jid);
		return locked(account, () -> {
			final password = readPassword(account, "Current password");
			final newPassword = readNewPassword("New password");
			return request(account, password, "password change failed",
				(stream, handler) -> Registration.changePassword(stream, account.jid.node, newPassword, handler), () -> {
					Term.info('changed the password of ${Jid.parseBare(account.jid)}');
					if (account.passwordCmd != null)
						Term.info('update the password returned by password_cmd: ${account.passwordCmd}');
				});
		});
	}

	/**
		Logs in and sends a request with `send`; `done` is called if it succeeds. Returns the exit code.
	**/
	function request(account:Account, password:String, failed:String, send:(Stream, Response<XML>->Void) -> Void, done:() -> Void):Int {
		var succeeded = false;
		final session = connect(account);
		session.onSecured = features -> session.login(password, features);
		session.onOnline = () -> send(session.stream, res -> switch res {
			case Result(_):
				succeeded = true;
				done();
				session.close();
			case Error(e):
				finish(1, '$failed: ${formError(e)}');
		});
		// e.g. the server closes the stream after removing the account
		session.onStreamError = condition -> if (!succeeded) Term.error('stream error: $condition');
		session.onClosed = (?msg) -> closed(succeeded, msg);
		return loop(session);
	}

	/** The session closed: done if `ok` **/
	function closed(ok:Bool, ?msg:String)
		finish(ok ? 0 : 1, ok ? null : 'disconnected' + (msg != null ? ': $msg' : ''));

	/** Runs `f` holding the pid file of `account`: it must not be in use by a running norc **/
	static function locked(account:Account, f:() -> Int):Int {
		// also no norc with another resource
		final others = PidFile.instances(Config.stateDir(account.name)).filter(i -> i.resource != null);
		if (others.length > 0)
			throw '${account.name}: already running with the resource ${others[0].resource} (pid ${others[0].pid}), stop it first';
		final lock = try PidFile.acquire(Config.stateDir(account.name)) catch (e) throw '${account.name}: $e, stop it first';
		return try {
			final code = f();
			lock.release();
			code;
		} catch (e) {
			lock.release();
			throw e;
		}
	}

	/** The account `jid` (config name, local part or jid), else the one given with `-a` or the only configured one **/
	function resolve(jid:Null<String>):Account {
		final account = if (jid != null && !jid.contains("@")) {
			// an account name, or the local part of a configured account
			Config.findAccount(jid);
		} else if (jid != null) {
			// a configured account (by name or jid), or an unconfigured jid
			try
				Config.findAccount(Jid.parseBare(jid))
			catch (_)
				Config.createAccount(options.name ?? Jid.parseBare(jid), jid);
		} else if (options.name != null) {
			Config.findAccount(options.name);
		} else {
			Config.defaultAccount();
		}
		applyOptions(account);
		return account;
	}

	function applyOptions(account:Account) {
		if (options.host != null)
			account.host = options.host;
		if (options.port != null)
			account.port = options.port;
		if (options.resource != null)
			account.resource = options.resource;
	}

	function connect(account:Account):Session {
		final session = new Session(events, account, options.debug);
		session.onError = (msg, _) -> finish(1, msg);
		this.session = session;
		session.open();
		return session;
	}

	function loop(session:Session):Int {
		while (exitCode == null) {
			switch events.pop(true) {
				case Net(c, e):
					if (session.owns(c))
						session.handle(e);
				case _:
			}
		}
		return exitCode;
	}

	function finish(code:Int, ?msg:String) {
		if (exitCode != null)
			return;
		if (msg != null)
			Term.error(msg);
		exitCode = code;
		if (code != 0)
			session?.abort();
	}

	function purge(account:Account) {
		final path = Config.accountPath(account.name);
		if (FileSystem.exists(path)) {
			FileSystem.deleteFile(path);
			Term.info('removed $path');
		}
		// an account directory: removed if it has nothing else (hooks and scripts are kept)
		final accountDir = Config.accountDir(account.name);
		if (accountDir != null) {
			if (FileSystem.readDirectory(accountDir).length == 0) {
				FileSystem.deleteDirectory(accountDir);
				Term.info('removed $accountDir');
			} else
				Term.info('kept $accountDir (hooks, scripts)');
		}
		final dir = Config.stateDir(account.name);
		if (FileSystem.exists(dir)) {
			deleteTree(dir);
			Term.info('removed $dir');
		}
	}

	/** Deletes the directory `dir` with its files and directories (e.g. the state of other resources, OMEMO) **/
	static function deleteTree(dir:String) {
		for (f in FileSystem.readDirectory(dir))
			if (FileSystem.isDirectory('$dir/$f'))
				deleteTree('$dir/$f');
			else
				FileSystem.deleteFile('$dir/$f');
		FileSystem.deleteDirectory(dir);
	}

	/** The password of the environment variable `NORC_PASSWORD` (set by `main`, which removes the variable) **/
	public static var envPassword:Null<String>;

	/**
		The password of `account`: of `NORC_PASSWORD`, else the output of its `password_cmd`, else asked for (with
		`prompt`)
	**/
	public static function readPassword(account:Account, prompt:String):String
		return envPassword ?? (account.passwordCmd != null ? Term.readCommand(account.passwordCmd) : Term.readPassword('$prompt for ${Jid.parseBare(account.jid)}: '));

	static function readNewPassword(prompt:String):String {
		for (_ in 0...3) {
			final password = Term.readPassword('$prompt: ');
			if (password.length == 0) {
				Term.error("the password must not be empty");
				continue;
			}
			if (Term.readPassword('Repeat ${prompt.toLowerCase()}: ') == password)
				return password;
			Term.error("the passwords don't match");
		}
		throw "no password set";
	}

	/**
		Asks for the values of the fields of a registration `form`.
		`payload` is the raw query, for media (e.g. CAPTCHA images) not kept by `DataForm`.
	**/
	function fillForm(form:DataForm, payload:XML, account:Account):Map<String, Array<String>> {
		if (form.title != null)
			Term.info(form.title);
		if (form.instructions != null)
			for (line in form.instructions)
				Term.info(line);
		final values = new Map<String, Array<String>>();
		for (field in form.fields) {
			final type = DataForm.fieldType(field);
			final name = field.variable;
			switch type {
				case fixed:
					if (field.values != null)
						for (v in field.values)
							Term.info(v);
					continue;
				case hidden:
					// returned unchanged (e.g. the challenge id of a CAPTCHA)
					if (name != null)
						values.set(name, field.values ?? []);
					continue;
				case _:
			}
			if (name == null)
				continue;
			for (uri in mediaUris(payload, name))
				Term.info('  $uri');
			if (field.desc != null)
				Term.info(field.desc);
			final label = (field.label ?? name) + (field.required == true ? "*" : "");
			final current = (field.values != null && field.values.length > 0) ? field.values[0] : null;
			var value:Array<String> = null;
			while (value == null) {
				value = switch type {
					case _ if (name == "username"):
						[account.jid.node];
					case _ if (name == "password"):
						[readNewPassword(label)];
					case text_private:
						[Term.readPassword('$label: ')];
					case boolean:
						[Term.confirm(label) ? "1" : "0"];
					case list_single:
						final option = chooseOption(label, field.options ?? []);
						option != null ? [option] : [];
					case list_multi, jid_multi, text_multi:
						Term.info('$label (one per line, empty line to finish)');
						final lines = [];
						var line:Null<String>;
						while ((line = Term.readLine("  ")) != null && line.length > 0)
							lines.push(line);
						lines;
					case _:
						final line = Term.readLine('$label' + (current != null ? ' [$current]' : '') + ': ');
						(line == null || line.length == 0) ? (current != null ? [current] : []) : [line];
				}
				if (field.required == true && value.length == 0) {
					Term.error('$label is required');
					value = null;
				}
			}
			values.set(name, value);
		}
		return values;
	}

	static function chooseOption(label:String, options:Array<FieldOption>):Null<String> {
		Term.info(label);
		for (i in 0...options.length)
			Term.info('  ${i + 1}) ${options[i].label ?? options[i].value}');
		final answer = Term.readLine("> ");
		if (answer == null || answer.length == 0)
			return null;
		final n = Std.parseInt(answer);
		return (n != null && n >= 1 && n <= options.length) ? options[n - 1].value : answer;
	}

	/** URIs of the media element (XEP-0221) of form field `name`, e.g. a CAPTCHA image **/
	static function mediaUris(payload:XML, name:String):Array<String> {
		final uris = [];
		for (x in payload.elements)
			if (x.name == "x")
				for (f in x.elements)
					if (f.name == "field" && f.get("var") == name)
						for (m in f.elements)
							if (m.name == "media")
								for (u in m.elements)
									if (u.name == "uri") {
										final uri:String = u.text;
										if (uri != null)
											uris.push(uri.startsWith("cid:") ? '$uri (embedded data, not supported)' : uri);
									}
		return uris;
	}

	static function registrationError(e:xmpp.Stanza.Error):String {
		final reason = switch (e.condition : String) {
			case "conflict": "the username is taken";
			case "not-acceptable": "missing or invalid data";
			case "not-allowed", "forbidden": "the server doesn't allow registration (from clients)";
			case "service-unavailable", "feature-not-implemented": "the server doesn't support in-band registration";
			case "resource-constraint": "too many registrations, try again later";
			case _: null;
		}
		return (reason != null) ? reason + (e.text != null ? ' (${e.text})' : '') : Term.errorText(e);
	}

	/** Error message, mentioning a data form the server asks to fill in (not supported) **/
	static function formError(e:xmpp.Stanza.Error):String {
		final form = e.payload != null ? Registration.parseFields(e.payload).form : null;
		return Term.errorText(e)
			+ (form != null ? ': the server asks for more information (${form.title ?? form.formType}), which norc does not support yet' : '');
	}
}
