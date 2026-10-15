package norc.module;

import norc.Commands;
import norc.Module;
import norc.Output;
import xmpp.EntityTime;
import xmpp.client.Stream;

/**
	Entity Time (XEP-0202): the local time and time zone of a client or server (`/time`).
	Requests are answered if enabled (`entity_time = 1`): the answer reveals your time zone.
**/
class Time extends Module {
	final contacts:Contacts;
	final answer:Bool;

	public function new(context:Context, contacts:Contacts, answer:Bool) {
		super(context);
		this.contacts = contacts;
		this.answer = answer;
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "time",
				args: "[jid]",
				description: "local time and time zone of a client or server (of each online client of a contact; default: your server)",
				online: true,
				run: (args, out) -> time(args[0], out)
			}
		];

	override public function attach(stream:Stream) {
		super.attach(stream);
		if (answer)
			EntityTime.handleRequests(stream);
	}

	function time(input:Null<String>, out:Output)
		for (target in contacts.clients((input != null) ? contacts.jid(input) : stream.domain))
			request(out, target, handler -> EntityTime.getEntityTime(stream, target, handler), payload -> {
				final t = (payload == null) ? null : EntityTime.parse(payload);
				if (t == null || t.date == null || t.offset == null) {
					out.error('$target: invalid time');
					return;
				}
				final local = -Date.now().getTimezoneOffset();
				// their wall clock: the time in their time zone, formatted in ours
				final clock = Date.fromTime(t.date.getTime() + (t.offset - local) * 60000);
				final skew = Math.round((t.date.getTime() - Date.now().getTime()) / 1000);
				out.data({
					jid: target,
					utc: t.utc,
					tzo: t.tzo,
					offset: t.offset,
					local: DateTools.format(clock, "%Y-%m-%d %H:%M:%S"),
					skew: skew
				}, () -> {
					final diff = t.offset - local;
					final relative = (diff == 0) ? "your time zone" : '${formatHours(Std.int(Math.abs(diff)))} ${diff > 0 ? "ahead of" : "behind"} you';
					out.print('$target: ${DateTools.format(clock, "%H:%M")} (UTC${t.offset == 0 ? "" : t.tzo}, $relative)'
						+ (Math.abs(skew) >= 60 ? ', clock ${Math.abs(skew)}s ${skew > 0 ? "ahead" : "behind"}' : ''));
				});
			});

	/** e.g. `2h`, `5h 30m` **/
	static function formatHours(minutes:Int):String
		return '${Std.int(minutes / 60)}h' + (minutes % 60 != 0 ? ' ${minutes % 60}m' : '');
}
