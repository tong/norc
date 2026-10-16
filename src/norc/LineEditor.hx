package norc;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileOutput;
import sys.thread.Mutex;

using StringTools;

/**
	Reads lines from the terminal with editing and history, while other output is printed above the input line.

	The terminal is switched to non-canonical mode without echo and signals (`stty`): keys are handled here,
	Ctrl-C included. Only on Unix terminals (`start` returns `null` otherwise); call `stop` to restore the terminal.

	Keys: Tab (complete), ←/→, Home/End, Backspace/Delete, ↑/↓ history (the lines starting with the text typed), Ctrl-A/E (start/end), Ctrl-U/K (delete to start/end),
	Ctrl-W (delete word), Ctrl-L (clear screen), Ctrl-C (clear the line; on an empty line `INTERRUPT`), Ctrl-D (quit on an empty line).
**/
class LineEditor {
	/** Returned for Ctrl-D on an empty line **/
	public static inline var QUIT = "/quit";

	/** Returned for Ctrl-C on an empty line **/
	public static inline var INTERRUPT = "\x03";

	static inline var MAX_HISTORY = 1000;

	var prompt:String;

	/** Terminal settings to restore (`stty -g`) **/
	final saved:String;

	/** Guards the input state and the terminal output, used by the input thread and the main thread **/
	final mutex = new Mutex();

	/** The input line, one character per element **/
	var line = new Array<String>();

	var cursor = 0;

	final history = new Array<String>();

	/** Position in the history while browsing, `history.length` for the new line **/
	var historyPos = 0;

	/** The new line while browsing the history **/
	var draft = new Array<String>();

	/** The history line shown by browsing, if the line was edited since then a new search starts **/
	var browsed:Null<String>;

	/** Ask the terminal whether it shows images (kitty graphics protocol) when started **/
	public static var queryImages = true;

	/** The terminal shows images (kitty graphics protocol): it answered the query sent when the editor started **/
	public var images(default, null) = false;

	/** Reading a line (the prompt is shown) **/
	var active = false;

	/**
		Completes the input up to the cursor: returns the text being completed (its end) and the candidates
		replacing it, see `Commands.complete`. Called on the input thread, without holding the editor's lock.
	**/
	public var complete:Null<(before:String) -> Null<{word:String, candidates:Array<String>}>>;

	/** Whether a line read stays on the screen (after the prompt), all if not set; on the input thread **/
	public var echo:Null<(line:String) -> Bool>;

	/** Called with the input line after each change by a key, on the input thread while holding the editor's lock **/
	public var changed:Null<(line:String) -> Void>;

	/** A text editor runs (`edit`): output is held back until it ends **/
	var suspended = false;

	/** Output held back while the text editor runs **/
	final held = new Array<{text:String, error:Bool}>();

	/** Ctrl-X was pressed: Ctrl-E follows for the text editor **/
	var ctrlX = false;

	/** The file keeping the history (lines appended), `null` without **/
	var historyFile:Null<FileOutput>;

	/**
		Switches the terminal to the editor's mode; returns `null` if stdin is no terminal or on Windows.
		With `historyPath`, the history is loaded from and kept in that file (readable only by the user).
	**/
	public static function start(prompt:String, ?historyPath:String):Null<LineEditor> {
		// only if stdin is the terminal (not e.g. piped input of a command run in a terminal)
		if (Sys.systemName() == "Windows" || Sys.command("test -t 0") != 0)
			return null;
		final saved = stty("-g");
		if (saved == null || stty("-icanon -echo -isig min 1 time 0") == null)
			return null;
		final editor = new LineEditor(prompt, saved);
		// the answer is read as input (see `escape`), terminals without the protocol ignore it: nothing to wait for
		if (queryImages)
			write("\x1B_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1B\\");
		if (historyPath != null)
			try
				editor.loadHistory(historyPath)
			catch (e)
				Term.error('cannot keep the history in $historyPath: $e');
		return editor;
	}

