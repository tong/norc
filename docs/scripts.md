[Hooks](hooks) react to events of norc. Scripts run as long as norc runs, e.g. to tell norc about things happening on your
computer: executables in `~/.config/norc/scripts/` (all accounts) and `~/.config/norc/accounts/<name>/scripts/`
(one account). norc starts them before connecting and stops them when it quits. Files without execute permission
are skipped, enable a script with `chmod +x`.

- A script's stdout and stdin are its connection to norc: it writes requests (JSON lines, as in the
  [API](api#protocol), already authenticated) and reads the replies and all events. Its stderr is shown as error
  output.
- At the end of its input (norc quits) a script should exit; after a second it is killed.
- Environment: `NORC_ACCOUNT`, `NORC_CONFIG` (the config directory), `NORC_ACCOUNT_DIR` (if the account is a
  directory).
- A script exiting with an error is started again after a delay (1 s, growing to 60 s); exiting with 0 ends it.
  Requests before the login fail with "not connected": wait for the `login` event.

| Command | Description |
|---|---|
| `/scripts` | list the scripts and their state (running, exited, failed, stopped) |
| `/scripts restart <name>` | start a script again |
| `/scripts stop <name>` | stop a script (until `/scripts restart` or the next start of norc) |

Examples (the new ones need `jq`) are in [`config/scripts/`](https://github.com/tong/norc/tree/main/config/scripts), installed disabled into `~/.config/norc/scripts/` on the first
start:

| Script | Does |
|---|---|
| `tune-mpris` | publishes the music you are listening to (`/tune`) from any MPRIS player (mpv, Spotify, browsers, …), via `playerctl`; paused or stopped clears it |
| `idle-away` | away after 5 minutes without input, extended away after 30, back to your presence and status when you return (only an available presence is changed); idle time from `swayidle`, `xprintidle`, or signals of another idle daemon (e.g. `hypridle`, see the script) |
| `auto-reply` | answers messages while you are away, xa or dnd with an away message, once per contact (again after you answered it, or were available) |
| `log-messages` | writes the messages to log files, one per contact and room: `~/.local/share/norc/logs/<account>/<jid>.log` |

A minimal script, sending a message after each login:

```sh
#!/bin/sh
while read -r line; do
	case $line in
	*'"event":"login"'*) echo '{"cmd":"msg","args":["alice@example.org","online again"]}' ;;
	esac
done
```
