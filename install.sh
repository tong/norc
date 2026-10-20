#!/bin/sh
#
# Installs norc (and norc-rtc, for calls) from the GitHub releases, on Linux (x86_64, arm64) and macOS (universal):
#
#   curl -fsSL https://raw.githubusercontent.com/tong/norc/main/install.sh | sh
#
# Options (or the environment variables):
#   --version <tag>   NORC_VERSION       a release, e.g. v0.7.1 (default: the latest)
#   --dir <dir>       NORC_INSTALL_DIR   where to put the programs (default: ~/.local/bin, as root /usr/local/bin)
#   --no-completion   NORC_COMPLETION=0  no shell completion (else for zsh and bash, those installed: in
#                                        <dir>/../share/zsh/site-functions and …/bash-completion/completions)
#
#   curl -fsSL https://raw.githubusercontent.com/tong/norc/main/install.sh | sh -s -- --version v0.7.1
#
# The archive is verified with the checksums of the release (SHA256SUMS). Running it again updates norc; a norc
# running meanwhile keeps running (the file is replaced, not overwritten).
# Windows: install.ps1 (PowerShell).

set -eu

repo=tong/norc
version=${NORC_VERSION:-}
dir=${NORC_INSTALL_DIR:-}
completion=${NORC_COMPLETION:-1}

say() { printf '%s\n' "$@"; }
fail() {
  printf 'norc install: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case $1 in
  --version)
    [ $# -ge 2 ] || fail "--version needs a value"
    version=$2
    shift 2
    ;;
  --version=*)
    version=${1#*=}
    shift
    ;;
  --dir)
    [ $# -ge 2 ] || fail "--dir needs a value"
    dir=$2
    shift 2
    ;;
  --dir=*)
    dir=${1#*=}
    shift
    ;;
  --no-completion)
    completion=0
    shift
    ;;
  -h | --help)
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0" 2>/dev/null || say "see https://github.com/$repo"
    exit 0
    ;;
  *) fail "unknown option: $1 (--version <tag>, --dir <dir>, --no-completion)" ;;
  esac
done

# downloads: curl or wget
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --proto '=https' -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q --https-only -O "$2" "$1"; }
else
  fail "needs curl or wget"
fi

# the target of the release archives
os=$(uname -s)
arch=$(uname -m)
case $os in
Linux) os=linux ;;
Darwin) os=macos ;;
MINGW* | MSYS* | CYGWIN*)
  fail "on Windows use PowerShell: irm https://raw.githubusercontent.com/$repo/main/install.ps1 | iex"
  ;;
*) fail "no release for $os: build it from the sources (https://github.com/$repo)" ;;
esac
case $arch in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "no release for $os on $arch: build it from the sources (https://github.com/$repo)" ;;
esac

# the latest release: where github.com/<repo>/releases/latest redirects to (no API, no rate limit)
if [ -z "$version" ]; then
  if command -v curl >/dev/null 2>&1; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") || url=
    version=${url##*/tag/}
    [ "$version" != "$url" ] || version=
  else
    version=$(wget -qO- "https://api.github.com/repos/$repo/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  fi
  [ -n "$version" ] || fail "cannot find the latest release of $repo"
fi
case $version in v*) ;; *) version=v$version ;; esac

if [ -z "$dir" ]; then
  if [ "$(id -u)" = 0 ]; then dir=/usr/local/bin; else dir=$HOME/.local/bin; fi
fi

base=https://github.com/$repo/releases/download/$version
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || fail "cannot download the checksums of $version (no such release?)"

# the archive: in the checksums of the release; macOS: universal, releases before it only for Apple silicon (arm64)
name=
for target in $([ $os = macos ] && echo universal) $arch; do
  grep -q " norc-$version-$os-$target.tar.gz\$" "$tmp/SHA256SUMS" && { name=norc-$version-$os-$target.tar.gz; break; }
done
[ -n "$name" ] || fail "no release $version for $os on $arch: build it from the sources (https://github.com/$repo)"

say "norc $version ($os-$arch) → $dir"
fetch "$base/$name" "$tmp/$name" || fail "cannot download $base/$name"

