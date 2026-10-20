# HashLink sources (git submodule), compiled into the single binary
HASHLINK_SRC ?= lib/hashlink
BUILD := build

PCRE := $(addprefix include/pcre/pcre2_,auto_possess chartables compile config context convert \
	dfa_match error extuni find_bracket jit_compile maketables match_data match newline ord2utf \
	pattern_info script_run serialize string_utils study substitute substring tables ucd valid_utf xclass)
LIBHL_SRC := $(PCRE) src/gc $(addprefix src/std/,array buffer bytes cast date error debug file fun \
	maps math obj random regexp socket string sys types ucs2 thread process track)

.PHONY: all build from-c clean install install-completion uninstall omemo.hdll
all: build

# Rebuild when sources or build settings change
SRC := $(shell find src -name '*.hx') norc.hxml
# and when the haxelibs change (e.g. git/dev libraries)
LIB_SRC := $(foreach lib,hxmpp sasl hxomemo,$(shell haxelib libpath $(lib) 2>/dev/null))
SRC += $(shell find $(addsuffix src,$(LIB_SRC)) -name '*.hx' 2>/dev/null)
# and when the git version changes (norc.Version): build/version is rewritten only if it differs
GIT_VERSION := $(shell git describe --tags --always --dirty 2>/dev/null)
$(shell mkdir -p $(BUILD) && [ "$$(cat $(BUILD)/version 2>/dev/null)" = "$(GIT_VERSION)" ] || echo "$(GIT_VERSION)" > $(BUILD)/version)
SRC += $(BUILD)/version
# and when the default config changes (embedded, norc.Defaults)
SRC += $(shell find config -type f 2>/dev/null)

# HashLink bytecode
norc.hl: build.hl.hxml $(SRC)
	haxe build.hl.hxml

# OMEMO for the bytecode (hl norc.hl): hxomemo's natives, found by hl in the current directory (or install it
# with hxomemo's `make install`)
omemo.hdll:
	$(MAKE) -C $(HXOMEMO) omemo.hdll HASHLINK_SRC=$(abspath $(HASHLINK_SRC))
	cp $(HXOMEMO)omemo.hdll $@

# --- HashLink/C, single binary: ./norc ---------------------------------------------------------------
#
# The generated HashLink/C code is compiled together with everything it needs from HashLink's sources:
#   libhl     HashLink runtime
#   ssl.hdll  with the mbedtls sources bundled with HashLink (its SSL_STATIC build)
#   fmt.hdll  only `digest` is used: lib/hl/fmt.c (with mbedtls and HashLink's zlib)
#   unix.c    norc's natives: Unix sockets (lib/hl/unix.c)
#   omemo.c   the natives of hxomemo (OMEMO): Monocypher, and the mbedtls above
#
# Linux:   fully static with musl (glibc can't resolve hostnames in static binaries)
# macOS:   links only system libraries and frameworks (macOS has no static libc); ARCHS="arm64 x86_64": a universal
#          binary (`make clean` before changing it)
# Windows: MSYS2 (UCRT64), links only system DLLs

UNAME := $(shell uname -s)
STATIC_CFLAGS := -O2 -ffunction-sections -fdata-sections -DLIBHL_STATIC -I$(HASHLINK_SRC)/src
ifeq ($(UNAME),Darwin)
STATIC_CC ?= clang
STATIC_LDFLAGS := -Wl,-dead_strip
STATIC_LIBS := -lm -lpthread -framework Security -framework CoreFoundation
ARCHS ?=
STATIC_CFLAGS += $(addprefix -arch ,$(ARCHS))
STATIC_LDFLAGS += $(addprefix -arch ,$(ARCHS))
else ifeq ($(OS),Windows_NT)
EXE := .exe
STATIC_CC ?= gcc
STATIC_CFLAGS += -municode
STATIC_LDFLAGS := -static -municode -Wl,--gc-sections
STATIC_LIBS := -lws2_32 -lwsock32 -ldbghelp -lcrypt32 -lbcrypt -lwinmm -lm
else
STATIC_CC ?= musl-gcc
# musl has no backtrace(): stub execinfo.h
STATIC_CFLAGS += -Ilib/musl
STATIC_LDFLAGS := -static -Wl,--gc-sections
STATIC_LIBS := -lm -lpthread
endif

STATIC := $(BUILD)/static
BIN := norc$(EXE)

