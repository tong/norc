
##
## NORC
##

all: documentation build

release:
	@make -C app/sys release --no-print-directory

#documentation:

build: android cra crx fos sys web

android:
	@make -C app/android --no-print-directory

cra:
	@make -C app/cra --no-print-directory

crx:
	@make -C app/crx --no-print-directory

fos:
	@make -C app/fos --no-print-directory

#googlescript:
#	@(cd app/googlescript;make)

sys:
	@make -C app/sys --no-print-directory

web:
	@make -C app/web --no-print-directory

clean:
	@make -C app/android clean --no-print-directory
	@make -C app/cra clean --no-print-directory
	@make -C app/crx clean --no-print-directory
	@make -C app/fos clean --no-print-directory
	@make -C app/gs clean --no-print-directory
	@make -C app/sys clean --no-print-directory
	@make -C app/web clean --no-print-directory

.PHONY: all build cra crx fos sys web clean
