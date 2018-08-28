module lzbacon.compression;

import lzbacon.common;
import lzbacon.base;
import lzbacon.compInternal;

public LZHAMCompressionStatus* compressInit(LZHAMCompressionParameters* params){
	
}
public LZHAMCompressionStatus* compressReinit(LZHAMCompressionStatus* state){
	
}
public uint compressDeinit(LZHAMCompressionStatus* state){
	
}
public LZHAMCompressionStatus compress(LZHAMCompressionStatus* state, const ubyte* inBuf, size_t inBufSize, ubyte* outBuf, size_t outBufSize, bool noMoreInputBytesFlag){
	
}
public LZHAMCompressionStatus compress2(LZHAMCompressionStatus* state, const ubyte* inBuf, size_t inBufSize, ubyte* outBuf, size_t outBufSize, LZHAMFlushTypes flushType){
	
}
public LZHAMCompressionStatus compressMem(LZHAMCompressionStatus* state, ubyte* destBuf, size_t destSize, const ubyte srcDuf, size_t srcSize, uint* pAdler32){
	
}
public int z_deflateInit(LZHAMZStream* pStream, int level){

}
public int z_deflateInit2(LZHAMZStream* pStream, int level, int method, int window_bits, int mem_level, int strategy){
	
}
public int z_deflateReset(LZHAMZStream* pStream){
	
}
public int z_deflate(LZHAMZStream* pStream, int flush){
	
}
public int z_deflateEnd(LZHAMZStream* pStream){
	
}
public ulong z_deflateBound(LZHAMZStream* pStream, ulong source_len){
	
}
public int z_compress(ubyte* pDest, ulong pDest_len, const ubyte* pSource, ulong pSource_len){
	
}
public int z_compress2(ubyte* pDest, ulong pDest_len, const ubyte* pSource, ulong pSource_len, int level) {
	
}
public ulong z_compressBound(ulong source_len) {
	
}

/*class LZCompressor : LZbase{
	
}*/

struct LZHAMCompressState{
	// task_pool requires 8 or 16 alignment
	//task_pool mTp; // replaced by D's own parallelization library
	LZCompressor compressor;
	uint dictSizeLog2;
	const ubyte* inBuf;
	size_t* inBufSize;
	ubyte* outBuf;
	size_t* outBufSize;

	size_t compDataOfs;

	bool finishedCompression;
	LZHAMCompressionParameters params;
	LZHAMCompressionStatus status;
}