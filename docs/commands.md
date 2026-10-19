Commands start with `/`. Arguments in `<>` are required, in `[]` optional, `...` takes the rest of the line
(spaces included). Words with spaces can be quoted (`"…"`). `/help` lists all commands, `/help <command>` shows
the usage of one.

Where a contact is expected, it can be given by jid, or by its name in the roster or the local part of its jid
(case-insensitive, if exactly one contact matches): `/msg alice hi` instead of `/msg alice@example.org hi`.
A resource can be added: `alice/phone`.

Aliases of commands are set in the config (`alias.m = msg`, see [Configuration](configuration)); `/help` lists them
(`/h` in the default config).

The commands of [file transfer](file-transfer) and [scripts](scripts) are on their pages.

## Messages and presence

| Command | Description |
|---|---|
| `/msg <jid> <text...>` | send a message to a jid or contact name (`\n` for a newline, `\\n` for the characters `\n`) |
| `/history <jid> [count]` | the last messages with a contact (or in a joined room) from the archive of the server, 20 or `count` (at most 100); needs message archiving on the server (MAM, Prosody: `mod_mam`, rooms: `mod_muc_mam`) |
| `/chatlog [jid] [#count]` | the local log of the chats with contacts (`chatlog = 1`, off by default; `/config chatlog=1 --save`): the last messages with a contact, 20 or `count` (at most 500), with corrections applied and retracted messages left out; without jid: on or off, where, the chats logged. Logs the messages as they are shown, also those of your other clients, not rooms; the chat mode (`/chat`) starts with the last messages of the log (`chat_history`), also offline and without archive |
| `/clear` | clear the screen and its scrollback, as the shell's `clear` (Ctrl-L: the screen only) |
| `/edit [text...]` | write the input line in your text editor (`$VISUAL`, `$EDITOR`, else `vi`), e.g. a long message: when the editor closes, the text is the input line (line breaks as `\n`), to send with Enter (in chat mode as a message); also Ctrl-X Ctrl-E with the line being typed |
| `/chat [jid]` | chat mode (interactive): lines without `/` are sent to the contact, `//` sends a line starting with `/`; without jid (or Ctrl-C on an empty line) leave it |
| `/presence [state] [status...]` | show or set your presence: `available`, `chat`, `away`, `xa` (extended away), `dnd` (busy), with an optional status message; kept across reconnects |
| `/presence status [text...]` | show or set your status message, keeping the presence state; `/presence status -` clears it (as `/status` with `alias.status = presence status`) |
| `/presence priority [n]` | show or set the priority of your presence (-128 to 127, default 0): messages to your bare jid go to your client with the highest priority; kept across reconnects |
| `/attention <jid> [text...]` | get the attention of a contact (their client may ring or flash), with an optional message |
| `/correct <text...>` | correct your last sent message (replaced by the text in the recipient's client) |
| `/react <jid> [^n] <emoji...>` | react to the last message of a contact or in a room (`^2`: the one before it, …) with emojis: each one is added to your reactions to it, or removed if you reacted with it already; `-` removes all |
| `/reply <jid> [^n] <text...>` | reply to the last message of a contact or in a room (`^2`: the one before it, …): shown with the message replied to, quoted for clients without replies (`\n` for a newline) |
| `/retract <jid> [^n]` | retract (delete) your last message to a contact or in a room for everyone (`^2`: the one before it, …): their clients delete it or show it as retracted, but may have kept it |
| `/chatstate <jid> <state>` | send your chat state: `active`, `composing` (typing), `paused`, `inactive`, `gone`; for editors and other programs using the API |
| `/xmpp-debug [on\|off]` | print the XMPP stream (passwords hidden), without argument: on; same as `--xmpp-debug` |
| `/overview` | what is going on: calls, unread messages (of chats you are not in, with mentions in rooms), file offers and transfers, subscription requests, rooms, who is typing, an ad-hoc command waiting for input; the same as the `status` event of the API |
| `/read [jid]` | mark the messages of a chat as read (without jid: of all chats), e.g. read in another program (norc.nvim does it when it shows the chat): the unread counts of `/overview`, the prompt and the `status` event |
| `/account` | your account and its session: your jid, connected since when, the server (address, login mechanism), whether the session can be resumed, your presence, your other clients online, where the api listens, the config file and the state directory |
| `/config` | show the config of the account (base config, account config and command line options); values not saved are marked with `*` |
| `/config key=value... [--save]` | change config values, e.g. `/config keepalive=30 --save`, `/config prompt="{status} > "` (quoted: with spaces); all or none if one is invalid. Applied at once where possible (`keepalive`, `priority`, the prompts, `alias.<name>`, `chat_history`, `inline_avatars`), the call settings with the next call, `host`, `port`, `stream_management` after `/reconnect`, the others after a restart of norc; `--save` also writes them to the config file, else they are lost when norc quits |
| `/config save` | save the config to `accounts/<name>` (created if needed): changed values are updated, comments and other lines kept, values of the base config not repeated |
| `/vcard [jid]` | show the vCard (profile) of a contact, or your own |
| `/vcard set <field> [value...]` | set a field of your vCard (`name`, `nickname`, `given`, `family`, `email`, `tel`, `url`, `birthday`, `org`, `title`, `role`, `desc`, `photo` with the path of an image), without value: clear it; other fields are kept |
| `/avatar [jid]` | save the avatar of a contact (or your own) in the cache and show the file (`$XDG_CACHE_HOME/norc/avatars/<hash>.<ext>`), and the image itself in terminals showing images (kitty graphics protocol, PNG avatars, see `terminal_images`); avatars of contacts are also loaded when they change, see the `avatar` event |
| `/avatar set <path...>` | publish your avatar: a PNG (recommended), JPEG, GIF or WebP image of at most 160 KB, as PEP avatar (XEP-0084) and vCard photo (XEP-0153) |
| `/avatar remove` | remove your avatar (PEP and vCard) |
| `/nick [name...]` | show or publish your nickname (`-` stops publishing it); contacts' nicknames are their names if they have none in the roster |
| `/mood [mood] [text...]` | show or publish your mood (`happy`, `tired`, … tab completes them) with an optional text; `-` stops publishing it |
| `/tune [tune...]` | show or publish the music you are listening to: `artist - title`, or fields as `key=value` (`artist`, `title`, `source`, `track`, `length` in seconds, …; values with spaces in quotes, `\"` for a quote); `-` stops publishing it |
| `/time [jid]` | local time and time zone of a client or server (each online client of a contact; default: your server) |
| `/command [jid]` | list the commands (XEP-0050 ad-hoc commands) of a server, service or client, default: your server (e.g. its administration) |
| `/command run <jid> <node>` | run a command (its node, or number in the last list); a command asking for input shows a form |
| `/command submit [field=value...]` | answer the form of the running command (`"…"` for values with spaces, a field repeated for several values, booleans as `yes`/`no`); `/command prev` goes back, `/command cancel` cancels it |
| `/ping [jid]` | ping a server or client and show the round-trip time (each online client of a contact; default: your server) |
| `/reconnect` | close the connection and reconnect, e.g. after a network change; resumes the session if the server supports stream management |
| `/quit` (`/exit`) | disconnect and exit |

`/react` and `/reply` refer to the messages of the others shown in the chat (`/retract` to your own), also those from `/history`
and those shown when the chat mode starts. In chat mode the jid can be left out (`/react 👍`, `/reply ^2 yes`).
Received reactions are shown as `<alice> reacted 👍 to "text"`, replies with a line quoting the message replied to
(`↪ <you> text`), retractions as `<alice> retracted "text"`, corrections with `✎`.
In rooms only the author can correct or retract a message: rooms adding occupant ids (XEP-0421) tell the author
also after a nick change, and nobody taking over the nick can; in other rooms the nick decides.

```
/msg alice@example.org Hello Alice!
/presence away back at 3
/presence available
/presence status in a meeting
/presence status -
```

## Contacts (roster)

| Command | Description |
|---|---|
| `/contacts` | list contacts with presence, subscription and groups, and what they publish: their mood and the music they listen to (tune) |
| `/contacts add <jid> [name...]` | add a contact and ask to see their presence |
| `/contacts remove <jid>` (`rm`) | remove a contact (ends the presence subscriptions both ways) |
| `/contacts rename <jid> [name...]` | set the name of a contact, or clear it |
| `/contacts groups <jid> [groups...]` | set the groups (comma separated), or clear them |
| `/contacts requests` | contacts asking to see your presence |
| `/contacts accept <jid>` | allow a contact to see your presence (and ask to see theirs) |
| `/contacts deny <jid>` | refuse a request, or stop sharing your presence |

## Calls

Audio and video calls with contacts, compatible with other clients (Conversations, Monal, Dino, Gajim, Movim: Jingle
RTP with WebRTC). The audio and video run in a separate program, `norc-rtc` (see [Installation](installation));
without it, calls are not available.

A call to a contact whose client supports it is proposed by message (Jingle Message Initiation, as Conversations,
Monal and Dino do): all clients of the contact ring (also on a phone in the background), the one answering gets the
call, the others stop ringing. Calls of these clients ring in norc the same way; answered or declined on another of
your clients, the call stops ringing in norc. Without resource (`/call alice`) all clients of the contact ring, with
one (`/call alice@example.org/phone`) only this one.

| Command | Description |
|---|---|
| `/call <jid> [options...]` | call a contact (audio); options: `video`, `audio`, `send` or `receive` (only one direction, for all media), `record` (see [Recording calls](#recording-calls)), and a file to play instead of your microphone, and of your camera if it has video and the call too (any format GStreamer plays, `~/` is the home directory; also a named pipe, see below); without resource a client of the contact supporting calls. The options can also come before the jid (`/call video alice`), e.g. for an alias: `alias.videocall = call video` |
| `/call accept [#id] [options...]` | accept a call (the only one, if no number is given); options: `audio` (accept a video call without video), `send` or `receive` (only one direction), `record`, a file to play |
| `/call decline [#id]` | decline a call |
| `/call hangup [#id]` | end a call, or cancel it while it rings |
| `/call mute [audio\|video]` | mute or unmute your audio (or video) |
| `/call record [#id] [on\|off]` | record the call, or stop recording it (without `on` or `off`: switched) |
| `/calls` | the calls and their state (ringing, calling, connecting, connected) |
| `/calls hangup` | end all calls (ringing calls are declined) |
| `/calls devices` | list the microphones, speakers and cameras for calls: names for `call_microphone`, `call_speaker`, `call_camera` |

```
/call alice video receive        watch alice's camera (and listen), send nothing
/call video alice                the same as /call alice video
/call alice send ~/song.ogg      play a file to alice, hear nothing back
/call accept 1 audio             accept a video call without video
/call cam video receive record   watch and record a camera
/call alice video ~/clip.webm    show alice a video (its sound instead of your microphone)
```

A file without video in a video call sends your camera, a file without audio your microphone. A named pipe
plays a live stream, e.g. of another program (in a format with a container: Matroska, WebM, Ogg, MPEG-TS):

```sh
mkfifo /tmp/stream
ffmpeg -nostdin -i rtsp://camera.local/stream -c:v libvpx -deadline realtime -c:a libopus -f matroska /tmp/stream &
norc ctl call alice video /tmp/stream
```

The other side can only narrow the directions: a call to receive can only be accepted to send.

```
#1 alice is calling (audio): /call accept 1 or /call decline 1
/call accept
#1 call with alice connected
/call hangup
#1 call with alice ended: hung up after 2:13
```

One call at a time: other callers get `busy`. Only contacts can call you, as the connection reveals your address.
In chat mode, `/call` calls the contact of the chat. `call_helper` sets the program and its options, e.g. other audio
devices: `call_helper = norc-rtc --audio-source "pipewiresrc target-object=…"` (see `norc-rtc --help`).

### Recording calls

Off unless `call_recording = 1` is in the config. `record` (an option of `/call` and `/call accept`) or `/call record`
during the call then writes the call into a file in
`call_record_dir` (default `~/.local/share/norc/calls/`): `<contact>-<date>-<time>.webm`, which plays in players and
browsers. It has both voices mixed into one audio track, the video of the other side and your own video (as received
and sent, not encoded again). The recording starts two seconds after the connection (with the media flowing then),
and ends with `/call record off` or the end of the call.

```
/call alice video record
#1 recording audio, video, own video into ~/.local/share/norc/calls/alice@example.org-2026-10-16-170342.webm
/call hangup
#1 recording saved: ~/.local/share/norc/calls/alice@example.org-2026-10-16-170342.webm
```

The other side is not told that you record: in many countries recording a call without the consent of the other
side is illegal. The `recording` event (hook `on-recording`) has the file, e.g. to move or convert it.

## Rooms (group chats)

| Command | Description |
|---|---|
| `/rooms` | list the rooms you are in, with your nick, the number of occupants and the subject |
| `/rooms find [service]` | list the public rooms of the chat service of your server (or of another service, e.g. `conference.example.org`), with their occupants and descriptions |
| `/rooms leave` | leave all rooms |
| `/bookmarks` | list the bookmarked rooms: stored on the server, shared with your other clients |
| `/bookmarks add <jid> [nick]` | bookmark a room (with autojoin): joined after each login, also by your other clients; default the nick you have in it |
| `/bookmarks autojoin <jid> <on\|off>` | join a bookmarked room after the login, or not: the bookmark is kept (also for your other clients) |
| `/bookmarks remove <jid>` (`rm`) | remove the bookmark of a room (the room is not left) |
| `/room join <room> [nick]` | join a room: its jid (`room@conference.example.org`), or its name on the chat service of your server (`/room join norc`); the nick defaults to the local part of your jid |
| `/room leave <jid>` | leave a room |
| `/room occupants <jid>` (`who`) | list the occupants of a room |
| `/room subject <jid> [text...]` | show or set the subject of a room |
| `/room config <jid> [field=value...]` | show the configuration form of a room (as its owner), or change it: e.g. `roomname="My Room" persistentroom=yes membersonly=yes` (the end of a field name is enough if unique; other settings are kept) |
| `/room nick <jid> <nick>` | change your nick in a room |
| `/room invite <jid> <contact> [reason...]` | invite a contact to a room |
| `/room moderate <jid> [^n] [reason...]` | as moderator: remove the last message of the others in a room for everyone (`^2`: the one before it, …), the reason is shown to the occupants; needs a room with message ids and moderation (Prosody: `mod_muc_mam`, `mod_muc_moderation`) |

A room can be given by its jid, or by its local part (`norc`) if you are in only one room with that name.
In room mode, occupants entering and leaving the room are shown (`norc alice entered`, `norc alice left`,
`norc alice is now alicia`). Joining a room on the terminal starts the group chat mode (see [Running norc](running)): lines without `/`
go to the room, and its commands work without `/room` and the jid: `/subject`, `/who`, `/nick tester`, `/invite bob`,
`/leave` (there `/nick` changes your nick in the room, not your published nickname); `/chat <room>` or `/room join <room>` returns to a joined room (Tab completes the rooms you are in). Leaving
the room ends it. Messages to a room go to all its occupants, also `/msg norc@conference.example.org hi`.
Rooms with a bookmark marked autojoin (also bookmarked by your other clients, e.g. Conversations or Dino) are
joined after the login, and when another client adds such a bookmark. Creating a room: join a room that doesn't exist yet (it is removed when the last occupant leaves, unless made
persistent: `/room config myroom persistentroom=yes`). Finding rooms:
`/rooms find` lists the public rooms of your server, `/rooms find <service>` those of another chat service. Room messages are shown as
`12:03:41 norc <alice> hi`. After a reconnect, norc joins the rooms again. Invitations are shown with the command to
join the room.

## Blocking

| Command | Description |
|---|---|
| `/block` | list blocked jids |
| `/block add <jid>` | block a jid, contact or domain: the server drops everything from it, for all your clients |
| `/block remove [jid]` | unblock a jid, or all without jid |

Needs server support (XEP-0191, Prosody: `mod_blocklist`).

<!-- disabled for now
## Shared documents

Shared documents are the transport of shared editing in [norc.nvim](https://github.com/tong/norc.nvim). Each document
is a PubSub node whose items arrive in the same order at every subscriber. norc only carries the items; their payloads
are text (JSON) of the editor.

| Command | Description |
|---|---|
| `/share` | the open nodes |
| `/share create <node> [jids...]` | create a node: only you and the jids may read and publish |
| `/share open <node> [service]` | subscribe: the reply has the items in order, then `share` events follow for new ones, without gap or duplicate |
| `/share close <node>` | unsubscribe |
| `/share publish <node> <payload...>` | publish an item with a new id (payloads up to 200 KiB) |
| `/share put <node> <id> <payload...>` | publish an item with an id, replacing it (e.g. a snapshot) |
| `/share add <node> <jid>` | let a jid read and publish (owner) |
| `/share remove <node> <jid>` | remove a jid and end its subscriptions (owner) |
| `/share members <node>` | affiliations and subscriptions (owner) |
| `/share invite <jid> <node> [name]` | invite a contact (a message, other clients show its text) |
| `/share delete <node>` | delete the node, for all (owner) |

The service is `share_service`, or the PubSub service of your server (Prosody: `Component "pubsub.example.org" "pubsub"`).
Nodes are subscribed with the full jid, so your other clients get nothing.
-->

## Service discovery

| Command | Description |
|---|---|
| `/server` | what your server offers: message archive (MAM), personal eventing (PEP: tunes, moods, nicknames, avatars, bookmarks), blocking, HTTP file upload, message carbons; asked after the login. Commands needing what it doesn't offer are marked in `/help` (`not on your server`) and refused with an error |
| `/disco info [jid] [node]` | identities and features of an entity (default: your server) |
| `/disco items [jid] [node]` | items of an entity, e.g. the services of your server |
| `/lastactivity [jid]` | uptime of a server (default: yours), how long ago an account was online (if its server supports it), or the idle time of a client |
| `/software [jid]` | software, version and operating system of a client or server (default: yours); for a contact without resource, of each of its online clients |

Note: a bare jid (`alice@example.org`) is answered by her server on behalf of the account. To see what a client
supports, query its full jid (`alice@example.org/phone`).

## Publish-subscribe nodes

What your account and your clients publish (personal eventing, PEP): avatar, nickname, tune, mood, bookmarks, the
keys of encryption (OMEMO), …; also the nodes of a contact or of a pubsub service (`pubsub.example.org`). The
service is the last argument, without it your own account.

| Command | Description |
|---|---|
| `/pubsub nodes [service]` | the nodes: who can read them (for your own: the access model, `open` is anybody), their number of items, what they are for |
| `/pubsub items <node> [service]` | the items of a node (at most 50, shortened on the terminal; complete in the data of the API) |
| `/pubsub config <node> [service] [field=value...]` | the configuration of a node (as its owner), or change it (short names work: `access_model=presence`) |
| `/pubsub publish <node> [service] <xml...>` | publish an item: `<item id="…">payload</item>`, or the payload alone (the service gives it an id) |
| `/pubsub access <node> [service]` | who may read or publish (as owner): owner, publishers, members (may read a `whitelist` node), outcasts |
| `/pubsub access <node> <jid> <affiliation> [service]` | change it: `owner`, `publisher`, `publish-only`, `member`, `none`, `outcast` |
| `/pubsub subscribers <node> [service]` | the subscribers (as owner); your PEP nodes have none: clients of contacts get them through your presence |
| `/pubsub subscribers <node> <jid> none\|subscribed [service]` | end a subscription (a full jid: of one client), or approve a pending one |
| `/pubsub retract <node> <id> [service]` | delete an item |
| `/pubsub purge <node> [service]` | delete all items of a node |
| `/pubsub delete <node> [service]` | delete a node with its items |

Nodes your other clients rely on (bookmarks, OMEMO devices and keys, OpenPGP keys, avatar, profile, displayed
sync) of your own account are deleted, purged, retracted from or changed only with `--force` at the end: e.g. the
keys of a device you no longer use, `/pubsub delete eu.siacs.conversations.axolotl.bundles:1234 --force`.

```
/pubsub nodes                                  your nodes and who can read them
/pubsub config http://jabber.org/protocol/tune access_model=roster
/pubsub access mynode alice@example.org member pubsub.example.org   alice may read the whitelist node
echo '<entry xmlns="urn:example">hi</entry>' | norc ctl -s pubsub publish urn:example
```
