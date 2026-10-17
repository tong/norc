package norc.module;

import haxe.io.Path;
import norc.Commands;
import norc.Files;
import norc.Module;
import norc.Output;
import norc.Term;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Thread;
import xmpp.HttpFileUpload;
import xmpp.Oob;
import xmpp.Response;
import xmpp.XML;

using StringTools;

/**
	HTTP File Upload (XEP-0363): uploads a file to the upload service of the server, which serves it at a URL
	(`/file upload`), e.g. to share it with contacts which are offline or can't receive Jingle file transfers
	(`/file share`, sent as message with the URL, shown as attachment by other clients).
**/
class Upload extends Module {
	/** Largest file uploaded (bytes), files are read into memory **/
	static inline var MAX_SIZE = 100 * 1024 * 1024;

	final messages:Messages;
	final contacts:Contacts;

	/** The upload service of the server, once found (`null`: not searched yet) **/
	var service:Null<{jid:Null<String>}>;

	public function new(context:Context, messages:Messages, contacts:Contacts) {
		super(context);
		this.messages = messages;
		this.contacts = contacts;
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "file",
				description: "",
				subcommands: [
					{
						name: "upload",
						requires: "upload",
						args: "<path...>",
						description: "upload a file to the upload service of your server, prints its URL",
						online: true,
						run: (args, out) -> upload(args[0], null, out)
					},
					{
						name: "share",
						requires: "upload",
						args: "<jid> <path...>",
						description: "upload a file and send its URL to a jid or contact (works offline and with any client)",
						online: true,
						run: (args, out) -> {
							final to = contacts.resolve(args[0], out);
							if (to != null)
								upload(args[1], to, out);
						}
					}
				]
			}
		];

	override public function detach() {
		super.detach();
		service = null;
	}

	/** Uploads the file at `path`, sends its URL to `to` if not `null` **/
	function upload(path:String, to:Null<String>, out:Output) {
		final file = Files.find(path, MAX_SIZE, out);
		if (file == null)
			return;
		final name = Path.withoutDirectory(file.path);
		final type = Files.type(name) ?? "application/octet-stream";
		final done = out.wait();
		findService(jid -> {
			if (jid == null) {
				out.error("your server has no upload service");
				return done();
			}
			HttpFileUpload.requestHttpUploadSlot(stream, jid, name, file.size, type, res -> switch res {
				case Result(payload):
					final slot = (payload == null) ? null : HttpFileUpload.parseSlot(payload);
					if (slot == null) {
						out.error("invalid upload slot");
						return done();
					}
					out.info('uploading $name (${Term.size(file.size)})');
					put(file.path, type, slot, error -> {
						if (error != null)
							out.error('upload of $name failed: $error');
						else {
							out.data({
								url: slot.get,
								name: name,
								size: file.size,
								type: type,
								to: to
							}, () -> out.print(slot.get));
							if (to != null && stream != null) {
								// the own image is shown from the file, not downloaded again (see InlineImages)
								if (type.startsWith("image/"))
									try {
										FileSystem.createDirectory(Path.directory(InlineImages.cachePath(slot.get, "orig")));
										File.copy(file.path, InlineImages.cachePath(slot.get, "orig"));
									} catch (_) {}
								// the URL as body and out of band data: other clients show it as attachment
								messages.send(to, slot.get, [XML.create("x").set("xmlns", Oob.XMLNS_X).append(XML.create("url", slot.get))]);
							}
						}
						done();
					});
				case Error(e):
					final max = HttpFileUpload.getMaxFileSize(e);
					out.error('cannot upload $name: ${Term.errorText(e)}' + (max != null ? ' (max ${Term.size(max)})' : ''));
					done();
			});
		});
	}

	/** Uploads the file with HTTP PUT (in a thread), `callback` gets the error or `null` on the main thread **/
	function put(path:String, type:String, slot:HttpUploadSlot, callback:Null<String>->Void) {
		Thread.create(() -> {
			final error = try {
				final http = new sys.Http(slot.put);
				for (h in slot.headers)
					http.setHeader(h.name, h.value);
				http.setHeader("Content-Type", type);
				http.setPostBytes(File.getBytes(path));
				var status = 0;
				var failure:Null<String> = null;
				http.onStatus = s -> status = s;
				http.onError = e -> failure = e;
				http.customRequest(true, new haxe.io.BytesOutput(), null, "PUT");
				failure ?? ((status >= 200 && status < 300) ? null : 'HTTP $status');
			} catch (e)
				Std.string(e);
			context.post(() -> callback(error));
		});
	}

	/** The upload service: the server or one of its items supporting HTTP File Upload, `null` if there is none **/
	function findService(callback:Null<String>->Void) {
		if (service != null)
			return callback(service.jid);
		Discovery.findService(stream, HttpFileUpload.XMLNS, jid -> {
			service = {jid: jid};
			callback(jid);
		});
	}
}
