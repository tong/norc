
##
## Norc-crx
##

TARGET = crx
RELEASE = false

JS_EXT = build/norc.js
JS_POPUP = build/popup.js
JS_SETTINGS = build/settings.js
CSS = build/style/norc.css
CRX = norc-ext.crx
SRC := Makefile $(shell find ../../src/norc/ -name *.hx -print)

CP = -cp src -cp ../../src/ -cp ../../../hxmpp/src -cp ../../../om/src
FLAGS = -lib chrome-extension
ifeq (${RELEASE},true)
	FLAGS += -dce full --no-traces
else
	FLAGS += -debug -D norc_debug -D xmpp_debug -D jabber_debug
endif

HX = haxe $(CP) $(FLAGS)

all: build


$(JS_SETTINGS): $(SRC)
	@mkdir -p build
	$(HX) -js $@ -main norc.crx.ExtensionSettings

js_settings: $(JS_SETTINGS)

$(JS_POPUP): $(SRC)
	@mkdir -p build
	$(HX) -js $@ -main norc.crx.ExtensionPopup

js_popup: $(JS_POPUP)

$(JS_EXT): $(SRC)
	@mkdir -p build
	$(HX) -js $@ -main norc.crx.Extension

js_ext: $(JS_EXT)

build: js_ext js_settings js_popup
	@mkdir -p build
	rsync res/manifest.json build
	rsync -r res/*.html build
	rsync -r res/icon build
	lessc res/norc.less build/norc.css

$(CRX): build
	google-chrome --pack-extension=build/ --pack-extension-key=build.pem
	mv build.crx norc-ext.crx

crx: $(CRX)

clean:
	rm -rf build
	rm -f $(CRX)

.PHONY: all build js crx clean