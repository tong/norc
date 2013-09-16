
##
## NORC - Network Organism Responsible for Communication
##

all: cra crx sys web

cra:
	@(cd app/cra;make)

crx:
	@(cd app/crx;make)

ffos:
	@(cd app/ffos;make)

googlescript:
	@(cd app/googlescript;make)

sys:
	@(cd app/sys;make)

web:
	@(cd app/web;make)

#android:
	
clean:
	@(cd app/crx;make clean)
	@(cd app/cra;make clean)
	@(cd app/sys;make clean)
	@(cd app/web;make clean)

.PHONY: all clean
