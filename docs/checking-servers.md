`norc check <domain...>` connects to servers directly, without an account, and reports what they offer before the
login: TLS, login mechanisms, stream features, and whether they allow in-band registration. The registration form
is requested, nothing is registered. Service discovery is tried too, though most servers only answer it after the login.

```sh
norc check conversations.im 404.city
norc check --json $(cat servers.txt) > servers.jsonl     # one JSON object per server and line
jq -r 'select(.registration == "open" or .registration == "captcha") | .domain' servers.jsonl
```

| `registration` | Meaning |
|---|---|
| `open` | in-band registration is open (`registrationFields`: the fields asked for) |
| `captcha` | open, with a CAPTCHA to solve |
| `web` | registration on a website (`url`) |
| `closed` | the server doesn't allow registration (`registrationError`) |
| `unsupported` | the server has no in-band registration |
| `unknown` | none of these |

Servers are checked one after another, each at most `--timeout` seconds (default 20); `--port` sets another port.
`error` is set if a server couldn't be reached (or has no TLS). Exit code `1` if any server failed.