# The C files (hundreds) compiled in parallel: by default on half of the CPUs (at least one), unless make got -j
CPUS := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
JOBS ?= $(shell echo $$(( ($(CPUS) + 1) / 2 )))
PARALLEL := $(if $(filter -j%,$(MAKEFLAGS)),,-j$(JOBS))

LIBHL_OBJ := $(addprefix $(STATIC)/libhl/,$(addsuffix .o,$(LIBHL_SRC)))
LIBHL_CFLAGS := -std=c11 -DPCRE2_CODE_UNIT_WIDTH=16 -DPCRE2_STATIC -DHAVE_CONFIG_H -I$(HASHLINK_SRC)/include/pcre

MBEDTLS_INC := -I$(HASHLINK_SRC)/libs/ssl -I$(HASHLINK_SRC)/include/mbedtls/include \
	-DMBEDTLS_USER_CONFIG_FILE=\"mbedtls_user_config.h\"
MBEDTLS_SRC := $(patsubst $(HASHLINK_SRC)/%.c,%,$(wildcard $(HASHLINK_SRC)/include/mbedtls/library/*.c))
SSL_OBJ := $(addprefix $(STATIC)/ssl/,$(addsuffix .o,libs/ssl/ssl $(MBEDTLS_SRC)))

ZLIB_OBJ := $(addprefix $(STATIC)/zlib/,$(addsuffix .o,include/zlib/crc32 include/zlib/adler32))
FMT_OBJ := $(STATIC)/lib/hl/fmt.o $(ZLIB_OBJ)

# norc's own natives: Unix sockets of the socket interface (norc.UnixSocket, -D norc_unix in build.hlc.hxml)
NORC_OBJ := $(STATIC)/lib/hl/unix.o

# the natives of hxomemo (omemo.Crypto, -D norc_omemo): its C sources, copied to out/hxomemo with the generated code,
# so `make from-c` builds without haxelib
HXOMEMO := $(shell haxelib libpath hxomemo 2>/dev/null)
OMEMO_OBJ := $(addprefix $(STATIC)/omemo/,omemo.o monocypher.o monocypher-ed25519.o)

# Generated code: the files listed in out/hlc.json (out/ may contain stale files of removed classes).
# Only known once out/ exists, so the link runs in a sub-make
OUT_OBJ := $(addprefix $(STATIC)/out/,$(patsubst %.c,%.o,$(shell grep -o '"[^"]*\.c"' out/hlc.json 2>/dev/null | tr -d '"')))

$(STATIC)/libhl/%.o: $(HASHLINK_SRC)/%.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) $(LIBHL_CFLAGS) -c $< -o $@

$(STATIC)/ssl/%.o: $(HASHLINK_SRC)/%.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) $(MBEDTLS_INC) -c $< -o $@

$(STATIC)/zlib/%.o: $(HASHLINK_SRC)/%.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) -c $< -o $@

$(STATIC)/lib/hl/unix.o: lib/hl/unix.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) -c $< -o $@

$(STATIC)/omemo/omemo.o: out/hxomemo/omemo.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) $(MBEDTLS_INC) -c $< -o $@

$(STATIC)/omemo/%.o: out/hxomemo/monocypher/%.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) -c $< -o $@

$(STATIC)/lib/hl/fmt.o: lib/hl/fmt.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) $(MBEDTLS_INC) -I$(HASHLINK_SRC)/include/zlib -c $< -o $@

# with the headers it includes as dependencies (.d): haxe rewrites only the files that changed, a changed class
# (e.g. a new field) must recompile the files using it
$(STATIC)/out/%.o: out/%.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) -std=c11 -DHL_MAKE -Iout $(MBEDTLS_INC) -MMD -MP -c $< -o $@

-include $(OUT_OBJ:.o=.d)

$(STATIC)/$(BIN): $(OUT_OBJ) $(SSL_OBJ) $(FMT_OBJ) $(NORC_OBJ) $(OMEMO_OBJ) $(LIBHL_OBJ)
	$(STATIC_CC) $(STATIC_LDFLAGS) -o $@ $^ $(STATIC_LIBS)

# haxe only rewrites generated files whose content changed: track the last run with a stamp
$(STATIC)/hlc.stamp: build.hlc.hxml $(SRC) $(wildcard $(HXOMEMO)native/*.c $(HXOMEMO)native/monocypher/*)
	haxe build.hlc.hxml
	@test -n "$(HXOMEMO)" || { echo "the haxelib hxomemo is missing" >&2; exit 1; }
	rm -rf out/hxomemo
	cp -R $(HXOMEMO)native out/hxomemo
	@mkdir -p $(dir $@)
	@touch $@

# The generated C code only (out/), e.g. for `make from-c` on another system
.PHONY: out
out: $(STATIC)/hlc.stamp

$(BIN): $(STATIC)/hlc.stamp | $(HASHLINK_SRC)/src/hl.h
	$(MAKE) $(PARALLEL) $(STATIC)/$(BIN)
	cp $(STATIC)/$(BIN) $(BIN)
	strip $(BIN)

$(HASHLINK_SRC)/src/hl.h:
	@echo "HashLink sources not found in $(HASHLINK_SRC): run 'git submodule update --init' (or set HASHLINK_SRC)" >&2
	@exit 1

ifneq ($(EXE),)
.PHONY: norc
norc: $(BIN)
endif

# The single binary (same as `make norc`)
build: $(BIN)

# The single binary from C code generated before (out/, e.g. on another machine), without haxe:
# for building on systems without haxe (e.g. arm64)
from-c: | $(HASHLINK_SRC)/src/hl.h
	@test -f out/hlc.json -a -f out/hxomemo/omemo.c || { echo "no generated C code in out/: run 'make out' first" >&2; exit 1; }
	$(MAKE) $(PARALLEL) $(STATIC)/$(BIN)
	cp $(STATIC)/$(BIN) $(BIN)
	strip $(BIN)

# --- norc-rtc: the media of calls (GStreamer webrtcbin), a separate program -----------------------------------
#
# Needs GStreamer with webrtcbin (gst-plugins-bad), libnice, opus and vpx, and json-glib.
# Test it without XMPP: rtc/loopback.py [--video] [--real]

RTC_PKGS := gstreamer-1.0 gstreamer-webrtc-1.0 gstreamer-sdp-1.0 json-glib-1.0
RTC_CFLAGS ?= -O2 -Wall

# a plain target name (for completion): norc-rtc, on Windows also for norc-rtc.exe
ifeq ($(EXE),)
norc-rtc: rtc/norc-rtc.c
	$(CC) $(RTC_CFLAGS) -o $@ $< $$(pkg-config --cflags --libs $(RTC_PKGS))
else
norc-rtc$(EXE): rtc/norc-rtc.c
	$(CC) $(RTC_CFLAGS) -o $@ $< $$(pkg-config --cflags --libs $(RTC_PKGS))

.PHONY: norc-rtc
norc-rtc: norc-rtc$(EXE)
endif

# --- Install (Linux): `make install`, `sudo make install`, `make install PREFIX=~/.local` ---------------
#
# Installs the single binary, and norc-rtc if it was built (`make norc-rtc`). `make install-completion` installs
# the shell completion: for the login shell ($SHELL) if it is zsh or bash, or for the shells in COMPLETION
# (e.g. COMPLETION="zsh bash").
# DESTDIR is prepended to all paths (packaging).

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
ZSH_COMPLETION_DIR ?= $(PREFIX)/share/zsh/site-functions
BASH_COMPLETION_DIR ?= $(PREFIX)/share/bash-completion/completions

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/norc
	@if [ -f norc-rtc$(EXE) ]; then echo install -Dm755 norc-rtc$(EXE) $(DESTDIR)$(BINDIR)/norc-rtc; \
		install -Dm755 norc-rtc$(EXE) $(DESTDIR)$(BINDIR)/norc-rtc; fi

install-completion:
	@for sh in $${COMPLETION:-$${SHELL##*/}}; do \
		case $$sh in \
		zsh) set -- extras/zsh/_norc $(DESTDIR)$(ZSH_COMPLETION_DIR)/_norc ;; \
		bash) set -- extras/bash/norc $(DESTDIR)$(BASH_COMPLETION_DIR)/norc ;; \
		*) echo "no completion for $$sh: set COMPLETION=zsh or bash" >&2; exit 1 ;; \
		esac; \
		echo install -Dm644 $$1 $$2; install -Dm644 $$1 $$2 || exit 1; \
	done

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/norc $(DESTDIR)$(BINDIR)/norc-rtc
	rm -f $(DESTDIR)$(ZSH_COMPLETION_DIR)/_norc
	rm -f $(DESTDIR)$(BASH_COMPLETION_DIR)/norc

clean:
	rm -rf $(BUILD) out norc.hl $(BIN) norc-rtc$(EXE)
