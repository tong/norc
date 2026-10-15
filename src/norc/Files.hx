package norc;

import haxe.io.Path;
import sys.FileSystem;

using StringTools;

/** Local files: to send, upload or publish, and programs **/
class Files {
	/** Content types by file extension, e.g. for clients to show images inline **/
	static final TYPES = [
		"jpg" => "image/jpeg",
		"jpeg" => "image/jpeg",
		"png" => "image/png",
		"gif" => "image/gif",
		"webp" => "image/webp",
		"svg" => "image/svg+xml",
		"mp4" => "video/mp4",
		"webm" => "video/webm",
		"mp3" => "audio/mpeg",
		"ogg" => "audio/ogg",
		"opus" => "audio/ogg",
		"m4a" => "audio/mp4",
		"pdf" => "application/pdf",
		"txt" => "text/plain",
		"md" => "text/markdown",
		"zip" => "application/zip",
		"json" => "application/json"
	];

	/**
		The file at `path` (`~/` is the home directory) with its size, if it exists and has at most `max` bytes;
		else `null`, with an error written to `out`.
	**/
	public static function find(path:String, max:Int, out:Output):Null<{path:String, size:Int}> {
		path = Config.expandHome(path);
		if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) {
			out.error('no such file: $path');
			return null;
		}
		final size = FileSystem.stat(path).size;
		if (size > max) {
			out.error('file too large: ${Term.size(size)} (max ${Term.size(max)})');
			return null;
		}
		return {path: path, size: size};
	}

	/** The path of program `name` (a path, or a name searched in `PATH`), `null` if there is none **/
	public static function which(name:String):Null<String> {
		final windows = Sys.systemName() == "Windows";
		if (name.contains("/") || (windows && name.contains("\\")))
			return FileSystem.exists(Config.expandHome(name)) ? Config.expandHome(name) : null;
		for (dir in (Sys.getEnv("PATH") ?? "").split(windows ? ";" : ":"))
			for (file in (windows ? ['$name.exe', name] : [name]))
				if (dir.length > 0 && FileSystem.exists('$dir/$file') && !FileSystem.isDirectory('$dir/$file'))
					return '$dir/$file';
		return null;
	}

	/** The content type of a file by its extension, `null` if unknown **/
	public static function type(path:String):Null<String>
		return TYPES.get((Path.extension(path) ?? "").toLowerCase());
}
