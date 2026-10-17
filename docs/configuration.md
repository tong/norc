The config directory is `~/.config/norc` (`$XDG_CONFIG_HOME/norc`, Windows: `%APPDATA%\norc`), or another one
given with `-c <dir>`.

An account can also be a directory, `accounts/<name>/`, with its config in `conf`, and hooks (`hooks/`) and
scripts (`scripts/`) only of this account. The hooks and scripts in the config directory are for all accounts.

When norc starts and the config directory doesn't exist, it creates it with the default config: `conf` (all
settings, commented, with their defaults) and an example for every hook in `hooks/`, and the example scripts in `scripts/`.
They are disabled (not executable), enable one with `chmod +x ~/.config/norc/hooks/on-message`. The defaults are in [`config/`](https://github.com/tong/norc/tree/main/config),
with an example account config in [`config/accounts/example`](https://github.com/tong/norc/blob/main/config/accounts/example).

```
~/.config/norc/
├── conf                     base config: defaults for all accounts
├── accounts/
│   ├── tong@example.org     one file per account, the file name is the account name
│   ├── work
│   └── home/                an account directory
│       ├── conf
│       ├── hooks/
│       └── scripts/
├── hooks/                   programs run on events (see Hooks)
└── scripts/                 programs running with norc (see Scripts)
```

Config files contain `key = value` lines, `#` starts a comment (only at the start of a line).
An account file overrides any value of `conf`:

| Key | Description | Default |
|---|---|---|
| `account` | only in `conf`: the account to use without `-a` (file name, local part or jid) | the only configured account |
| `jid` | the account, e.g. `me@example.org` or `me@example.org/laptop` (required) | |
| `password_cmd` | command printing the password, e.g. `pass xmpp/me@example.org`; without it norc asks | |
| `host` | server host, if the server isn't reachable at the domain of the jid or its SRV records (`_xmpp-client._tcp`) | from the SRV records, else the jid's domain |
| `port` | server port | `5222` |
| `resource` | resource of the connection (a resource in the jid takes precedence) | `norc` |
| `download_dir` | directory for received files (`~/` is the home directory) | `$XDG_DOWNLOAD_DIR` or `~/Downloads` |
| `keepalive` | seconds without data from the server before pinging it; norc reconnects without answer within 30 seconds; `0` disables it | `60` |
| `last_activity` | `1`: answer last activity requests (`/lastactivity`) with the time since your last input in norc | `0` |
| `carbons` | `0`: don't receive copies of the messages sent and received by your other clients (Message Carbons) | `1` |
| `chat_states` | `0`: don't send chat states (typing, …) | `1` |
| `entity_time` | `1`: answer time requests (`/time`) with your local time, revealing your time zone | `0` |
| `inline_images` | images shared in messages shown after them (in terminals showing images, see [file transfer](file-transfer)): `contacts`: of contacts and your own, `all`: of everybody, also in rooms, `off`: only with `/file show` | `contacts` |
| `disable_modules` | modules not loaded, separated by commas: their commands, the features other clients see and the handling of their stanzas are left out, e.g. `calls, tunes, avatars`; the modules: `rooms`, `history`, `carbons`, `receipts`, `chat-states`, `profile`, `moods`, `tunes`, `corrections`, `reactions`, `replies`, `retractions`, `avatars`, `attention`, `time`, `ping`, `adhoc`, `pubsub`, `blocking`, `file-transfers`, `calls`, `upload`, `images` (contacts, messages and service discovery are always loaded) | none |
| `attention` | `0`: ignore attention requests (`/attention`) of contacts; else they ring the terminal bell | `1` |
| `stream_management` | `0`: no stream management (XEP-0198): no resuming of the session after a disconnection; a killed norc then goes offline at once instead of when the server drops the session | `1` |
| `share.<name>` | a directory shared with your contacts (browsed and downloaded with `/file browse` and `/file get`), e.g. `share.music = ~/Music`, see [Sharing files](file-transfer#sharing-files) | none |
| `share_access` | who may list and download the shared directories: `roster` (contacts seeing your presence), `none`, `group:<name>` (a roster group), jids; several separated by `,` | `roster` |
| `alias.<name>` | an alias of a command: `/<name>` runs it, with its first arguments if given, e.g. `alias.m = msg`, `alias.away = presence away` (`/away lunch` runs `/presence away lunch`); a command of the same name is run instead | `alias.h = help` (in the default `conf`) |
| `priority` | priority of your presence (-128 to 127), see `/presence priority` | `0` (not sent) |
| `autojoin_bookmarks` | `0`: don't join the rooms bookmarked with autojoin after the login (e.g. for a norc used by scripts) | `1` |
| `call_microphone`, `call_speaker`, `call_camera` | devices of calls: their names, or parts of them (`/calls devices` lists them) | the default devices |
| `call_echo_cancel` | `0`: no echo cancellation and noise suppression of the microphone in calls | `1` |
| `call_self_view` | `0`: no window with your own video (small, mirrored) in video calls | `1` |
| `call_video_size`, `call_video_fps` | size (e.g. `1280x720`) and frames per second of the sent video | of the camera |
| `call_video_bitrate`, `call_audio_bitrate` | bitrates of the sent video and audio in kbit/s, e.g. lower on mobile data | of the codecs |
| `stun` | STUN server for calls (`stun://host:port`), in addition to those of your server (XEP-0215) | |
| `turn` | TURN servers for calls (`turn://user:password@host:port`, `turns://…`, several separated by `,`), in addition to those of your server; needed when both sides are behind NAT | |
| `call_helper` | program for the audio and video of calls, with its options (see `norc-rtc --help`) | `norc-rtc` |
| `call_recording` | `1`: calls can be recorded (`/call record`); the other side is not told | `0` |
| `call_record_dir` | directory of the recordings of calls, `~/` is the home directory | `$XDG_DATA_HOME/norc/calls` |
| `chat_history` | messages of the archive of the server shown when the chat mode starts with a contact (`/chat`, MAM), `0`: none | `10` |
| `inline_avatars` | `1`: small avatars of contacts, before their names in messages and notices, and `{avatar}` in `chat_prompt` (in terminals showing images, PNG avatars; with ImageMagick scaled to fit with a pixel of space around them, else filling two cells); with `0` `{avatar}` is empty | `0` |
| `terminal_images` | `0`: don't show images (avatars) in the terminal; else they are shown in terminals supporting the kitty graphics protocol (kitty, WezTerm, Ghostty, Konsole), detected when the interactive mode starts | `1` |
| `persistent_command_history` | `0`: don't keep the history of the input line (interactive mode) between runs; else it is kept in `~/.local/state/norc/<account>/history` (readable only by you, the last 1000 lines) | `1` |
| `prompt` | prompt of the input line (interactive mode), in `"` to keep spaces at the start or end, e.g. `"me> "`; `{status}` shows the calls (active/pending), rooms joined and file transfers (active/pending) there are, e.g. `☎1/0 #3 ⇅0/1 ` (nothing without), the numbers alone are `{calls_active}`, `{calls_pending}`, `{rooms}`, `{transfers_active}`, `{transfers_pending}` (in all three prompts), e.g. `"{calls_active}/{calls_pending}\|{rooms}> "` | `"{status}> "` |
| `chat_prompt` | prompt in chat mode (`/chat`): `{name}` is the name of the contact (in its color), `{jid}` its jid, `{state}` its chat state unless active (e.g. ` (typing)`), `{avatar}` its avatar (a small image, with `inline_avatars = 1` in terminals showing images, else nothing), e.g. `"{avatar}{name}{state}> "` | `"{name}{state}> "` |
| `room_prompt` | prompt in group chat mode (in a room): `{name}` is the room's local part (in its color), `{jid}` its jid, `{nick}` your nick in it | `"#{name}> "` |
| `api` | the socket interface for other programs, see [API](api): `1` (at the Unix socket and over TCP), or where: `socket` (the Unix socket `$XDG_RUNTIME_DIR/norc/<account>.sock`), the path of a Unix socket, `tcp` (`127.0.0.1`, a free port), a port, `host:port`; several separated by `,`, e.g. `socket,9990` | `0` |
| `api_host`, `api_port` | for `api = 1`: address and port of TCP | `127.0.0.1`, a free port |
| `api_socket`, `api_tcp` | for `api = 1`: `0`: not at the Unix socket, not over TCP | `1` (the socket in the single binary on Linux and macOS) |

Example account `~/.config/norc/accounts/work`:

```
jid = me@work.example.org
password_cmd = pass xmpp/work
download_dir = ~/work/incoming
```

Passwords are never taken from the command line: use `password_cmd`, or type it when asked.

## Files and directories

| Path | Content |
|---|---|
| `~/.config/norc/conf` | base config |
| `~/.config/norc/accounts/<name>` | account configs (or `accounts/<name>/conf`) |
| `~/.config/norc/hooks/on-<event>` | [hooks](hooks) |
| `~/.config/norc/scripts/` | [scripts](scripts) |
| `~/.local/state/norc/<account>/pid` | pid of the running norc of the account |
| `~/.local/state/norc/<account>/history` | history of the input line (`persistent_command_history`) |
| `~/.local/state/norc/<account>/api` | address and token of the socket interface (while running) |

On Windows: `%APPDATA%\norc` for the config, `%LOCALAPPDATA%\norc` for the state.
