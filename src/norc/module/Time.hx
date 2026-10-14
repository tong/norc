package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import xmpp.EntityTime;
import xmpp.Jid;
import xmpp.Response;
import xmpp.client.Stream;

/**
	Entity Time (XEP-0202): the local time and time zone of a client or server (`/time`).
	Requests are answered if enabled (`entity_time = 1`): the answer reveals your time zone.
**/
class Time implements Module {
	/** A contact name to its jid, other input unchanged **/
	final resolve:String->String;

	/** The available full jids of a bare jid **/
	final resources:String->Array<String>;

	final answer:Bool;

	var stream:Null<Stream>;

	public function new(resolve:String->String, resources:String->Array<String>, answer:Bool) {
		this.resolve = resolve;
		this.resources = resources;
		this.answer = answer;
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "time",
				args: "[jid]",
				description: "local time and time zone of a client or server (of each online client of a contact; default: your server)",
				online: true,
				run: (args, out) -> time(args[0], out)
			}
		];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream) {
		this.stream = stream;
		if (answer)
			EntityTime.handleRequests(stream);
	}

	public function online() {}

	public function detach()
		stream = null;

	function time(input:Null<String>, out:Output) {
		final jid = (input != null) ? resolve(input) : stream.domain;
		final online = (Jid.parseNode(jid) != null && Jid.parseResource(jid) == null) ? resources(jid) : [];
		final targets = (online.length > 0) ? online : [jid];
		for (target in targets) {
			final done = out.wait();
			EntityTime.getEntityTime(stream, target, res -> {
				switch res {
					case Result(payload):
						final t = (payload == null) ? null : EntityTime.parse(payload);
						if (t == null || t.date == null || t.offset == null) {
							out.error('$target: invalid time');
						} else {
							final local = -Date.now().getTimezoneOffset();
							// their wall clock: the time in their time zone, formatted in ours
							final clock = Date.fromTime(t.date.getTime() + (t.offset - local) * 60000);
							final skew = Math.round((t.date.getTime() - Date.now().getTime()) / 1000);
							out.data({jid: target, utc: t.utc, tzo: t.tzo, offset: t.offset, local: DateTools.format(clock, "%Y-%m-%d %H:%M:%S"), skew: skew}, () -> {
								final diff = t.offset - local;
								final relative = (diff == 0) ? "your time zone" : '${formatHours(Std.int(Math.abs(diff)))} ${diff > 0 ? "ahead of" : "behind"} you';
								out.print('$target: ${DateTools.format(clock, "%H:%M")} (UTC${t.offset == 0 ? "" : t.tzo}, $relative)'
									+ (Math.abs(skew) >= 60 ? ', clock ${Math.abs(skew)}s ${skew > 0 ? "ahead" : "behind"}' : ''));
							});
						}
					case Error(e):
						out.error('$target: ${e.condition}' + (e.text != null ? ': ${e.text}' : ''));
				}
				done();
			});
		}
	}

	/** e.g. `2h`, `5h 30m` **/
	static function formatHours(minutes:Int):String
		return '${Std.int(minutes / 60)}h' + (minutes % 60 != 0 ? ' ${minutes % 60}m' : '');
}
