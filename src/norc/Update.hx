package norc;

import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
	`norc update`: replaces norc (and norc-rtc next to it) with the latest release on GitHub, as `install.sh` does:
	the archive of the platform, verified with the checksums of the release (`SHA256SUMS`), unpacked with `tar` next
	to norc, tried (`--version`), then renamed over the old files. A running norc keeps its file until it restarts.

	Only release builds update themselves: not development builds (no tag, or uncommitted changes), not the bytecode
	(`norc.hl`), nor builds of package managers (`-D norc_no_update`), which update with their package. Not on Windows
	(its zip is a folder of DLLs and plugins).
**/
class Update {
	public static final USAGE = 'Usage: norc update [<version>] [--check]

Replaces norc (and norc-rtc next to it) with the latest release (or <version>, e.g. v0.9.1) from
https://github.com/$REPO/releases, verified with the checksums of the release.
--check: only show whether there is a newer release.';

	static inline var REPO = "tong/norc";

	/** Redirects followed per request **/
	static inline var MAX_REDIRECTS = 5;

	/** The largest archive downloaded **/
	static inline var MAX_SIZE = 128 * 1024 * 1024;

	/** Updates to `version` (a tag, the latest release if `null`), or only reports with `check`; returns the exit code **/
	public static function run(version:Null<String>, check:Bool):Int {
		final current = Version.VERSION;
		#if norc_no_update
		return fail('norc $current was installed by a package manager: update it with that');
		#elseif (hl && !hlc)
		// Sys.programPath() is norc.hl: the binary of the release would be put over it
		return fail('norc $current is HashLink bytecode (norc.hl), not a release: build it again (make), or install a release (install.sh)');
		#else
		if (!check && (Version.TAG == null || Version.DIRTY))
			return fail('norc $current is a development build (no release): build it from the sources, or install a release (install.sh)');
		if (version != null && !version.startsWith("v"))
			version = 'v$version';
		final latest = version == null;
		final tag = try version ?? latestTag() catch (e) return fail('cannot find the latest release: $e');
		final target = tag.substr(1);
		if (latest && compare(target, current) <= 0) {
			// a development build after the tag is not the release itself
			Term.info(current == target ? 'norc $current is the latest release' : 'norc $target is the latest release (this is $current)');
			return 0;
		}
		if (check) {
			final c = compare(target, current);
			Term.info(c > 0 ? 'norc $target is available (installed: $current): norc update${latest ? "" : ' $tag'}' : c < 0 ? 'norc $target is older than the installed $current' : 'norc $current is installed');
			return 0;
		}
		if (version != null && compare(target, current) == 0 && Version.TAG == tag) {
			Term.info('norc $current is installed already');
			return 0;
		}
		final platform = try platforms() catch (e:String) return fail(e);
		final base = 'https://github.com/$REPO/releases/download/$tag';
		final sums = try download('$base/SHA256SUMS').toString() catch (e) return fail('cannot download the checksums of $tag (no such release?): $e');
		// the first platform in the checksums: macOS universal, releases before it only arm64
		var name:Null<String> = null;
		var expected:Null<String> = null;
		for (p in platform) {
			final file = 'norc-$tag-$p.tar.gz';
			for (line in sums.split("\n")) {
				final parts = ~/\s+/g.split(line.trim());
				if (parts.length == 2 && parts[1] == file) {
					name = file;
					expected = parts[0].toLowerCase();
				}
			}
			if (name != null)
				break;
		}
		if (name == null)
			return fail('no release $tag for ${platform[platform.length - 1]}: build it from the sources (https://github.com/$REPO)');

		// norc's own file (not a link to it): replaced by renaming, so the new files are put next to it
		final program = FileSystem.fullPath(Sys.programPath());
		final dir = Path.directory(program);
		final tmp = Path.join([dir, '.norc-update-${Std.random(0x7fffffff)}']);
		try
			FileSystem.createDirectory(tmp)
		catch (e)
			return fail('cannot write to $dir' + (Sys.getEnv("USER") != "root" ? ' (installed as root? sudo norc update)' : ''));
		final code = try install('$base/$name', expected, tmp, dir, program, target) catch (e) fail(e.message);
		remove(tmp);
		return code;
		#end
	}

	/** Downloads, verifies, unpacks and tries the release in `tmp`, then moves its programs into `dir` **/
	static function install(url:String, expected:String, tmp:String, dir:String, program:String, version:String):Int {
		Term.info('downloading $url');
		final data = try download(url) catch (e) throw 'cannot download $url: $e';
		final digest = xmpp.Digest.create("sha-256");
		digest.update(data, 0, data.length);
		if (digest.finish().toHex() != expected)
			throw 'checksum mismatch of ${Path.withoutDirectory(url)}: the download is damaged or was changed';
		final archive = Path.join([tmp, "norc.tar.gz"]);
		File.saveBytes(archive, data);
		final unpacked = Path.join([tmp, "x"]);
		FileSystem.createDirectory(unpacked);
		if (Sys.command("tar", ["-xzf", archive, "-C", unpacked]) != 0)
			throw 'cannot unpack $archive (tar)';
		final norc = Path.join([unpacked, "norc"]);
		if (!FileSystem.exists(norc))
			throw "no norc in the archive";
		// it runs here: not for another platform, not damaged
		final out = try {
			final p = new sys.io.Process(norc, ["--version"]);
			final s = p.stdout.readAll().toString().trim();
			final ok = p.exitCode() == 0;
			p.close();
			ok ? s : "";
		} catch (e) "";
		if (out != 'norc $version')
			throw 'the new norc doesn\'t run here (norc --version: ${out == "" ? "failed" : out})';
		// renamed over the old files: a running norc or norc-rtc keeps its file
		FileSystem.rename(norc, program);
		final rtc = Path.join([unpacked, "norc-rtc"]);
		if (FileSystem.exists(rtc))
			FileSystem.rename(rtc, Path.join([dir, "norc-rtc"]));
		Term.info('updated to norc $version: $program' + (FileSystem.exists(Path.join([dir, "norc-rtc"])) ? ' (and norc-rtc)' : ''));
		Term.info('a running norc keeps the old version until it is restarted');
		return 0;
	}

