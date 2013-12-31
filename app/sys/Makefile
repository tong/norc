
##
## NORC-sys
##

RELEASE = false
TARGET = sys
CP = -cp src \
	 -cp ../../src/ \
	 -cp ../../../hxmpp/src \
	 -cp ../../../om/src
LIBS = -lib hxargs
FLAGS =

ifeq (${RELEASE},true)
	FLAGS += -dce full --no-traces
else
	FLAGS += -debug -D xmpp_debug -D jabber_debug -D norc_debug
endif

HX = haxe -main norc.sys.App $(CP) $(FLAGS) $(LIBS)

SRC := $(shell find ../../src/norc/ src/norc/sys/*.hx -name *.hx -print)

all: build

build/norc.n: $(SRC)
	@mkdir -p build
	$(HX) -neko build/norc.n

build: build/norc.n
	@mkdir -p build
	rsync res/creds.json build
	
clean:
	rm -rf build/norc.n

.PHONY: all build clean
