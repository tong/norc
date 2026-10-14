package norc.module;

import haxe.io.Bytes;
import haxe.io.Path;
import norc.Commands;
import norc.Config;
import norc.Module;
import norc.Output;
import norc.Term;
import norc.module.Messages;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Thread;
import xmpp.HttpFileUpload;
import xmpp.Oob;
import xmpp.Response;
import xmpp.ServiceDiscovery;
import xmpp.XML;
import xmpp.client.Stream;

/**
	HTTP File Upload (XEP-0363): uploads a file to the upload service of the server, which serves it at a URL
	(`/file upload`), e.g. to share it with contacts which are offline or can't receive Jingle file transfers
	(`/file share`, sent as message with the URL, shown as attachment by other clients).
**/
class Upload implements Module {
	/** Largest file uploaded (bytes), files are read into memory **/
	static inline var MAX_SIZE = FileTransfers.MAX_SIZE;

	/** Content types by file extension, for clients to show e.g. images inline **/
	static final TYPES = [
		"jpg" => "image/jpeg", "jpeg" => "image/jpeg", "png" => "image/png", "gif" => "image/gif", "webp" => "image/webp",
		"svg" => "image/svg+xml", "mp4" => "video/mp4", "webm" => "video/webm", "mp3" => "audio/mpeg", "ogg" => "audio/ogg",
		"opus" => "audio/ogg", "m4a" => "audio/mp4", "pdf" => "application/pdf", "txt" => "text/plain", "md" => "text/markdown",
		"zip" => "application/zip", "json" => "application/json"
	];

	final messages:Messages;

	/** The jid of a contact given by name or jid, `null` (with an error) if unknown **/
	final resolve:(input:String, out:Output) -> Null<String>;

	/** Runs a callback on the main thread (the end of an upload) **/
	final post:(() -> Void)->Void;

	var stream:Null<Stream>;

	/** The upload service of the server, once found (`null`: not searched yet) **/
	var service:Null<{jid:Null<String>}>;

	public function new(messages:Messages, resolve:(input:String, out:Output) -> Null<String>, post:(() -> Void)->Void) {
		this.messages = messages;
		this.resolve = resolve;
		this.post = post;
	}

	public function commands():Array<Commands.Command>
		return [
			{
				name: "file",
				subcommands: [
					{
						name: "upload",
						args: "<path...>",
						description: "upload a file to the upload service of your server, prints its URL",
						online: true,
						run: (args, out) -> upload(args[0], null, out)
					},
					{
						name: "share",
						args: "<jid> <path...>",
						description: "upload a file and send its URL to a jid or contact (works offline and with any client)",
						online: true,
						run: (args, out) -> {
							final to = resolve(args[0], out);
							if (to != null)
								upload(args[1], to, out);
						}
					}
				],
				description: ""
			}
		];

	public function features():Array<String>
		return [];

	public function attach(stream:Stream)
		this.stream = stream;

	public function online() {}

	public function detach() {
		stream = null;
		service = null;
	}

	/** Uploads the file at `path`, sends its URL to `to` if not `null` **/
	function upload(path:String, to:Null<String>, out:Output) {
		path = Config.expandHome(path);
		if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) {
			out.error('no such file: $path');
			return;
		}
		final size = FileSystem.stat(path).size;
		if (size > MAX_SIZE) {
			out.error('file too large: ${FileTransfers.formatSize(size)} (max ${FileTransfers.formatSize(MAX_SIZE)})');
			return;
		}
		final name = Path.withoutDirectory(path);
		final type = TYPES.get((Path.extension(name) ?? "").toLowerCase()) ?? "application/octet-stream";
		final done = out.wait();
		findService(jid -> {
			if (jid == null) {
				out.error("your server has no upload service");
				return done();
			}
			HttpFileUpload.requestHttpUploadSlot(stream, jid, name, size, type, res -> switch res {
				case Result(payload):
					final slot = (payload == null) ? null : HttpFileUpload.parseSlot(payload);
					if (slot == null) {
						out.error("invalid upload slot");
						return done();
					}
					out.info('uploading $name (${FileTransfers.formatSize(size)})');
					put(path, type, slot, error -> {
						if (error != null) {
							out.error('upload of $name failed: $error');
							return done();
						}
						out.data({url: slot.get, name: name, size: size, type: type, to: to}, () -> out.print(slot.get));
						if (to != null && stream != null)
							// the URL as body and out of band data: other clients show it as attachment
							messages.send(to, slot.get, [XML.create("x").set("xmlns", Oob.XMLNS_X).append(XML.create("url", slot.get))]);
						done();
					});
				case Error(e):
					final max = HttpFileUpload.getMaxFileSize(e);
					out.error('cannot upload $name: ${e.condition}'
						+ (max != null ? ' (max ${FileTransfers.formatSize(max)})' : e.text != null ? ' (${e.text})' : ''));
					done();
			});
		});
	}

	/** Uploads the file with HTTP PUT (in a thread), `callback` gets the error or `null` on the main thread **/
	function put(path:String, type:String, slot:HttpUploadSlot, callback:Null<String>->Void) {
		Thread.create(() -> {
			final error = try {
				final data = File.getBytes(path);
				final http = new sys.Http(slot.put);
				for (h in slot.headers)
					http.setHeader(h.name, h.value);
				http.setHeader("Content-Type", type);
				http.setPostBytes(data);
				var status = 0;
				var failure:Null<String> = null;
				http.onStatus = s -> status = s;
				http.onError = e -> failure = e;
				http.customRequest(true, new haxe.io.BytesOutput(), null, "PUT");
				failure ?? ((status >= 200 && status < 300) ? null : 'HTTP $status');
			} catch (e) Std.string(e);
			post(() -> callback(error));
		});
	}

	/** The upload service: an item of the server supporting HTTP File Upload, `null` if there is none **/
	function findService(callback:Null<String>->Void) {
		if (service != null)
			return callback(service.jid);
		ServiceDiscovery.discoItems(stream, null, null, res -> {
			final items = switch res {
				case Result(payload) if (payload != null): [for (i in ServiceDiscovery.parseItems(payload)) i.jid];
				case _: [];
			}
			// the server itself can be the service
			items.unshift(stream.domain);
			function next(i:Int) {
				if (stream == null)
					return;
				if (i >= items.length) {
					service = {jid: null};
					return callback(null);
				}
				ServiceDiscovery.discoInfo(stream, items[i], null, res -> switch res {
					case Result(payload) if (payload != null && ServiceDiscovery.hasFeature(ServiceDiscovery.parseInfo(payload), HttpFileUpload.XMLNS)):
						service = {jid: items[i]};
						callback(items[i]);
					case _:
						next(i + 1);
				});
			}
			next(0);
		});
	}
}
