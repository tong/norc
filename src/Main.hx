import norc.AccountCommand;
import norc.Client;
import norc.Config;
import norc.PidFile;
import norc.Term;

using StringTools;

private final USAGE = 'Usage: norc [options]
       norc account <command> [options]   (norc account help)
       norc check <domain...> [--json] [--timeout <s>]   what servers offer, e.g. registration (norc check)
       norc ctl <command> [args...]                      run a command in the running norc (norc ctl --help)
       norc complete [-a <account>] -- <words...>        complete the last word of a norc ctl command (for shells)

Options:
  -a, --account <name>   account to use (config: <config dir>/accounts/<name>)
  -j, --jid <jid>        use this jid instead of a configured account
  -c, --config <dir>     config directory (default: ${Config.configDir()})
      --host <host>      server host (default: the jid\'s domain)
      --port <port>      server port (default: 5222)
      --resource <res>   resource of the jid (default: from the config, or norc)
  -i, --interactive      read commands from stdin, also if it is no terminal (default: on a terminal, in the foreground)
      --no-input         don\'t read commands from the terminal (e.g. for norc running in the background)
      --api [where]      socket interface for other programs, at a Unix socket and over TCP (where, in the state
                         dir: api); or only where: socket, tcp, a port, host:port, a socket path; several with ,
      --stdin            the api over stdin and stdout (JSON lines, no token), other output to stderr
      --xmpp-debug       print the XMPP stream
      --no-color         disable colored output
      --silent           print nothing (only errors that stop norc), e.g. with hooks or --api; needs password_cmd
                         or NORC_PASSWORD
  -v, --version          show the version
  -h, --help             show this help

Environment:
  NORC_PASSWORD          the password (instead of password_cmd or asking), e.g. NORC_PASSWORD=$(pass xmpp/me) norc;
                         also for norc account register, unregister, passwd (the current one); removed at the start';

function main() {
	// the password, removed from the environment: not inherited by hooks, scripts and norc-rtc
	final envPassword = Sys.getEnv("NORC_PASSWORD");
	if (envPassword != null) {
		Sys.putEnv("NORC_PASSWORD", null);
		if (envPassword.length > 0)
			AccountCommand.envPassword = envPassword;
	}
	final args = Sys.args();
	var accountName:Null<String> = null;
	var jid:Null<String> = null;
	var host:Null<String> = null;
	var port:Null<Int> = null;
	var resource:Null<String> = null;
	var debug = false;
	// null: on a terminal (in the foreground)
	var interactive:Null<Bool> = null;
	var api = false;
	var apiSpec:Null<String> = null;
	var stdin = false;
	var silent = false;
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
		// norc ctl: its own options and the words of a command, as given
		if (args[i] == "ctl" && positional.length == 0)
			Sys.exit(norc.Ctl.run(args.slice(i + 1), accountName));
		// norc complete: the candidates of a command line of norc ctl (for the shell's completion)
		if (args[i] == "complete" && positional.length == 0)
			Sys.exit(norc.Ctl.run(args.slice(i + 1), accountName, true));
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
				port = try Config.parsePort(value()) catch (e) exit(Std.string(e));
			case "--resource":
				resource = value();
				if (resource.trim().length == 0)
					exit('invalid resource: "$resource"');
			case "-i", "--interactive":
				interactive = true;
			case "--no-input":
				interactive = false;
			case "--api":
				api = true;
				// where: the next argument if it is an endpoint (socket, tcp, a port, host:port, a path)
				if (i + 1 < args.length && Config.isApiSpec(args[i + 1]))
					apiSpec = args[++i];
			case arg if (arg.startsWith("--api=")):
				api = true;
				apiSpec = arg.substr("--api=".length);
			case "--stdin":
				stdin = true;
			case "--xmpp-debug":
				debug = true;
			case "--no-color":
				Term.colors = false;
			case "--silent":
				silent = true;
				Term.silent = true;
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
			Sys.exit(norc.Check.run(positional.slice(1), {
				json: json,
				timeout: seconds,
				debug: debug,
				port: port
			}));
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
	if (resource != null) {
		// another resource: a norc of its own, besides the one of the configured resource
		if (resource != account.resource)
			account.instance = resource;
		account.resource = resource;
	}
	if (api)
		account.api = true;
	if (apiSpec != null)
		try
			Config.setApi(account, apiSpec)
		catch (e:String)
			exit(e);
	if (port != null)
		account.port = port;
	if (stdin) {
		if (interactive == true)
			exit('--stdin and -i both read stdin, use one');
		// stdin carries the api: the password can't be asked
		if (account.passwordCmd == null && AccountCommand.envPassword == null)
			exit('--stdin needs password_cmd in the account config, or NORC_PASSWORD');
		Term.stderrOnly = true;
	}
	if (silent) {
		if (interactive == true)
			exit('--silent and -i: -i shows the input line, use one');
		// the password can't be asked
		if (account.passwordCmd == null && AccountCommand.envPassword == null)
			exit('--silent needs password_cmd in the account config, or NORC_PASSWORD');
	}
	final pidFile = try PidFile.acquire(Config.instanceDir(account)) catch (e) {
		final running = PidFile.running(Config.instanceDir(account)) != null;
		exit('${account.name}/${account.resource}: $e' + (running && account.instance == null ? ' (another one: --resource)' : ''));
	}
	final password = try AccountCommand.readPassword(account, "Password") catch (e) {
		pidFile.release();
		exit('cannot read password: $e');
	}
	final client = new Client(account, password);
	client.debug = debug;
	final code = client.run(interactive ?? (!stdin && !silent && Term.isForegroundTerminal()), stdin);
	pidFile.release();
	Sys.exit(code);
}

private function exit<T>(msg:String):T {
	// also with --silent: why norc doesn't run
	Term.silent = false;
	Term.error(msg);
	Sys.exit(1);
	return null;
}
