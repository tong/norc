## Install

The latest release, on Linux (x86-64, arm64) and macOS (Apple silicon), into `~/.local/bin` (as root `/usr/local/bin`):

```sh
curl -fsSL https://raw.githubusercontent.com/tong/norc/main/install.sh | sh
curl -fsSL https://raw.githubusercontent.com/tong/norc/main/install.sh | sh -s -- --version v0.7.1 --dir ~/bin
```

On Windows, in PowerShell, into `%LOCALAPPDATA%\Programs\norc` (its `bin` added to your `PATH`):

```powershell
irm https://raw.githubusercontent.com/tong/norc/main/install.ps1 | iex
```

Both download the archive of the [release](https://github.com/tong/norc/releases), verify it with its checksums
(`SHA256SUMS`) and install `norc` and `norc-rtc` (calls); running them again updates norc. `install.sh` also
installs the completion of zsh and bash (those installed) next to the programs, e.g.
`~/.local/share/zsh/site-functions/_norc` (it says if that is not in zsh's `$fpath`) and
`~/.local/share/bash-completion/completions/norc` (loaded by bash-completion); `--no-completion` skips it. `NORC_VERSION` and
`NORC_INSTALL_DIR` choose the release and the directory. On Linux and macOS, norc-rtc uses the GStreamer of the
system: the script tells what to install if it is missing (see [Calls](#calls-norc-rtc)); the Windows archive
brings its own.

## Build

norc is written in [haxe](https://haxe.org) and runs on [hashlink](https://hashlink.haxe.org).
It needs the haxelibs [hxmpp](https://github.com/tong/hxmpp), [sasl](https://github.com/tong/hxsasl) and
[hxomemo](https://github.com/tong/hxomemo) (OMEMO).

```sh
git clone --recursive https://github.com/tong/norc
cd norc
make            # norc.hl: HashLink bytecode, run with `hl norc.hl`
make norc       # norc: single binary (Linux: static with musl, needs musl-gcc)
make install    # /usr/local/bin/norc (PREFIX=~/.local for your user)
make omemo.hdll # OMEMO for norc.hl (the binary has it built in): found by hl in the current directory
```

`norc.hl` starts without `omemo.hdll`, OMEMO (`omemo = 1`) is off then. To use it from anywhere, install it next to
HashLink's libraries: `make -C $(haxelib libpath hxomemo) install HASHLINK_SRC=$PWD/lib/hashlink` (`/usr/local/lib`).

`make norc` needs the `hashlink` haxelib (for hashlink/C code), from the submodule:
`haxelib dev hashlink lib/hashlink/other/haxelib`.
It compiles HashLink from the submodule `lib/hashlink` into the binary (`HASHLINK_SRC` to use another
checkout). `make install-completion` installs the zsh or bash completion of your login shell
(`COMPLETION="zsh bash"` for others).

The version (`norc --version`) comes from git: the tag of the commit (e.g. `v0.1.0` → `0.1.0`), else
the last tag with the commits since it, the commit and uncommitted changes as semver build metadata
(`0.1.0+5.g885f830.dirty`).
Without git, set it with `-D norc_version=0.1.0` (and `norc_tag`, `norc_commit`, `norc_date`, `norc_dirty`).

Release binaries for Linux (x86-64, arm64), macOS and Windows are built by the GitHub workflow `release`: one
archive per platform with `norc` and `norc-rtc` (calls, see below).

`norc.hl` only runs on x86/x86-64 (HashLink's JIT); on ARM, e.g. a Raspberry Pi, use the single binary.
To build it on a system without Haxe, generate the C code elsewhere (`make out`: also the C sources of hxomemo, in `out/hxomemo`), copy `out/`
and run `make from-c`.

## Calls: norc-rtc

The audio and video of calls run in a separate program, `norc-rtc` (C, with GStreamer). It needs GStreamer with
`webrtcbin`, libnice and json-glib.

* arch: `gst-plugins-bad gst-plugins-good libnice json-glib`
* debian/ubuntu: `libgstreamer-plugins-bad1.0-dev gstreamer1.0-plugins-bad gstreamer1.0-plugins-good gstreamer1.0-nice libjson-glib-dev`):

```sh
make norc-rtc       # then make install installs it next to norc
rtc/loopback.py     # test: two norc-rtc connected to each other (--real: your microphone and speaker)
```

norc finds it in `PATH`, or set `call_helper`. Without it, norc works as before, without calls.

The release archives contain `norc-rtc` next to `norc`; norc finds it there. On Linux and macOS it uses the GStreamer
of the system (the packages above, macOS: `brew install gstreamer libnice-gstreamer json-glib`); the Windows zip
contains everything, in a folder `norc` (`bin\` with `norc.exe`, `norc-rtc.exe` and the DLLs, `lib\` with the
GStreamer plugins): add `norc\bin` to `PATH`.

## Shell completion

zsh: [`extras/zsh/_norc`](https://github.com/tong/norc/blob/main/extras/zsh/_norc), bash: [`extras/bash/norc`](https://github.com/tong/norc/blob/main/extras/bash/norc), installed by
`make install-completion` (see the comments in the files for manual installation). The commands of `norc ctl` are
completed by the running norc (`norc complete`): its commands, aliases, contacts, rooms, and files of your current
directory.
