package norc;

import norc.Config.Account;
import norc.Event;
import sys.thread.Deque;
import sys.thread.Thread;
import xmpp.Jid;
import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.XML;
import xmpp.client.Account as Registration;
import xmpp.client.Authentication;

using StringTools;

typedef CheckOptions = {
	var json:Bool;

	/** Seconds per server **/
	var timeout:Float;

	var debug:Bool;
	var ?port:Int;
}

/** Result of checking a server **/
typedef CheckResult = {
	var domain:String;
	var host:String;
	var port:Int;

	/** The connection failed, or the server has no TLS **/
	var ?error:String;

	var tls:Bool;

	/** SASL mechanisms offered for the login **/
	var mechanisms:Array<String>;

	/** Stream features (names and namespaces) after TLS, before the login **/
	var features:Array<String>;

	/** `open`, `captcha` (a form with a challenge), `web` (on a website, see `url`), `closed`, `unsupported`, `unknown` **/
	var ?registration:String;

	/** Fields asked for an open registration, or the error of the request **/
	var ?registrationFields:Array<String>;

	var ?registrationError:String;
	var ?instructions:String;
	var ?url:String;

	/** Service discovery of the server before the login, `null` if not answered (see `discoError`) **/
	var ?disco:{identities:Array<String>, features:Array<String>};

	var ?discoError:String;
}

/**
	`norc check <domain...>`: connects to servers directly (without an account) and reports what they offer before
	the login: TLS, login mechanisms, stream features, and whether they allow in-band registration (the registration
	form is requested, nothing is registered). Service discovery is tried too, though most servers only answer it
	after the login.
**/
class Check {
	public static final USAGE = 'Usage: norc check <domain...> [--json] [--timeout <seconds>]

Connects to each server (without account) and reports TLS, login mechanisms, stream features and
whether in-band registration is open (the registration form is requested, nothing is registered).
--json: one JSON object per server and line.';

	final options:CheckOptions;
	final events = new Deque<Event>();

	function new(options:CheckOptions)
		this.options = options;

	/** Checks the servers one after another; returns `0` if all were reachable **/
	public static function run(domains:Array<String>, options:CheckOptions):Int {
		if (domains.length == 0) {
			Sys.println(USAGE);
			return 1;
		}
		final check = new Check(options);
		var failed = 0;
		for (domain in domains) {
			final r = check.check(domain.trim().toLowerCase());
			if (r.error != null)
				failed++;
			if (options.json)
				Sys.println(haxe.Json.stringify(r));
			else
				print(r);
		}
		return (failed == 0) ? 0 : 1;
	}

	function check(domain:String):CheckResult {
		final port = options.port ?? xmpp.client.Stream.PORT;
		final r:CheckResult = {domain: domain, host: domain, port: port, tls: false, mechanisms: [], features: []};
		if (!Jid.isValid(domain) || domain.contains("@") || domain.contains("/")) {
			r.error = 'invalid domain';
			return r;
		}
		// an account only to connect: the stream is not authenticated
		final account:Account = {name: domain, jid: 'check@$domain', port: port, resource: Config.DEFAULT_RESOURCE};
		final session = new Session(events, account, options.debug);
		session.verbose = false;
		var done = false;
		// asking for the registration form or service discovery: servers may close the stream (not-authorized)
		var registering = false;
		var discovering = false;
		function finish(?error:String) {
			if (done)
				return;
			done = true;
			if (error != null && r.error == null)
				r.error = error;
			session.abort();
		}
		session.onError = (msg, _) -> finish(msg);
		session.onStreamError = condition -> {
			if (registering) {
				r.registrationError = condition;
				r.registration = (r.registration == "unsupported") ? "unsupported" : "closed";
			} else if (discovering)
				r.discoError = condition;
			else
				r.error = 'stream error: $condition';
		}
		session.onClosed = (?msg) -> {
			if (registering || discovering) {
				if (discovering)
					r.discoError ??= msg ?? "connection closed";
				else
					r.registrationError ??= msg ?? "connection closed";
				finish();
			} else
				finish(msg ?? "connection closed");
		}
		session.onSecured = features -> {
			r.tls = true;
			if (session.address != null) {
				r.host = session.address.host;
				r.port = session.address.port;
			}
			r.mechanisms = Authentication.getMechanisms(features);
			r.features = [for (e in features.elements) e.name + (e.get("xmlns") != null ? ' ${e.get("xmlns")}' : '')];
			if (!Registration.isOffered(features))
				r.registration = "unsupported";
			registering = true;
			Registration.requestRegistrationFields(session.stream, null, res -> {
				registering = false;
				readRegistration(r, res);
				discovering = true;
				ServiceDiscovery.discoInfo(session.stream, null, null, res -> {
					switch res {
						case Result(payload) if (payload != null):
							final info = ServiceDiscovery.parseInfo(payload);
							r.disco = {
								identities: [for (i in info.identities) '${i.category}/${i.type}' + (i.name != null ? ' (${i.name})' : '')],
								features: info.features
							};
						case Result(_):
							r.discoError = "empty";
						case Error(e):
							r.discoError = e.condition;
					}
					finish();
				});
			});
		}
		// the whole check takes at most `timeout` seconds
		final timeout = options.timeout;
		Thread.create(() -> {
			Sys.sleep(timeout);
			events.add(Call(() -> finish('timeout (${timeout}s)')));
		});
		session.open();
		while (!done) {
			switch events.pop(true) {
				case Net(c, e) if (session.owns(c)):
					session.handle(e);
				case Call(f):
					f();
				case _:
			}
		}
		return r;
	}

