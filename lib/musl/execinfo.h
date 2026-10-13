/*
	Stub for musl, which has no backtrace() (glibc only).
	Used by HashLink's hlc_main.c for exception stack traces; with musl they are empty.
*/
#ifndef NORC_EXECINFO_H
#define NORC_EXECINFO_H

static inline int backtrace(void **buffer, int size) {
	(void)buffer;
	(void)size;
	return 0;
}

static inline char **backtrace_symbols(void *const *buffer, int size) {
	(void)buffer;
	(void)size;
	return 0;
}

#endif
