import norc.AccountCommand;
import norc.Client;
import norc.Config;
import norc.PidFile;
import norc.Term;

using StringTools;

private final USAGE = 'Usage: norc [options]
       norc account <command> [options]   (norc account help)
       norc check <domain...> [--json] [--timeout <s>]   what servers offer, e.g. registration (norc check)

Options:
  -a, --account <name>   account to use (config: <config dir>/accounts/<name>)
  -j, --jid <jid>        use this jid instead of a configured account
  -c, --config <dir>     config directory (default: ${Config.configDir()})
      --host <host>      server host (default: the jid\'s domain)
      --port <port>      server port (default: 5222)
      --resource <res>   resource of the jid (default: from the config, or norc)
  -i, --interactive      read commands from stdin
      --api              socket interface for other programs (port and token in the state dir: api)
      --stdin            the api over stdin and stdout (JSON lines, no token), other output to stderr
      --xmpp-debug       print the XMPP stream
      --no-color         disable colored output
  -v, --version          show the version
  -h, --help             show this help';

function main() {
	final args = Sys.args();
	var accountName:Null<String> = null;
	var jid:Null<String> = null;
	var host:Null<String> = null;
	var port:Null<String> = null;
	var resource:Null<String> = null;
	var debug = false;
	var interactive = false;
	var api = false;
	var stdin = false;
	var save = false;
	var yes = false;
	var purge = false;
	var json = false;
	var timeout:Null<String> = null;
	final positional = new Array<String>();
	var i = 0;
	function value():String {
		final opt = args[i];
		if (++i >= args.length)
			exit('missing value for $opt');
		return args[i];
	}
	while (i < args.length) {
		switch args[i] {
			case "-c", "--config":
				Config.dir = haxe.io.Path.removeTrailingSlashes(value());
			case "-a", "--account":
				accountName = value();
			case "-j", "--jid":
				jid = value();
			case "--host":
				host = value();
			case "--port":
				port = value();
			case "--resource":
				resource = value();
				if (resource.trim().length == 0)
					exit('invalid resource: "$resource"');
			case "-i", "--interactive":
				interactive = true;
			case "--api":
				api = true;
			case "--stdin":
				stdin = true;
			case "--xmpp-debug":
				debug = true;
			case "--no-color":
				Term.colors = false;
			case "--save":
				save = true;
			case "--yes":
				yes = true;
			case "--json":
				json = true;
			case "--timeout":
				timeout = value();
			case "--purge":
				purge = true;
			case "-v", "--version":
				Sys.println('norc ${norc.Version.VERSION}');
				Sys.exit(0);
			case "-h", "--help":
				Sys.println(USAGE);
				Sys.exit(0);
			case arg if (arg.startsWith("-")):
				exit('unknown option: $arg\n\n$USAGE');
			case arg:
				positional.push(arg);
		}
		i++;
	}
	// the first start: write the default config (conf, example hooks)
	if (positional[0] != "check") {
		final dir = Config.configDir();
		final installed = try norc.Defaults.install(dir) catch (e) {
			Term.error('cannot create $dir: $e');
			[];
		}
		if (installed.length > 0)
			Term.info('created $dir with the default config: conf, example hooks and scripts in hooks/ and scripts/ (disabled, enable them with chmod +x)');
	}
	switch positional {
		case []:
		case ["account", _] | ["account", _, _] | ["account"]:
			final port = port != null ? (try Config.parsePort(port) catch (e) exit(Std.string(e))) : null;
			Sys.exit(AccountCommand.run(positional.slice(1), {
				name: accountName,
				host: host,
				port: port,
				resource: resource,
				debug: debug,
				save: save,
				yes: yes,
				purge: purge
			}));
		case ["check"]:
			Sys.println(norc.Check.USAGE);
			Sys.exit(0);
		case _ if (positional[0] == "check"):
			final seconds = (timeout != null) ? Std.parseFloat(timeout) : 20.0;
			if (Math.isNaN(seconds) || seconds <= 0)
				exit('invalid timeout: $timeout');
			final port = port != null ? (try Config.parsePort(port) catch (e) exit(Std.string(e))) : null;
			Sys.exit(norc.Check.run(positional.slice(1), {json: json, timeout: seconds, debug: debug, port: port}));
		case _:
			exit('unknown command: ${positional.join(" ")}\n\n$USAGE');
	}
	if (save || yes || purge)
		exit('--save, --yes and --purge are options of: norc account (norc account help)');
	final account = try {
		if (jid != null) {
			Config.createAccount(accountName ?? xmpp.Jid.parseBare(jid), jid);
		} else {
			accountName != null ? Config.findAccount(accountName) : Config.defaultAccount();
		}
	} catch (e)
		exit(Std.string(e));
	if (host != null)
		account.host = host;
	if (resource != null)
		account.resource = resource;
	if (api)
		account.api = true;
	if (port != null)
		account.port = try Config.parsePort(port) catch (e) exit(Std.string(e));
	if (stdin) {
		if (interactive)
			exit('--stdin and -i both read stdin, use one');
		// stdin carries the api: the password can't be asked
		if (account.passwordCmd == null)
			exit('--stdin needs password_cmd in the account config');
		Term.stderrOnly = true;
	}
	final pidFile = try PidFile.acquire(Config.stateDir(account.name)) catch (e) exit('${account.name}: $e');
	final password = try {
		account.passwordCmd != null ? Term.readCommand(account.passwordCmd) : Term.readPassword('Password for ${xmpp.Jid.parseBare(account.jid)}: ');
	} catch (e) {
		pidFile.release();
		exit('cannot read password: $e');
	}
	final client = new Client(account, password);
	client.debug = debug;
	final code = client.run(interactive, stdin);
	pidFile.release();
	Sys.exit(code);
}

private function exit<T>(msg:String):T {
	Term.error(msg);
	Sys.exit(1);
	return null;
}
