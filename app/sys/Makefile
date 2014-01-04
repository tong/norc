
##
## NORC-sys
##

TARGET = sys
RELEASE = false

BIN = build/norc.n
SRC := Makefile $(shell find ../../src/norc/ src/norc/sys/*.hx -name *.hx -print)
CP = -cp src \
	 -cp ../../src/ \
	 -cp ../../../hxmpp/src \
	 -cp ../../../om/src
LIBS = -lib hxargs -lib hxssl
FLAGS =

ifeq (${RELEASE},true)
	FLAGS += -dce full --no-traces
else
	FLAGS += -debug -D xmpp_debug -D jabber_debug -D norc_debug -D hxmpp_debug
endif

HX = haxe -neko build/norc.n -main norc.sys.App $(CP) $(FLAGS) $(LIBS)

all: build

$(BIN): $(SRC)
	@mkdir -p build
	$(HX)

build: $(BIN)
	@mkdir -p build

clean:
	rm -rf build

.PHONY: all build clean
