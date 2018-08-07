module libLZHAM.compression;

import libLZHAM.common;
import libLZHAM.base;

@nogc public LZHAMCompressionStatus* compressInit(LZHAMCompressionParameters* params){
	
}
@nogc public LZHAMCompressionStatus* compressReinit(LZHAMCompressionStatus* state){
	
}
@nogc public uint compressDeinit(LZHAMCompressionStatus* state){
	
}
@nogc public LZHAMCompressionStatus compress(LZHAMCompressionStatus* state, const ubyte* inBuf, size_t inBufSize, ubyte* outBuf, size_t outBufSize, bool noMoreInputBytesFlag){
	
}
@nogc public LZHAMCompressionStatus compress2(LZHAMCompressionStatus* state, const ubyte* inBuf, size_t inBufSize, ubyte* outBuf, size_t outBufSize, LZHAMFlushTypes flushType){
	
}
@nogc public LZHAMCompressionStatus compressMem(LZHAMCompressionStatus* state, ubyte* destBuf, size_t destSize, const ubyte srcDuf, size_t srcSize, uint* pAdler32){
	
}
@nogc public int z_deflateInit(LZHAMZStream* pStream, int level){

}
@nogc public int z_deflateInit2(LZHAMZStream* pStream, int level, int method, int window_bits, int mem_level, int strategy){
	
}
@nogc public int z_deflateReset(LZHAMZStream* pStream){
	
}
@nogc public int z_deflate(LZHAMZStream* pStream, int flush){
	
}
@nogc public int z_deflateEnd(LZHAMZStream* pStream){
	
}
@nogc public ulong z_deflateBound(LZHAMZStream* pStream, ulong source_len){
	
}
@nogc public int z_compress(ubyte* pDest, ulong pDest_len, const ubyte* pSource, ulong pSource_len){
	
}
@nogc public int z_compress2(ubyte* pDest, ulong pDest_len, const ubyte* pSource, ulong pSource_len, int level) {
	
}
@nogc public ulong z_compressBound(ulong source_len) {
	
}

/*class LZCompressor : LZbase{
	
}*/

struct LZHAMCompressState{
	// task_pool requires 8 or 16 alignment
	//task_pool mTp; // replaced by D's own parallelization library
	LZCompressor mCompressor;
	uint mDictSizeLog2;
	const ubyte* mPInBuf;
	size_t* mPInBufSize;
	ubyte* mPOutBuf;
	size_t* mPOutBufSize;

	size_t mCompDataOfs;

	bool mFinishedCompression;
	LZHAMCompressionParameters mParams;
	LZHAMCompressionStatus mStatus;
}