package norc.module;

import norc.Commands;
import norc.Forms;
import norc.Module;
import norc.Output;
import norc.Term;
import xmpp.AdHocCommand;
import xmpp.DataForm;
import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.XML;
import xmpp.client.Stream;

using StringTools;

/**
	Ad-Hoc Commands (XEP-0050): run the commands of servers, services and clients, e.g. the administration
	of your server. `/adhoc` lists the commands, `/adhoc run` starts one; a command asking for input shows a form,
	answered with `/adhoc submit field=value…` (or `/adhoc prev`, `/adhoc cancel`).
**/
class AdHoc implements Module {
	/** A contact name to its jid, other input unchanged **/
	final resolve:String->String;

	var stream:Null<Stream>;

	/** The commands of the last listing, by number **/
	var listed:Array<{jid:String, node:String, name:Null<String>}> = [];

	/** The command being executed, waiting for input **/
	var current:Null<{jid:String, command:Command}>;

	public function new(resolve:String->String)
		this.resolve = resolve;

	public function commands():Array<Commands.Command>
		return [
			{
				name: "adhoc",
				args: "[jid]",
				description: "list the commands of a server, service or client (default: your server)",
				online: true,
				run: (args, out) -> list(args[0] != null ? resolve(args[0]) : stream.domain, out),
				subcommands: [
					{
						name: "run",
						args: "<jid> <node>",
						description: "run a command (node, or its number in the last list)",
						online: true,
						run: (args, out) -> execute(resolve(args[0]), args[1], out),
						complete: ["node" => _ -> [for (c in listed) c.node]]
					},
					{
						name: "submit",
						args: "[values...]",
						description: "answer the form of the running command: field=value (\"…\" for spaces, repeated for several values)",
						online: true,
						run: (args, out) -> proceed(null, args[0], out)
					},
					{
						name: "prev",
						description: "go back to the previous stage of the running command",
						online: true,
						run: (args, out) -> proceed(prev, null, out)
					},
					{
						name: "cancel",
						description: "cancel the running command",
						online: true,
						run: (args, out) -> proceed(cancel, null, out)
					}
				]
			}
		];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach() {
		stream = null;
		current = null;
	}

	function list(jid:String, out:Output) {
		final done = out.wait();
		AdHocCommand.requestCommandList(stream, jid, res -> {
			switch res {
				case Result(payload):
					final items = (payload == null) ? [] : ServiceDiscovery.parseItems(payload);
					listed = [for (i in items) if (i.node != null) {jid: i.jid ?? jid, node: i.node, name: i.name}];
					out.data({jid: jid, commands: listed}, () -> {
						if (listed.length == 0)
							out.info('$jid has no commands (for you)');
						for (n in 0...listed.length)
							out.print('  ${Std.string(n + 1).lpad(" ", 2)}  ${listed[n].name ?? listed[n].node}' + Term.style('  ${listed[n].node}', 2));
						if (listed.length > 0)
							out.info('/adhoc run $jid <number or node>');
					});
				case Error(e):
					out.error('$jid: ${e.condition}' + (e.text != null ? ': ${e.text}' : ''));
			}
			done();
		});
	}

	function execute(jid:String, node:String, out:Output) {
		// a number of the last list
		final n = Std.parseInt(node);
		if (n != null && n >= 1 && n <= listed.length)
			node = listed[n - 1].node;
		if (current != null)
			// only one command at a time: end the previous one
			AdHocCommand.cancelCommand(stream, current.jid, current.command, _ -> {});
		current = null;
		final done = out.wait();
		AdHocCommand.execute(stream, jid, node, res -> {
			respond(jid, res, out);
			done();
		});
	}

	/** Continues the running command with `action` (default: the default action of the stage) and the values of its form **/
	function proceed(action:Null<Action>, input:Null<String>, out:Output) {
		final c = current;
		if (c == null) {
			out.error("no command is running (/adhoc run)");
			return;
		}
		var form:Null<DataForm> = null;
		if (action != cancel && action != prev && c.command.form != null && c.command.form.type == FormType.form) {
			final values = try Forms.parseValues(c.command.form, input) catch (e:String) {
				out.error(e);
				return;
			}
			final missing = Forms.missing(c.command.form, values);
			if (missing.length > 0) {
				out.error('missing: ${missing.join(", ")}');
				return;
			}
			form = c.command.form.createSubmit(values);
		}
		final done = out.wait();
		AdHocCommand.continueCommand(stream, c.jid, c.command, action, form, res -> {
			respond(c.jid, res, out);
			done();
		});
	}

	/** Shows a response: notes, the form or result; keeps the command if it waits for input **/
	function respond(jid:String, res:Response<XML>, out:Output) {
		switch res {
			case Result(payload):
				if (payload == null) {
					out.error('$jid: empty response');
					current = null;
					return;
				}
				final command = AdHocCommand.parseCommand(payload);
				final executing = command.status == executing;
				current = executing ? {jid: jid, command: command} : null;
				out.data({
					jid: jid,
					node: command.node,
					sessionid: command.sessionid,
					status: (command.status : Null<String>),
					actions: [for (a in command.actions ?? []) (a : String)],
					notes: [for (n in command.notes) {type: (n.type : String), text: n.text}],
					form: (command.form != null) ? Forms.data(command.form) : null
				}, () -> {
					for (n in command.notes)
						switch n.type {
							case error: out.error(n.text);
							case warn: out.print(Term.style(n.text, 33));
							case _: out.info(n.text);
						}
					if (command.form != null)
						Forms.print(command.form, out);
					if (executing) {
						final actions = [for (a in command.actions ?? []) if (a == prev) "/adhoc prev"];
						out.info('/adhoc submit field=value…' + (actions.length > 0 ? ', ${actions.join(", ")}' : '') + ', /adhoc cancel');
					} else if (command.status == canceled)
						out.info("canceled");
					else if (command.notes.length == 0 && command.form == null)
						out.info("done");
				});
			case Error(e):
				current = null;
				out.error('$jid: ${e.condition}' + (e.text != null ? ': ${e.text}' : ''));
		}
	}
}
