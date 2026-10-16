// Tells which NBA Jam TE rev 2.1 romset a zip holds, from the CRC32 of its uj12 program ROM as
// stored in the zip's central directory (no decompression needed). Shared by the iOS and Windows
// launchers (windows/romcheck.h is a copy).
#pragma once
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

enum { ROMSET_UNREADABLE = -1, ROMSET_UNKNOWN = 0, ROMSET_REWIND = 1, ROMSET_REWIND_BLEEP = 2, ROMSET_UNPATCHED = 3 };

static inline uint32_t zip_rd32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static inline uint32_t zip_rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }

static inline int romset_variant(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) return ROMSET_UNREADABLE;
	fseek(f, 0, SEEK_END); long size = ftell(f);
	long tail = size < 66000 ? size : 66000;                  // end of central directory + max comment
	uint8_t *buf = (uint8_t *)malloc(tail);
	fseek(f, size - tail, SEEK_SET);
	if (!buf || fread(buf, 1, tail, f) != (size_t)tail) { free(buf); fclose(f); return ROMSET_UNREADABLE; }
	long eocd = -1;
	for (long i = tail - 22; i >= 0; i--) if (zip_rd32(buf + i) == 0x06054b50) { eocd = i; break; }
	int result = ROMSET_UNKNOWN;
	if (eocd >= 0) {
		uint32_t cdSize = zip_rd32(buf + eocd + 12), cdOff = zip_rd32(buf + eocd + 16);
		uint8_t *cd = (uint8_t *)malloc(cdSize ? cdSize : 1);
		fseek(f, cdOff, SEEK_SET);
		if (cd && fread(cd, 1, cdSize, f) == cdSize) {
			for (uint32_t p = 0; p + 46 <= cdSize && zip_rd32(cd + p) == 0x02014b50; ) {
				uint32_t crc = zip_rd32(cd + p + 16), nl = zip_rd16(cd + p + 28), xl = zip_rd16(cd + p + 30), cl = zip_rd16(cd + p + 32);
				const char *name = (const char *)cd + p + 46;
				if (nl >= 5 && p + 46 + nl <= cdSize && !memcmp(name + nl - 5, ".uj12", 5)) {
					if (crc == 0x9b3fc483) result = ROMSET_REWIND;
					else if (crc == 0x383cd3ec) result = ROMSET_REWIND_BLEEP;
					else if (crc == 0xd009aa29) result = ROMSET_UNPATCHED;
					break;
				}
				p += 46 + nl + xl + cl;
			}
		}
		free(cd);
	}
	free(buf); fclose(f);
	return result;
}