	function new(prompt:String, saved:String) {
		this.prompt = prompt;
		this.saved = saved;
	}

	/** Loads the history of `path` (created private if missing, trimmed to `MAX_HISTORY` lines), new lines are added **/
	function loadHistory(path:String) {
		if (!FileSystem.exists(path)) {
			FileSystem.createDirectory(haxe.io.Path.directory(path));
			File.saveContent(path, "");
			if (Sys.systemName() != "Windows")
				Sys.command("chmod", ["600", path]);
		}
		final lines = File.getContent(path).split("\n").filter(l -> l.length > 0);
		for (l in lines.slice(-MAX_HISTORY))
			history.push(l);
		// grows to twice the size before it is trimmed
		if (lines.length > MAX_HISTORY * 2)
			File.saveContent(path, history.join("\n") + "\n");
		historyFile = File.append(path, false);
	}

	/** Restores the terminal **/
	public function stop() {
		mutex.acquire();
		if (active)
			write("\r\x1B[K");
		active = false;
		historyFile?.close();
		historyFile = null;
		mutex.release();
		stty(saved);
	}

	/** Replaces the prompt, also of the line being read **/
	public function setPrompt(prompt:String) {
		mutex.acquire();
		this.prompt = prompt;
		if (active)
			redraw();
		mutex.release();
	}

	/**
		Prints `text` (a complete line, without newline) above the input line.
	**/
	public function print(text:String, error = false) {
		mutex.acquire();
		if (suspended) {
			held.push({text: text, error: error});
			mutex.release();
			return;
		}
		if (active)
			write("\r\x1B[K");
		if (error) {
			Sys.stderr().writeString(text + "\n");
			Sys.stderr().flush();
		} else
			write(text + "\n");
		if (active)
			redraw();
		mutex.release();
	}

	/**
		Reads a line (blocking, on the input thread), starting with `initial`; `null` at the end of input.
	**/
	public function readLine(?initial:String):Null<String> {
		mutex.acquire();
		line = (initial != null) ? splitChars(initial) : [];
		cursor = line.length;
		historyPos = history.length;
		active = true;
		redraw();
		mutex.release();
		final input = Sys.stdin();
		while (true) {
			final c = try input.readByte() catch (_:haxe.io.Eof) -1;
			mutex.acquire();
			final before = line.join("");
			final result = key(c, input);
			if (result.match(Continue) && changed != null && line.join("") != before)
				changed(line.join(""));
			mutex.release();
			switch result {
				case Continue:
				case Done(text):
					return text;
			}
		}
	}

	function key(c:Int, input:haxe.io.Input):KeyResult {
		final x = ctrlX;
		ctrlX = false;
		switch c {
			case -1:
				return finish(null);
			case 13, 10: // enter
				final text = line.join("");
				if (text.trim().length > 0 && history[history.length - 1] != text) {
					history.push(text);
					if (history.length > MAX_HISTORY)
						history.shift();
					try {
						historyFile?.writeString(text + "\n");
						historyFile?.flush();
					} catch (_) {}
				}
				return finish(text);
			case 3: // ctrl-c
				if (line.length == 0)
					return finish(INTERRUPT);
				line = [];
				cursor = 0;
			case 4: // ctrl-d
				if (line.length == 0)
					return finish(QUIT);
				if (cursor < line.length)
					line.splice(cursor, 1);
			case 127, 8: // backspace
				if (cursor > 0) {
					line.splice(cursor - 1, 1);
					cursor--;
				}
			case 24: // ctrl-x, ctrl-e: the line in the text editor
				ctrlX = true;
				return Continue;
			case 5 if (x):
				mutex.release();
				final text = edit(line.join(""));
				mutex.acquire();
				if (text != null) {
					line = splitChars(text);
					cursor = line.length;
				}
			case 1: // ctrl-a
				cursor = 0;
			case 5: // ctrl-e
				cursor = line.length;
			case 21: // ctrl-u
				line.splice(0, cursor);
				cursor = 0;
			case 11: // ctrl-k
				line.splice(cursor, line.length - cursor);
			case 23: // ctrl-w: the word before the cursor
				var start = cursor;
				while (start > 0 && line[start - 1] == " ")
					start--;
				while (start > 0 && line[start - 1] != " ")
					start--;
				line.splice(start, cursor - start);
				cursor = start;
			case 9: // tab
				completeWord();
			case 12: // ctrl-l
				write("\x1B[2J\x1B[H");
			case 27: // escape sequence
				escape(input);
			case _ if (c >= 32):
				final char = utf8Char(c, input);
				line.insert(cursor, char);
				cursor++;
			case _:
		}
		redraw();
		return Continue;
	}

