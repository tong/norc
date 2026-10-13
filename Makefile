# HashLink sources (git submodule), compiled into the single binary
HASHLINK_SRC ?= lib/hashlink
BUILD := build

PCRE := $(addprefix include/pcre/pcre2_,auto_possess chartables compile config context convert \
	dfa_match error extuni find_bracket jit_compile maketables match_data match newline ord2utf \
	pattern_info script_run serialize string_utils study substitute substring tables ucd valid_utf xclass)
LIBHL_SRC := $(PCRE) src/gc $(addprefix src/std/,array buffer bytes cast date error debug file fun \
	maps math obj random regexp socket string sys types ucs2 thread process track)

.PHONY: all clean install uninstall
all: norc.hl

# Rebuild when sources or build settings change
SRC := $(shell find src -name '*.hx') norc.hxml

# HashLink bytecode
norc.hl: build.hl.hxml $(SRC)
	haxe build.hl.hxml

# --- HashLink/C, single binary: ./norc ---------------------------------------------------------------
#
# The generated HashLink/C code is compiled together with everything it needs from HashLink's sources:
#   libhl     HashLink runtime
#   ssl.hdll  with the mbedtls sources bundled with HashLink (its SSL_STATIC build)
#   fmt.hdll  only `digest` is used: lib/hl/fmt.c (with mbedtls and HashLink's zlib)
#
# Linux:   fully static with musl (glibc can't resolve hostnames in static binaries)
# macOS:   links only system libraries and frameworks (macOS has no static libc)
# Windows: MSYS2 MinGW64, links only system DLLs

UNAME := $(shell uname -s)
STATIC_CFLAGS := -O2 -ffunction-sections -fdata-sections -DLIBHL_STATIC -I$(HASHLINK_SRC)/src
ifeq ($(UNAME),Darwin)
STATIC_CC ?= clang
STATIC_LDFLAGS := -Wl,-dead_strip
STATIC_LIBS := -lm -lpthread -framework Security -framework CoreFoundation
else ifneq ($(findstring MINGW,$(UNAME)),)
EXE := .exe
STATIC_CC ?= gcc
STATIC_CFLAGS += -municode
STATIC_LDFLAGS := -static -municode -Wl,--gc-sections
STATIC_LIBS := -lws2_32 -lwsock32 -ldbghelp -lcrypt32 -lbcrypt -lm
else
STATIC_CC ?= musl-gcc
# musl has no backtrace(): stub execinfo.h
STATIC_CFLAGS += -Ilib/musl
STATIC_LDFLAGS := -static -Wl,--gc-sections
STATIC_LIBS := -lm -lpthread
endif

STATIC := $(BUILD)/static
BIN := norc$(EXE)

LIBHL_OBJ := $(addprefix $(STATIC)/libhl/,$(addsuffix .o,$(LIBHL_SRC)))
LIBHL_CFLAGS := -std=c11 -DPCRE2_CODE_UNIT_WIDTH=16 -DPCRE2_STATIC -DHAVE_CONFIG_H -I$(HASHLINK_SRC)/include/pcre

MBEDTLS_INC := -I$(HASHLINK_SRC)/libs/ssl -I$(HASHLINK_SRC)/include/mbedtls/include \
	-DMBEDTLS_USER_CONFIG_FILE=\"mbedtls_user_config.h\"
MBEDTLS_SRC := $(patsubst $(HASHLINK_SRC)/%.c,%,$(wildcard $(HASHLINK_SRC)/include/mbedtls/library/*.c))
SSL_OBJ := $(addprefix $(STATIC)/ssl/,$(addsuffix .o,libs/ssl/ssl $(MBEDTLS_SRC)))

ZLIB_OBJ := $(addprefix $(STATIC)/zlib/,$(addsuffix .o,include/zlib/crc32 include/zlib/adler32))
FMT_OBJ := $(STATIC)/lib/hl/fmt.o $(ZLIB_OBJ)

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

$(STATIC)/lib/hl/fmt.o: lib/hl/fmt.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) $(MBEDTLS_INC) -I$(HASHLINK_SRC)/include/zlib -c $< -o $@

$(STATIC)/out/%.o: out/%.c
	@mkdir -p $(dir $@)
	$(STATIC_CC) $(STATIC_CFLAGS) -std=c11 -DHL_MAKE -Iout $(MBEDTLS_INC) -c $< -o $@

$(STATIC)/$(BIN): $(OUT_OBJ) $(SSL_OBJ) $(FMT_OBJ) $(LIBHL_OBJ)
	$(STATIC_CC) $(STATIC_LDFLAGS) -o $@ $^ $(STATIC_LIBS)

# haxe only rewrites generated files whose content changed: track the last run with a stamp
$(STATIC)/hlc.stamp: build.hlc.hxml $(SRC)
	haxe build.hlc.hxml
	@mkdir -p $(dir $@)
	@touch $@

$(BIN): $(STATIC)/hlc.stamp | $(HASHLINK_SRC)/src/hl.h
	$(MAKE) $(STATIC)/$(BIN)
	cp $(STATIC)/$(BIN) $(BIN)
	strip $(BIN)

$(HASHLINK_SRC)/src/hl.h:
	@echo "HashLink sources not found in $(HASHLINK_SRC): run 'git submodule update --init' (or set HASHLINK_SRC)" >&2
	@exit 1

ifneq ($(EXE),)
.PHONY: norc
norc: $(BIN)
endif

# --- Install (Linux): `make install`, `sudo make install`, `make install PREFIX=~/.local` ---------------
#
# Installs the single binary, and the zsh completion if zsh is the login shell ($SHELL; override with
# ZSH_COMPLETION=yes or no). DESTDIR is prepended to all paths (packaging).

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
ZSH_COMPLETION_DIR ?= $(PREFIX)/share/zsh/site-functions
ZSH_COMPLETION ?= auto

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/norc
	@if [ "$(ZSH_COMPLETION)" = yes ] || { [ "$(ZSH_COMPLETION)" = auto ] && [ "$${SHELL##*/}" = zsh ]; }; then \
		echo install -Dm644 extras/zsh/_norc $(DESTDIR)$(ZSH_COMPLETION_DIR)/_norc; \
		install -Dm644 extras/zsh/_norc $(DESTDIR)$(ZSH_COMPLETION_DIR)/_norc; \
	fi

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/norc
	rm -f $(DESTDIR)$(ZSH_COMPLETION_DIR)/_norc

clean:
	rm -rf $(BUILD) out norc.hl $(BIN)
