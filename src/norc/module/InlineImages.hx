package norc.module;

import haxe.crypto.Sha1;
import haxe.io.Bytes;
import haxe.io.Path;
import norc.Commands;
import norc.Images;
import norc.Module;
import norc.Output;
import norc.Term;
import sys.FileSystem;
import sys.io.File;
import sys.thread.Thread;
import xmpp.Jid;
import xmpp.Message;
import xmpp.Oob;

/** When images shared in messages are shown (`inline_images`) **/
enum abstract InlinePolicy(String) to String {
	/** Of contacts in the roster and the own (not in rooms) **/
	var contacts;

	/** Of everybody, also in rooms **/
	var all;

	/** Only with `/file show` **/
	var off;
}

/**
	Shows images shared in messages (a message with out of band data whose body is its URL, as `/file share` and other
	clients send them) in terminals showing images (kitty graphics protocol), after the message.

	The image is downloaded into the cache (`$XDG_CACHE_HOME/norc/images/`), at most `MAX_SIZE`: downloading reveals your
	address to the server of the file, so by default only images of contacts are loaded (`inline_images`), others with
	`/file show`. PNG is shown as it is, JPEG, GIF and WebP converted with ImageMagick (`magick`) if it is installed.
**/
class InlineImages extends Module {
	/** The largest image downloaded **/
	static inline var MAX_SIZE = 5 * 1024 * 1024;

	/** The height of an image shown, in lines **/
	static inline var ROWS = 8;

	/** Images are scaled to this size at most (with ImageMagick), in pixels **/
	static inline var MAX_PIXELS = 800;

	final contacts:Contacts;
	final policy:InlinePolicy;

	/** The URL of the last image shared, for `/file show` without URL **/
	var last:Null<String>;

	/** URLs being downloaded **/
	final loading = new Map<String, Bool>();

	public function new(context:Context, messages:Messages, contacts:Contacts, policy:InlinePolicy) {
		super(context);
		this.contacts = contacts;
		this.policy = policy;
		messages.displayed.push(shown);
	}

	override public function commands():Array<Commands.Command>
		return [
			{
				name: "file",
				description: "send and receive files",
				subcommands: [
					{
						name: "show",
						args: "[url]",
						description: "show an image shared in a message (the last one without URL), e.g. one not loaded automatically (inline_images)",
						run: (args, out) -> showCommand(args[0], out)
					}
				]
			}
		];

	/** The URL of an image shared in `m`: out of band data whose URL is the body, with the extension of an image **/
	static function imageUrl(m:Message):Null<String> {
		final oob = Oob.getOob(m);
		if (oob == null || oob.url == null || m.body == null || StringTools.trim(m.body) != oob.url)
			return null;
		final url = oob.url;
		if (!StringTools.startsWith(url, "https://") && !StringTools.startsWith(url, "http://"))
			return null;
		final path = url.split("?")[0].split("#")[0];
		return ["png", "jpg", "jpeg", "gif", "webp"].contains((Path.extension(path) ?? "").toLowerCase()) ? url : null;
	}

	/** A message was shown in `chat` (bare jid): its image is shown after it, if the policy allows it **/
	function shown(chat:String, m:Message, own:Bool, room:Bool) {
		final url = imageUrl(m);
		if (url == null)
			return;
		last = url;
		final allowed = switch policy {
			case InlinePolicy.all: true;
			case InlinePolicy.contacts: own || (!room && contacts.contains(Jid.parseBare(chat)));
			case InlinePolicy.off: false;
		}
		if (allowed && showsImages())
			load(url, null);
	}

	static function showsImages():Bool
		return Term.editor?.images == true;

	function showCommand(url:Null<String>, out:Output) {
		final u = url ?? last;
		if (u == null) {
			out.error("no image shared yet (or give its URL)");
			return;
		}
		if (!showsImages()) {
			out.error("the terminal shows no images (kitty graphics protocol)");
			return;
		}
		load(u, out);
	}

	/** The file of the image of `url` in the cache (by the hash of the URL), `ext` its format **/
	public static function cachePath(url:String, ext:String):String
		return '${Config.cacheDir()}/images/${Sha1.encode(url)}.$ext';

	/** Shows the image of `url`: from the cache, else downloaded; errors to `out` (`null`: quietly) **/
	function load(url:String, out:Null<Output>) {
		final png = cachePath(url, "png");
		if (FileSystem.exists(png)) {
			show(png, out);
			return;
		}
		if (loading.exists(url))
			return;
		loading.set(url, true);
		final done = out?.wait();
		Thread.create(() -> {
			final result:{?path:String, ?error:String} = try prepare(url) catch (e) {error: Std.string(e)};
			context.post(() -> {
				loading.remove(url);
				if (result.error != null)
					out?.error('cannot show $url: ${result.error}');
				else
					show(result.path, out);
				if (done != null)
					done();
			});
		});
	}

	/** Downloads the image of `url` (if not cached) and converts it to PNG; on a thread **/
	static function prepare(url:String):{?path:String, ?error:String} {
		FileSystem.createDirectory('${Config.cacheDir()}/images');
		final png = cachePath(url, "png");
		final original = cachePath(url, "orig");
		final data = FileSystem.exists(original) ? File.getBytes(original) : download(url);
		final info = Images.info(data);
		if (info == null)
			return {error: "no image (PNG, JPEG, GIF, WebP)"};
		if (!FileSystem.exists(original))
			File.saveBytes(original, data);
		// smaller with ImageMagick, the first frame of an animation
		final magick = Files.which("magick");
		if (magick != null) {
			final code = Sys.command(magick, ['$original[0]', "-resize", '${MAX_PIXELS}x${MAX_PIXELS}>', 'png:$png']);
			if (code == 0 && FileSystem.exists(png))
				return {path: png};
		}
		if (info.type != "image/png")
			return {error: '${info.type} needs ImageMagick (magick) to be shown'};
		File.saveBytes(png, data);
		return {path: png};
	}

	/** The data at `url`, at most `MAX_SIZE` **/
	static function download(url:String):Bytes {
		final http = new sys.Http(url);
		final output = new LimitedOutput(MAX_SIZE);
		var status = 0;
		var failure:Null<String> = null;
		http.onStatus = s -> status = s;
		http.onError = e -> failure = e;
		http.customRequest(false, output);
		if (output.exceeded)
			throw 'larger than ${Term.size(MAX_SIZE)}';
		if (failure != null)
			throw failure;
		if (status < 200 || status >= 300)
			throw 'HTTP $status';
		return output.getBytes();
	}

	function show(path:String, out:Null<Output>) {
		final data = try File.getBytes(path) catch (e) {
			out?.error('cannot read $path: $e');
			return;
		}
		if (!Term.image(data, ROWS))
			out?.error("the terminal shows no images (kitty graphics protocol)");
	}
}

/** Bytes written up to a limit: more ends the download (`exceeded`) **/
private class LimitedOutput extends haxe.io.BytesOutput {
	final max:Int;

	public var exceeded(default, null) = false;

	public function new(max:Int) {
		super();
		this.max = max;
	}

	override function writeByte(c:Int) {
		check(1);
		super.writeByte(c);
	}

	override function writeBytes(buf:Bytes, pos:Int, len:Int):Int {
		check(len);
		return super.writeBytes(buf, pos, len);
	}

	function check(n:Int)
		if (length + n > max) {
			exceeded = true;
			throw "too large";
		}
}
