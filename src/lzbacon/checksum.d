module lzbacon.checksum;

import lzbacon.common;

import lzbacon.system;

import std.digest.crc;

/*static if(USE_INTEL_INTRINSICS){
	import inteli.emmintrin;
}*/

enum{ 
	ADLER_MOD = 65521
}

/**
 * Heavily modified and slow. Original one used some form of not real vectorization, so I had to do something
 */
@nogc uint adler32(ubyte* pBuf, size_t buflen, uint adlr32 = 1u){
	ulong a, b;
	while(buflen){
		a += *pBuf;
		b += a;
		pBuf++;
		buflen--;
	}
	a = a % ADLER_MOD;
	b = b % ADLER_MOD;
	return cast(uint)((b << 16) | a);
}
/**
 * Replaced with std.digest.crc
 */
ubyte[] crc32(uint crc, ubyte* ptr, size_t buf_len){
	import std.digest.crc;
	CRC32 c32;
	scope const ubyte[] data = ptrToArray(ptr, buf_len);
	c32.put(data);
	c32.start;
	ubyte[] result = c32.finish();
	return result; 
}