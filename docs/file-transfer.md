Files are sent with Jingle file transfer (XEP-0234), over a direct connection or your server's proxy
(SOCKS5 bytestreams), falling back to in-band bytestreams through the server.

| Command | Description |
|---|---|
| `/file send <jid> <path...>` | send a file; without resource to the first online client of the contact supporting file transfer |
| `/file accept [#id] [path...]` | accept a file offer (the only one, if no number is given), save it to `path` (a file or directory) or the download directory |
| `/file decline [#id]` | decline a file offer |
| `/file abort [#id]` | abort a file transfer: sending, receiving (nothing is saved), or your offer not accepted yet; an offer to you is declined. The other side sees it as cancelled (the `file-failed` event, reason `aborted`, theirs `cancel`) |
| `/file transfers` | list pending file offers and active transfers |
| `/file upload <path...>` | upload a file to the upload service of your server (HTTP File Upload), prints its URL |
| `/file share <jid> <path...>` | upload a file and send its URL to a contact: works when they are offline, and with clients without Jingle; shown as attachment by most clients |
| `/file show [url]` | show an image shared in a message (the last one without URL), e.g. one not loaded automatically, see `inline_images` |

```
/file send alice@example.org ~/photos/holiday.jpg
#1 alice@example.org/phone offers report.pdf (1.2 MB): /file accept 1 or /file decline 1
/file accept 1 ~/Documents
```

Received files never overwrite existing ones (`name (1).ext`). Files are kept in memory during the transfer,
the size is limited to 100 MB. A direct connection shows your local address to the peer.

## Images in messages

Images shared in messages (`/file share`, and the attachments of other clients: a message with out of band data whose
text is its URL) are shown after the message in terminals showing images (kitty graphics protocol): PNG as it is,
JPEG, GIF and WebP if ImageMagick (`magick`) is installed. They are downloaded into `~/.cache/norc/images/`, at most
5 MB. Downloading reveals your address to the server of the file: by default only images of contacts (and your own)
are loaded, see `inline_images`; `/file show` loads one anyway.