	function escape(input:haxe.io.Input) {
		mutex.release();
		final c1 = try input.readByte() catch (_:haxe.io.Eof) -1;
		if (c1 == "_".code) {
			// an answer of the terminal (APC): to the query of the kitty graphics protocol `i=31;OK`
			final answer = applicationCommand(input);
			mutex.acquire();
			if (answer.startsWith("Gi=31;") && answer.endsWith(";OK"))
				images = true;
			return;
		}
		if (c1 != "[".code && c1 != "O".code) {
			mutex.acquire();
			return;
		}
		// CSI parameters (e.g. "3~", "?62;4" of an answer of the terminal) and the final byte
		var params = "";
		var c = try input.readByte() catch (_:haxe.io.Eof) -1;
		while (c >= "0".code && c <= "9".code || c == ";".code || c == "?".code || c == ">".code) {
			params += String.fromCharCode(c);
			c = try input.readByte() catch (_:haxe.io.Eof) -1;
		}
		mutex.acquire();
		switch [c, params] {
			case ["A".code, _]:
				browse(-1);
			case ["B".code, _]:
				browse(1);
			case ["C".code, _]:
				if (cursor < line.length)
					cursor++;
			case ["D".code, _]:
				if (cursor > 0)
					cursor--;
			case ["H".code, _] | ["~".code, "1" | "7"]:
				cursor = 0;
			case ["F".code, _] | ["~".code, "4" | "8"]:
				cursor = line.length;
			case ["~".code, "3"]:
				if (cursor < line.length)
					line.splice(cursor, 1);
			case _:
		}
	}

	/** The rest of an application program command (after `ESC _`), up to `ESC \` (at most 4096 bytes) **/
	static function applicationCommand(input:haxe.io.Input):String {
		final b = new StringBuf();
		var esc = false;
		for (_ in 0...4096) {
			final c = try input.readByte() catch (_:haxe.io.Eof) -1;
			if (c < 0 || (esc && c == "\\".code))
				break;
			esc = c == 0x1B;
			if (!esc)
				b.addChar(c);
		}
		return b.toString();
	}

	/**
		Replaces the word before the cursor with the only candidate, or with the start all candidates share;
		lists the candidates if the word can not be extended.
	**/
	function completeWord() {
		final f = complete;
		if (f == null)
			return;
		final before = line.slice(0, cursor).join("");
		// other output can be printed meanwhile, only this thread changes the line
		mutex.release();
		final c = try f(before) catch (_) null;
		mutex.acquire();
		if (c == null || c.candidates.length == 0 || !before.endsWith(c.word))
			return;
		final candidates = c.candidates;
		final insert = if (candidates.length == 1) {
			candidates[0] + (candidates[0].endsWith("/") ? "" : " ");
		} else {
			var common = candidates[0];
			for (v in candidates)
				while (!v.startsWith(common))
					common = common.substr(0, common.length - 1);
			(common.length > c.word.length) ? common : null;
		}
		if (insert == null) {
			// without the start of the word up to the last directory or word, e.g. `/` of a command
			final cut = Std.int(Math.max(c.word.lastIndexOf("/"), c.word.lastIndexOf(" "))) + 1;
			write("\r\x1B[K" + [for (v in candidates) v.substr(cut)].join("  ") + "\n");
			return;
		}
		final n = splitChars(c.word).length;
		line.splice(cursor - n, n);
		cursor -= n;
		for (char in splitChars(insert))
			line.insert(cursor++, char);
	}

