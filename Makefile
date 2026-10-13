HASHLINK_SRC ?= $(HOME)/src/hashlink
BUILD := build

PCRE := $(addprefix include/pcre/pcre2_,auto_possess chartables compile config context convert \
	dfa_match error extuni find_bracket jit_compile maketables match_data match newline ord2utf \
	pattern_info script_run serialize string_utils study substitute substring tables ucd valid_utf xclass)
LIBHL_SRC := $(PCRE) src/gc $(addprefix src/std/,array buffer bytes cast date error debug file fun \
	maps math obj random regexp socket string sys types ucs2 thread process track)
LIBHL_OBJ := $(addprefix $(BUILD)/libhl/,$(addsuffix .o,$(LIBHL_SRC)))
LIBHL_CFLAGS := -O2 -std=c11 -DLIBHL_STATIC -DPCRE2_CODE_UNIT_WIDTH=16 -DPCRE2_STATIC -DHAVE_CONFIG_H \
	-I$(HASHLINK_SRC)/include/pcre -I$(HASHLINK_SRC)/src

.PHONY: all hl hlc static clean
all: hl

# HashLink bytecode: ./norc.hl
hl:
	haxe build.hl.hxml

# HashLink/C: ./norc (haxe generates out/ and runs its Makefile)
hlc:
	haxe build.hlc.hxml
	cp out/main norc

$(BUILD)/libhl/%.o: $(HASHLINK_SRC)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(LIBHL_CFLAGS) -c $< -o $@

$(BUILD)/libhl.a: $(LIBHL_OBJ)
	$(AR) rcs $@ $^

# Fully static binary (experimental): only links once the used hdlls (ssl) are built statically too
static: hlc $(BUILD)/libhl.a
	$(MAKE) -C out EXTRA_CFLAGS=-DLIBHL_STATIC
	cd out && $(CC) -static @objects.txt -o ../norc-static -L../$(BUILD) -lhl -lm -lpthread
	strip norc-static

clean:
	rm -rf $(BUILD) out norc.hl norc norc-static
