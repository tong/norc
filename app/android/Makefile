
##
## norc-android
##

TARGET = android
RELEASE = false

SRC := Makefile $(shell find ../../src/norc/ src/norc/android/*.hx -name *.hx -print)

JAR = build/norc.jar

CP = -cp src \
	 -cp ../../src/ \
	 -cp ../../../hxmpp/src \
	 -cp ../../../om/src
FLAGS = -lib hxargs -D android

ifeq (${RELEASE},true)
	FLAGS += -dce full --no-traces
else
	FLAGS += -debug -D xmpp_debug -D jabber_debug -D norc_debug
endif

all: build

$(JAR): $(SRC)
	haxe -java build norc.android.XMPPClient $(CP) $(FLAGS)
	mv build/build.jar $@

jar: $(JAR)

build: jar

clean:
	rm -rf build

.PHONY: all build jar clean
