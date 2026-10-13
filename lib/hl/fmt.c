/*
	The part of HashLink's fmt.hdll that norc uses: `digest` (haxe.crypto.Md5, Sha1, Crc32, Adler32).

	Linking HashLink's libs/fmt/fmt.c would pull in png, jpeg and vorbis.
	md5 and sha1 come from mbedtls (linked for ssl), crc32 and adler32 from zlib.
*/
#define HL_NAME(n) fmt_##n
#include <hl.h>
#include <string.h>
#include <mbedtls/md5.h>
#include <mbedtls/sha1.h>
#include <zlib.h>

HL_PRIM void HL_NAME(digest)(vbyte *out, vbyte *in, int length, int format) {
	if (format & 256) {
		in = (vbyte *)hl_to_utf8((uchar *)in);
		length = (int)strlen((char *)in);
	}
	switch (format & 0xFF) {
	case 0:
		mbedtls_md5(in, length, out);
		break;
	case 1:
		mbedtls_sha1(in, length, out);
		break;
	case 2:
		*((int *)out) = crc32(*(int *)out, in, length);
		break;
	case 3:
		*((int *)out) = adler32(*(int *)out, in, length);
		break;
	default:
		hl_error("Unknown digest format %d", format & 0xFF);
		break;
	}
}
