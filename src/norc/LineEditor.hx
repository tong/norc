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
	Ctrl-W (delete word), Ctrl-L (clear screen), Ctrl-C (clear the line; on an empty line `INTERRUPT`), Ctrl-D (quit on an empty line),
	Shift-Enter or Alt-Enter (a line break: shown as `↵`, the line read has it as `\n`).

	Terminals with the kitty keyboard protocol tell Shift-Enter from Enter once it is switched on: they report
	keys with Ctrl as `CSI code;modifiers u` then, these are handled as the keys they stand for.
**/
/** Where printed text ended on the screen: its row (counted by the editor) and column, at a terminal width **/
typedef Position = {
	var row:Int;
	var column:Int;
	var columns:Int;
}

class LineEditor {
	/** Returned for Ctrl-D on an empty line **/
	public static inline var QUIT = "/quit";

	/** Returned for Ctrl-C on an empty line **/
	public static inline var INTERRUPT = "\x03";

	static inline var MAX_HISTORY = 1000;

	/** Switches the kitty keyboard protocol on (pushed: disambiguate escape codes), and off (popped) **/
	static inline var KEYBOARD_ON = "\x1B[>1u";

	static inline var KEYBOARD_OFF = "\x1B[<u";

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

	/** The size of a cell of the terminal in pixels (answer to `CSI 16 t`), `null` if unknown **/
	public var cellSize(default, null):Null<{width:Int, height:Int}>;

	/** Rows printed above the input line (wrapped lines by the width of the terminal), to find lines again (`mark`) **/
	var rows = 0;

	/** Writes `s` to the terminal as it is, e.g. image data for the terminal (not shown, the cursor stays) **/
	public function writeRaw(s:String) {
		mutex.acquire();
		write(s);
		mutex.release();
	}

	/** The size of the terminal (`stty size`) **/
	var columns = 80;

	var screenRows = 24;

	/** Reading a line (the prompt is shown) **/
	var active = false;

	/**
		Completes the input up to the cursor: returns the text being completed (its end) and the candidates
		replacing it, see `Commands.complete`. Called on the input thread, without holding the editor's lock.
	**/
	public var complete:Null<(before:String) -> Null<{word:String, candidates:Array<String>, ?groups:Array<Array<String>>}>>;

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