	/** The tag of the latest release: where github.com/<repo>/releases/latest redirects to (no API, no rate limit) **/
	static function latestTag():String {
		final location = request('https://github.com/$REPO/releases/latest', new haxe.io.BytesOutput()).location;
		final re = ~/\/releases\/tag\/(v[0-9][^\/?#]*)$/;
		if (location == null || !re.match(location))
			throw 'no release found at https://github.com/$REPO/releases';
		return re.matched(1);
	}

	/** The release targets of this system, preferred first (e.g. `["macos-universal", "macos-arm64"]`) **/
	static function platforms():Array<String> {
		final os = switch Sys.systemName() {
			case "Linux": "linux";
			case "Mac": "macos";
			case "Windows": throw 'on Windows, download the zip of the latest release: https://github.com/$REPO/releases/latest';
			case name: throw 'no release for $name: build it from the sources (https://github.com/$REPO)';
		}
		final machine = try {
			final p = new sys.io.Process("uname", ["-m"]);
			final s = p.stdout.readAll().toString().trim();
			p.close();
			s;
		} catch (e) "";
		final arch = switch machine {
			case "x86_64" | "amd64": "x86_64";
			case "aarch64" | "arm64": "arm64";
			case _: throw 'no release for $os on ${machine == "" ? "this machine" : machine}: build it from the sources (https://github.com/$REPO)';
		}
		return (os == "macos" ? ['$os-universal'] : []).concat(['$os-$arch']);
	}

	/** The body at `url`, following redirects (GitHub's downloads redirect to its storage) **/
	static function download(url:String):Bytes {
		for (_ in 0...MAX_REDIRECTS + 1) {
			final output = new haxe.io.BytesOutput();
			final res = request(url, output);
			if (res.location != null) {
				url = res.location;
				continue;
			}
			if (res.status < 200 || res.status >= 300)
				throw 'HTTP ${res.status}';
			if (output.length > MAX_SIZE)
				throw 'larger than ${Term.size(MAX_SIZE)}';
			return output.getBytes();
		}
		throw "too many redirects";
	}

	/** One request: its status, and the target of a redirect (`null` if none) **/
	static function request(url:String, output:haxe.io.BytesOutput):{status:Int, location:Null<String>} {
		final http = new sys.Http(url);
		http.setHeader("User-Agent", 'norc/${Version.VERSION}');
		var status = 0;
		var failure:Null<String> = null;
		http.onStatus = s -> status = s;
		http.onError = e -> failure = e;
		http.customRequest(false, output);
		if (failure != null)
			throw failure;
		var location:Null<String> = null;
		if (status >= 300 && status < 400 && http.responseHeaders != null)
			for (name => value in http.responseHeaders)
				if (name.toLowerCase() == "location")
					location = value.trim();
		// relative to the request
		if (location != null && location.startsWith("/")) {
			final origin = ~/^(https?:\/\/[^\/]+)/;
			if (origin.match(url))
				location = origin.matched(1) + location;
		}
		return {status: status, location: location};
	}

	/**
		Semantic version precedence: `< 0` if `a` is older than `b`, `0` if equal, `> 0` if newer; build metadata
		(`+…`) is ignored, a pre-release (`-rc.1`) is older than its release
	**/
	public static function compare(a:String, b:String):Int {
		function parse(v:String) {
			v = v.split("+")[0];
			final dash = v.indexOf("-");
			final pre = dash < 0 ? null : v.substr(dash + 1);
			final core = (dash < 0 ? v : v.substr(0, dash)).split(".").map(n -> Std.parseInt(n) ?? 0);
			while (core.length < 3)
				core.push(0);
			return {core: core, pre: pre};
		}
		final va = parse(a), vb = parse(b);
		for (i in 0...3)
			if (va.core[i] != vb.core[i])
				return va.core[i] < vb.core[i] ? -1 : 1;
		if (va.pre == vb.pre)
			return 0;
		if (va.pre == null)
			return 1;
		if (vb.pre == null)
			return -1;
		// pre-releases: field by field, numbers below names
		final pa = va.pre.split("."), pb = vb.pre.split(".");
		for (i in 0...Std.int(Math.min(pa.length, pb.length))) {
			final na = Std.parseInt(pa[i]), nb = Std.parseInt(pb[i]);
			final c = (na != null && nb != null) ? na - nb : (na != null) ? -1 : (nb != null) ? 1 : Reflect.compare(pa[i], pb[i]);
			if (c != 0)
				return c < 0 ? -1 : 1;
		}
		return pa.length == pb.length ? 0 : (pa.length < pb.length ? -1 : 1);
	}

	static function remove(path:String) {
		try {
			if (FileSystem.isDirectory(path)) {
				for (name in FileSystem.readDirectory(path))
					remove(Path.join([path, name]));
				FileSystem.deleteDirectory(path);
			} else
				FileSystem.deleteFile(path);
		} catch (e) {}
	}

	static function fail(msg:String):Int {
		Term.error(msg);
		return 1;
	}
}
