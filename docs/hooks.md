Hooks are programs run on events: executables in `~/.config/norc/hooks/` named `on-<event>`. They run
asynchronously with the main values as arguments, and all values as `NORC_*` environment variables.
Files without execute permission are skipped (disabled hooks, enabled with `chmod +x`).

Several hooks for one event: names starting with `on-<event>.` (e.g. `on-message.notify`, `on-message.log`).
All of them run, started in the order of their names.

| Hook | Arguments | Environment |
|---|---|---|
| `on-message` | from, body | `NORC_FROM` (full jid), `NORC_NAME`, `NORC_BODY`, `NORC_TYPE`, `NORC_DELAYED` (`1` for messages delivered on login), `NORC_CARBON` (`1`: received by another of your clients), `NORC_ID`, `NORC_REPLACES` (a correction: the id of the corrected message), `NORC_REPLY_ID` and `NORC_REPLY_TO` (a reply: the id and author of the message replied to; `NORC_BODY` is without its quote), `NORC_AVATAR` (the file of the contact's avatar, if known: e.g. the icon of a notification) |
| `on-sent` | to, body | a message you sent: `NORC_TO`, `NORC_NAME`, `NORC_BODY`, `NORC_ID`, `NORC_TYPE` (`groupchat`: to a room, also a `room` event when the room sends it back), `NORC_CARBON` (`1`: sent by another of your clients), `NORC_REPLACES`, `NORC_REPLY_ID`, `NORC_REPLY_TO` (as for `on-message`) |
| `on-reaction` | chat, reactions | reactions to a message (`/react`), of a contact or in a room: `NORC_CHAT` (the contact or room), `NORC_FROM`, `NORC_NAME` (in rooms the nick), `NORC_ROOM` (in rooms), `NORC_ID` (of the message reacted to), `NORC_TEXT` (its text, if known), `NORC_REACTIONS` (all reactions of the sender to it, separated by spaces; empty: removed), `NORC_OWN` (`1`: your own), `NORC_CARBON`, `NORC_DELAYED` |
| `on-retraction` | chat, id | a message was retracted (`/retract`), or removed by a moderator of a room: `NORC_CHAT` (the contact or room), `NORC_FROM`, `NORC_NAME` (in rooms the nick; for a moderation the moderator), `NORC_ROOM` (in rooms), `NORC_ID` (of the retracted message), `NORC_TEXT` and `NORC_AUTHOR` (its text and author, if known), `NORC_OWN` (`1`: your own retraction, for a moderation: your message), `NORC_MODERATED` (`1`: by a moderator), `NORC_REASON`, `NORC_CARBON`, `NORC_DELAYED` |
| `on-server` | server, features | after the login: what your server offers (see `/server`): `NORC_SERVER`, `NORC_FEATURES` and `NORC_MISSING` (of `mam`, `pep`, `blocking`, `upload`, `carbons`, separated by spaces), `NORC_UPLOAD` (the upload service) |
| `on-avatar` | jid, path | the avatar of a contact (or your own) changed, loaded into the cache: `NORC_JID`, `NORC_NAME`, `NORC_PATH` (the image file; empty: removed), `NORC_ID` (its SHA-1 hash), `NORC_TYPE`, `NORC_BYTES`, `NORC_WIDTH`, `NORC_HEIGHT`, `NORC_SOURCE` (`pep` or `vcard`), `NORC_OWN` |
| `on-receipt` | from, id | a contact's client received your message (delivery receipt): `NORC_FROM`, `NORC_NAME`, `NORC_ID` (of the sent message, see `on-sent`) |
| `on-chatstate` | from, state | a contact is typing (`composing`), stopped (`paused`), or `active`, `inactive`, `gone`: `NORC_FROM`, `NORC_NAME`, `NORC_STATE`; not shown in the terminal |
| `on-nickname` | from, nickname | a contact published a nickname (empty: stopped publishing it): `NORC_FROM`, `NORC_NAME`, `NORC_NICKNAME` |
| `on-mood` | from, mood, text | a contact published a mood (empty: stopped publishing it): `NORC_FROM`, `NORC_NAME`, `NORC_MOOD`, `NORC_TEXT` |
| `on-tune` | from, artist, title | a contact is listening to music (empty: stopped): `NORC_FROM`, `NORC_NAME`, `NORC_ARTIST`, `NORC_TITLE`, `NORC_SOURCE`, `NORC_TRACK`, `NORC_LENGTH`, `NORC_URI` |
| `on-call` | from, state | a call: `NORC_FROM`, `NORC_NAME`, `NORC_STATE` (`ringing`: a contact calls you, `calling`, `connected`, `ended`), `NORC_MEDIA` (`audio`, `video`), `NORC_AUDIO` and `NORC_VIDEO` (your direction: `both`, `send`, `receive`, `none`), `NORC_INCOMING`, `NORC_RECORDING` (the file, if the call is recorded), `NORC_REASON` and `NORC_DURATION` (seconds connected) when ended |
| `on-recording` | from, state, file | a recording of a call (`/call record`): `NORC_FROM`, `NORC_NAME`, `NORC_STATE` (`started`, `stopped`: the file is written, `failed`), `NORC_FILE`, `NORC_TRACKS` (`audio`, `video`, `own-video`, separated by spaces, when started), `NORC_MESSAGE` (why it failed) |
| `on-room` | room, nick, body | a message in a room: `NORC_ROOM`, `NORC_NICK`, `NORC_BODY`, `NORC_ID`, `NORC_OWN` (`1`: your own message, sent back by the room), `NORC_DELAYED` (`1`: history sent when joining), `NORC_MENTION` (`1`: the message contains your nick), `NORC_STANZA_ID` (the id the room gave it, if any), `NORC_REPLY_ID`, `NORC_REPLY_TO` (as for `on-message`) |
| `on-room-invite` | room, from | an invitation to a room: `NORC_ROOM`, `NORC_FROM`, `NORC_REASON` |
| `on-attention` | from, text | a contact wants your attention (`/attention`): `NORC_FROM`, `NORC_NAME`, `NORC_TEXT` |
| `on-presence` | from, state, status | `NORC_FROM`, `NORC_NAME`, `NORC_STATE` (`available`, `chat`, `away`, `xa`, `dnd`, `offline`), `NORC_STATUS`, `NORC_PREVIOUS` (previous state of the resource), `NORC_RESOURCES` (online devices of the contact), `NORC_INITIAL` (`1` for the presences sent after the login) |
| `on-subscribe` | from | `NORC_FROM`, `NORC_NAME` |
| `on-subscription` | from, type | `NORC_FROM`, `NORC_NAME`, `NORC_TYPE` (`subscribed`: you can see their presence, `unsubscribed`: not anymore, `unsubscribe`: they stopped seeing yours) |
| `on-roster` | jid, action | the roster changed (also by another of your clients): `NORC_JID_CONTACT`, `NORC_NAME`, `NORC_ACTION` (`added`, `updated`, `removed`), `NORC_SUBSCRIPTION`, `NORC_GROUPS` |
| `on-file-offer` | from, name, size | `NORC_FROM`, `NORC_FILE`, `NORC_SIZE`, `NORC_ID` |
| `on-file-received` | from, path | `NORC_FROM`, `NORC_PATH` |
| `on-file-sent` | to, path | `NORC_TO`, `NORC_PATH`, `NORC_FILE`, `NORC_SIZE` |
| `on-file-failed` | peer, name, reason | `NORC_PEER`, `NORC_FILE`, `NORC_REASON`, `NORC_DIRECTION` (`send` or `receive`) |
| `on-login` | own jid | `NORC_RESUMED` (`1`: the previous session was resumed after a disconnection, no messages were lost) |
| `on-stanza-send`, `on-stanza-recv` | (stanza on stdin) | see [Filter hooks](#filter-hooks-modifying-stanzas) |
| `on-logout` | reason | `NORC_REASON` (`quit` or the error), `NORC_RECONNECT` (`1` if norc reconnects, `0` if it exits) |
| `on-error` | kind, text | `NORC_KIND` (`connection`, `stream`, `login`, `message`), `NORC_TEXT`, `NORC_FROM` (message errors) |

Always set: `NORC_EVENT`, `NORC_ACCOUNT`, `NORC_JID`. A hook failing (exit code other than 0) is reported.

## Filter hooks: modifying stanzas

`on-stanza-send` and `on-stanza-recv` can modify or drop every stanza (`message`, `presence`, `iq`) sent and
received after the login: the stanza is passed on stdin, the hook prints the stanza to use on stdout.

- Empty output drops the stanza.
- Several hooks (`on-stanza-send.*`) are chained in the order of their names: the output of one is the input of
  the next.
- If a hook fails (exit code other than 0), takes longer than 5 seconds or prints anything but one XML element,
  its output is ignored (reported as error) and the stanza passed on unchanged.
- norc waits for the hooks: each stanza starts a process. The stream setup and the login (credentials) are not
  passed to them.

Example, `~/.config/norc/hooks/on-stanza-send`:

```sh
#!/bin/sh
# replace "teh" with "the" in sent messages
sed 's/\bteh\b/the/g'
```

## Example

Desktop notification for messages, `~/.config/norc/hooks/on-message`:

```sh
#!/bin/sh
[ "$NORC_DELAYED" = 1 ] && exit 0
exec notify-send --app-name=norc "$NORC_NAME" "$NORC_BODY"
```

An example for every hook is in [`config/hooks/`](https://github.com/tong/norc/tree/main/config/hooks) (installed disabled into `~/.config/norc/hooks/`
on the first start).
