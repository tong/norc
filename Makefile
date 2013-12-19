
##
## NORC - Network Organism Responsible for Communication
##

### cra crx ffos sys web

all: sys

cra:
	@(cd app/cra;make)

crx:
	@(cd app/crx;make)

ffos:
	@(cd app/ffos;make)

#googlescript:
#	@(cd app/googlescript;make)

sys:
	@make -C app/sys --no-print-directory

web:
	@(cd app/web;make)

#android:
	
clean:
	@(cd app/crx;make clean)
	@(cd app/cra;make clean)
	@(cd app/sys;make clean)
	@(cd app/web;make clean)

.PHONY: all clean
