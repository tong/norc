With `api = 1` (or `--api`), other programs can use a running norc: send commands and receive events.
A program starting norc itself can use the same protocol over stdin and stdout instead: `norc --stdin` (see
[Over stdin and stdout](#over-stdin-and-stdout)).
norc listens on `127.0.0.1` (`api_host`) on a free port (`api_port`), and writes the address and a random token
to `~/.local/state/norc/<account>/api`, readable only by you:

```
host = 127.0.0.1
port = 41735
token = ebd072ad0ae7…
```

## From the shell: norc ctl

`norc ctl` runs a command in the running norc of an account and prints
its output, as on the terminal; the exit code is `1` if the command failed or no norc runs with the socket
interface. The words are passed as they are, no quoting for norc needed.

```sh
norc ctl presence away back at 3     # the default account
norc ctl -a work msg alice build finished
norc ctl --json contacts             # the replies as JSON lines (data instead of text)
norc ctl events message call         # print events (JSON lines) until norc quits, all without names
norc ctl -t 60 wait login            # wait for an event (at most 60 seconds), print it
```

E.g. in the config of other programs: `on-timeout = norc ctl presence away` (an idle daemon), a key binding for
`norc ctl calls hangup`.

### From stdin

With `-s` (`--stdin`), the last argument of the command comes from stdin, e.g. the text of a message, or a file for
an argument `path` (`file share`, `file send`, `file upload`, `avatar set`). With `-l` (`--lines`), each line is sent
as it comes, until the end of the input: lines arriving together (e.g. a burst of a log) go in one message, at most
one message a second.

```sh
make 2>&1 | tail -20 | norc ctl -s msg alice          # one message, line breaks kept
tail -f /var/log/app.log | norc ctl -l msg alice
grim - | norc ctl -s -n screen.png file share alice    # the name of the file (-n), else stdin.png
pg_dump db | gzip | norc ctl -s file send alice@example.org/laptop
```

A text is at most 64 KiB (a file for more). A file from stdin is stored in a temporary directory readable only by
you and removed once norc has read it; without `-n` it is named `stdin` with the extension of its type, recognized
by its first bytes (`.png`, `.jpg`, `.pdf`, `.webm`, `.txt`, …).

## Protocol

One JSON object per line, for requests, replies and events. The first request authenticates, then commands follow:

```
→ {"auth":"ebd072ad0ae7…"}
← {"type":"auth","ok":true}
→ {"id":1,"cmd":"contacts"}
← {"type":"data","id":1,"data":{"contacts":[{"jid":"alice@example.org","name":"Alice","presence":"available","subscription":"both","asked":false,"groups":[]}]}}
← {"type":"done","id":1,"ok":true}
→ {"id":2,"cmd":"msg","args":["alice","hi there"]}
← {"type":"done","id":2,"ok":true}
→ {"id":3,"cmd":"contacts add","args":["nobody"]}
← {"type":"error","id":3,"text":"invalid jid: nobody (expected user@domain)"}
← {"type":"done","id":3,"ok":false}
← {"type":"event","event":"message","data":{"from":"alice@example.org/phone","name":"Alice","body":"hello","type":"chat","delayed":false}}
```

Requests:

- `cmd`: the command, with subcommand (`contacts add`), without `/`.
- `args`: its arguments, one per parameter, no quoting needed. A parameter taking the rest of the line (e.g. the
  text of `msg`) gets all remaining arguments, joined with spaces. Without `args`, `cmd` is a command line as in the
  interactive prompt (`"cmd":"msg alice hi there"`).
- `id`: optional, any JSON value, copied into all replies of the request.

Replies:

- `data`: the result of commands which return data (`contacts`, `contacts requests`, `presence`, `presence status`, `file transfers`, `config`,
  `help`, `block`, `disco info`, `disco items`, `software`, `lastactivity`, `file send`, `file accept`, `history`, `bookmarks`, `rooms`, `rooms find`, `room occupants`, `room subject`, `calls`) instead of their text.
- `out`, `info`, `error`: text output as on the terminal (`text`, without colors).
- `done`: the request is complete (`ok`: `false` if an error was reported), including the responses of the server
  the command waits for (at most 60 seconds). Later replies with the same id are notifications, e.g. the progress
  of a file transfer started with `file send`.

Events are the same as for [hooks](hooks) (`message`, `sent`, `receipt`, `reaction`, `retraction`, `avatar`, `server`, `chatstate`, `nickname`, `mood`, `tune`, `attention`, `call`, `room`, `room-invite`, `presence`, `subscribe`, `subscription`, `roster`, `file-offer`,
`file-received`, `file-sent`, `file-failed`, `login`, `logout`, `error`), with the values of their environment
variables (lowercase, without `NORC_`) as `data`, typed: numbers, booleans (`true` instead of `1`), `null` for unset
values. They are sent to all authenticated clients.

For use by hand (e.g. `socat - TCP:127.0.0.1:<port>`), plain lines work too: `auth <token>`, then command lines,
optionally prefixed with `@<id> `. The replies are JSON.

## Example: sending a message from the shell

```sh
api=~/.local/state/norc/me/api
port=$(sed -n 's/^port = //p' $api)
token=$(sed -n 's/^token = //p' $api)
printf 'auth %s\nmsg alice@example.org build finished\n' "$token" | nc -q1 127.0.0.1 "$port"
```

(`-q1` closes the connection after the input; some netcat versions use `-N` instead.)

The online contacts, with [jq](https://jqlang.org):

```sh
{ printf '{"auth":"%s"}\n{"cmd":"contacts"}\n' "$token"; sleep 1; } | nc -q1 127.0.0.1 "$port" \
	| jq -r 'select(.type == "data") | .data.contacts[] | select(.presence) | "\(.name // .jid): \(.presence)"'
```

The connection is not encrypted: with an `api_host` other than `127.0.0.1` the token can be read from the network
traffic. For remote access, use an SSH tunnel: `ssh -L 5280:127.0.0.1:5280 host`.

## Over stdin and stdout

`norc --stdin` reads requests from stdin and writes replies and events to stdout, as JSON lines of the same
protocol, without authentication (the program started norc). Everything norc prints otherwise goes to stderr, so
stdout carries only JSON. norc quits when stdin is closed. The password must come from `password_cmd`, as stdin
can't be used to ask for it.

```sh
{ echo '{"id":1,"cmd":"msg","args":["alice@example.org","hello"]}'; sleep 5; } | norc -a me --stdin 2>/dev/null
```

Editors and other programs can run norc as child process this way (e.g. with `jobstart` in Neovim), without
socket, port or token.
