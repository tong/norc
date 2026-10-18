package norc;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import xmpp.FileSharing;
import xmpp.JingleFileTransfer;

using StringTools;

/** The hash of a file, valid while its size and modification time (of stat) are the same **/
private typedef Hashed = {
	var stat:Float;
	var mtime:Float;

	/** The size read (stat's is 32-bit on HashLink) **/
	var size:Float;

	var hash:String;
}

/**
	Shared directories (XEP-0329, `share.<name> = <directory>` in the config): who may see them, their listing, the
	files contacts may request (only inside them: no `..`, hidden files or links pointing outside), and the sha-256 of
	the files, computed in a thread (`index`) and kept in `<state dir>/shares.json`.
	Paths contacts see start with the name of the share: `music/album/song.ogg`.
**/
class Shares {
	/** Files listed of a directory at most: a listing must fit in a stanza (servers limit them, e.g. 256 KiB) **/
	public static inline var MAX_LISTED = 500;

	/** Files hashed by `index` at most (all shares) **/
	static inline var MAX_INDEXED = 100000;

	/** `index` saves the cache after this many files hashed **/
	static inline var SAVE_EVERY = 100;

	final dirs:Map<String, String>;
	final access:Array<String>;
	final cachePath:String;
	final cache = new Map<String, Hashed>();

	/** `index` runs **/
	var indexing = false;

	public function new(dirs:Map<String, String>, access:Null<String>, stateDir:String) {
		this.dirs = dirs;
		this.access = [for (a in (access ?? "roster").split(",")) if (a.trim().length > 0) a.trim()];
		cachePath = '$stateDir/shares.json';
		try {
			final data:haxe.DynamicAccess<Hashed> = haxe.Json.parse(File.getContent(cachePath));
			for (k => v in data)
				cache.set(k, v);
		} catch (_) {}
	}

	/** Directories are shared **/
	public function enabled():Bool
		return dirs.keys().hasNext() && !access.contains("none");

	/** The shares by name, with their directory **/
	public function list():Array<{name:String, dir:String}> {
		final list = [for (name => dir in dirs) {name: name, dir: dir}];
		list.sort((a, b) -> Reflect.compare(a.name, b.name));
		return list;
	}

	/** Who may list and download, as configured (`share_access`) **/
	public function describeAccess():String
		return access.join(", ");

	/**
		`bare` may list and download: by `share_access`: `roster` (contacts seeing the own presence), `group:<name>`
		(a roster group), a jid; `none`: nobody.
	**/
	public function allowed(bare:String, seesPresence:String->Bool, groups:String->Array<String>):Bool {
		final jid = bare.toLowerCase();
		for (a in access)
			if (a == "roster" && seesPresence(bare) || a.startsWith("group:") && groups(bare).contains(a.substr(6)) || a.toLowerCase() == jid)
				return true;
		return false;
	}

	/**
		The local path of the shared `path` (`<share>/<path in it>`), `null` if it is not shared: an unknown share,
		`.` and `..`, hidden names, links pointing outside the share, or missing.
	**/
	public function resolve(path:String):Null<String> {
		final parts = path.split("/");
		final dir = dirs.get(parts[0]);
		if (dir == null || !FileSystem.exists(dir))
			return null;
		for (p in parts.slice(1))
			if (p.length == 0 || p.startsWith(".") || p.contains("\\") || p.contains("\x00"))
				return null;
		final local = Path.join([dir].concat(parts.slice(1)));
		if (!FileSystem.exists(local))
			return null;
		final root = Path.removeTrailingSlashes(FileSystem.fullPath(dir));
		final real = FileSystem.fullPath(local);
		return (real == root || real.startsWith('$root/')) ? local : null;
	}

	/**
		The listing of `node`: the shares at the root (`null`), else the directories and files of the directory
		(at most `MAX_LISTED` files, hidden ones not), with size, date and hash where known; of a file its details.
		`null` if it is not shared.
	**/
	public function listing(node:Null<String>):Null<FileListing> {
		if (node == null)
			return {directories: [for (s in list()) if (FileSystem.exists(s.dir) && FileSystem.isDirectory(s.dir)) s.name], files: []};
		final local = resolve(node);
		if (local == null)
			return null;
		// a file: its details (requested before downloading it)
		if (!FileSystem.isDirectory(local))
			return {directories: [], files: [describe(local, Path.withoutDirectory(local))]};
		final names = try FileSystem.readDirectory(local) catch (_) [];
		names.sort(Reflect.compare);
		final listing:FileListing = {directories: [], files: []};
		for (name in names) {
			if (name.startsWith("."))
				continue;
			final path = '$local/$name';
			// links pointing outside are not listed
			if (resolve('$node/$name') == null)
				continue;
			if (FileSystem.isDirectory(path))
				listing.directories.push(name);
			else if (listing.files.length < MAX_LISTED)
				listing.files.push(describe(path, name));
		}
		return listing;
	}