	static function readRegistration(r:CheckResult, res:Response<XML>) {
		switch res {
			case Result(payload):
				final info = (payload == null) ? null : Registration.parseFields(payload);
				if (info == null) {
					r.registration = "unknown";
					return;
				}
				r.instructions = info.instructions;
				// registration on a website (XEP-0077: out of band data instead of fields)
				final x = payload.elements.first(e -> e.name == "x" && e.is(xmpp.Oob.XMLNS_X));
				final oob = (x == null) ? null : xmpp.Oob.parse(x);
				final url = oob?.url ?? findUrl(info.instructions);
				if (info.form != null) {
					final fields = [
						for (f in info.form.fields)
							if (f.variable != null && xmpp.DataForm.fieldType(f) != hidden && xmpp.DataForm.fieldType(f) != fixed) f.variable
					];
					r.registrationFields = fields;
					// a CAPTCHA (XEP-0158): an `ocr`, `qa`, … field or the captcha form type
					final captcha = info.form.formType == "urn:xmpp:captcha"
						|| Lambda.exists(fields, f -> ["ocr", "qa", "audio_recog", "picture_recog", "picture_q", "speech_q", "speech_recog", "video_q", "video_recog"].contains(f));
					r.registration = captcha ? "captcha" : "open";
				} else if (info.fields.length > 0) {
					r.registrationFields = info.fields;
					r.registration = "open";
				} else
					r.registration = (url != null) ? "web" : "unknown";
				if (url != null) {
					r.url = url;
					if (r.registrationFields == null || r.registrationFields.length == 0)
						r.registration = "web";
				}
			case Error(e):
				r.registrationError = e.condition + (e.text != null ? ': ${e.text}' : '');
				r.url = findUrl(e.text);
				r.registration = switch (e.condition : String) {
					case "not-allowed", "forbidden", "not-authorized", "registration-required": (r.url != null) ? "web" : "closed";
					case "service-unavailable", "feature-not-implemented": "unsupported";
					case _: "unknown";
				}
		}
	}

	/** A URL in a text, e.g. the instructions pointing to a website for the registration **/
	static function findUrl(text:Null<String>):Null<String> {
		final re = ~/https?:\/\/[^\s<>"']+/;
		return (text != null && re.match(text)) ? re.matched(0) : null;
	}

	static function print(r:CheckResult) {
		final status = (r.error != null) ? Term.style('error: ${r.error}', 31) : switch r.registration {
			case "open": Term.style("registration open", 32);
			case "captcha": Term.style("registration open (CAPTCHA)", 32);
			case "web": Term.style("registration on a website", 33);
			case "closed": "registration closed";
			case "unsupported": "no in-band registration";
			case _: "registration unknown";
		}
		Sys.println(Term.style(r.domain, 1) + '  $status');
		if (!r.tls && r.error != null)
			return;
		function line(label:String, value:Null<String>)
			if (value != null && value.length > 0)
				Sys.println('  ${label.rpad(" ", 13)}$value');
		line("fields", r.registrationFields?.join(", "));
		line("url", r.url);
		line("instructions", r.instructions?.replace("\n", " "));
		line("reason", r.registrationError);
		line("login", r.mechanisms.join(", "));
		line("features", [for (f in r.features) f.split(" ")[0]].join(", "));
		if (r.disco != null) {
			line("identities", r.disco.identities.join(", "));
			line("disco", '${r.disco.features.length} features');
		} else
			line("disco", Term.style('not answered before login (${r.discoError})', 2));
	}
}
