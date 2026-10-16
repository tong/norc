These commands open their own short connection, separate from a running norc.

```sh
norc account register me@example.org --save    # create the account, write its config
norc account passwd me                          # change the password
norc account unregister me --purge              # delete the account on the server and locally
norc account list                               # configured accounts (and running instances)
```

| Command | Description |
|---|---|
| `register <jid>` | create the account on the server (in-band registration, if the server allows it); `--save` writes the account config (name: `-a`, default: the jid) |
| `unregister [jid]` | delete the account on the server; asks for confirmation (`--yes` skips it); `--purge` also removes the account config and local state |
| `passwd [jid]` | change the password |
| `list` | configured accounts |

`unregister` and `passwd` refuse to run while a norc process uses the account.
