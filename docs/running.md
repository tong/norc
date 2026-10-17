```sh
norc                    # the default account (account in conf), or the only configured one
norc -a work            # account "work" (file name, local part of the jid, or the jid)
norc -a work --no-input # without input line, e.g. in the background
norc -j me@example.org  # without config file (asks for the password)
```

| Option | Description |
|---|---|
| `-a, --account <name>` | account to use: the file name in `accounts/`, or the local part (`me`) or jid of a configured account if it is unique |
| `-j, --jid <jid>` | use this jid instead of a configured account |
| `-c, --config <dir>` | config directory |
| `--host <host>`, `--port <port>` | server host and port |
| `--resource <res>` | resource of the jid, overrides `resource` of the config and a resource given with the jid |
| `-i, --interactive` | read commands from stdin, also if it is no terminal (e.g. piped commands); the default on a terminal, when norc runs in its foreground |
| `--no-input` | don't read commands from the terminal: only show messages and events (e.g. norc in a terminal multiplexer, with hooks or the socket interface) |
| `--api` | enable the socket interface |
| `--stdin` | the API over stdin and stdout instead of a socket (JSON lines, no token); other output goes to stderr; needs `password_cmd` |
| `--xmpp-debug` | print the XMPP stream (passwords are hidden) |
| `--no-color` | disable colored output |
| `--silent` | print nothing: no messages, notices or errors (only errors that stop norc, e.g. an invalid config); for norc running in the background with hooks or the socket interface; no input line, not with `-i`, needs `password_cmd` |
| `-v, --version` | show the version |
| `-h, --help` | show the help |

On a terminal norc reads commands (interactive mode). Started in the background (`norc &`), with `--no-input`, `--stdin`,
`--silent`, or with stdin no terminal (e.g. a systemd service), it doesn't, and only prints incoming messages and presence changes; use [hooks](hooks) or the [socket interface](api) to act
on them. norc reconnects automatically after the connection was lost.

Each account can only be used by one norc process at a time; a second one stops with `already running (pid …)`.
For several accounts, run several norc processes.

## The interactive prompt

On a terminal, norc shows a prompt (`> `) and prints incoming messages above it. The prompt shows calls, rooms and
file transfers while there are any, e.g. `☎1/0 #2 ⇅0/1 > `: one call connected and none ringing, two rooms, a file
offered to you (see `prompt` in the [configuration](configuration)).

When a contact's client received your message (delivery receipt), a `✓` is added at the end of the message, if it
is still on the screen; else a line `✓ alice: the start of the message` is printed.

`/chat <contact>` starts the chat mode: the prompt shows the contact, and lines without `/` are sent to it. The last
messages with the contact are shown first, from the archive of the server (`chat_history`, if the server keeps one).
`/room join <room>` starts the group chat mode in the room, the same with the room's prompt (`#room> `); `/chat <room>`
returns to a joined room. The prompts of the three modes are set with `prompt`, `chat_prompt` and `room_prompt`
(see [Configuration](configuration)).
Commands keep working; `/chat` or Ctrl-C on an empty line leaves it.

In chat mode, commands taking a jid use the contact when it is left out: `/file send ~/photo.jpg`, `/attention`,
`/ping`, `/vcard`. A jid or contact name given still works as usual (`/file send bob ~/photo.jpg`). The first word
is taken as the jid if it contains `@` or is the name of a contact; a command with an optional jid uses the contact
when it gets no arguments at all (`/disco info example.org` still queries the server).

Chat states are sent automatically (unless `chat_states = 0`): the contact sees that you are in the chat, typing,
paused (5 seconds without typing) or gone (you left the chat). The prompt shows the state of the contact:
`alice (typing)> `, `alice (paused)> `, `alice (gone)> `.

```
> /chat alice
alice> hi!
alice> /presence away
alice> /chat
>
```

| Key | Action |
|---|---|
| Tab | complete commands, subcommands, contacts, files and other arguments; lists the candidates if there are several |
| ↑ / ↓ | previous / next line of the history starting with the text typed, all lines on an empty input (kept between runs, see `persistent_command_history`) |
| ← / →, Home / End, Ctrl-A / Ctrl-E | move the cursor |
| Backspace / Delete | delete before / under the cursor |
| Ctrl-U / Ctrl-K / Ctrl-W | delete to the start / to the end / the word before the cursor |
| Shift-Enter, Alt-Enter | a line break in the message (shown as `↵`; sent as a newline, in commands as `\n`). Shift-Enter in terminals with the kitty keyboard protocol (kitty, foot, WezTerm, Ghostty, Alacritty, iTerm2), not in tmux or screen; Alt-Enter in all |
| Ctrl-L | clear the screen |
| Ctrl-X Ctrl-E | edit the line in your text editor (`$VISUAL`, `$EDITOR`, else `vi`), see `/edit` |
| Ctrl-C | clear the line, on an empty line: leave the chat mode, else quit |
| Ctrl-D | quit on an empty line |