	/** The kitty keyboard protocol was switched on (disambiguated keys): switched off again when stopping **/
	var keyboard = false;

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
		final size = terminalSize();
		if (size != null) {
			editor.screenRows = size.rows;
			editor.columns = size.columns;
		}
		// the answer is read as input (see `escape`), terminals without the protocol ignore it: nothing to wait for
		// not in terminal multiplexers: tmux shows it as text (and passes images only with allow-passthrough)
		final term = Sys.getEnv("TERM") ?? "";
		if (queryImages && Sys.getEnv("TMUX") == null && !term.startsWith("screen") && !term.startsWith("tmux"))
			// and the size of a cell in pixels, e.g. to scale images exactly
			write("\x1B_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1B\\\x1B[16t");
		// Shift-Enter told from Enter (terminals without the protocol ignore it), not in multiplexers either
		if (Sys.getEnv("TMUX") == null && !term.startsWith("screen") && !term.startsWith("tmux")) {
			write(KEYBOARD_ON);
			editor.keyboard = true;
		}
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
		if (keyboard)
			write(KEYBOARD_OFF);
		keyboard = false;
		mutex.release();
		stty(saved);
	}

	/** Clears the screen and the scrollback (`/clear`, as the shell's `clear`), the input line stays **/
	public function clear() {
		mutex.acquire();
		clearScreen(true);
		if (active)
			redraw();
		mutex.release();
	}

	/** Clears the screen (with `scrollback` also that, as the shell's `clear`; Ctrl-L: not), holding the lock **/
	function clearScreen(scrollback:Bool) {
		write("\x1B[2J" + (scrollback ? "\x1B[3J" : "") + "\x1B[H");
		// the printed lines are gone
		rows += screenRows;
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
	public function print(text:String, error = false):Null<Position> {
		mutex.acquire();
		if (suspended) {
			held.push({text: text, error: error});
			mutex.release();
			return null;
		}
		if (active)
			write("\r\x1B[K");
		if (error) {
			Sys.stderr().writeString(text + "\n");
			Sys.stderr().flush();
		} else
			write(text + "\n");
		// the rows of the text, and where it ended
		var end:Null<Position> = null;
		for (l in text.split("\n")) {
			final width = Term.displayWidth(l);
			final n = (width == 0) ? 1 : Std.int((width + columns - 1) / columns);
			rows += n;
			end = {row: rows - 1, column: (width == 0) ? 0 : width - (n - 1) * columns, columns: columns};
		}
		if (active)
			redraw();
		mutex.release();
		return end;
	}

	/**
		Writes `text` at the end of printed text (at `pos`, see `print`) if it is still on the screen and there is room,
		e.g. a mark; returns `false` if it isn't, or the terminal was resized since.
	**/
	public function mark(pos:Null<Position>, text:String):Bool {
		if (pos == null)
			return false;
		final size = terminalSize();
		mutex.acquire();
		if (size != null) {
			screenRows = size.rows;
			columns = size.columns;
		}
		final up = rows - pos.row;
		// the input line on one row: the cursor is on the row after the printed text
		final input = Term.displayWidth(prompt) + Term.displayWidth(line.join("").replace("\n", " "));
		final ok = active && !suspended && pos.columns == columns && up >= 1 && up < screenRows && input < columns
			&& pos.column + Term.displayWidth(text) < columns;
		// up to the line, the text at its end, down again; the input line is drawn again (the cursor back in it).
		// No save and restore of the cursor (ESC 7, ESC 8): HashLink/C writes "\x1B7" as one character (C reads all
		// hex digits of an escape)
		if (ok) {
			write('\x1B[${up}A\r' + ((pos.column > 0) ? '\x1B[${pos.column}C' : '') + text + '\x1B[${up}B');
			redraw();
		}
		mutex.release();
		return ok;
	}

	/** The size of the terminal, `null` if unknown **/
	static function terminalSize():Null<{rows:Int, columns:Int}> {
		final words = (stty("size") ?? "").split(" ");
		final r = Std.parseInt(words[0] ?? ""), c = Std.parseInt(words[1] ?? "");
		return (r != null && c != null && r > 0 && c > 0) ? {rows: r, columns: c} : null;
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
				// line breaks (Shift-Enter) as in messages
				final text = line.join("").replace("\n", "\\n");
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
				clearScreen(false);
			case 27: // escape sequence
				final k = escape(input);
				if (k != null) {
					// a key reported by the keyboard protocol, e.g. Ctrl-E after Ctrl-X
					ctrlX = x;
					return key(k, input);
				}
			case _ if (c >= 32):
				final char = utf8Char(c, input);
				line.insert(cursor, char);
				cursor++;
			case _:
		}
		redraw();
		return Continue;
	}

	/**
		Handles an escape sequence (after ESC); returns the code of a key to handle (e.g. 3 for Ctrl-C reported by the
		keyboard protocol), `null` if done.
	**/
	function escape(input:haxe.io.Input):Null<Int> {
		mutex.release();
		final c1 = try input.readByte() catch (_:haxe.io.Eof) -1;
		if (c1 == 13 || c1 == 10) {
			// Alt-Enter: a line break
			mutex.acquire();
			lineBreak();
			return null;
		}
		if (c1 == "_".code) {
			// an answer of the terminal (APC): to the query of the kitty graphics protocol `i=31;OK`
			final answer = applicationCommand(input);
			mutex.acquire();
			if (answer.startsWith("Gi=31;") && answer.endsWith(";OK"))
				images = true;
			return null;
		}
		if (c1 != "[".code && c1 != "O".code) {
			mutex.acquire();
			return null;
		}
		// CSI parameters (e.g. "3~", "?62;4" of an answer of the terminal) and the final byte
		var params = "";
		var c = try input.readByte() catch (_:haxe.io.Eof) -1;
		while (c >= "0".code && c <= "9".code || c == ";".code || c == ":".code || c == "?".code || c == ">".code) {
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
			case ["u".code, _] if (!params.startsWith("?")):
				// a key of the keyboard protocol: code;modifiers (`:` adds alternatives and events)
				final v = params.split(";");
				return reported(Std.parseInt(v[0].split(":")[0]) ?? 0, Std.parseInt((v[1] ?? "1").split(":")[0]) ?? 1);
			case ["~".code, _] if (params.startsWith("27;")):
				// xterm's modifyOtherKeys: 27;modifiers;code
				final v = params.split(";");
				return reported(Std.parseInt(v[2] ?? "") ?? 0, Std.parseInt(v[1]) ?? 1);
			case ["t".code, _] if (params.startsWith("6;")):
				// the size of a cell (answer of the terminal): 6;height;width
				final v = params.split(";");
				final h = Std.parseInt(v[1] ?? ""), w = Std.parseInt(v[2] ?? "");
				if (h != null && w != null && h > 0 && w > 0)
					cellSize = {width: w, height: h};
			case _:
		}
		return null;
	}

	/**
		A key reported with its modifiers (1 + Shift 1, Alt 2, Ctrl 4): Enter with modifiers a line break,
		Ctrl with a letter its control code, Ctrl or Alt with Backspace deletes the word; `null` if handled or ignored.
	**/
	function reported(code:Int, modifiers:Int):Null<Int> {
		final m = modifiers - 1;
		return switch code {
			case 13 if (m > 0):
				lineBreak();
				null;
			case 127 | 8 if (m & 6 != 0): 23;
			case 13 | 9 | 127 | 8: code;
			case _ if (m & 4 != 0 && code >= "a".code && code <= "z".code): code - 96;
			case _: null;
		}
	}

	/** Inserts a line break at the cursor **/
	function lineBreak() {
		line.insert(cursor, "\n");
		cursor++;
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
			write("\r\x1B[K" + [for (g in c.groups ?? [candidates]) [for (v in g) v.substr(cut)].join("  ")].join("\n\x1B[K") + "\n");
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
		// the text editor may change the screen: the printed lines can't be found anymore
		rows += screenRows;
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
			File.saveContent(path, Commands.unescape(text));
			stty(saved);
			if (keyboard)
				write(KEYBOARD_OFF);
			final editor = Sys.getEnv("VISUAL") ?? Sys.getEnv("EDITOR") ?? "vi";
			// the editor may have options (e.g. `code --wait`)
			if (Sys.command("sh", ["-c", editor + ' "$$1" </dev/tty >/dev/tty', "sh", path]) == 0)
				result = Commands.escape(~/\n+$/.replace(File.getContent(path), ""));
		} catch (_) {}
		try
			FileSystem.deleteFile(path)
		catch (_) {}
		stty("-icanon -echo -isig min 1 time 0");
		if (keyboard)
			write(KEYBOARD_ON);
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
		write("\r\x1B[K" + ((text != null && (echo == null || echo(text))) ? prompt + shown() + "\n" : ""));
		return Done(text);
	}

	function redraw() {
		var s = "\r" + prompt + shown() + "\x1B[K";
		final back = line.length - cursor;
		if (back > 0)
			s += '\x1B[${back}D';
		write(s);
	}

	/** The input line as shown: line breaks as a dim `↵` (one column, the line stays on one row) **/
	function shown():String
		return line.join("").replace("\n", "\x1B[2m↵\x1B[22m");

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
