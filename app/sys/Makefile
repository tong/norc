
##
## Norc:sys
##

SRC := $(shell find ../../src/norc/ -name *.hx -print)
CP = -cp src \
	 -cp ../../src/ \
	 -cp ../../../hxmpp/src \
	 -cp ../../../om/src
LIBS = -lib hxargs
FLAGS = -D norc_debug -D xmpp_debug

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

clean:
	rm -rf build/norc.n

.PHONY: all build clean
