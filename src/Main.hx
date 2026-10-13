import norc.Client;
import norc.Config;
import norc.PidFile;
import norc.Term;

private final USAGE = 'Usage: norc [options]

Options:
  -a, --account <name>   account to use (config: ${Config.accountsDir()}/<name>)
  -j, --jid <jid>        use this jid instead of a configured account
      --host <host>      server host (default: the jid\'s domain)
      --port <port>      server port (default: 5222)
  -i, --interactive      read commands from stdin
      --xmpp-debug       print the XMPP stream
      --no-color         disable colored output
  -h, --help             show this help';

function main() {
	final args = Sys.args();
	var accountName:Null<String> = null;
	var jid:Null<String> = null;
	var host:Null<String> = null;
	var port:Null<String> = null;
	var debug = false;
	var interactive = false;
	var i = 0;
	function value():String {
		final opt = args[i];
		if (++i >= args.length)
			exit('missing value for $opt');
		return args[i];
	}
	while (i < args.length) {
		switch args[i] {
			case "-a", "--account":
				accountName = value();
			case "-j", "--jid":
				jid = value();
			case "--host":
				host = value();
			case "--port":
				port = value();
			case "-i", "--interactive":
				interactive = true;
			case "--xmpp-debug":
				debug = true;
			case "--no-color":
				Term.colors = false;
			case "-h", "--help":
				Sys.println(USAGE);
				Sys.exit(0);
			case arg:
				exit('unknown argument: $arg\n\n$USAGE');
		}
		i++;
	}
	final account = try {
		if (jid != null) {
			Config.createAccount(accountName ?? xmpp.Jid.parseBare(jid), jid);
		} else {
			if (accountName == null) {
				final accounts = Config.listAccounts();
				switch accounts.length {
					case 0: exit('no account configured: create ${Config.accountsDir()}/<name> or use --jid');
					case 1: accountName = accounts[0];
					case _: exit('several accounts configured, select one with -a: ${accounts.join(", ")}');
				}
			}
			Config.loadAccount(accountName);
		}
	} catch (e)
		exit(Std.string(e));
	if (host != null)
		account.host = host;
	if (port != null)
		account.port = try Config.parsePort(port) catch (e) exit(Std.string(e));
	final pidFile = try PidFile.acquire(Config.stateDir(account.name)) catch (e) exit('${account.name}: $e');
	final password = try {
		account.passwordCmd != null ? Term.readCommand(account.passwordCmd) : Term.readPassword('Password for ${xmpp.Jid.parseBare(account.jid)}: ');
	} catch (e) {
		pidFile.release();
		exit('cannot read password: $e');
	}
	final client = new Client(account, password);
	client.debug = debug;
	final code = client.run(interactive);
	pidFile.release();
	Sys.exit(code);
}

private function exit<T>(msg:String):T {
	Term.error(msg);
	Sys.exit(1);
	return null;
}
