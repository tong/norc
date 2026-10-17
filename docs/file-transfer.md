Files are sent with Jingle file transfer (XEP-0234), over a direct connection or your server's proxy
(SOCKS5 bytestreams), falling back to in-band bytestreams through the server.

| Command | Description |
|---|---|
| `/file send <jid> <path...>` | send a file; without resource to the first online client of the contact supporting file transfer |
| `/file accept [#id] [path...]` | accept a file offer (the only one, if no number is given), save it to `path` (a file or directory) or the download directory |
| `/file decline [#id]` | decline a file offer |
| `/file abort [#id]` | abort a file transfer: sending, receiving (nothing is saved), your file being read before it is offered, or your offer not accepted yet; an offer to you is declined. The other side sees it as cancelled (the `file-failed` event, reason `aborted`, theirs `cancel`) |
| `/file transfers` | list pending file offers, your files being read before they are offered (with progress), and active transfers |
| `/file shared` | your shared directories (`share.<name>`), their files, who may download them (`share_access`), see [Sharing files](#sharing-files) |
| `/file browse <jid> [path...]` | the files a contact shares: their directories, or those of `path` (e.g. `music/album`) |
| `/file get <jid> <path> [target...]` | download a file a contact shares (its path as `/file browse` lists it), to `target` (a file or directory) or the download directory |
| `/file upload <path...>` | upload a file to the upload service of your server (HTTP File Upload), prints its URL |
| `/file share <jid> <path...>` | upload a file and send its URL to a contact: works when they are offline, and with clients without Jingle; shown as attachment by most clients |
| `/file show [url]` | show an image shared in a message (the last one without URL), e.g. one not loaded automatically, see `inline_images` |

```
/file send alice@example.org ~/photos/holiday.jpg
#1 alice@example.org/phone offers report.pdf (1.2 MB): /file accept 1 or /file decline 1
/file accept 1 ~/Documents
```

Received files never overwrite existing ones (`name (1).ext`). Files of any size: they are read
and written as they are transferred, not kept in memory. A file sent is read once before it is offered, for its size
and hash (a few seconds for large files); a file received is written to `<name>.part`, renamed once its hash is
verified (removed if the transfer fails). A direct connection shows your local address to the peer.

## Sharing files

Directories you share can be browsed and downloaded by your contacts, while norc runs (File Information Sharing,
XEP-0329): in the config, `share.<name> = <directory>` for each, and who may see them:

```
share.music = ~/Music
share.papers = ~/Documents/papers
share_access = roster            # contacts seeing your presence (the default)
# share_access = group:Friends, bob@example.org
```

Contacts see the shares by their name (`music/album/song.ogg`), only the files in them: hidden files and links
pointing outside are not listed and can't be requested, nor paths with `..`. The sha-256 of the files is computed
after the login, in the background (kept in the state dir, `shares.json`): listings have it, and the downloader
verifies the file with it. A download is a Jingle file request, listed in `/file transfers` on both sides and ended
with `/file abort`.

```
/file browse bob
  music/
  papers/
/file browse bob music/album
  music/album/01 intro.ogg  4.2 MB  2026-09-30
/file get bob "music/album/01 intro.ogg" ~/Music/
#2 downloading 01 intro.ogg (4.2 MB) from bob@example.org/laptop → ~/Music/01 intro.ogg
```

XEP-0329 is rare in other clients: browsing and downloading work between norc and clients implementing it.

## Images in messages

Images shared in messages (`/file share`, and the attachments of other clients: a message with out of band data whose
text is its URL) are shown after the message in terminals showing images (kitty graphics protocol): PNG as it is,
JPEG, GIF and WebP if ImageMagick (`magick`) is installed. They are downloaded into `~/.cache/norc/images/`, at most
5 MB. Downloading reveals your address to the server of the file: by default only images of contacts (and your own)
are loaded, see `inline_images`; `/file show` loads one anyway.
