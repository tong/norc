
##
## Norc:sys
##

DEBUG=true
SRC := $(shell find ../../src/norc/ src/norc/sys/*.hx -name *.hx -print)
CP = -cp src \
	 -cp ../../src/ \
	 -cp ../../../hxmpp/src \
	 -cp ../../../om/src
LIBS = -lib hxargs
FLAGS = -D xmpp_debug -D jabber_debug -D norc_debug

ifeq (${DEBUG},true)
	FLAGS += -debug
else
	FLAGS += -dce full
	FLAGS += --no-traces
endif

HX = haxe -main norc.sys.App $(CP) $(FLAGS) $(LIBS)

all: build

build/norc.n: $(SRC)
	@mkdir -p build
	$(HX) -neko build/norc.n

build: build/norc.n
	@mkdir -p build
	rsync data/creds.json build
	
clean:
	rm -rf build/norc.n

.PHONY: all build clean
