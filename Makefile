HASHLINK_SRC ?= $(HOME)/src/hashlink
BUILD := build

PCRE := $(addprefix include/pcre/pcre2_,auto_possess chartables compile config context convert \
	dfa_match error extuni find_bracket jit_compile maketables match_data match newline ord2utf \
	pattern_info script_run serialize string_utils study substitute substring tables ucd valid_utf xclass)
LIBHL_SRC := $(PCRE) src/gc $(addprefix src/std/,array buffer bytes cast date error debug file fun \
	maps math obj random regexp socket string sys types ucs2 thread process track)

.PHONY: all clean
all: norc.hl

# Rebuild when sources or build settings change
SRC := $(shell find src -name '*.hx') norc.hxml

# HashLink bytecode
norc.hl: build.hl.hxml $(SRC)
	haxe build.hl.hxml

# --- HashLink/C, fully static binary: ./norc ------------------------------------------------------------
#
# Everything is compiled with musl (glibc can't resolve hostnames in static binaries) from source:
#   out/      the generated HashLink/C code
#   libhl     HashLink runtime
#   ssl.hdll  with the mbedtls sources bundled with HashLink (its SSL_STATIC build)
#   fmt.hdll  only `digest` is used; unused functions (png, jpeg, vorbis, …) are dropped by --gc-sections

MUSL_CC ?= musl-gcc
STATIC := $(BUILD)/static
STATIC_CFLAGS := -O2 -ffunction-sections -fdata-sections -DLIBHL_STATIC -I$(HASHLINK_SRC)/src

LIBHL_OBJ := $(addprefix $(STATIC)/libhl/,$(addsuffix .o,$(LIBHL_SRC)))
LIBHL_CFLAGS := -std=c11 -DPCRE2_CODE_UNIT_WIDTH=16 -DPCRE2_STATIC -DHAVE_CONFIG_H -I$(HASHLINK_SRC)/include/pcre

MBEDTLS_INC := -I$(HASHLINK_SRC)/libs/ssl -I$(HASHLINK_SRC)/include/mbedtls/include \
	-DMBEDTLS_USER_CONFIG_FILE=\"mbedtls_user_config.h\"
MBEDTLS_SRC := $(patsubst $(HASHLINK_SRC)/%.c,%,$(wildcard $(HASHLINK_SRC)/include/mbedtls/library/*.c))
SSL_OBJ := $(addprefix $(STATIC)/ssl/,$(addsuffix .o,libs/ssl/ssl $(MBEDTLS_SRC)))

FMT_OBJ := $(addprefix $(STATIC)/fmt/,$(addsuffix .o,libs/fmt/fmt libs/fmt/sha1 include/zlib/crc32 include/zlib/adler32))
# fmt.c includes png/jpeg/vorbis headers for functions that are never linked: take them from the system
FMT_CFLAGS := -I$(HASHLINK_SRC)/libs/fmt -I$(HASHLINK_SRC)/include/zlib -I$(HASHLINK_SRC)/include/minimp3 -idirafter /usr/include

# Generated code: listed in out/objects.txt (written by out/Makefile, which haxe runs), which also
# leaves out stale files of removed classes. Only known once out/ exists, so the link runs in a sub-make
OUT_OBJ := $(addprefix $(STATIC)/out/,$(shell cat out/objects.txt 2>/dev/null))

$(STATIC)/libhl/%.o: $(HASHLINK_SRC)/%.c
	@mkdir -p $(dir $@)
	$(MUSL_CC) $(STATIC_CFLAGS) $(LIBHL_CFLAGS) -c $< -o $@

$(STATIC)/ssl/%.o: $(HASHLINK_SRC)/%.c
	@mkdir -p $(dir $@)
	$(MUSL_CC) $(STATIC_CFLAGS) $(MBEDTLS_INC) -c $< -o $@

$(STATIC)/fmt/%.o: $(HASHLINK_SRC)/%.c
	@mkdir -p $(dir $@)
	$(MUSL_CC) $(STATIC_CFLAGS) $(FMT_CFLAGS) -c $< -o $@

$(STATIC)/out/%.o: out/%.c
	@mkdir -p $(dir $@)
	$(MUSL_CC) $(STATIC_CFLAGS) -std=c11 -DHL_MAKE -Iout -Ilib/musl $(MBEDTLS_INC) -c $< -o $@

$(STATIC)/norc: $(OUT_OBJ) $(SSL_OBJ) $(FMT_OBJ) $(LIBHL_OBJ)
	$(MUSL_CC) -static -Wl,--gc-sections -o $@ $^ -lm -lpthread

norc: build.hlc.hxml $(SRC)
	haxe build.hlc.hxml
	$(MAKE) $(STATIC)/norc
	cp $(STATIC)/norc norc
	strip norc

clean:
	rm -rf $(BUILD) out norc.hl norc
