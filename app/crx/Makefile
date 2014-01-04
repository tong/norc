
##
## norc-crx
##

TARGET = crx
DEBUG = true

SRC := Makefile $(shell find ../../src/norc/ -name *.hx -print)

JS = build/norc.js
CSS = build/style/norc.css
CRX = norc-ext.crx

CP = -cp src -cp ../../src/ -cp ../../../hxmpp/src -cp ../../../om/src
FLAGS = -lib chrome-extension
ifeq (${DEBUG},true)
	FLAGS += -debug -D norc_debug -D xmpp_debug -D jabber_debug
else
	FLAGS += -dce full --no-traces
endif

HX = haxe $(CP) $(FLAGS)

all: build

$(JS): $(SRC)
	@mkdir -p build
	$(HX) -js $@ -main norc.crx.App

js: $(JS)

build: js
	@mkdir -p build
	@rsync res/manifest.json build
	@rsync -r res/html build
	@rsync -r res/icon build

$(CRX): build
	google-chrome --pack-extension=build/ --pack-extension-key=build.pem
	mv build.crx norc-ext.crx

crx: $(CRX)

clean:
	rm -rf build
	rm -f $(CRX)

.PHONY: all build js crx clean