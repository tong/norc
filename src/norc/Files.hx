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
		The directory of the program a request of the API comes from (its `cwd`) while it runs: relative paths in
		commands are of that program, not of norc. `null`: the directory of norc (e.g. on the terminal).
	**/
	public static var cwd:Null<String>;

	/** A path given in a command: `~/` is the home directory, a relative path is relative to `cwd` (if set) **/
	public static function resolve(path:String):String {
		path = Config.expandHome(path);
		return (cwd != null && !Path.isAbsolute(path)) ? Path.join([cwd, path]) : path;
	}

	/**
		The file at `path` (`~/` is the home directory, see `resolve`) with its size, if it exists and has at most `max`
		bytes (`null`: any size; the size of files over 2 GB is wrong, HashLink has it as 32-bit integer); else `null`,
		with an error written to `out`.
	**/
	public static function find(path:String, max:Null<Int>, out:Output):Null<{path:String, size:Int}> {
		path = resolve(path);
		if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) {
			out.error('no such file: $path');
			return null;
		}
		final size = FileSystem.stat(path).size;
		if (max != null && size > max) {
			out.error('file too large: ${Term.size(size)} (max ${Term.size(max)})');
			return null;
		}
		return {path: path, size: size};
	}

	/**
		The path of program `name`: a path, or a name searched in `PATH` and then next to norc (e.g. unpacked from a
		release); on Windows also with `.exe`. `null` if there is none.
	**/
	public static function which(name:String):Null<String> {
		final windows = Sys.systemName() == "Windows";
		final path = name.contains("/") || (windows && name.contains("\\"));
		final dirs = path ? [""] : (Sys.getEnv("PATH") ?? "").split(windows ? ";" : ":").concat([Path.directory(Sys.programPath())]);
		for (dir in dirs)
			for (ext in (windows ? [".exe", ""] : [""])) {
				final file = (dir == "" ? Config.expandHome(name) : '$dir/$name') + ext;
				if ((path || dir != "") && FileSystem.exists(file) && !FileSystem.isDirectory(file))
					return file;
			}
		return null;
	}

	/** The content type of a file by its extension, `null` if unknown **/
	public static function type(path:String):Null<String>
		return TYPES.get((Path.extension(path) ?? "").toLowerCase());
}