# verified with the checksums of the release
expected=$(grep " $name\$" "$tmp/SHA256SUMS" | cut -d ' ' -f 1)
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$name" | cut -d ' ' -f 1)
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$tmp/$name" | cut -d ' ' -f 1)
else
  fail "needs sha256sum or shasum to verify the download"
fi
[ "$actual" = "$expected" ] || fail "checksum mismatch of $name: the download is damaged or was changed"

mkdir -p "$tmp/x"
tar -xzf "$tmp/$name" -C "$tmp/x"
mkdir -p "$dir" || fail "cannot create $dir (as root: sudo sh, or --dir)"
for f in norc norc-rtc; do
  [ -f "$tmp/x/$f" ] || continue
  # next to it and renamed: a running norc keeps its file ("text file busy" otherwise)
  cp "$tmp/x/$f" "$dir/.$f.new" || fail "cannot write to $dir (as root: sudo sh, or --dir)"
  chmod 755 "$dir/.$f.new"
  mv -f "$dir/.$f.new" "$dir/$f"
done

say "installed: $("$dir/norc" --version 2>/dev/null || echo "$dir/norc")"

# the completion of zsh and bash (those installed), next to the programs: <prefix>/share/… for <prefix>/bin, else
# ~/.local/share (as root /usr/local/share); from the archive, or (older releases) the sources of the release
if [ "$completion" != 0 ]; then
  case $dir in
  */bin) share=${dir%/bin}/share ;;
  *) if [ "$(id -u)" = 0 ]; then share=/usr/local/share; else share=${XDG_DATA_HOME:-$HOME/.local/share}; fi ;;
  esac
  for sh in zsh bash; do
    command -v $sh >/dev/null 2>&1 || continue
    case $sh in
    zsh) src=extras/zsh/_norc target=$share/zsh/site-functions/_norc ;;
    bash) src=extras/bash/norc target=$share/bash-completion/completions/norc ;;
    esac
    if [ ! -f "$tmp/x/$src" ]; then
      mkdir -p "$tmp/x/${src%/*}"
      fetch "https://raw.githubusercontent.com/$repo/$version/$src" "$tmp/x/$src" 2>/dev/null || {
        say "no $sh completion for $version"
        continue
      }
    fi
    mkdir -p "${target%/*}" && cp "$tmp/x/$src" "$target" || {
      say "cannot write $target"
      continue
    }
    say "$sh completion: $target"
    # zsh finds it only in a directory of $fpath (bash-completion looks in ~/.local/share and /usr/local/share)
    if [ $sh = zsh ] && ! zsh -c 'print -rl -- $fpath' 2>/dev/null | grep -qx "${target%/*}"; then
      say "  not in zsh's \$fpath: add to ~/.zshrc, before compinit:" "    fpath=(${target%/*} \$fpath)"
    fi
  done
fi

case ":$PATH:" in
*":$dir:"*) ;;
*) say "" "$dir is not in your PATH: add it to your shell's config, e.g.:" "  export PATH=\"$dir:\$PATH\"" ;;
esac

# norc-rtc (calls) uses the GStreamer of the system
if [ -f "$dir/norc-rtc" ] && ! "$dir/norc-rtc" --help >/dev/null 2>&1; then
  say "" "norc-rtc (for calls) needs GStreamer with webrtcbin, libnice, opus, vpx and json-glib:"
  case $os in
  macos) say "  brew install gstreamer json-glib" ;;
  linux)
    if command -v pacman >/dev/null 2>&1; then
      say "  sudo pacman -S gst-plugins-good gst-plugins-bad libnice json-glib"
    elif command -v apt-get >/dev/null 2>&1; then
      say "  sudo apt install gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-nice libjson-glib-1.0-0"
    elif command -v dnf >/dev/null 2>&1; then
      say "  sudo dnf install gstreamer1-plugins-good gstreamer1-plugins-bad-free libnice-gstreamer1 json-glib"
    else
      say "  (the GStreamer packages of your distribution)"
    fi
    ;;
  esac
  say "  norc works without it, only calls need it."
fi

say "" "next: norc account register <jid> --save (a new account), or create ~/.config/norc/accounts/<name> with jid = …;" \
  "then run norc. Docs: https://github.com/$repo"