	/**
		Edits `text` in the text editor (`$VISUAL`, `$EDITOR`, else `vi`), on the input thread without reading a line:
		returns the text written, line breaks as `\n` (as in messages), `null` if the editor failed. Output is held
		back while the editor runs.
	**/
	public function edit(text:String):Null<String> {
		mutex.acquire();
		suspended = true;
		if (active)
			write("\r\x1B[K");
		mutex.release();
		final path = haxe.io.Path.join([Sys.getEnv("TMPDIR") ?? "/tmp", 'norc-${Std.random(1 << 30)}.txt']);
		var result:Null<String> = null;
		try {
			File.saveContent(path, "");
			Sys.command("chmod", ["600", path]);
			File.saveContent(path, text.replace("\\n", "\n"));
			stty(saved);
			final editor = Sys.getEnv("VISUAL") ?? Sys.getEnv("EDITOR") ?? "vi";
			// the editor may have options (e.g. `code --wait`)
			if (Sys.command("sh", ["-c", editor + ' "$$1" </dev/tty >/dev/tty', "sh", path]) == 0)
				result = ~/\n+$/.replace(File.getContent(path), "").replace("\n", "\\n");
		} catch (_) {}
		try
			FileSystem.deleteFile(path)
		catch (_) {}
		stty("-icanon -echo -isig min 1 time 0");
		mutex.acquire();
		suspended = false;
		mutex.release();
		for (h in held.splice(0, held.length))
			print(h.text, h.error);
		return result;
	}

	/**
		Moves through the history: -1 older, 1 newer. Only lines starting with the text typed before browsing
		(all for an empty line), each different from the line shown. An edited history line is typed text:
		browsing starts again from the newest line.
	**/
	function browse(dir:Int) {
		final shown = line.join("");
		if (historyPos == history.length || shown != browsed) {
			historyPos = history.length;
			draft = line;
		}
		final prefix = draft.join("");
		var pos = historyPos + dir;
		while (pos >= 0 && pos < history.length && (!history[pos].startsWith(prefix) || history[pos] == shown))
			pos += dir;
		if (pos < 0 || pos > history.length)
			return;
		historyPos = pos;
		line = (pos == history.length) ? draft : splitChars(history[pos]);
		browsed = line.join("");
		cursor = line.length;
	}

	function finish(text:Null<String>):KeyResult {
		active = false;
		write("\r\x1B[K" + ((text != null && (echo == null || echo(text))) ? prompt + line.join("") + "\n" : ""));
		return Done(text);
	}

	function redraw() {
		var s = "\r" + prompt + line.join("") + "\x1B[K";
		final back = line.length - cursor;
		if (back > 0)
			s += '\x1B[${back}D';
		write(s);
	}

	/** Reads the rest of a UTF-8 sequence starting with `lead` **/
	static function utf8Char(lead:Int, input:haxe.io.Input):String {
		final size = if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else 1;
		final b = Bytes.alloc(size);
		b.set(0, lead);
		for (i in 1...size)
			b.set(i, try input.readByte() catch (_:haxe.io.Eof) 0);
		return b.getString(0, size, UTF8);
	}

	static function splitChars(s:String):Array<String>
		return [for (c in new haxe.iterators.StringIteratorUnicode(s)) String.fromCharCode(c)];

	static function write(s:String) {
		Sys.stdout().writeString(s);
		Sys.stdout().flush();
	}

	/** Runs `stty` on the terminal, returns its output or `null` on failure **/
	static function stty(args:String):Null<String>
		return Term.output("sh", ["-c", 'stty $args < /dev/tty'])?.trim();
}

private enum KeyResult {
	Continue;
	Done(text:Null<String>);
}