	/** A file of a listing or the answer to a request: its name, size, date and hash (if known) **/
	public function describe(path:String, name:String):JingleFile {
		final stat = try FileSystem.stat(path) catch (_) null;
		final file:JingleFile = {name: name};
		if (stat == null)
			return file;
		file.date = xmpp.DelayedDelivery.formatStamp(stat.mtime);
		final h = hashed(path);
		if (h != null) {
			file.size = h.size;
			file.hashes = [{algo: "sha-256", value: h.hash}];
		} else if (stat.size >= 0)
			file.size = stat.size;
		return file;
	}

	/** The cached hash of the file at `path`, `null` if it changed or was not hashed **/
	public function hashed(path:String):Null<Hashed> {
		final h = cache.get(try FileSystem.fullPath(path) catch (_) path);
		return isFresh(h, path) ? h : null;
	}

	/** `h` is the hash of the file at `path` as it is (same size and modification time) **/
	static function isFresh(h:Null<Hashed>, path:String):Bool {
		final stat = (h != null) ? try FileSystem.stat(path) catch (_) null : null;
		return stat != null && h.stat == stat.size && h.mtime == stat.mtime.getTime();
	}

	/** Keeps the hash of the file at `path` (read with `size`), saves the cache (`save`, else later) **/
	public function remember(path:String, size:Float, hash:String, save = true) {
		final stat = try FileSystem.stat(path) catch (_) return;
		cache.set(try FileSystem.fullPath(path) catch (_) path, {stat: stat.size, mtime: stat.mtime.getTime(), size: size, hash: hash});
		if (save)
			this.save();
	}

	function save()
		try {
			final data:haxe.DynamicAccess<Hashed> = {};
			for (k => v in cache)
				data.set(k, v);
			File.saveContent(cachePath, haxe.Json.stringify(data));
		} catch (_) {}

	/**
		Hashes the files of the shares not hashed yet, in a thread (also walking the shares, one file at a time);
		`post` runs callbacks on the main thread, `done` with the number hashed. The cache is saved now and then.
	**/
	public function index(post:(() -> Void)->Void, ?done:Int->Void) {
		if (indexing)
			return;
		indexing = true;
		// the thread reads a copy: the cache is changed on the main thread
		final known = cache.copy();
		sys.thread.Thread.create(() -> {
			final all = files();
			final current = [for (f in all) (try FileSystem.fullPath(f) catch (_) f) => true];
			var n = 0;
			for (f in all) {
				if (isFresh(known.get(try FileSystem.fullPath(f) catch (_) f), f))
					continue;
				final r = try Files.hashFile(f) catch (_) null;
				if (r != null) {
					n++;
					final save = n % SAVE_EVERY == 0;
					post(() -> remember(f, r.size, r.hash, save));
				}
			}
			final count = n;
			post(() -> {
				indexing = false;
				// drop files no longer shared
				for (k in [for (k in cache.keys()) k])
					if (!current.exists(k))
						cache.remove(k);
				save();
				if (done != null)
					done(count);
			});
		});
	}

	/** The files of all shares (not hidden, not through links pointing outside), at most `MAX_INDEXED` **/
	public function files():Array<String> {
		final found = [];
		final visited = new Map<String, Bool>();
		function walk(dir:String, path:String) {
			final real = try FileSystem.fullPath(dir) catch (_) return;
			if (visited.exists(real) || found.length >= MAX_INDEXED)
				return;
			visited.set(real, true);
			for (name in (try FileSystem.readDirectory(dir) catch (_) [])) {
				if (name.startsWith(".") || found.length >= MAX_INDEXED)
					continue;
				final local = '$dir/$name';
				if (resolve('$path/$name') == null)
					continue;
				if (FileSystem.isDirectory(local))
					walk(local, '$path/$name');
				else
					found.push(local);
			}
		}
		for (s in list())
			walk(s.dir, s.name);
		return found;
	}

	/** Counts of the shares by name: their files, and of them hashed **/
	public function counts():Map<String, {files:Int, hashed:Int}> {
		final counts = [for (name in dirs.keys()) name => {files: 0, hashed: 0}];
		for (f in files()) {
			final name = owner(f);
			final c = (name != null) ? counts.get(name) : null;
			if (c == null)
				continue;
			c.files++;
			if (hashed(f) != null)
				c.hashed++;
		}
		return counts;
	}

	/** The share of a file of `files` **/
	function owner(local:String):Null<String> {
		for (name => dir in dirs)
			if (local.startsWith(Path.addTrailingSlash(dir)))
				return name;
		return null;
	}
}
