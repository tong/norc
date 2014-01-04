
##
## norc-cra
##

TARGET = cra
DEBUG = true

SRC := Makefile $(shell find ../../src/norc/ src/norc/cra/*.hx -name *.hx -print)

JS = build/app.js
CSS = build/style/norc.css
CRX = norc-app.crx

CP = -cp src/ -cp ../../src/ -cp ../../../hxmpp/src -cp ../../../../lib/om/src
FLAGS = -lib chrome-app
ifeq (${DEBUG},true)
	FLAGS += -debug -D norc_debug -D xmpp_debug -D jabber_debug
else
	FLAGS += -dce full --no-traces
endif

HX = haxe $(CP) $(FLAGS)

all: build

$(CSS): res/norc.less
	@mkdir -p build/style
	lessc res/norc.less $@

css: $(CSS)

$(JS): $(SRC)
	@mkdir -p build
	$(HX) -js $@ -main norc.cra.App

js: $(JS)

build: css js
	@rsync res/app.html build
	@rsync res/background.js build
	@rsync res/manifest.json build
	@rsync -r res/icon build

$(CRX): build
	google-chrome --pack-extension=build/ --pack-extension-key=data/norc-cra.pem
	mv build.crx norc-app.crx

crx: $(CRX)

clean:
	rm -rf build/
	rm -f $(CRX)

.PHONY: all build css js crx clean
