module lzbacon.decompression;

import lzbacon.decompbase;
import lzbacon.common;
import lzbacon.huffmanCodes;
import lzbacon.symbolCodec;
import lzbacon.prefixCoding;
import lzbacon.system;
public import lzbacon.exceptions;
import lzbacon.checksum;

import core.stdc.stdlib;
import core.stdc.string;
import core.thread;

import std.bitmanip;

static const ubyte[24] sLiteralNextState =
[
	0, 0, 0, 0, 1, 2, 3, // 0-6: literal states
	4, 5, 6, 4, 5,       // 7-11: match states
	7, 7, 7, 7, 7, 7, 7, 10, 10, 10, 10, 10   // 12-23: unused
];
enum{
	LZHAM_CR_INITIAL_STATE = 0,
}
static const uint[4] sHugeMatchBaseLen = [ CLZDecompBase.cMaxMatchLen + 1, CLZDecompBase.cMaxMatchLen + 1 + 256, CLZDecompBase.cMaxMatchLen + 1 + 256 + 1024, CLZDecompBase.cMaxMatchLen + 1 + 256 + 1024 + 4096 ];
static const ubyte[4] sHugeMatchCodeLen = [ 8, 10, 12, 16 ];
/**
 * Decompression codec implementation.
 */
public class LZHAMDecompressor : Fiber{
	static if(CPU_64BIT_CAPABLE){
		static enum cBitBufSize = 64;
	}else{
		static enum cBitBufSize = 32;
	}
	int state2;
	
	CLZDecompBase lzBase;
	SymbolCodec codec;
	
	uint rawDecompBufSize;
	ubyte* rawDecompBuf;
	ubyte* decompBuf;
	uint decompAdler32;
	
	ubyte* inBuf;
	size_t* inBufSize;
	ubyte* outBuf;
	size_t* outBufSize;
	bool noMoreInputBytesFlag;
	
	ubyte* origOutBuf;
	size_t origOutBufSize;
	
	LZHAMDecompressionParameters params;

	LZHAMDecompressionStatus status;
	
	RawQuasiAdaptiveHuffmanDataModel litTable;
	RawQuasiAdaptiveHuffmanDataModel deltaLitTable;
	RawQuasiAdaptiveHuffmanDataModel mainTable;
	RawQuasiAdaptiveHuffmanDataModel[2] repLenTable;
	RawQuasiAdaptiveHuffmanDataModel[2] largeLenTable;
	RawQuasiAdaptiveHuffmanDataModel distLsbTable;
	
	AdaptiveBitModel[CLZDecompBase.cNumStates] isMatchModel;
	AdaptiveBitModel[CLZDecompBase.cNumStates] isRepModel;
	AdaptiveBitModel[CLZDecompBase.cNumStates] isRep0Model;
	AdaptiveBitModel[CLZDecompBase.cNumStates] isRep0SingleByteModel;
	AdaptiveBitModel[CLZDecompBase.cNumStates] isRep1Model;
	AdaptiveBitModel[CLZDecompBase.cNumStates] isRep2Model;
	
	uint dstOfs;
	uint dstHighwaterOfs;
	
	//uint m_step;
	//uint m_block_step;
	//uint m_initial_step;
	
	debug uint blockIndex;

	// most likely these will be removed
	int matchHist0;		///Currently unused, was used as a crude way to implement a coroutine. No longer needed thanks to Fiber
	int matchHist1;		///Currently unused, was used as a crude way to implement a coroutine. No longer needed thanks to Fiber
	int matchHist2;		///Currently unused, was used as a crude way to implement a coroutine. No longer needed thanks to Fiber
	int matchHist3;		///Currently unused, was used as a crude way to implement a coroutine. No longer needed thanks to Fiber
	uint curState;		///Currently unused, was used as a crude way to implement a coroutine. No longer needed thanks to Fiber
	
	uint startBlockDstOfs;
	
	uint blockType;
	
	ubyte* pFlushSrc;
	size_t flushNumBytesRemaining;
	size_t flushN;
	
	uint seedBytesToIgnoreWhenFlushing;
	
	uint fileSrcFileAdler32;
	
	uint repLit0;
	uint matchLen;
	uint matchSlot;
	uint extraBits;
	uint numExtraBits;
	
	uint srcOfs;
	ubyte* pCopySrc;
	uint numRawBytesRemaining;
	
	//uint m_debug_is_match;
	//uint m_debug_match_len;
	//uint m_debug_match_dist;
	//uint m_debug_lit;
	
	LZHAMDecompressionStatus lastStatus;	///Stores the last status the fiber have exited.
	uint m_z_first_call;
	uint m_z_has_flushed;
	uint m_z_cmf;
	uint m_z_flg;
	uint dictAdler32;
	
	uint m_tmp;
	
	public this(bool unbuffered){
		if(unbuffered)
			super(&decompress!true);
		else
			super(&decompress!false);
	}
	void init(){
		lzBase.initPositionSlots(params.dictSizeLog2);
		//state = LZHAM_CR_INITIAL_STATE;
		//m_step = 0;
		//m_block_step = 0;
		debug blockIndex = 0;
		//m_initial_step = 0;
		
		this.dstOfs = 0;
		dstHighwaterOfs = 0;
		
		inBuf = null;
		*inBufSize = 0;
		outBuf = null;
		*outBufSize = 0;
		noMoreInputBytesFlag = false;
		status = LZHAMDecompressionStatus.NOT_FINISHED;
		origOutBuf = null;
		origOutBufSize = 0;
		decompAdler32 = 1;
		seedBytesToIgnoreWhenFlushing = 0;
		
		lastStatus = LZHAMDecompressionStatus.NOT_FINISHED;
		m_z_first_call = 1;
		m_z_has_flushed = 0;
		m_z_cmf = 0;
		m_z_flg = 0;
		dictAdler32 = 0;
		
		m_tmp = 0;
		
		matchHist0 = 0;
		matchHist1 = 0;
		matchHist2 = 0;
		matchHist3 = 0;
		curState = 0;
		
		startBlockDstOfs = 0;
		blockType = 0;
		flushNumBytesRemaining = 0;
		flushN = 0;
		fileSrcFileAdler32 = 0;
		repLit0 = 0;
		matchLen = 0;
		matchSlot = 0;
		extraBits = 0;
		numExtraBits = 0;
		srcOfs = 0;
		pCopySrc = null;
		numRawBytesRemaining = 0;
		
		codec.clear();
	}
	/// ORIGINAL COMMENT
	/// Important: This function is a coroutine. ANY locals variables that need to be preserved across coroutine
	/// returns must be either be a member variable, or a local which is saved/restored to a member variable at
	/// the right times. (This makes this function difficult to follow and freaking ugly due to the macros of doom - but hey it works.)
	/// The most often used variables are in locals so the compiler hopefully puts them into CPU registers.
	/// END OF ORIGINAL COMMENT
	///
	/// I decided to use Fiber from core.thread for implementing this coroutine, which means that local variables will automatically preserved.
	/// Currently I'm only commenting out the saving in case if I decide to do something else.
	/// Please use void LZHAMDecompressor.call() instead of calling this function directly. The function won't work properly otherwise.
	/// To do list:
	///  - Parallelize memcpy and memset if the compiler won't do it.
	///  - Code cleanup
	///  - Add switch-case since it's no longer forbidden
	///  - Some further optimizations
	///  - Add some extra capabilities, e.g. delta compression, random access
	void decompress(bool unbuffered = false)(){
		SymbolCodec codec = this.codec;
		const uint dictSize = 1U << params.dictSizeLog2;
		//const uint dictSizeMask = unbuffered ? UINT_MAX : (dict_size - 1);
		
		int matchHist0, matchHist1, matchHist2, matchHist3;
		uint curState, dstOfs;
		
		size_t outBufSize = *(this.outBufSize);//was const originally
		
		//uint8* pDst = unbuffered ? reinterpret_cast<uint8*>(m_pOut_buf) : reinterpret_cast<uint8*>(m_pDecomp_buf);
		//uint8* pDst_end = unbuffered ?  (reinterpret_cast<uint8*>(m_pOut_buf) + out_buf_size) : (reinterpret_cast<uint8*>(m_pDecomp_buf) + dict_size);
		static if(unbuffered){
			const uint dictSizeMask = uint.max;
			ubyte* pDst = cast(ubyte*)outBuf;
			ubyte* pDstEnd = pDst + outBufSize;
		}else{
			const uint dictSizeMask = dictSize - 1;
			ubyte* pDst = cast(ubyte*)decompBuf;
			ubyte* pDstEnd = pDst + dictSize;
		}
		uint arithValue;
		uint arithLength;
		static if(CPU_64BIT_CAPABLE){
			ulong bitBuf; 
		}else{
			uint bitBuf; 
		}
		int bitCount; 
		ubyte* decodeBufNext;//was const originally
		
		if ((!unbuffered) && (params.numSeedBytes)){
			memcpy(pDst, params.seedBytes, params.numSeedBytes);
			dstOfs += params.numSeedBytes;
			if (dstOfs >= dictSize)
				dstOfs = 0;
			else
				seedBytesToIgnoreWhenFlushing = dstOfs;
		}
		if (!codec.startDecoding(inBuf, *inBufSize, noMoreInputBytesFlag, null, null))
			yieldAndThrow(new LZHAMException("Initialization failure"));
		//return LZHAMDecompressionStatus.FAILED_INITIALIZING;// LZHAM_DECOMP_STATUS_FAILED_INITIALIZING;
		arithValue = codec.arithValue; 
		arithLength = codec.arithLength; 
		bitBuf = codec.bitBuf; 
		bitCount = codec.bitCount; 
		decodeBufNext = codec.decodeBufNext;
		{
			if (params.decompressFlags & LZHAMDecompressFlags.READ_ZLIB_STREAM){
				uint check;
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_z_cmf, 8);
				{
					while (bitCount < cast(int)(8)){
						uint r;
						if (decodeBufNext == codec.decodeBufEnd){
							if (!codec.decodeBufEOF){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								//LZHAM_DECODE_NEEDS_BYTES
								//LZHAM_SAVE_STATE
								/*this.m_match_hist0 = matchHist0; 
								 this.m_match_hist1 = matchHist1; 
								 this.m_match_hist2 = matchHist2; 
								 this.m_match_hist3 = matchHist3;
								 this.m_cur_state = curState; 
								 this.m_dst_ofs = dstOfs;*/
								//are these even used, or am I in macro hell?
								for ( ; ; ){
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = 0;
									//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
									//what the fuck supposed to be this???
									//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
									status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
									yield();
									codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
								 matchHist1 = this.m_match_hist1; 
								 matchHist2 = this.m_match_hist2; 
								 matchHist3 = this.m_match_hist3;
								 curState = this.m_cur_state; 
								 dstOfs = this.m_dst_ofs;*/
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
								arithValue = codec.arithValue;
								arithLength = codec.arithLength; 
								bitBuf = codec.bitBuf; 
								bitCount = codec.bitCount; 
								decodeBufNext = codec.decodeBufNext;
							}
							r = 0; 
							if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
						}else
							r = *decodeBufNext++;
						bitCount += 8;
						bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
					}
					m_z_cmf = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
					bitBuf <<= (8);
					bitCount -= (8);
				}
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_z_flg, 8);
				{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
					while (bitCount < cast(int)(8)){
						uint r;
						if (decodeBufNext == codec.decodeBufEnd){
							if (!codec.decodeBufEOF){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								//LZHAM_DECODE_NEEDS_BYTES
								//LZHAM_SAVE_STATE
								/*this.m_match_hist0 = matchHist0; 
								 this.m_match_hist1 = matchHist1; 
								 this.m_match_hist2 = matchHist2; 
								 this.m_match_hist3 = matchHist3;
								 this.m_cur_state = curState; 
								 this.m_dst_ofs = dstOfs;*/
								//are these even used, or am I in macro hell?
								for ( ; ; ){
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = 0;
									//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
									//what the fuck supposed to be this???
									//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
									status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
									yield();
									codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
								 matchHist1 = this.m_match_hist1; 
								 matchHist2 = this.m_match_hist2; 
								 matchHist3 = this.m_match_hist3;
								 curState = this.m_cur_state; 
								 dstOfs = this.m_dst_ofs;*/
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
								arithValue = codec.arithValue;
								arithLength = codec.arithLength; 
								bitBuf = codec.bitBuf; 
								bitCount = codec.bitCount; 
								decodeBufNext = codec.decodeBufNext;
							}
							r = 0;
							if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
						}else
							r = *decodeBufNext++;
						bitCount += 8;
						bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
					}
					m_z_flg = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
					bitBuf <<= (8);
					bitCount -= (8);
				}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				check = ((m_z_cmf << 8) + m_z_flg) % 31;
				if ((check != 0) || ((m_z_cmf & 15) != LZHAM_Z_LZHAM)){
					throw new BadZLIBHeaderException("Header is invalid and/or corrupt!");
				}
				
				if (m_z_flg & 32){
					if ((!params.seedBytes) || (unbuffered))
						throw new NeedSeedBytesException("Seed bytes not found!");
					//return LZHAMDecompressionStatus.FAILED_NEED_SEED_BYTES;//LZHAM_DECOMP_STATUS_FAILED_NEED_SEED_BYTES;
					dictAdler32 = 0;
					for (m_tmp = 0; m_tmp < 4; ++m_tmp){
						uint n; 
						//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, n, 8);
						{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
							while (bitCount < cast(int)(8)){
								uint r;
								if (decodeBufNext == codec.decodeBufEnd){
									if (!codec.decodeBufEOF){
										//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
										codec.arithValue = arithValue; 
										codec.arithLength = arithLength; 
										codec.bitBuf = bitBuf; 
										codec.bitCount = bitCount; 
										codec.decodeBufNext = decodeBufNext;
										//LZHAM_DECODE_NEEDS_BYTES
										//LZHAM_SAVE_STATE
										/*this.m_match_hist0 = matchHist0; 
										 this.m_match_hist1 = matchHist1; 
										 this.m_match_hist2 = matchHist2; 
										 this.m_match_hist3 = matchHist3;
										 this.m_cur_state = curState; 
										 this.m_dst_ofs = dstOfs;*/
										//are these even used, or am I in macro hell?
										for ( ; ; ){
											*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
											*this.outBufSize = 0;
											//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
											//what the fuck supposed to be this???
											//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
											status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
											yield();
											codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
											if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
										}
										//LZHAM_RESTORE_STATE
										/*matchHist0 = this.m_match_hist0; 
										 matchHist1 = this.m_match_hist1; 
										 matchHist2 = this.m_match_hist2; 
										 matchHist3 = this.m_match_hist3;
										 curState = this.m_cur_state; 
										 dstOfs = this.m_dst_ofs;*/
										//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
										arithValue = codec.arithValue;
										arithLength = codec.arithLength; 
										bitBuf = codec.bitBuf; 
										bitCount = codec.bitCount; 
										decodeBufNext = codec.decodeBufNext;
									}
									r = 0;
									if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
								}else
									r = *decodeBufNext++;
								bitCount += 8;
								bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
							}
							n = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
							bitBuf <<= (8);
							bitCount -= (8);
						}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
						dictAdler32 = (dictAdler32 << 8) | n;
					}
					if (adler32(cast(ubyte*)params.seedBytes, params.numSeedBytes) != dictAdler32){
						//logger.log("Adler32 error at " ~ to!string(params.seedBytes));
						/*if(!forceFinish){
						 return LZHAMDecompressionStatus.FAILED_BAD_SEED_BYTES;
						 }*/
						throw new BadSeedBytesException("Seed byte checksum failure!");
					}
					//return LZHAM_DECOMP_STATUS_FAILED_BAD_SEED_BYTES;
				}
			}
			
			{
				// Was written by lzcompressor::send_configuration().
				//uint tmp;
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, tmp, 2);
			}
			
			uint maxUpdateInterval = params.tableMaxUpdateInterval, updateIntervalSlowRate =  params.tableUpdateIntervalSlowRate;
			if (!maxUpdateInterval && !updateIntervalSlowRate){
				uint rate = params.tableUpdateRate;
				if (!rate)
					rate = LZHAMTableUpdateRate.DEFAULT;
				//rate = math::clamp<uint>(rate, 1, LZHAM_FASTEST_TABLE_UPDATE_RATE) - 1;
				if(rate <= 1)
					rate = 1;
				else if(rate >= LZHAMTableUpdateRate.FASTEST)
					rate = LZHAMTableUpdateRate.FASTEST;
				rate--;
				maxUpdateInterval = gTableUpdateSettings[rate].maxUpdateInterval;
				updateIntervalSlowRate = gTableUpdateSettings[rate].slowRate;
			}

			bool succeeded = litTable.init2(false, 256, maxUpdateInterval, updateIntervalSlowRate, null);
			succeeded = succeeded && deltaLitTable.assign(litTable);
			
			succeeded = succeeded && mainTable.init2(false, CLZDecompBase.cLZXNumSpecialLengths + (lzBase.mNumLZXSlots - CLZDecompBase.cLZXLowestUsableMatchSlot) * 8, maxUpdateInterval, updateIntervalSlowRate, null);
			
			succeeded = succeeded && repLenTable[0].init2(false, CLZDecompBase.cNumHugeMatchCodes + (CLZDecompBase.cMaxMatchLen - CLZDecompBase.cMinMatchLen + 1), maxUpdateInterval, updateIntervalSlowRate, null);
			succeeded = succeeded && repLenTable[1].assign(repLenTable[0]);
			
			succeeded = succeeded && largeLenTable[0].init2(false, CLZDecompBase.cNumHugeMatchCodes + CLZDecompBase.cLZXNumSecondaryLengths, maxUpdateInterval, updateIntervalSlowRate, null);
			succeeded = succeeded && largeLenTable[1].assign(largeLenTable[0]);
			
			succeeded = succeeded && distLsbTable.init2(false, 16, maxUpdateInterval, updateIntervalSlowRate, null);
			if (!succeeded)
				throw new LZHAMException("Initialization error!");
			//return LZHAMDecompressionStatus.FAILED_INITIALIZING;//LZHAM_DECOMP_STATUS_FAILED_INITIALIZING;
		}
		// Output block loop.
		do{
			/*debug{
			 uint outer_sync_marker; 
			 //LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, k, 12);
			 assert(outer_sync_marker == 166);
			 }*/
			//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_block_type, CLZDecompBase::cBlockHeaderBits);
			{
				while (bitCount < cast(int)(CLZDecompBase.cBlockHeaderBits)){
					uint r;
					if (decodeBufNext == codec.decodeBufEnd){
						if (!codec.decodeBufEOF){
							//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
							codec.arithValue = arithValue; 
							codec.arithLength = arithLength; 
							codec.bitBuf = bitBuf; 
							codec.bitCount = bitCount; 
							codec.decodeBufNext = decodeBufNext;
							//LZHAM_DECODE_NEEDS_BYTES
							//LZHAM_SAVE_STATE
							/*this.m_match_hist0 = matchHist0; 
							 this.m_match_hist1 = matchHist1; 
							 this.m_match_hist2 = matchHist2; 
							 this.m_match_hist3 = matchHist3;
							 this.m_cur_state = curState; 
							 this.m_dst_ofs = dstOfs;*/
							//are these even used, or am I in macro hell?
							for ( ; ; ){
								*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
								*this.outBufSize = 0;
								//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
								//what the fuck supposed to be this???
								//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
								status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
								yield();
								codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
								if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
							}
							//LZHAM_RESTORE_STATE
							/*matchHist0 = this.m_match_hist0; 
							 matchHist1 = this.m_match_hist1; 
							 matchHist2 = this.m_match_hist2; 
							 matchHist3 = this.m_match_hist3;
							 curState = this.m_cur_state; 
							 dstOfs = this.m_dst_ofs;*/
							//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
							arithValue = codec.arithValue;
							arithLength = codec.arithLength; 
							bitBuf = codec.bitBuf; 
							bitCount = codec.bitCount; 
							decodeBufNext = codec.decodeBufNext;
						}
						r = 0; 
						if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
					}else
						r = *decodeBufNext++;
					bitCount += 8;
					bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
				}
				blockType = (CLZDecompBase.cBlockHeaderBits) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (CLZDecompBase.cBlockHeaderBits))) : 0;
				bitBuf <<= (CLZDecompBase.cBlockHeaderBits);
				bitCount -= (CLZDecompBase.cBlockHeaderBits);
			}
			if (blockType == CLZDecompBase.cSyncBlock){
				// Sync block
				// Reset either the symbol table update rates, or all statistics, then force a coroutine return to give the caller a chance to handle the output right now.
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_tmp, CLZDecompBase::cBlockFlushTypeBits);
				{
					while (bitCount < cast(int)(CLZDecompBase.cBlockFlushTypeBits)){
						uint r;
						if (decodeBufNext == codec.decodeBufEnd){
							if (!codec.decodeBufEOF){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								//LZHAM_DECODE_NEEDS_BYTES
								//LZHAM_SAVE_STATE
								/*this.m_match_hist0 = matchHist0; 
								 this.m_match_hist1 = matchHist1; 
								 this.m_match_hist2 = matchHist2; 
								 this.m_match_hist3 = matchHist3;
								 this.m_cur_state = curState; 
								 this.m_dst_ofs = dstOfs;*/
								//are these even used, or am I in macro hell?
								for ( ; ; ){
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = 0;
									//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
									//what the fuck supposed to be this???
									//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
									status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
									yield();
									codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
								 matchHist1 = this.m_match_hist1; 
								 matchHist2 = this.m_match_hist2; 
								 matchHist3 = this.m_match_hist3;
								 curState = this.m_cur_state; 
								 dstOfs = this.m_dst_ofs;*/
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
								arithValue = codec.arithValue;
								arithLength = codec.arithLength; 
								bitBuf = codec.bitBuf; 
								bitCount = codec.bitCount; 
								decodeBufNext = codec.decodeBufNext;
							}
							r = 0; 
							if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
						}else
							r = *decodeBufNext++;
						bitCount += 8;
						bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
					}
					blockType = (CLZDecompBase.cBlockFlushTypeBits) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (CLZDecompBase.cBlockHeaderBits))) : 0;
					bitBuf <<= (CLZDecompBase.cBlockFlushTypeBits);
					bitCount -= (CLZDecompBase.cBlockFlushTypeBits);
				}
				// See lzcompressor::send_sync_block() (TODO: make these an enum)
				if (m_tmp == 1)
					resetHuffmanTableUpdateRates();
				else if (m_tmp == 2)
					resetAllTables();
				
				//LZHAM_SYMBOL_CODEC_DECODE_ALIGN_TO_BYTE(codec);
				if (bitCount & 7) { //LZHAM_SYMBOL_CODEC_DECODE_ALIGN_TO_BYTE
					int dummyResult; 
					//LZHAM_NOTE_UNUSED(dummy_result); 
					//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, dummy_result, bit_count & 7); 
					{
						while (bitCount < cast(int)(bitCount & 7)){
							uint r;
							if (decodeBufNext == codec.decodeBufEnd){
								if (!codec.decodeBufEOF){
									//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
									codec.arithValue = arithValue; 
									codec.arithLength = arithLength; 
									codec.bitBuf = bitBuf; 
									codec.bitCount = bitCount; 
									codec.decodeBufNext = decodeBufNext;
									//LZHAM_DECODE_NEEDS_BYTES
									//LZHAM_SAVE_STATE
									/*this.m_match_hist0 = matchHist0; 
									 this.m_match_hist1 = matchHist1; 
									 this.m_match_hist2 = matchHist2; 
									 this.m_match_hist3 = matchHist3;
									 this.m_cur_state = curState; 
									 this.m_dst_ofs = dstOfs;*/
									//are these even used, or am I in macro hell?
									for ( ; ; ){
										*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
										*this.outBufSize = 0;
										//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
										//what the fuck supposed to be this???
										//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
										status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
										yield();
										codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
										if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
									}
									//LZHAM_RESTORE_STATE
									/*matchHist0 = this.m_match_hist0; 
									 matchHist1 = this.m_match_hist1; 
									 matchHist2 = this.m_match_hist2; 
									 matchHist3 = this.m_match_hist3;
									 curState = this.m_cur_state; 
									 dstOfs = this.m_dst_ofs;*/
									//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
									arithValue = codec.arithValue;
									arithLength = codec.arithLength; 
									bitBuf = codec.bitBuf; 
									bitCount = codec.bitCount; 
									decodeBufNext = codec.decodeBufNext;
								}
								r = 0; 
								if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
							}else
								r = *decodeBufNext++;
							bitCount += 8;
							bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - (bitCount)));
						}
						dummyResult = (7) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (bitCount & 7))) : 0;
						bitBuf <<= (bitCount & 7);
						bitCount -= (bitCount & 7);
					}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				}//LZHAM_SYMBOL_CODEC_DECODE_ALIGN_TO_BYTE
				
				uint n; 
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, n, 16);
				{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
					while (bitCount < cast(int)(16)){
						uint r;
						if (decodeBufNext == codec.decodeBufEnd){
							if (!codec.decodeBufEOF){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								//LZHAM_DECODE_NEEDS_BYTES
								//LZHAM_SAVE_STATE
								/*this.m_match_hist0 = matchHist0; 
								 this.m_match_hist1 = matchHist1; 
								 this.m_match_hist2 = matchHist2; 
								 this.m_match_hist3 = matchHist3;
								 this.m_cur_state = curState; 
								 this.m_dst_ofs = dstOfs;*/
								//are these even used, or am I in macro hell?
								for ( ; ; ){
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = 0;
									//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
									//what the fuck supposed to be this???
									//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
									status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
									yield();
									codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
								 matchHist1 = this.m_match_hist1; 
								 matchHist2 = this.m_match_hist2; 
								 matchHist3 = this.m_match_hist3;
								 curState = this.m_cur_state; 
								 dstOfs = this.m_dst_ofs;*/
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
								arithValue = codec.arithValue;
								arithLength = codec.arithLength; 
								bitBuf = codec.bitBuf; 
								bitCount = codec.bitCount; 
								decodeBufNext = codec.decodeBufNext;
							}
							r = 0; 
							if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
						}else
							r = *decodeBufNext++;
						bitCount += 8;
						bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - 16));
					}
					n = (16) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (16))) : 0;
					bitBuf <<= (16);
					bitCount -= (16);
				}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				if (n != 0){
					//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
					codec.arithValue = arithValue; 
					codec.arithLength = arithLength; 
					codec.bitBuf = bitBuf; 
					codec.bitCount = bitCount; 
					codec.decodeBufNext = decodeBufNext;
					*inBufSize = cast(size_t)(codec.decodeGetBytesConsumed());
					origOutBufSize = 0;
					//for ( ; ; ) { LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_FAILED_BAD_SYNC_BLOCK); }
					//again this coroutine...
				}
				
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, n, 16);
				{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
					while (bitCount < cast(int)(16)){
						uint r;
						if (decodeBufNext == codec.decodeBufEnd){
							if (!codec.decodeBufEOF){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								//LZHAM_DECODE_NEEDS_BYTES
								//LZHAM_SAVE_STATE
								/*this.m_match_hist0 = matchHist0; 
								 this.m_match_hist1 = matchHist1; 
								 this.m_match_hist2 = matchHist2; 
								 this.m_match_hist3 = matchHist3;
								 this.m_cur_state = curState; 
								 this.m_dst_ofs = dstOfs;*/
								//are these even used, or am I in macro hell?
								for ( ; ; ){
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = 0;
									//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
									//what the fuck supposed to be this???
									//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
									status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
									yield();
									codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
								 matchHist1 = this.m_match_hist1; 
								 matchHist2 = this.m_match_hist2; 
								 matchHist3 = this.m_match_hist3;
								 curState = this.m_cur_state; 
								 dstOfs = this.m_dst_ofs;*/
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
								arithValue = codec.arithValue;
								arithLength = codec.arithLength; 
								bitBuf = codec.bitBuf; 
								bitCount = codec.bitCount; 
								decodeBufNext = codec.decodeBufNext;
							}
							r = 0; 
							if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
						}else
							r = *decodeBufNext++;
						bitCount += 8;
						bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
					}
					n = (16) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (16))) : 0;
					bitBuf <<= (16);
					bitCount -= (16);
				}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				if (n != 0xFFFF){
					//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
					codec.arithValue = arithValue; 
					codec.arithLength = arithLength; 
					codec.bitBuf = bitBuf; 
					codec.bitCount = bitCount; 
					codec.decodeBufNext = decodeBufNext;
					*inBufSize = cast(size_t)(codec.decodeGetBytesConsumed());
					origOutBufSize = 0;
					//for ( ; ; ) { LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_FAILED_BAD_SYNC_BLOCK); }
					//yet again...
					import std.conv;
					yieldAndThrow(new BadSyncBlockException("Bad sync block at: " ~ to!string(*decodeBufNext)));
				}
				
				// See lzcompressor::send_sync_block() (TODO: make these an enum)            
				if ((m_tmp == 2) || (m_tmp == 3)){
					// It's a sync or full flush, so immediately give caller whatever output we have. Also gives the caller a chance to reposition the input stream ptr somewhere else before continuing.
					//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
					codec.arithValue = arithValue; 
					codec.arithLength = arithLength; 
					codec.bitBuf = bitBuf; 
					codec.bitCount = bitCount; 
					codec.decodeBufNext = decodeBufNext;
					
					if ((!unbuffered) && (dstOfs)){  
						//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);BEGIN
						//LZHAM_SAVE_STATE;
						/*this.m_match_hist0 = matchHist0; 
						 this.m_match_hist1 = matchHist1; 
						 this.m_match_hist2 = matchHist2; 
						 this.m_match_hist3 = matchHist3;
						 this.m_cur_state = curState; 
						 this.m_dst_ofs = dstOfs;*/
						pFlushSrc = decompBuf + seedBytesToIgnoreWhenFlushing + dstHighwaterOfs;  
						flushNumBytesRemaining = dstOfs - seedBytesToIgnoreWhenFlushing - dstHighwaterOfs;
						seedBytesToIgnoreWhenFlushing = 0;
						dstHighwaterOfs = dstOfs & dictSizeMask;
						while (flushNumBytesRemaining){
							//m_flush_n = LZHAM_MIN(m_flush_num_bytes_remaining, *m_pOut_buf_size);
							flushN = flushNumBytesRemaining > outBufSize ? origOutBufSize : flushNumBytesRemaining;
							if (0 == (params.decompressFlags & LZHAMDecompressFlags.COMPUTE_ADLER32)){
								memcpy(outBuf, pFlushSrc, flushN);
							}else{
								size_t copyOfs = 0;
								while (copyOfs < flushN){
									const uint cBytesToMemCpyPerIteration = 8192U;
									size_t helperValue = flushN - copyOfs;
									size_t bytesToCopy = helperValue > cBytesToMemCpyPerIteration ? cBytesToMemCpyPerIteration : helperValue;
									//LZHAM_MIN((size_t)(m_flush_n - copyOfs), cBytesToMemCpyPerIteration);  
									memcpy(outBuf + copyOfs, pFlushSrc + copyOfs, bytesToCopy);
									decompAdler32 = adler32(cast(ubyte*)(pFlushSrc + copyOfs), bytesToCopy, decompAdler32);  
									copyOfs += bytesToCopy;  
								}  
							} 
							*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
							outBufSize = flushN;
							//LZHAM_CR_RETURN(m_state, m_flush_n ? LZHAM_DECOMP_STATUS_NOT_FINISHED : LZHAM_DECOMP_STATUS_HAS_MORE_OUTPUT);
							this.codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
							pFlushSrc += flushN;
							flushNumBytesRemaining -= flushN;
						}
						//LZHAM_RESTORE_STATE
						/*matchHist0 = this.m_match_hist0; 
						 matchHist1 = this.m_match_hist1; 
						 matchHist2 = this.m_match_hist2; 
						 matchHist3 = this.m_match_hist3;
						 curState = this.m_cur_state; 
						 dstOfs = this.m_dst_ofs;*/
						//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);END
					}else{
						static if (unbuffered){
							assert(dstOfs >= dstHighwaterOfs);
						}else{
							assert(!dstHighwaterOfs);
						}
						
						// unbuffered, or dst_ofs==0
						*inBufSize = cast(size_t)(codec.decodeGetBytesConsumed());
						*this.outBufSize = dstOfs - dstHighwaterOfs;
						
						// Partial/sync flushes in unbuffered mode details:
						// We assume the caller doesn't move the output buffer between calls AND the pointer to the output buffer input parameter won't change between calls (i.e.
						// it *always* points to the beginning of the decompressed stream). The caller will need to track the current output buffer offset.
						dstHighwaterOfs = dstOfs;
						
						//LZHAM_SAVE_STATE
						//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NOT_FINISHED);
						//LZHAM_RESTORE_STATE
						
						this.codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
					}
					
					//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec);
					arithValue = codec.arithValue;
					arithLength = codec.arithLength; 
					bitBuf = codec.bitBuf; 
					bitCount = codec.bitCount; 
					decodeBufNext = codec.decodeBufNext;
				}
			}else if (blockType == CLZDecompBase.cRawBlock){
				// Raw block handling is complex because we ultimately want to (safely) handle as many bytes as possible using a small number of memcpy()'s.
				uint numRawBytesRemaining;
				//num_raw_bytes_remaining = 0;
				//#define LZHAM_SAVE_LOCAL_STATE m_num_raw_bytes_remaining = num_raw_bytes_remaining;
				//#define LZHAM_RESTORE_LOCAL_STATE num_raw_bytes_remaining = m_num_raw_bytes_remaining;
				// Determine how large this raw block is.
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, numRawBytesRemaining, 24);
				{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
					while (bitCount < cast(int)(24)){
						uint r;
						if (decodeBufNext == codec.decodeBufEnd){
							if (!codec.decodeBufEOF){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								//LZHAM_DECODE_NEEDS_BYTES
								//LZHAM_SAVE_STATE
								/*this.m_match_hist0 = matchHist0; 
								 this.m_match_hist1 = matchHist1; 
								 this.m_match_hist2 = matchHist2; 
								 this.m_match_hist3 = matchHist3;
								 this.m_cur_state = curState; 
								 this.m_dst_ofs = dstOfs;*/
								//are these even used, or am I in macro hell?
								for ( ; ; ){
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = 0;
									//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
									//what the fuck supposed to be this???
									//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
									status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
									yield();
									codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
								 matchHist1 = this.m_match_hist1; 
								 matchHist2 = this.m_match_hist2; 
								 matchHist3 = this.m_match_hist3;
								 curState = this.m_cur_state; 
								 dstOfs = this.m_dst_ofs;*/
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
								arithValue = codec.arithValue;
								arithLength = codec.arithLength; 
								bitBuf = codec.bitBuf; 
								bitCount = codec.bitCount; 
								decodeBufNext = codec.decodeBufNext;
							}
							r = 0; 
							if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
						}else
							r = *decodeBufNext++;
						bitCount += 8;
						bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
					}
					numRawBytesRemaining = (24) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (24))) : 0;
					bitBuf <<= (24);
					bitCount -= (24);
				}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				// Get and verify raw block length check bits.
				uint numRawBytesCheckBits; 
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, numRawBytesCheckBits, 8);
				{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
					while (bitCount < cast(int)(8)){
						uint r;
						if (decodeBufNext == codec.decodeBufEnd){
							if (!codec.decodeBufEOF){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								//LZHAM_DECODE_NEEDS_BYTES
								//LZHAM_SAVE_STATE
								/*this.m_match_hist0 = matchHist0; 
								 this.m_match_hist1 = matchHist1; 
								 this.m_match_hist2 = matchHist2; 
								 this.m_match_hist3 = matchHist3;
								 this.m_cur_state = curState; 
								 this.m_dst_ofs = dstOfs;*/
								//are these even used, or am I in macro hell?
								for ( ; ; ){
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = 0;
									//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
									//what the fuck supposed to be this???
									//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
									status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
									yield();
									codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
								 matchHist1 = this.m_match_hist1; 
								 matchHist2 = this.m_match_hist2; 
								 matchHist3 = this.m_match_hist3;
								 curState = this.m_cur_state; 
								 dstOfs = this.m_dst_ofs;*/
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
								arithValue = codec.arithValue;
								arithLength = codec.arithLength; 
								bitBuf = codec.bitBuf; 
								bitCount = codec.bitCount; 
								decodeBufNext = codec.decodeBufNext;
							}
							r = 0; 
							if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
						}else
							r = *decodeBufNext++;
						bitCount += 8;
						bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
					}
					numRawBytesRemaining = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
					bitBuf <<= (8);
					bitCount -= (8);
				}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				
				uint rawBytesRemaining0, rawBytesRemaining1, rawBytesRemaining2;
				rawBytesRemaining0 = numRawBytesRemaining & 0xFF;
				rawBytesRemaining1 = (numRawBytesRemaining >> 8) & 0xFF;
				rawBytesRemaining2 = (numRawBytesRemaining >> 16) & 0xFF;
				if (numRawBytesCheckBits != ((rawBytesRemaining0 ^ rawBytesRemaining1) ^ rawBytesRemaining2)){
					//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
					codec.arithValue = arithValue; 
					codec.arithLength = arithLength; 
					codec.bitBuf = bitBuf; 
					codec.bitCount = bitCount; 
					codec.decodeBufNext = decodeBufNext;
					*inBufSize = cast(size_t)(codec.decodeGetBytesConsumed());
					*this.outBufSize = 0;
					//for ( ; ; ) { LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_FAILED_BAD_RAW_BLOCK); }
					yieldAndThrow(new BadRawBlockException(decodeBufNext));
				}
				
				numRawBytesRemaining++;
				
				// Discard any partial bytes from the bit buffer (align up to the next byte).
				//LZHAM_SYMBOL_CODEC_DECODE_ALIGN_TO_BYTE(codec);
				
				if (bitCount & 7) { //LZHAM_SYMBOL_CODEC_DECODE_ALIGN_TO_BYTE
					//int dummyResult; 
					//LZHAM_NOTE_UNUSED(dummy_result); 
					//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, dummy_result, bit_count & 7); 
					{
						while (bitCount < cast(int)(bitCount & 7)){
							uint r;
							if (decodeBufNext == codec.decodeBufEnd){
								if (!codec.decodeBufEOF){
									//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
									codec.arithValue = arithValue; 
									codec.arithLength = arithLength; 
									codec.bitBuf = bitBuf; 
									codec.bitCount = bitCount; 
									codec.decodeBufNext = decodeBufNext;
									//LZHAM_DECODE_NEEDS_BYTES
									//LZHAM_SAVE_STATE
									/*this.m_match_hist0 = matchHist0; 
									 this.m_match_hist1 = matchHist1; 
									 this.m_match_hist2 = matchHist2; 
									 this.m_match_hist3 = matchHist3;
									 this.m_cur_state = curState; 
									 this.m_dst_ofs = dstOfs;*/
									//are these even used, or am I in macro hell?
									for ( ; ; ){
										*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
										*this.outBufSize = 0;
										//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
										//what the fuck supposed to be this???
										//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
										status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
										yield();
										codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
										if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
									}
									//LZHAM_RESTORE_STATE
									/*matchHist0 = this.m_match_hist0; 
									 matchHist1 = this.m_match_hist1; 
									 matchHist2 = this.m_match_hist2; 
									 matchHist3 = this.m_match_hist3;
									 curState = this.m_cur_state; 
									 dstOfs = this.m_dst_ofs;*/
									//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
									arithValue = codec.arithValue;
									arithLength = codec.arithLength; 
									bitBuf = codec.bitBuf; 
									bitCount = codec.bitCount; 
									decodeBufNext = codec.decodeBufNext;
								}
								r = 0; 
								if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
							}else
								r = *decodeBufNext++;
							bitCount += 8;// DO NOT TOUCH THIS
							bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - (bitCount)));// DO NOT TOUCH THIS
						}
						//dummyResult = (bitCount & 7) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (bitCount & 7))) : 0;
						bitBuf <<= (bitCount & 7);
						bitCount -= (bitCount & 7);
					}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				}//LZHAM_SYMBOL_CODEC_DECODE_ALIGN_TO_BYTE
				
				// Flush any full bytes from the bit buffer.
				do{
					int b;
					//LZHAM_SYMBOL_CODEC_DECODE_REMOVE_BYTE_FROM_BIT_BUF(codec, b);
					if (b < 0)
						break;
					static if(unbuffered){
						if ((dstOfs >= outBufSize)){
							//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
							codec.arithValue = arithValue; 
							codec.arithLength = arithLength; 
							codec.bitBuf = bitBuf; 
							codec.bitCount = bitCount; 
							codec.decodeBufNext = decodeBufNext;
							*inBufSize = cast(size_t)(codec.decodeGetBytesConsumed());
							outBufSize = 0;
							//for ( ; ; ) { LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_FAILED_DEST_BUF_TOO_SMALL); }
							yieldAndThrow(new OutputBufferTooSmallException("Destination buffer is too small!"));
						}
					}
					
					pDst[dstOfs++] = cast(ubyte)(b);
					static if(!unbuffered){  
						if ((dstOfs > dictSizeMask)){  
							//LZHAM_SYMBOL_CODEC_DECODE_END(codec);  
							codec.arithValue = arithValue;  
							codec.arithLength = arithLength;
							codec.bitBuf = bitBuf;
							codec.bitCount = bitCount; 
							codec.decodeBufNext = decodeBufNext;
							//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dict_size);
							//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);BEGIN
							//LZHAM_SAVE_STATE;
							/*this.m_match_hist0 = matchHist0; 
							 this.m_match_hist1 = matchHist1; 
							 this.m_match_hist2 = matchHist2; 
							 this.m_match_hist3 = matchHist3;
							 this.m_cur_state = curState; 
							 this.m_dst_ofs = dstOfs;*/
							pFlushSrc = decompBuf + seedBytesToIgnoreWhenFlushing + dstHighwaterOfs;  
							flushNumBytesRemaining = dictSize - seedBytesToIgnoreWhenFlushing - dstHighwaterOfs;
							seedBytesToIgnoreWhenFlushing = 0;
							dstHighwaterOfs = dictSize & dictSizeMask;
							while (flushNumBytesRemaining){
								//m_flush_n = LZHAM_MIN(m_flush_num_bytes_remaining, *m_pOut_buf_size);
								flushN = flushNumBytesRemaining > outBufSize ? origOutBufSize : flushNumBytesRemaining;
								if (0 == (params.decompressFlags & LZHAMDecompressFlags.COMPUTE_ADLER32)){
									memcpy(outBuf, pFlushSrc, flushN);
								}else{
									size_t copyOfs = 0;
									while (copyOfs < flushN){
										const uint cBytesToMemCpyPerIteration = 8192U;
										size_t helperValue = flushN - copyOfs;
										size_t bytesToCopy = helperValue > cBytesToMemCpyPerIteration ? cBytesToMemCpyPerIteration : helperValue;
										//LZHAM_MIN((size_t)(m_flush_n - copyOfs), cBytesToMemCpyPerIteration);  
										memcpy(this.outBuf + copyOfs, pFlushSrc + copyOfs, bytesToCopy);
										decompAdler32 = adler32(pFlushSrc + copyOfs, bytesToCopy, decompAdler32);  
										copyOfs += bytesToCopy;  
									}  
								} 
								*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
								*(this.outBufSize) = flushN;
								//LZHAM_CR_RETURN(m_state, m_flush_n ? LZHAM_DECOMP_STATUS_NOT_FINISHED : LZHAM_DECOMP_STATUS_HAS_MORE_OUTPUT);
								if(flushN){
									status = LZHAMDecompressionStatus.NOT_FINISHED;
								}else{
									status = LZHAMDecompressionStatus.HAS_MORE_OUTPUT;
								}
								yield();
								this.codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
								pFlushSrc += flushN;
								flushNumBytesRemaining -= flushN;
							}
							//LZHAM_RESTORE_STATE
							/*matchHist0 = this.m_match_hist0; 
							 matchHist1 = this.m_match_hist1; 
							 matchHist2 = this.m_match_hist2; 
							 matchHist3 = this.m_match_hist3;
							 curState = this.m_cur_state; 
							 dstOfs = this.m_dst_ofs;*/
							//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);END
							//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec);
							arithValue = codec.arithValue;
							arithLength = codec.arithLength; 
							bitBuf = codec.bitBuf; 
							bitCount = codec.bitCount; 
							decodeBufNext = codec.decodeBufNext;
							
							dstOfs = 0;
						}
					}
					
					numRawBytesRemaining--;
				}while (numRawBytesRemaining);
				
				//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
				codec.arithValue = arithValue;  
				codec.arithLength = arithLength;
				codec.bitBuf = bitBuf;
				codec.bitCount = bitCount; 
				codec.decodeBufNext = decodeBufNext;
				// Now handle the bulk of the raw data with memcpy().
				while (numRawBytesRemaining){
					ulong inBufOfs, inBufRemaining;
					inBufOfs = codec.decodeGetBytesConsumed();
					inBufRemaining = *inBufSize - inBufOfs;
					
					while (!inBufRemaining){
						// We need more bytes from the caller.
						*inBufSize = cast(size_t)(inBufOfs);
						outBufSize = 0;
						if(noMoreInputBytesFlag){
							yieldAndThrow(new LZHAMException("Decompressor needs more bytes!"));
						}
						/*if (m_no_more_input_bytes_flag){
						 for ( ; ; ) { LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_FAILED_EXPECTED_MORE_RAW_BYTES); }
						 }*/
						
						//LZHAM_SAVE_STATE
						//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
						//LZHAM_RESTORE_STATE
						status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
						yield();
						
						this.codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
						
						inBufOfs = 0;
						inBufRemaining = *inBufSize;
					}
					
					// Determine how many bytes we can safely memcpy() in a single call.
					uint numBytesToCopy;
					//numBytesToCopy = cast(uint)(LZHAM_MIN(numRawBytesRemaining, inBufRemaining));
					numBytesToCopy = cast(uint)(numRawBytesRemaining > inBufRemaining ? inBufRemaining : numRawBytesRemaining);
					static if (!unbuffered){
						//numBytesToCopy = LZHAM_MIN(numBytesToCopy, dict_size - dst_ofs);
						uint helpervalue = dictSize - dstOfs;
						numBytesToCopy = numBytesToCopy > helpervalue ? helpervalue : numBytesToCopy;
					}else{
						if (((dstOfs + numBytesToCopy) > outBufSize)){
							// Output buffer is not large enough.
							*inBufSize = cast(size_t)(inBufOfs);
							outBufSize = 0;
							//for ( ; ; ) { LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_FAILED_DEST_BUF_TOO_SMALL); }
							yieldAndThrow(new OutputBufferTooSmallException("Destination buffer is too small!"));
						}
					}
					
					// Copy the raw bytes.
					memcpy(pDst + dstOfs, inBuf + inBufOfs, numBytesToCopy);
					
					inBufOfs += numBytesToCopy;
					numRawBytesRemaining -= numBytesToCopy;
					
					codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf + inBufOfs, noMoreInputBytesFlag);
					
					dstOfs += numBytesToCopy;
					
					if ((!unbuffered) && (dstOfs > dictSizeMask))
					{
						assert(dstOfs == dictSize);
						
						//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dict_size);
						//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);BEGIN
						//LZHAM_SAVE_STATE;
						/*this.m_match_hist0 = matchHist0; 
						 this.m_match_hist1 = matchHist1; 
						 this.m_match_hist2 = matchHist2; 
						 this.m_match_hist3 = matchHist3;
						 this.m_cur_state = curState; 
						 this.m_dst_ofs = dstOfs;*/
						pFlushSrc = decompBuf + seedBytesToIgnoreWhenFlushing + dstHighwaterOfs;  
						flushNumBytesRemaining = dictSize - seedBytesToIgnoreWhenFlushing - dstHighwaterOfs;
						seedBytesToIgnoreWhenFlushing = 0;
						dstHighwaterOfs = dictSize & dictSizeMask;
						while (flushNumBytesRemaining){
							//m_flush_n = LZHAM_MIN(m_flush_num_bytes_remaining, *m_pOut_buf_size);
							flushN = flushNumBytesRemaining > outBufSize ? origOutBufSize : flushNumBytesRemaining;
							if (0 == (params.decompressFlags & LZHAMDecompressFlags.COMPUTE_ADLER32)){
								memcpy(outBuf, pFlushSrc, flushN);
							}else{
								size_t copyOfs = 0;
								while (copyOfs < flushN){
									const uint cBytesToMemCpyPerIteration = 8192U;
									size_t helperValue = flushN - copyOfs;
									size_t bytesToCopy = helperValue > cBytesToMemCpyPerIteration ? cBytesToMemCpyPerIteration : helperValue;
									//LZHAM_MIN((size_t)(m_flush_n - copyOfs), cBytesToMemCpyPerIteration);  
									memcpy(outBuf + copyOfs, pFlushSrc + copyOfs, bytesToCopy);
									decompAdler32 = adler32(pFlushSrc + copyOfs, bytesToCopy, decompAdler32);  
									copyOfs += bytesToCopy;  
								}  
							} 
							*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
							*this.outBufSize = flushN;
							//LZHAM_CR_RETURN(m_state, m_flush_n ? LZHAM_DECOMP_STATUS_NOT_FINISHED : LZHAM_DECOMP_STATUS_HAS_MORE_OUTPUT);
							status = LZHAMDecompressionStatus.HAS_MORE_OUTPUT;
							yield();
							this.codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
							pFlushSrc += flushN;
							flushNumBytesRemaining -= flushN;
						}
						//LZHAM_RESTORE_STATE
						/*matchHist0 = this.m_match_hist0; 
						 matchHist1 = this.m_match_hist1; 
						 matchHist2 = this.m_match_hist2; 
						 matchHist3 = this.m_match_hist3;
						 curState = this.m_cur_state; 
						 dstOfs = this.m_dst_ofs;*/
						//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);END
						dstOfs = 0;
					}
				}
				
				//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec);
				arithValue = codec.arithValue;
				arithLength = codec.arithLength; 
				bitBuf = codec.bitBuf; 
				bitCount = codec.bitCount; 
				decodeBufNext = codec.decodeBufNext;
			}else if (blockType == CLZDecompBase.cCompBlock){
				//LZHAM_SYMBOL_CODEC_DECODE_ARITH_START(codec)
				{
					for ( arithValue = 0, arithLength = 0; arithLength < 4; ++arithLength ){
						uint val; 
						//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, val, 8);
						{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
							while (bitCount < cast(int)(8)){
								uint r;
								if (decodeBufNext == codec.decodeBufEnd){
									if (!codec.decodeBufEOF){
										//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
										codec.arithValue = arithValue; 
										codec.arithLength = arithLength; 
										codec.bitBuf = bitBuf; 
										codec.bitCount = bitCount; 
										codec.decodeBufNext = decodeBufNext;
										//LZHAM_DECODE_NEEDS_BYTES
										//LZHAM_SAVE_STATE
										/*this.m_match_hist0 = matchHist0; 
										 this.m_match_hist1 = matchHist1; 
										 this.m_match_hist2 = matchHist2; 
										 this.m_match_hist3 = matchHist3;
										 this.m_cur_state = curState; 
										 this.m_dst_ofs = dstOfs;*/
										//are these even used, or am I in macro hell?
										for ( ; ; ){
											*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
											*this.outBufSize = 0;
											//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
											//what the fuck supposed to be this???
											//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
											status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
											yield();
											codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
											if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
										}
										//LZHAM_RESTORE_STATE
										/*matchHist0 = this.m_match_hist0; 
										 matchHist1 = this.m_match_hist1; 
										 matchHist2 = this.m_match_hist2; 
										 matchHist3 = this.m_match_hist3;
										 curState = this.m_cur_state; 
										 dstOfs = this.m_dst_ofs;*/
										//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
										arithValue = codec.arithValue;
										arithLength = codec.arithLength; 
										bitBuf = codec.bitBuf; 
										bitCount = codec.bitCount; 
										decodeBufNext = codec.decodeBufNext;
									}
									r = 0; 
									if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
								}else
									r = *decodeBufNext++;
								bitCount += 8;//
								bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - 8));
							}
							val = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
							bitBuf <<= (8);
							bitCount -= (8);
						}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
						arithValue = (arithValue << 8) | val;
					}
					arithLength = cSymbolCodecArithMaxLen;
				}
				
				matchHist0 = 1;
				matchHist1 = 1;
				matchHist2 = 1;
				matchHist3 = 1;
				curState = 0;
				
				startBlockDstOfs = dstOfs;
				
				{
					uint blockFlushType; 
					//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, block_flush_type, CLZDecompBase.cBlockFlushTypeBits);
					{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
						while (bitCount < cast(int)(CLZDecompBase.cBlockFlushTypeBits)){
							uint r;
							if (decodeBufNext == codec.decodeBufEnd){
								if (!codec.decodeBufEOF){
									//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
									codec.arithValue = arithValue; 
									codec.arithLength = arithLength; 
									codec.bitBuf = bitBuf; 
									codec.bitCount = bitCount; 
									codec.decodeBufNext = decodeBufNext;
									//LZHAM_DECODE_NEEDS_BYTES
									//LZHAM_SAVE_STATE
									/*this.m_match_hist0 = matchHist0; 
									 this.m_match_hist1 = matchHist1; 
									 this.m_match_hist2 = matchHist2; 
									 this.m_match_hist3 = matchHist3;
									 this.m_cur_state = curState; 
									 this.m_dst_ofs = dstOfs;*/
									//are these even used, or am I in macro hell?
									for ( ; ; ){
										*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
										*this.outBufSize = 0;
										//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
										//what the fuck supposed to be this???
										//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
										status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
										yield();
										codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
										if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
									}
									//LZHAM_RESTORE_STATE
									/*matchHist0 = this.m_match_hist0; 
									 matchHist1 = this.m_match_hist1; 
									 matchHist2 = this.m_match_hist2; 
									 matchHist3 = this.m_match_hist3;
									 curState = this.m_cur_state; 
									 dstOfs = this.m_dst_ofs;*/
									//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
									arithValue = codec.arithValue;
									arithLength = codec.arithLength; 
									bitBuf = codec.bitBuf; 
									bitCount = codec.bitCount; 
									decodeBufNext = codec.decodeBufNext;
								}
								r = 0; 
								if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
							}else
								r = *decodeBufNext++;
							bitCount += 8;// DO NOT TOUCH THIS!
							bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));
						}
						blockFlushType = (CLZDecompBase.cBlockFlushTypeBits) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (CLZDecompBase.cBlockFlushTypeBits))) : 0;
						bitBuf <<= (CLZDecompBase.cBlockFlushTypeBits);
						bitCount -= (CLZDecompBase.cBlockFlushTypeBits);
					}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
					if (blockFlushType == 1)
						resetHuffmanTableUpdateRates();
					else if (blockFlushType == 2)
						resetAllTables();
				}
				
				/*#ifdef LZHAM_LZDEBUG
				 m_initial_step = m_step;
				 m_block_step = 0;
				 for ( ; ; m_step++, m_block_step++)
				 #else*/
				for ( ; ; ){
					//#endif
					
					//#ifdef LZHAM_LZDEBUG
					debug{
						/*uint sync_marker; 
						 //LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, x, CLZDecompBase.cLZHAMDebugSyncMarkerBits);
						 assert(sync_marker == CLZDecompBase.cLZHAMDebugSyncMarkerValue);
						 
						 //LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_debug_is_match, 1);
						 //LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_debug_match_len, 17);
						 
						 uint debug_cur_state; LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, debug_cur_state, 4);
						 assert(cur_state == debug_cur_state);*/
					}
					//#endif
					
					// Read "is match" bit.
					uint matchModelIndex;
					matchModelIndex = (curState);
					assert(matchModelIndex < isMatchModel.length);
					
					uint isMatchBit;
					//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, isMatchBit, m_is_match_model[matchModelIndex]);
					{//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) BEGIN
						AdaptiveBitModel pModel;
						pModel = isMatchModel[matchModelIndex];//pModel = &model;
						while (arithLength < cSymbolCodecArithMinLen){
							uint c; 
							codec.savedModel = cast(void*)(&pModel);
							//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, c, 8);
							{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
								while (bitCount < cast(int)(8)){
									uint r;
									if (decodeBufNext == codec.decodeBufEnd){
										if (!codec.decodeBufEOF){
											//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
											codec.arithValue = arithValue; 
											codec.arithLength = arithLength; 
											codec.bitBuf = bitBuf; 
											codec.bitCount = bitCount; 
											codec.decodeBufNext = decodeBufNext;
											//LZHAM_DECODE_NEEDS_BYTES
											//LZHAM_SAVE_STATE
											/*this.m_match_hist0 = matchHist0; 
											 this.m_match_hist1 = matchHist1; 
											 this.m_match_hist2 = matchHist2; 
											 this.m_match_hist3 = matchHist3;
											 this.m_cur_state = curState; 
											 this.m_dst_ofs = dstOfs;*/
											//are these even used, or am I in macro hell?
											for ( ; ; ){
												*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
												*this.outBufSize = 0;
												//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
												//what the fuck supposed to be this???
												//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
												status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
												yield();
												codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
												if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
											}
											//LZHAM_RESTORE_STATE
											/*matchHist0 = this.m_match_hist0; 
											 matchHist1 = this.m_match_hist1; 
											 matchHist2 = this.m_match_hist2; 
											 matchHist3 = this.m_match_hist3;
											 curState = this.m_cur_state; 
											 dstOfs = this.m_dst_ofs;*/
											//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
											arithValue = codec.arithValue;
											arithLength = codec.arithLength; 
											bitBuf = codec.bitBuf; 
											bitCount = codec.bitCount; 
											decodeBufNext = codec.decodeBufNext;
										}
										r = 0; 
										if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
									}else
										r = *decodeBufNext++;
									bitCount += 8;// DO NOT TOUCH THIS!
									bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
								}
								isMatchBit = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
								bitBuf <<= (8);
								bitCount -= (8);
							}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
							pModel = *cast(AdaptiveBitModel*)(codec.savedModel);
							arithValue = (arithValue << 8) | c;
							arithLength <<= 8;
						}
						uint x = pModel.bit0Prob * (arithLength >> cSymbolCodecArithProbBits);
						isMatchBit = (arithValue >= x);//result = (arithValue >= x);
						if (!isMatchBit){//if (!result)
							pModel.bit0Prob += ((cSymbolCodecArithProbScale - pModel.bit0Prob) >> cSymbolCodecArithProbMoveBits);
							arithLength = x;
						}else{
							pModel.bit0Prob -= (pModel.bit0Prob >> cSymbolCodecArithProbMoveBits);
							arithValue  -= x;
							arithLength -= x;
						}
					}//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) END
					//#ifdef LZHAM_LZDEBUG
					/*debug{
					 LZHAM_VERIFY(isMatchBit == m_debug_is_match);
					 }*/
					//#endif
					
					if ((!isMatchBit)){
						// Handle literal.
						
						//#ifdef LZHAM_LZDEBUG		
						debug{
							/*LZHAM_VERIFY(m_debug_match_len == 1);
							 LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_debug_lit, 8);*/
						}
						//#endif
						static if(unbuffered){
							if (dstOfs >= outBufSize){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								*inBufSize = cast(size_t)(codec.decodeGetBytesConsumed());
								*this.outBufSize = 0;
								//for ( ; ; ) { LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_FAILED_DEST_BUF_TOO_SMALL); }
								yieldAndThrow(new OutputBufferTooSmallException("Destination buffer is too small!"));
							}
						}
						
						if (curState < CLZDecompBase.cNumLitStates){
							// Regular literal
							uint r; 
							//LZHAM_DECOMPRESS_DECODE_ADAPTIVE_SYMBOL(codec, r, m_lit_table);
							//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN(codec, result, model) BEGIN
							{
								QuasiAdaptiveHuffmanDataModel pModel; 
								DecoderTables pTables;
								pModel = litTable; //pModel = &model; 
								pTables = litTable.m_pDecodeTables;
								if (bitCount < 24){
									uint c;
									decodeBufNext += uint.sizeof;
									if (decodeBufNext >= codec.decodeBufEnd){
										decodeBufNext -= uint.sizeof;
										while (bitCount < 24){
											if (!codec.decodeBufEOF){
												codec.savedHuffModel = pModel;
												//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
												codec.arithValue = arithValue; 
												codec.arithLength = arithLength; 
												codec.bitBuf = bitBuf; 
												codec.bitCount = bitCount; 
												codec.decodeBufNext = decodeBufNext;
												//LZHAM_DECODE_NEEDS_BYTES
												
												//LZHAM_SAVE_STATE
												/*this.m_match_hist0 = matchHist0; 
												 this.m_match_hist1 = matchHist1; 
												 this.m_match_hist2 = matchHist2; 
												 this.m_match_hist3 = matchHist3;
												 this.m_cur_state = curState; 
												 this.m_dst_ofs = dstOfs;*/
												//are these even used, or am I in macro hell?
												for ( ; ; ){
													*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
													*this.outBufSize = 0;
													//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
													//what the fuck supposed to be this???
													//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
													status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
													yield();
													codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
													if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
												}
												//LZHAM_RESTORE_STATE
												/*matchHist0 = this.m_match_hist0; 
												 matchHist1 = this.m_match_hist1; 
												 matchHist2 = this.m_match_hist2; 
												 matchHist3 = this.m_match_hist3;
												 curState = this.m_cur_state; 
												 dstOfs = this.m_dst_ofs;*/
												//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
												arithValue = codec.arithValue;
												arithLength = codec.arithLength; 
												bitBuf = codec.bitBuf; 
												bitCount = codec.bitCount; 
												decodeBufNext = codec.decodeBufNext;
												pModel = codec.savedHuffModel;
												pTables = pModel.m_pDecodeTables;
											}
											//c = 0;
											if (decodeBufNext < codec.decodeBufEnd) c = *decodeBufNext++;
											bitCount += 8;
											bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
										}
									}else{
										//c = LZHAM_READ_BIG_ENDIAN_UINT32(decodeBufNext - sizeof(uint32));
										c = bigEndianToNative!(uint, 4)(*cast(ubyte[4]*)(decodeBufNext - uint.sizeof));
										bitCount += 32;
										bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
									}
								}
								uint k = cast(uint)((bitBuf >> (cBitBufSize - 16)) + 1);
								uint len;
								if (k <= pTables.tableMaxCode){
									uint t = pTables.lookup[bitBuf >> (cBitBufSize - pTables.tableBits)];
									r = t & ushort.max;//result = t & ushort.max;
									len = t >> 16;
								}else{
									len = pTables.decodeStartCodeSize;
									for ( ; ; ){
										if (k <= pTables.maxCodes[len - 1])
											break;
										len++;
									}
									int valPtr = pTables.valPtrs[len - 1] + cast(int)(bitBuf >> (cBitBufSize - len));
									if ((cast(uint)valPtr >= pModel.mTotalSyms)) valPtr = 0;
									r = pTables.sortedSymbolOrder[valPtr];//result = pTables.mSortedSymbolOrder[valPtr];
								}
								bitBuf <<= len;
								bitCount -= len;
								uint freq = pModel.mSymFreq[r];//uint freq = pModel.mSymFreq[result];
								freq++;
								pModel.mSymFreq[r] = cast(ushort)(freq);//pModel.mSymFreq[result] = cast(ushort)(freq);
								assert(freq <= ushort.max);
								if (--pModel.mSymbolsUntilUpdate == 0){
									pModel.updateTables();
								}
							}//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN END
							pDst[dstOfs] = cast(ubyte)(r);
							
							//#ifdef LZHAM_LZDEBUG
							debug{
								//assert(pDst[dst_ofs] == m_debug_lit);
							}
							//#endif
						}else{
							// Delta literal
							uint matchHist0Ofs, repLit0;
							
							// Determine delta literal's partial context.
							matchHist0Ofs = dstOfs - matchHist0;
							repLit0 = pDst[matchHist0Ofs & dictSizeMask];
							
							/*#undef LZHAM_SAVE_LOCAL_STATE
							 #undef LZHAM_RESTORE_LOCAL_STATE
							 #define LZHAM_SAVE_LOCAL_STATE m_rep_lit0 = rep_lit0;
							 #define LZHAM_RESTORE_LOCAL_STATE rep_lit0 = m_rep_lit0;*/
							
							//#ifdef LZHAM_LZDEBUG
							debug{
								/*uint debug_rep_lit0; 
								 //LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, debug_rep_lit0, 8);
								 LZHAM_VERIFY(debug_rep_lit0 == rep_lit0);*/
							}
							//#endif
							
							uint r; 
							//LZHAM_DECOMPRESS_DECODE_ADAPTIVE_SYMBOL(codec, r, m_delta_lit_table);
							//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN(codec, result, model) BEGIN
							{
								QuasiAdaptiveHuffmanDataModel pModel; 
								DecoderTables pTables;
								pModel = deltaLitTable; //pModel = &model; 
								pTables = deltaLitTable.m_pDecodeTables;
								if (bitCount < 24){
									uint c;
									decodeBufNext += uint.sizeof;
									if (decodeBufNext >= codec.decodeBufEnd){
										decodeBufNext -= uint.sizeof;
										while (bitCount < 24){
											if (!codec.decodeBufEOF){
												codec.savedHuffModel = pModel;
												//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
												codec.arithValue = arithValue; 
												codec.arithLength = arithLength; 
												codec.bitBuf = bitBuf; 
												codec.bitCount = bitCount; 
												codec.decodeBufNext = decodeBufNext;
												//LZHAM_DECODE_NEEDS_BYTES
												
												//LZHAM_SAVE_STATE
												/*this.m_match_hist0 = matchHist0; 
												 this.m_match_hist1 = matchHist1; 
												 this.m_match_hist2 = matchHist2; 
												 this.m_match_hist3 = matchHist3;
												 this.m_cur_state = curState; 
												 this.m_dst_ofs = dstOfs;*/
												//are these even used, or am I in macro hell?
												for ( ; ; ){
													*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
													*this.outBufSize = 0;
													//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
													//what the fuck supposed to be this???
													//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
													status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
													yield();
													codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
													if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
												}
												//LZHAM_RESTORE_STATE
												/*matchHist0 = this.m_match_hist0; 
												 matchHist1 = this.m_match_hist1; 
												 matchHist2 = this.m_match_hist2; 
												 matchHist3 = this.m_match_hist3;
												 curState = this.m_cur_state; 
												 dstOfs = this.m_dst_ofs;*/
												//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
												arithValue = codec.arithValue;
												arithLength = codec.arithLength; 
												bitBuf = codec.bitBuf; 
												bitCount = codec.bitCount; 
												decodeBufNext = codec.decodeBufNext;
												pModel = codec.savedHuffModel;
												pTables = pModel.m_pDecodeTables;
											}
											//c = 0;
											if (decodeBufNext < codec.decodeBufEnd) c = *decodeBufNext++;
											bitCount += 8;
											bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
										}
									}else{
										//c = LZHAM_READ_BIG_ENDIAN_UINT32(decodeBufNext - sizeof(uint32));
										c = bigEndianToNative!(uint, 4)(*cast(ubyte[4]*)(decodeBufNext - uint.sizeof));
										bitCount += 32;
										bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
									}
								}
								uint k = cast(uint)((bitBuf >> (cBitBufSize - 16)) + 1);
								uint len;
								if (k <= pTables.tableMaxCode){
									uint t = pTables.lookup[bitBuf >> (cBitBufSize - pTables.tableBits)];
									r = t & ushort.max;//result = t & ushort.max;
									len = t >> 16;
								}else{
									len = pTables.decodeStartCodeSize;
									for ( ; ; ){
										if (k <= pTables.maxCodes[len - 1])
											break;
										len++;
									}
									int valPtr = pTables.valPtrs[len - 1] + cast(int)(bitBuf >> (cBitBufSize - len));
									if ((cast(uint)valPtr >= pModel.mTotalSyms)) valPtr = 0;
									r = pTables.sortedSymbolOrder[valPtr];//result = pTables.mSortedSymbolOrder[valPtr];
								}
								bitBuf <<= len;
								bitCount -= len;
								uint freq = pModel.mSymFreq[r];//uint freq = pModel.mSymFreq[result];
								freq++;
								pModel.mSymFreq[r] = cast(ushort)(freq);//pModel.mSymFreq[result] = cast(ushort)(freq);
								assert(freq <= ushort.max);
								if (--pModel.mSymbolsUntilUpdate == 0){
									pModel.updateTables();
								}
							}//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN END
							r ^= repLit0;
							pDst[dstOfs] = cast(ubyte)(r);
							
							//#ifdef LZHAM_LZDEBUG
							debug{
								//assert(pDst[dstOfs] == m_debug_lit);
							}
							//#endif
							
							/*#undef LZHAM_SAVE_LOCAL_STATE
							 #undef LZHAM_RESTORE_LOCAL_STATE
							 #define LZHAM_SAVE_LOCAL_STATE
							 #define LZHAM_RESTORE_LOCAL_STATE*/
						}
						
						curState = sLiteralNextState[curState];
						
						dstOfs++;
						static if(!unbuffered){
							if (dstOfs > dictSizeMask){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
								//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dict_size);
								//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);BEGIN
								//LZHAM_SAVE_STATE;
								/*this.m_match_hist0 = matchHist0; 
								 this.m_match_hist1 = matchHist1; 
								 this.m_match_hist2 = matchHist2; 
								 this.m_match_hist3 = matchHist3;
								 this.m_cur_state = curState; 
								 this.m_dst_ofs = dstOfs;*/
								pFlushSrc = decompBuf + seedBytesToIgnoreWhenFlushing + dstHighwaterOfs;  
								flushNumBytesRemaining = dictSize - seedBytesToIgnoreWhenFlushing - dstHighwaterOfs;
								seedBytesToIgnoreWhenFlushing = 0;
								dstHighwaterOfs = dictSize & dictSizeMask;
								while (flushNumBytesRemaining){
									//m_flush_n = LZHAM_MIN(m_flush_num_bytes_remaining, *m_pOut_buf_size);
									flushN = flushNumBytesRemaining > outBufSize ? origOutBufSize : flushNumBytesRemaining;
									if (0 == (params.decompressFlags & LZHAMDecompressFlags.COMPUTE_ADLER32)){
										memcpy(outBuf, pFlushSrc, flushN);
									}else{
										size_t copyOfs = 0;
										while (copyOfs < flushN){
											const uint cBytesToMemCpyPerIteration = 8192U;
											size_t helperValue = flushN - copyOfs;
											size_t bytesToCopy = helperValue > cBytesToMemCpyPerIteration ? cBytesToMemCpyPerIteration : helperValue;
											//LZHAM_MIN((size_t)(m_flush_n - copyOfs), cBytesToMemCpyPerIteration);  
											memcpy(this.outBuf + copyOfs, pFlushSrc + copyOfs, bytesToCopy);
											decompAdler32 = adler32(pFlushSrc + copyOfs, bytesToCopy, decompAdler32);  
											copyOfs += bytesToCopy;  
										}  
									} 
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = flushN;
									//LZHAM_CR_RETURN(m_state, m_flush_n ? LZHAM_DECOMP_STATUS_NOT_FINISHED : LZHAM_DECOMP_STATUS_HAS_MORE_OUTPUT);
									status = LZHAMDecompressionStatus.HAS_MORE_OUTPUT;
									yield();
									this.codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									pFlushSrc += flushN;
									flushNumBytesRemaining -= flushN;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
								 matchHist1 = this.m_match_hist1; 
								 matchHist2 = this.m_match_hist2; 
								 matchHist3 = this.m_match_hist3;
								 curState = this.m_cur_state; 
								 dstOfs = this.m_dst_ofs;*/
								//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);END
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec);
								dstOfs = 0;
							}
						}
					}else{
						// Handle match.
						uint matchLen;
						matchLen = 1;
						
						/*#undef LZHAM_SAVE_LOCAL_STATE
						 #undef LZHAM_RESTORE_LOCAL_STATE
						 #define LZHAM_SAVE_LOCAL_STATE m_match_len = match_len;
						 #define LZHAM_RESTORE_LOCAL_STATE match_len = m_match_len;*/
						
						// Determine if match is a rep_match, and if so what type.
						uint isRep; 
						//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, is_rep, m_is_rep_model[cur_state]);
						{//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) BEGIN
							AdaptiveBitModel *pModel;
							pModel = &isRepModel[curState];//pModel = &model;
							while (arithLength < cSymbolCodecArithMinLen){
								uint c; codec.savedModel = pModel;
								//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, c, 8);
								{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
									while (bitCount < cast(int)(8)){
										uint r;
										if (decodeBufNext == codec.decodeBufEnd){
											if (!codec.decodeBufEOF){
												//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
												codec.arithValue = arithValue; 
												codec.arithLength = arithLength; 
												codec.bitBuf = bitBuf; 
												codec.bitCount = bitCount; 
												codec.decodeBufNext = decodeBufNext;
												//LZHAM_DECODE_NEEDS_BYTES
												//LZHAM_SAVE_STATE
												/*this.m_match_hist0 = matchHist0; 
												 this.m_match_hist1 = matchHist1; 
												 this.m_match_hist2 = matchHist2; 
												 this.m_match_hist3 = matchHist3;
												 this.m_cur_state = curState; 
												 this.m_dst_ofs = dstOfs;*/
												//are these even used, or am I in macro hell?
												for ( ; ; ){
													*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
													*this.outBufSize = 0;
													//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
													//what the fuck supposed to be this???
													//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
													status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
													yield();
													codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
													if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
												}
												//LZHAM_RESTORE_STATE
												/*matchHist0 = this.m_match_hist0; 
												 matchHist1 = this.m_match_hist1; 
												 matchHist2 = this.m_match_hist2; 
												 matchHist3 = this.m_match_hist3;
												 curState = this.m_cur_state; 
												 dstOfs = this.m_dst_ofs;*/
												//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
												arithValue = codec.arithValue;
												arithLength = codec.arithLength; 
												bitBuf = codec.bitBuf; 
												bitCount = codec.bitCount; 
												decodeBufNext = codec.decodeBufNext;
											}
											r = 0; 
											if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
										}else
											r = *decodeBufNext++;
										bitCount += 8;// DO NOT TOUCH THIS!
										bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
									}
									c = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
									bitBuf <<= (8);
									bitCount -= (8);
								}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
								pModel = cast(AdaptiveBitModel*)(codec.savedModel);
								arithValue = (arithValue << 8) | c;
								arithLength <<= 8;
							}
							uint x = pModel.bit0Prob * (arithLength >> cSymbolCodecArithProbBits);
							isRep = (arithValue >= x);//result = (arithValue >= x);
							if (!isRep){//if (!result){
								pModel.bit0Prob += ((cSymbolCodecArithProbScale - pModel.bit0Prob) >> cSymbolCodecArithProbMoveBits);
								arithLength = x;
							}else{
								pModel.bit0Prob -= (pModel.bit0Prob >> cSymbolCodecArithProbMoveBits);
								arithValue  -= x;
								arithLength -= x;
							}
						}//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) END
						if (isRep){
							uint isRep0; 
							//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, isRep0, m_is_rep0_model[curState]);
							{//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) BEGIN
								AdaptiveBitModel *pModel;
								pModel = &isRep0Model[curState];//pModel = &model;
								while (arithLength < cSymbolCodecArithMinLen){
									uint c; codec.savedModel = pModel;
									//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, c, 8);
									{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										while (bitCount < cast(int)(8)){
											uint r;
											if (decodeBufNext == codec.decodeBufEnd){
												if (!codec.decodeBufEOF){
													//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
													codec.arithValue = arithValue; 
													codec.arithLength = arithLength; 
													codec.bitBuf = bitBuf; 
													codec.bitCount = bitCount; 
													codec.decodeBufNext = decodeBufNext;
													//LZHAM_DECODE_NEEDS_BYTES
													//LZHAM_SAVE_STATE
													/*this.m_match_hist0 = matchHist0; 
													 this.m_match_hist1 = matchHist1; 
													 this.m_match_hist2 = matchHist2; 
													 this.m_match_hist3 = matchHist3;
													 this.m_cur_state = curState; 
													 this.m_dst_ofs = dstOfs;*/
													//are these even used, or am I in macro hell?
													for ( ; ; ){
														*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
														*this.outBufSize = 0;
														//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
														//what the fuck supposed to be this???
														//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
														status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
														yield();
														codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
														if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
													}
													//LZHAM_RESTORE_STATE
													/*matchHist0 = this.m_match_hist0; 
													 matchHist1 = this.m_match_hist1; 
													 matchHist2 = this.m_match_hist2; 
													 matchHist3 = this.m_match_hist3;
													 curState = this.m_cur_state; 
													 dstOfs = this.m_dst_ofs;*/
													//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
													arithValue = codec.arithValue;
													arithLength = codec.arithLength; 
													bitBuf = codec.bitBuf; 
													bitCount = codec.bitCount; 
													decodeBufNext = codec.decodeBufNext;
												}
												r = 0; 
												if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
											}else
												r = *decodeBufNext++;
											bitCount += 8;// DO NOT TOUCH THIS!
											bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
										}
										c = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
										bitBuf <<= (8);
										bitCount -= (8);
									}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
									pModel = cast(AdaptiveBitModel*)(codec.savedModel);
									arithValue = (arithValue << 8) | c;
									arithLength <<= 8;
								}
								uint x = pModel.bit0Prob * (arithLength >> cSymbolCodecArithProbBits);
								isRep0 = (arithValue >= x);//result = (arithValue >= x);
								if (!isRep0){//if (!result){
									pModel.bit0Prob += ((cSymbolCodecArithProbScale - pModel.bit0Prob) >> cSymbolCodecArithProbMoveBits);
									arithLength = x;
								}else{
									pModel.bit0Prob -= (pModel.bit0Prob >> cSymbolCodecArithProbMoveBits);
									arithValue  -= x;
									arithLength -= x;
								}
							}//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) END
							if (isRep0){
								uint isRep0Len1; 
								//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, isRep0Len1, m_is_rep0_single_byte_model[curState]);
								{//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) BEGIN
									AdaptiveBitModel *pModel;
									pModel = &isRep0SingleByteModel[curState];//pModel = &model;
									while (arithLength < cSymbolCodecArithMinLen){
										uint c; codec.savedModel = pModel;
										//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, c, 8);
										{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
											while (bitCount < cast(int)(8)){
												uint r;
												if (decodeBufNext == codec.decodeBufEnd){
													if (!codec.decodeBufEOF){
														//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
														codec.arithValue = arithValue; 
														codec.arithLength = arithLength; 
														codec.bitBuf = bitBuf; 
														codec.bitCount = bitCount; 
														codec.decodeBufNext = decodeBufNext;
														//LZHAM_DECODE_NEEDS_BYTES
														//LZHAM_SAVE_STATE
														/*this.m_match_hist0 = matchHist0; 
														 this.m_match_hist1 = matchHist1; 
														 this.m_match_hist2 = matchHist2; 
														 this.m_match_hist3 = matchHist3;
														 this.m_cur_state = curState; 
														 this.m_dst_ofs = dstOfs;*/
														//are these even used, or am I in macro hell?
														for ( ; ; ){
															*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
															*this.outBufSize = 0;
															//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
															//what the fuck supposed to be this???
															//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
															status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
															yield();
															codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
															if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
														}
														//LZHAM_RESTORE_STATE
														/*matchHist0 = this.m_match_hist0; 
														 matchHist1 = this.m_match_hist1; 
														 matchHist2 = this.m_match_hist2; 
														 matchHist3 = this.m_match_hist3;
														 curState = this.m_cur_state; 
														 dstOfs = this.m_dst_ofs;*/
														//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
														arithValue = codec.arithValue;
														arithLength = codec.arithLength; 
														bitBuf = codec.bitBuf; 
														bitCount = codec.bitCount; 
														decodeBufNext = codec.decodeBufNext;
													}
													r = 0; 
													if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
												}else
													r = *decodeBufNext++;
												bitCount += 8;// DO NOT TOUCH THIS!
												bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
											}
											c = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
											bitBuf <<= (8);
											bitCount -= (8);
										}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										pModel = cast(AdaptiveBitModel*)(codec.savedModel);
										arithValue = (arithValue << 8) | c;
										arithLength <<= 8;
									}
									uint x = pModel.bit0Prob * (arithLength >> cSymbolCodecArithProbBits);
									isRep0Len1 = (arithValue >= x);//result = (arithValue >= x);
									if (!isRep0Len1){//if (!result){
										pModel.bit0Prob += ((cSymbolCodecArithProbScale - pModel.bit0Prob) >> cSymbolCodecArithProbMoveBits);
										arithLength = x;
									}else{
										pModel.bit0Prob -= (pModel.bit0Prob >> cSymbolCodecArithProbMoveBits);
										arithValue  -= x;
										arithLength -= x;
									}
								}//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) END
								if ((isRep0Len1)){
									curState = (curState < CLZDecompBase.cNumLitStates) ? 9 : 11;
								}else{
									//LZHAM_DECOMPRESS_DECODE_ADAPTIVE_SYMBOL(codec, matchLen, m_rep_len_table[cur_state >= CLZDecompBase::cNumLitStates]);
									//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN(codec, result, model) BEGIN
									{
										QuasiAdaptiveHuffmanDataModel pModel; 
										DecoderTables pTables;
										pModel = repLenTable[curState >= CLZDecompBase.cNumLitStates]; //pModel = &model; 
										pTables = repLenTable[curState >= CLZDecompBase.cNumLitStates].m_pDecodeTables;
										if (bitCount < 24){
											uint c;
											decodeBufNext += uint.sizeof;
											if (decodeBufNext >= codec.decodeBufEnd){
												decodeBufNext -= uint.sizeof;
												while (bitCount < 24){
													if (!codec.decodeBufEOF){
														codec.savedHuffModel = pModel;
														//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
														codec.arithValue = arithValue; 
														codec.arithLength = arithLength; 
														codec.bitBuf = bitBuf; 
														codec.bitCount = bitCount; 
														codec.decodeBufNext = decodeBufNext;
														//LZHAM_DECODE_NEEDS_BYTES
														
														//LZHAM_SAVE_STATE
														/*this.m_match_hist0 = matchHist0; 
														 this.m_match_hist1 = matchHist1; 
														 this.m_match_hist2 = matchHist2; 
														 this.m_match_hist3 = matchHist3;
														 this.m_cur_state = curState; 
														 this.m_dst_ofs = dstOfs;*/
														//are these even used, or am I in macro hell?
														for ( ; ; ){
															*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
															*this.outBufSize = 0;
															//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
															//what the fuck supposed to be this???
															//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
															status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
															yield();
															codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
															if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
														}
														//LZHAM_RESTORE_STATE
														/*matchHist0 = this.m_match_hist0; 
														 matchHist1 = this.m_match_hist1; 
														 matchHist2 = this.m_match_hist2; 
														 matchHist3 = this.m_match_hist3;
														 curState = this.m_cur_state; 
														 dstOfs = this.m_dst_ofs;*/
														//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
														arithValue = codec.arithValue;
														arithLength = codec.arithLength; 
														bitBuf = codec.bitBuf; 
														bitCount = codec.bitCount; 
														decodeBufNext = codec.decodeBufNext;
														pModel = codec.savedHuffModel;
														pTables = pModel.m_pDecodeTables;
													}
													//c = 0;
													if (decodeBufNext < codec.decodeBufEnd) c = *decodeBufNext++;
													bitCount += 8;
													bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
												}
											}else{
												//c = LZHAM_READ_BIG_ENDIAN_UINT32(decodeBufNext - sizeof(uint32));
												c = bigEndianToNative!(uint, 4)(*cast(ubyte[4]*)(decodeBufNext - uint.sizeof));
												bitCount += 32;
												bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
											}
										}
										uint k = cast(uint)((bitBuf >> (cBitBufSize - 16)) + 1);
										uint len;
										if (k <= pTables.tableMaxCode){
											uint t = pTables.lookup[bitBuf >> (cBitBufSize - pTables.tableBits)];
											matchLen = t & ushort.max;//result = t & ushort.max;
											len = t >> 16;
										}else{
											len = pTables.decodeStartCodeSize;
											for ( ; ; ){
												if (k <= pTables.maxCodes[len - 1])
													break;
												len++;
											}
											int valPtr = pTables.valPtrs[len - 1] + cast(int)(bitBuf >> (cBitBufSize - len));
											if ((cast(uint)valPtr >= pModel.mTotalSyms)) valPtr = 0;
											matchLen = pTables.sortedSymbolOrder[valPtr];//result = pTables.mSortedSymbolOrder[valPtr];
										}
										bitBuf <<= len;
										bitCount -= len;
										uint freq = pModel.mSymFreq[matchLen];
										freq++;
										pModel.mSymFreq[matchLen] = cast(ushort)(freq);//pModel.mSymFreq[result] = cast(ushort)(freq);
										assert(freq <= ushort.max);
										if (--pModel.mSymbolsUntilUpdate == 0){
											pModel.updateTables();
										}
									}//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN END
									matchLen += CLZDecompBase.cMinMatchLen;
									
									if (matchLen == (CLZDecompBase.cMaxMatchLen + 1)){
										// Decode "huge" match length.
										matchLen = 0;
										do {
											uint b; 
											//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, b, 1);
											{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
												while (bitCount < cast(int)(1)){
													uint r;
													if (decodeBufNext == codec.decodeBufEnd){
														if (!codec.decodeBufEOF){
															//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
															codec.arithValue = arithValue; 
															codec.arithLength = arithLength; 
															codec.bitBuf = bitBuf; 
															codec.bitCount = bitCount; 
															codec.decodeBufNext = decodeBufNext;
															//LZHAM_DECODE_NEEDS_BYTES
															//LZHAM_SAVE_STATE
															/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
															//are these even used, or am I in macro hell?
															for ( ; ; ){
																*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
																*this.outBufSize = 0;
																//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
																//what the fuck supposed to be this???
																//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
																status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
																yield();
																codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
																if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
															}
															//LZHAM_RESTORE_STATE
															/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
															//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
															arithValue = codec.arithValue;
															arithLength = codec.arithLength; 
															bitBuf = codec.bitBuf; 
															bitCount = codec.bitCount; 
															decodeBufNext = codec.decodeBufNext;
														}
														r = 0; 
														if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
													}else
														r = *decodeBufNext++;
													bitCount += 8;// DO NOT TOUCH THIS!
													bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
												}
												b = (1) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (1))) : 0;
												bitBuf <<= (1);
												bitCount -= (1);
											}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
											if (!b)
												break;
											matchLen++;
										} while (matchLen < 3);
										uint k; 
										//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, k, sHugeMatchCodeLen[matchLen]);
										{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
											while (bitCount < cast(int)(sHugeMatchCodeLen[matchLen])){
												uint r;
												if (decodeBufNext == codec.decodeBufEnd){
													if (!codec.decodeBufEOF){
														//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
														codec.arithValue = arithValue; 
														codec.arithLength = arithLength; 
														codec.bitBuf = bitBuf; 
														codec.bitCount = bitCount; 
														codec.decodeBufNext = decodeBufNext;
														//LZHAM_DECODE_NEEDS_BYTES
														//LZHAM_SAVE_STATE
														/*this.m_match_hist0 = matchHist0; 
														 this.m_match_hist1 = matchHist1; 
														 this.m_match_hist2 = matchHist2; 
														 this.m_match_hist3 = matchHist3;
														 this.m_cur_state = curState; 
														 this.m_dst_ofs = dstOfs;*/
														//are these even used, or am I in macro hell?
														for ( ; ; ){
															*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
															*this.outBufSize = 0;
															//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
															//what the fuck supposed to be this???
															//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
															status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
															yield();
															codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
															if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
														}
														//LZHAM_RESTORE_STATE
														/*matchHist0 = this.m_match_hist0; 
														 matchHist1 = this.m_match_hist1; 
														 matchHist2 = this.m_match_hist2; 
														 matchHist3 = this.m_match_hist3;
														 curState = this.m_cur_state; 
														 dstOfs = this.m_dst_ofs;*/
														//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
														arithValue = codec.arithValue;
														arithLength = codec.arithLength; 
														bitBuf = codec.bitBuf; 
														bitCount = codec.bitCount; 
														decodeBufNext = codec.decodeBufNext;
													}
													r = 0; 
													if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
												}else
													r = *decodeBufNext++;
												bitCount += 8;// DO NOT TOUCH THIS!
												bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
											}
											k = (sHugeMatchCodeLen[matchLen]) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (sHugeMatchCodeLen[matchLen]))) : 0;
											bitBuf <<= (sHugeMatchCodeLen[matchLen]);
											bitCount -= (sHugeMatchCodeLen[matchLen]);
										}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										matchLen = sHugeMatchBaseLen[matchLen] + k;
									}
									
									curState = (curState < CLZDecompBase.cNumLitStates) ? 8 : 11;
								}
							}else{
								//LZHAM_DECOMPRESS_DECODE_ADAPTIVE_SYMBOL(codec, matchLen, m_rep_len_table[cur_state >= CLZDecompBase.cNumLitStates]);
								//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN(codec, result, model) BEGIN
								{
									QuasiAdaptiveHuffmanDataModel pModel; 
									DecoderTables pTables;
									pModel = repLenTable[curState >= CLZDecompBase.cNumLitStates]; //pModel = &model; 
									pTables = repLenTable[curState >= CLZDecompBase.cNumLitStates].m_pDecodeTables;
									if (bitCount < 24){
										uint c;
										decodeBufNext += uint.sizeof;
										if (decodeBufNext >= codec.decodeBufEnd){
											decodeBufNext -= uint.sizeof;
											while (bitCount < 24){
												if (!codec.decodeBufEOF){
													codec.savedHuffModel = pModel;
													//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
													codec.arithValue = arithValue; 
													codec.arithLength = arithLength; 
													codec.bitBuf = bitBuf; 
													codec.bitCount = bitCount; 
													codec.decodeBufNext = decodeBufNext;
													//LZHAM_DECODE_NEEDS_BYTES
													
													//LZHAM_SAVE_STATE
													/*this.m_match_hist0 = matchHist0; 
													 this.m_match_hist1 = matchHist1; 
													 this.m_match_hist2 = matchHist2; 
													 this.m_match_hist3 = matchHist3;
													 this.m_cur_state = curState; 
													 this.m_dst_ofs = dstOfs;*/
													//are these even used, or am I in macro hell?
													for ( ; ; ){
														*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
														*this.outBufSize = 0;
														//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
														//what the fuck supposed to be this???
														//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
														status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
														yield();
														codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
														if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
													}
													//LZHAM_RESTORE_STATE
													/*matchHist0 = this.m_match_hist0; 
													 matchHist1 = this.m_match_hist1; 
													 matchHist2 = this.m_match_hist2; 
													 matchHist3 = this.m_match_hist3;
													 curState = this.m_cur_state; 
													 dstOfs = this.m_dst_ofs;*/
													//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
													arithValue = codec.arithValue;
													arithLength = codec.arithLength; 
													bitBuf = codec.bitBuf; 
													bitCount = codec.bitCount; 
													decodeBufNext = codec.decodeBufNext;
													pModel = codec.savedHuffModel;
													pTables = pModel.m_pDecodeTables;
												}
												//c = 0;
												if (decodeBufNext < codec.decodeBufEnd) c = *decodeBufNext++;
												bitCount += 8;
												bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
											}
										}else{
											//c = LZHAM_READ_BIG_ENDIAN_UINT32(decodeBufNext - sizeof(uint32));
											c = bigEndianToNative!(uint, 4)(*cast(ubyte[4]*)(decodeBufNext - uint.sizeof));
											bitCount += 32;
											bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
										}
									}
									uint k = cast(uint)((bitBuf >> (cBitBufSize - 16)) + 1);
									uint len;
									if (k <= pTables.tableMaxCode){
										uint t = pTables.lookup[bitBuf >> (cBitBufSize - pTables.tableBits)];
										matchLen = t & ushort.max;//result = t & ushort.max;
										len = t >> 16;
									}else{
										len = pTables.decodeStartCodeSize;
										for ( ; ; ){
											if (k <= pTables.maxCodes[len - 1])
												break;
											len++;
										}
										int valPtr = pTables.valPtrs[len - 1] + cast(int)(bitBuf >> (cBitBufSize - len));
										if ((cast(uint)valPtr >= pModel.mTotalSyms)) valPtr = 0;
										matchLen = pTables.sortedSymbolOrder[valPtr];//result = pTables.mSortedSymbolOrder[valPtr];
									}
									bitBuf <<= len;
									bitCount -= len;
									uint freq = pModel.mSymFreq[matchLen];
									freq++;
									pModel.mSymFreq[matchLen] = cast(ushort)(freq);//pModel.mSymFreq[result] = cast(ushort)(freq);
									assert(freq <= ushort.max);
									if (--pModel.mSymbolsUntilUpdate == 0){
										pModel.updateTables();
									}
								}//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN END
								matchLen += CLZDecompBase.cMinMatchLen;
								
								if (matchLen == (CLZDecompBase.cMaxMatchLen + 1)){
									// Decode "huge" match length.
									matchLen = 0;
									do {
										uint b; 
										//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, b, 1);
										{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
											while (bitCount < cast(int)(1)){
												uint r;
												if (decodeBufNext == codec.decodeBufEnd){
													if (!codec.decodeBufEOF){
														//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
														codec.arithValue = arithValue; 
														codec.arithLength = arithLength; 
														codec.bitBuf = bitBuf; 
														codec.bitCount = bitCount; 
														codec.decodeBufNext = decodeBufNext;
														//LZHAM_DECODE_NEEDS_BYTES
														//LZHAM_SAVE_STATE
														/*this.m_match_hist0 = matchHist0; 
														 this.m_match_hist1 = matchHist1; 
														 this.m_match_hist2 = matchHist2; 
														 this.m_match_hist3 = matchHist3;
														 this.m_cur_state = curState; 
														 this.m_dst_ofs = dstOfs;*/
														//are these even used, or am I in macro hell?
														for ( ; ; ){
															*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
															*this.outBufSize = 0;
															//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
															//what the fuck supposed to be this???
															//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
															status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
															yield();
															codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
															if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
														}
														//LZHAM_RESTORE_STATE
														/*matchHist0 = this.m_match_hist0; 
														 matchHist1 = this.m_match_hist1; 
														 matchHist2 = this.m_match_hist2; 
														 matchHist3 = this.m_match_hist3;
														 curState = this.m_cur_state; 
														 dstOfs = this.m_dst_ofs;*/
														//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
														arithValue = codec.arithValue;
														arithLength = codec.arithLength; 
														bitBuf = codec.bitBuf; 
														bitCount = codec.bitCount; 
														decodeBufNext = codec.decodeBufNext;
													}
													r = 0; 
													if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
												}else
													r = *decodeBufNext++;
												bitCount += 8;// DO NOT TOUCH THIS!
												bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
											}
											b = (1) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (1))) : 0;
											bitBuf <<= (1);
											bitCount -= (1);
										}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										if (!b)
											break;
										matchLen++;
									} while (matchLen < 3);
									uint k; 
									//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, k, s_huge_match_code_len[matchLen]);
									{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										while (bitCount < cast(int)(sHugeMatchCodeLen[matchLen])){
											uint r;
											if (decodeBufNext == codec.decodeBufEnd){
												if (!codec.decodeBufEOF){
													//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
													codec.arithValue = arithValue; 
													codec.arithLength = arithLength; 
													codec.bitBuf = bitBuf; 
													codec.bitCount = bitCount; 
													codec.decodeBufNext = decodeBufNext;
													//LZHAM_DECODE_NEEDS_BYTES
													//LZHAM_SAVE_STATE
													/*this.m_match_hist0 = matchHist0; 
													 this.m_match_hist1 = matchHist1; 
													 this.m_match_hist2 = matchHist2; 
													 this.m_match_hist3 = matchHist3;
													 this.m_cur_state = curState; 
													 this.m_dst_ofs = dstOfs;*/
													//are these even used, or am I in macro hell?
													for ( ; ; ){
														*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
														*this.outBufSize = 0;
														//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
														//what the fuck supposed to be this???
														//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
														status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
														yield();
														codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
														if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
													}
													//LZHAM_RESTORE_STATE
													/*matchHist0 = this.m_match_hist0; 
													 matchHist1 = this.m_match_hist1; 
													 matchHist2 = this.m_match_hist2; 
													 matchHist3 = this.m_match_hist3;
													 curState = this.m_cur_state; 
													 dstOfs = this.m_dst_ofs;*/
													//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
													arithValue = codec.arithValue;
													arithLength = codec.arithLength; 
													bitBuf = codec.bitBuf; 
													bitCount = codec.bitCount; 
													decodeBufNext = codec.decodeBufNext;
												}
												r = 0; 
												if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
											}else
												r = *decodeBufNext++;
											bitCount += 8;// DO NOT TOUCH THIS!
											bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
										}
										k = (sHugeMatchCodeLen[matchLen]) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (sHugeMatchCodeLen[matchLen]))) : 0;
										bitBuf <<= (sHugeMatchCodeLen[matchLen]);
										bitCount -= (sHugeMatchCodeLen[matchLen]);
									}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
									matchLen = sHugeMatchBaseLen[matchLen] + k;
								}
								
								uint isRep1; 
								//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, isRep1, m_is_rep1_model[curState]);
								{//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) BEGIN
									AdaptiveBitModel *pModel;
									pModel = &isRep1Model[curState];//pModel = &model;
									while (arithLength < cSymbolCodecArithMinLen){
										uint c; codec.savedModel = pModel;
										//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, c, 8);
										{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
											while (bitCount < cast(int)(8)){
												uint r;
												if (decodeBufNext == codec.decodeBufEnd){
													if (!codec.decodeBufEOF){
														//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
														codec.arithValue = arithValue; 
														codec.arithLength = arithLength; 
														codec.bitBuf = bitBuf; 
														codec.bitCount = bitCount; 
														codec.decodeBufNext = decodeBufNext;
														//LZHAM_DECODE_NEEDS_BYTES
														//LZHAM_SAVE_STATE
														/*this.m_match_hist0 = matchHist0; 
														 this.m_match_hist1 = matchHist1; 
														 this.m_match_hist2 = matchHist2; 
														 this.m_match_hist3 = matchHist3;
														 this.m_cur_state = curState; 
														 this.m_dst_ofs = dstOfs;*/
														//are these even used, or am I in macro hell?
														for ( ; ; ){
															*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
															*this.outBufSize = 0;
															//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
															//what the fuck supposed to be this???
															//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
															status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
															yield();
															codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
															if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
														}
														//LZHAM_RESTORE_STATE
														/*matchHist0 = this.m_match_hist0; 
														 matchHist1 = this.m_match_hist1; 
														 matchHist2 = this.m_match_hist2; 
														 matchHist3 = this.m_match_hist3;
														 curState = this.m_cur_state; 
														 dstOfs = this.m_dst_ofs;*/
														//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
														arithValue = codec.arithValue;
														arithLength = codec.arithLength; 
														bitBuf = codec.bitBuf; 
														bitCount = codec.bitCount; 
														decodeBufNext = codec.decodeBufNext;
													}
													r = 0; 
													if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
												}else
													r = *decodeBufNext++;
												bitCount += 8;// DO NOT TOUCH THIS!
												bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
											}
											c = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
											bitBuf <<= (8);
											bitCount -= (8);
										}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										pModel = cast(AdaptiveBitModel*)(codec.savedModel);
										arithValue = (arithValue << 8) | c;
										arithLength <<= 8;
									}
									uint x = pModel.bit0Prob * (arithLength >> cSymbolCodecArithProbBits);
									isRep1 = (arithValue >= x);//result = (arithValue >= x);
									if (!isRep1){//if (!result){
										pModel.bit0Prob += ((cSymbolCodecArithProbScale - pModel.bit0Prob) >> cSymbolCodecArithProbMoveBits);
										arithLength = x;
									}else{
										pModel.bit0Prob -= (pModel.bit0Prob >> cSymbolCodecArithProbMoveBits);
										arithValue  -= x;
										arithLength -= x;
									}
								}//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) END
								if (isRep1){
									uint temp = matchHist1;
									matchHist1 = matchHist0;
									matchHist0 = temp;
								}else{
									uint isRep2; 
									//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, isRep2, m_is_rep2_model[curState]);
									{//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) BEGIN
										AdaptiveBitModel *pModel;
										pModel = &isRep2Model[curState];//pModel = &model;
										while (arithLength < cSymbolCodecArithMinLen){
											uint c; codec.savedModel = pModel;
											//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, c, 8);
											{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
												while (bitCount < cast(int)(8)){
													uint r;
													if (decodeBufNext == codec.decodeBufEnd){
														if (!codec.decodeBufEOF){
															//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
															codec.arithValue = arithValue; 
															codec.arithLength = arithLength; 
															codec.bitBuf = bitBuf; 
															codec.bitCount = bitCount; 
															codec.decodeBufNext = decodeBufNext;
															//LZHAM_DECODE_NEEDS_BYTES
															//LZHAM_SAVE_STATE
															/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
															//are these even used, or am I in macro hell?
															for ( ; ; ){
																*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
																*this.outBufSize = 0;
																//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
																//what the fuck supposed to be this???
																//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
																status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
																yield();
																codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
																if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
															}
															//LZHAM_RESTORE_STATE
															/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
															//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
															arithValue = codec.arithValue;
															arithLength = codec.arithLength; 
															bitBuf = codec.bitBuf; 
															bitCount = codec.bitCount; 
															decodeBufNext = codec.decodeBufNext;
														}
														r = 0; 
														if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
													}else
														r = *decodeBufNext++;
													bitCount += 8;// DO NOT TOUCH THIS!
													bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
												}
												c = (8) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (8))) : 0;
												bitBuf <<= (8);
												bitCount -= (8);
											}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
											pModel = cast(AdaptiveBitModel*)(codec.savedModel);
											arithValue = (arithValue << 8) | c;
											arithLength <<= 8;
										}
										uint x = pModel.bit0Prob * (arithLength >> cSymbolCodecArithProbBits);
										isRep2 = (arithValue >= x);//result = (arithValue >= x);
										if (!isRep2){//if (!result){
											pModel.bit0Prob += ((cSymbolCodecArithProbScale - pModel.bit0Prob) >> cSymbolCodecArithProbMoveBits);
											arithLength = x;
										}else{
											pModel.bit0Prob -= (pModel.bit0Prob >> cSymbolCodecArithProbMoveBits);
											arithValue  -= x;
											arithLength -= x;
										}
									}//LZHAM_SYMBOL_CODEC_DECODE_ARITH_BIT(codec, result, model) END
									
									if (isRep2){
										// rep2
										uint temp = matchHist2;
										matchHist2 = matchHist1;
										matchHist1 = matchHist0;
										matchHist0 = temp;
									}else{
										// rep3
										uint temp = matchHist3;
										matchHist3 = matchHist2;
										matchHist2 = matchHist1;
										matchHist1 = matchHist0;
										matchHist0 = temp;
									}
								}
								
								curState = (curState < CLZDecompBase.cNumLitStates) ? 8 : 11;
							}
						}else{
							// Handle normal/full match.
							uint sym; 
							//LZHAM_DECOMPRESS_DECODE_ADAPTIVE_SYMBOL(codec, sym, m_main_table);
							//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN(codec, result, model) BEGIN
							{
								QuasiAdaptiveHuffmanDataModel pModel; 
								DecoderTables pTables;
								pModel = mainTable; //pModel = &model; 
								pTables = mainTable.m_pDecodeTables;
								if (bitCount < 24){
									uint c;
									decodeBufNext += uint.sizeof;
									if (decodeBufNext >= codec.decodeBufEnd){
										decodeBufNext -= uint.sizeof;
										while (bitCount < 24){
											if (!codec.decodeBufEOF){
												codec.savedHuffModel = pModel;
												//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
												codec.arithValue = arithValue; 
												codec.arithLength = arithLength; 
												codec.bitBuf = bitBuf; 
												codec.bitCount = bitCount; 
												codec.decodeBufNext = decodeBufNext;
												//LZHAM_DECODE_NEEDS_BYTES
												
												//LZHAM_SAVE_STATE
												/*this.m_match_hist0 = matchHist0; 
												 this.m_match_hist1 = matchHist1; 
												 this.m_match_hist2 = matchHist2; 
												 this.m_match_hist3 = matchHist3;
												 this.m_cur_state = curState; 
												 this.m_dst_ofs = dstOfs;*/
												//are these even used, or am I in macro hell?
												for ( ; ; ){
													*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
													*this.outBufSize = 0;
													//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
													//what the fuck supposed to be this???
													//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
													status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
													yield();
													codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
													if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
												}
												//LZHAM_RESTORE_STATE
												/*matchHist0 = this.m_match_hist0; 
												 matchHist1 = this.m_match_hist1; 
												 matchHist2 = this.m_match_hist2; 
												 matchHist3 = this.m_match_hist3;
												 curState = this.m_cur_state; 
												 dstOfs = this.m_dst_ofs;*/
												//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
												arithValue = codec.arithValue;
												arithLength = codec.arithLength; 
												bitBuf = codec.bitBuf; 
												bitCount = codec.bitCount; 
												decodeBufNext = codec.decodeBufNext;
												pModel = codec.savedHuffModel;
												pTables = pModel.m_pDecodeTables;
											}
											//c = 0;
											if (decodeBufNext < codec.decodeBufEnd) c = *decodeBufNext++;
											bitCount += 8;
											bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
										}
									}else{
										//c = LZHAM_READ_BIG_ENDIAN_UINT32(decodeBufNext - sizeof(uint32));
										c = bigEndianToNative!(uint, 4)(*cast(ubyte[4]*)(decodeBufNext - uint.sizeof));
										bitCount += 32;
										bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
									}
								}
								uint k = cast(uint)((bitBuf >> (cBitBufSize - 16)) + 1);
								uint len;
								if (k <= pTables.tableMaxCode){
									uint t = pTables.lookup[bitBuf >> (cBitBufSize - pTables.tableBits)];
									sym = t & ushort.max;//result = t & ushort.max;
									len = t >> 16;
								}else{
									len = pTables.decodeStartCodeSize;
									for ( ; ; ){
										if (k <= pTables.maxCodes[len - 1])
											break;
										len++;
									}
									int valPtr = pTables.valPtrs[len - 1] + cast(int)(bitBuf >> (cBitBufSize - len));
									if ((cast(uint)valPtr >= pModel.mTotalSyms)) valPtr = 0;
									sym = pTables.sortedSymbolOrder[valPtr];//result = pTables.mSortedSymbolOrder[valPtr];
								}
								bitBuf <<= len;
								bitCount -= len;
								uint freq = pModel.mSymFreq[sym];
								freq++;
								pModel.mSymFreq[sym] = cast(ushort)(freq);//pModel.mSymFreq[result] = cast(ushort)(freq);
								assert(freq <= ushort.max);
								if (--pModel.mSymbolsUntilUpdate == 0){
									pModel.updateTables();
								}
							}//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN END
							sym -= CLZDecompBase.cLZXNumSpecialLengths;
							
							if (cast(int)(sym) < 0){
								// Handle special symbols.
								if (cast(int)(sym) == (CLZDecompBase.cLZXSpecialCodeEndOfBlockCode - CLZDecompBase.cLZXNumSpecialLengths))
									break;
								else{
									// Must be cLZXSpecialCodePartialStateReset.
									matchHist0 = 1;
									matchHist1 = 1;
									matchHist2 = 1;
									matchHist3 = 1;
									curState = 0;
									continue;
								}
							}
							
							// Low 3 bits of symbol = match length category, higher bits = distance category.
							matchLen = (sym & 7) + 2;
							
							uint matchSlot;
							matchSlot = (sym >> 3) + CLZDecompBase.cLZXLowestUsableMatchSlot;
							
							/*#undef LZHAM_SAVE_LOCAL_STATE
							 #undef LZHAM_RESTORE_LOCAL_STATE
							 #define LZHAM_SAVE_LOCAL_STATE m_match_len = match_len; m_match_slot = match_slot;
							 #define LZHAM_RESTORE_LOCAL_STATE match_len = m_match_len; match_slot = m_match_slot;*/
							
							if (matchLen == 9){
								// Match is >= 9 bytes, decode the actual length.
								uint e; 
								//LZHAM_DECOMPRESS_DECODE_ADAPTIVE_SYMBOL(codec, e, largeLenTable[cur_state >= CLZDecompBase.cNumLitStates ? 1 : 0]);
								//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN(codec, result, model) BEGIN
								{
									QuasiAdaptiveHuffmanDataModel pModel; 
									DecoderTables pTables;
									pModel = largeLenTable[curState >= CLZDecompBase.cNumLitStates]; //pModel = &model; 
									pTables = largeLenTable[curState >= CLZDecompBase.cNumLitStates].m_pDecodeTables;
									if (bitCount < 24){
										uint c;
										decodeBufNext += uint.sizeof;
										if (decodeBufNext >= codec.decodeBufEnd){
											decodeBufNext -= uint.sizeof;
											while (bitCount < 24){
												if (!codec.decodeBufEOF){
													codec.savedHuffModel = pModel;
													//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
													codec.arithValue = arithValue; 
													codec.arithLength = arithLength; 
													codec.bitBuf = bitBuf; 
													codec.bitCount = bitCount; 
													codec.decodeBufNext = decodeBufNext;
													//LZHAM_DECODE_NEEDS_BYTES
													
													//LZHAM_SAVE_STATE
													/*this.m_match_hist0 = matchHist0; 
													 this.m_match_hist1 = matchHist1; 
													 this.m_match_hist2 = matchHist2; 
													 this.m_match_hist3 = matchHist3;
													 this.m_cur_state = curState; 
													 this.m_dst_ofs = dstOfs;*/
													//are these even used, or am I in macro hell?
													for ( ; ; ){
														*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
														*this.outBufSize = 0;
														//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
														//what the fuck supposed to be this???
														//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
														status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
														yield();
														codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
														if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
													}
													//LZHAM_RESTORE_STATE
													/*matchHist0 = this.m_match_hist0; 
													 matchHist1 = this.m_match_hist1; 
													 matchHist2 = this.m_match_hist2; 
													 matchHist3 = this.m_match_hist3;
													 curState = this.m_cur_state; 
													 dstOfs = this.m_dst_ofs;*/
													//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
													arithValue = codec.arithValue;
													arithLength = codec.arithLength; 
													bitBuf = codec.bitBuf; 
													bitCount = codec.bitCount; 
													decodeBufNext = codec.decodeBufNext;
													pModel = codec.savedHuffModel;
													pTables = pModel.m_pDecodeTables;
												}
												//c = 0;
												if (decodeBufNext < codec.decodeBufEnd) c = *decodeBufNext++;
												bitCount += 8;
												bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
											}
										}else{
											//c = LZHAM_READ_BIG_ENDIAN_UINT32(decodeBufNext - sizeof(uint32));
											c = bigEndianToNative!(uint, 4)(*cast(ubyte[4]*)(decodeBufNext - uint.sizeof));
											bitCount += 32;
											bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
										}
									}
									uint k = cast(uint)((bitBuf >> (cBitBufSize - 16)) + 1);
									uint len;
									if (k <= pTables.tableMaxCode){
										uint t = pTables.lookup[bitBuf >> (cBitBufSize - pTables.tableBits)];
										e = t & ushort.max;//result = t & ushort.max;
										len = t >> 16;
									}else{
										len = pTables.decodeStartCodeSize;
										for ( ; ; ){
											if (k <= pTables.maxCodes[len - 1])
												break;
											len++;
										}
										int valPtr = pTables.valPtrs[len - 1] + cast(int)(bitBuf >> (cBitBufSize - len));
										if ((cast(uint)valPtr >= pModel.mTotalSyms)) valPtr = 0;
										e = pTables.sortedSymbolOrder[valPtr];//result = pTables.mSortedSymbolOrder[valPtr];
									}
									bitBuf <<= len;
									bitCount -= len;
									uint freq = pModel.mSymFreq[e];
									freq++;
									pModel.mSymFreq[e] = cast(ushort)(freq);//pModel.mSymFreq[result] = cast(ushort)(freq);
									assert(freq <= ushort.max);
									if (--pModel.mSymbolsUntilUpdate == 0){
										pModel.updateTables();
									}
								}//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN END
								matchLen += e;
								
								if (matchLen == (CLZDecompBase.cMaxMatchLen + 1)){
									// Decode "huge" match length.
									matchLen = 0;
									do {
										uint b; 
										//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, b, 1);
										{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
											while (bitCount < cast(int)(1)){
												uint r;
												if (decodeBufNext == codec.decodeBufEnd){
													if (!codec.decodeBufEOF){
														//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
														codec.arithValue = arithValue; 
														codec.arithLength = arithLength; 
														codec.bitBuf = bitBuf; 
														codec.bitCount = bitCount; 
														codec.decodeBufNext = decodeBufNext;
														//LZHAM_DECODE_NEEDS_BYTES
														//LZHAM_SAVE_STATE
														/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
														//are these even used, or am I in macro hell?
														for ( ; ; ){
															*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
															*this.outBufSize = 0;
															//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
															//what the fuck supposed to be this???
															//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
															status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
															yield();
															codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
															if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
														}
														//LZHAM_RESTORE_STATE
														/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
														//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
														arithValue = codec.arithValue;
														arithLength = codec.arithLength; 
														bitBuf = codec.bitBuf; 
														bitCount = codec.bitCount; 
														decodeBufNext = codec.decodeBufNext;
													}
													r = 0; 
													if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
												}else
													r = *decodeBufNext++;
												bitCount += 8;// DO NOT TOUCH THIS!
												bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
											}
											b = (1) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (1))) : 0;
											bitBuf <<= (1);
											bitCount -= (1);
										}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										if (!b)
											break;
										matchLen++;
									} while (matchLen < 3);
									uint k; 
									//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, k, s_huge_match_code_len[matchLen]);
									{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										while (bitCount < cast(int)(sHugeMatchCodeLen[matchLen])){
											uint r;
											if (decodeBufNext == codec.decodeBufEnd){
												if (!codec.decodeBufEOF){
													//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
													codec.arithValue = arithValue; 
													codec.arithLength = arithLength; 
													codec.bitBuf = bitBuf; 
													codec.bitCount = bitCount; 
													codec.decodeBufNext = decodeBufNext;
													//LZHAM_DECODE_NEEDS_BYTES
													//LZHAM_SAVE_STATE
													/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
													//are these even used, or am I in macro hell?
													for ( ; ; ){
														*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
														*this.outBufSize = 0;
														//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
														//what the fuck supposed to be this???
														//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
														status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
														yield();
														codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
														if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
													}
													//LZHAM_RESTORE_STATE
													/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
													//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
													arithValue = codec.arithValue;
													arithLength = codec.arithLength; 
													bitBuf = codec.bitBuf; 
													bitCount = codec.bitCount; 
													decodeBufNext = codec.decodeBufNext;
												}
												r = 0; 
												if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
											}else
												r = *decodeBufNext++;
											bitCount += 8;// DO NOT TOUCH THIS!
											bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
										}
										k = (sHugeMatchCodeLen[matchLen]) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (sHugeMatchCodeLen[matchLen]))) : 0;
										bitBuf <<= (sHugeMatchCodeLen[matchLen]);
										bitCount -= (sHugeMatchCodeLen[matchLen]);
									}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
									matchLen = sHugeMatchBaseLen[matchLen] + k;
								}
							}
							
							uint numExtraBits;
							numExtraBits = lzBase.mLZXPositionBase[matchSlot];
							
							uint extraBits;
							
							/*#undef LZHAM_SAVE_LOCAL_STATE
							 #undef LZHAM_RESTORE_LOCAL_STATE
							 #define LZHAM_SAVE_LOCAL_STATE m_match_len = match_len; m_match_slot = match_slot; m_num_extra_bits = num_extra_bits;
							 #define LZHAM_RESTORE_LOCAL_STATE match_len = m_match_len; match_slot = m_match_slot; num_extra_bits = m_num_extra_bits;*/
							
							if (numExtraBits < 3){
								//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, extraBits, numExtraBits);
								{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
									while (bitCount < cast(int)(numExtraBits)){
										uint r;
										if (decodeBufNext == codec.decodeBufEnd){
											if (!codec.decodeBufEOF){
												//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
												codec.arithValue = arithValue; 
												codec.arithLength = arithLength; 
												codec.bitBuf = bitBuf; 
												codec.bitCount = bitCount; 
												codec.decodeBufNext = decodeBufNext;
												//LZHAM_DECODE_NEEDS_BYTES
												//LZHAM_SAVE_STATE
												/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
												//are these even used, or am I in macro hell?
												for ( ; ; ){
													*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
													*this.outBufSize = 0;
													//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
													//what the fuck supposed to be this???
													//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
													status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
													yield();
													codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
													if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
												}
												//LZHAM_RESTORE_STATE
												/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
												//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
												arithValue = codec.arithValue;
												arithLength = codec.arithLength; 
												bitBuf = codec.bitBuf; 
												bitCount = codec.bitCount; 
												decodeBufNext = codec.decodeBufNext;
											}
											r = 0; 
											if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
										}else
											r = *decodeBufNext++;
										bitCount += 8;// DO NOT TOUCH THIS!
										bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
									}
									extraBits = (numExtraBits) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (numExtraBits))) : 0;
									bitBuf <<= (numExtraBits);
									bitCount -= (numExtraBits);
								}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
							}else{
								extraBits = 0;
								if (numExtraBits > 4){
									//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, extraBits, numExtraBits - 4);
									{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
										while (bitCount < cast(int)(numExtraBits - 4)){
											uint r;
											if (decodeBufNext == codec.decodeBufEnd){
												if (!codec.decodeBufEOF){
													//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
													codec.arithValue = arithValue; 
													codec.arithLength = arithLength; 
													codec.bitBuf = bitBuf; 
													codec.bitCount = bitCount; 
													codec.decodeBufNext = decodeBufNext;
													//LZHAM_DECODE_NEEDS_BYTES
													//LZHAM_SAVE_STATE
													/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
													//are these even used, or am I in macro hell?
													for ( ; ; ){
														*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
														*this.outBufSize = 0;
														//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
														//what the fuck supposed to be this???
														//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
														status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
														yield();
														codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
														if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
													}
													//LZHAM_RESTORE_STATE
													/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
													//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
													arithValue = codec.arithValue;
													arithLength = codec.arithLength; 
													bitBuf = codec.bitBuf; 
													bitCount = codec.bitCount; 
													decodeBufNext = codec.decodeBufNext;
												}
												r = 0; 
												if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
											}else
												r = *decodeBufNext++;
											bitCount += 8;// DO NOT TOUCH THIS!
											bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
										}
										extraBits = (numExtraBits - 4) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (numExtraBits - 4))) : 0;
										bitBuf <<= (numExtraBits - 4);
										bitCount -= (numExtraBits - 4);
									}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
									extraBits <<= 4;
								}
								
								/*#undef LZHAM_SAVE_LOCAL_STATE
								 #undef LZHAM_RESTORE_LOCAL_STATE
								 #define LZHAM_SAVE_LOCAL_STATE m_match_len = match_len; m_match_slot = match_slot; m_extra_bits = extra_bits;
								 #define LZHAM_RESTORE_LOCAL_STATE match_len = m_match_len; match_slot = m_match_slot; extra_bits = m_extra_bits;*/
								
								uint j; 
								//LZHAM_DECOMPRESS_DECODE_ADAPTIVE_SYMBOL(codec, j, distLsbTable);
								//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN(codec, result, model) BEGIN
								{
									QuasiAdaptiveHuffmanDataModel pModel; 
									DecoderTables pTables;
									pModel = distLsbTable; //pModel = &model; 
									pTables = distLsbTable.m_pDecodeTables;
									if (bitCount < 24){
										uint c;
										decodeBufNext += uint.sizeof;
										if (decodeBufNext >= codec.decodeBufEnd){
											decodeBufNext -= uint.sizeof;
											while (bitCount < 24){
												if (!codec.decodeBufEOF){
													codec.savedHuffModel = pModel;
													//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
													codec.arithValue = arithValue; 
													codec.arithLength = arithLength; 
													codec.bitBuf = bitBuf; 
													codec.bitCount = bitCount; 
													codec.decodeBufNext = decodeBufNext;
													//LZHAM_DECODE_NEEDS_BYTES
													
													//LZHAM_SAVE_STATE
													/*this.m_match_hist0 = matchHist0; 
													 this.m_match_hist1 = matchHist1; 
													 this.m_match_hist2 = matchHist2; 
													 this.m_match_hist3 = matchHist3;
													 this.m_cur_state = curState; 
													 this.m_dst_ofs = dstOfs;*/
													//are these even used, or am I in macro hell?
													for ( ; ; ){
														*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
														*this.outBufSize = 0;
														//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
														//what the fuck supposed to be this???
														//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
														status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
														yield();
														codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
														if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
													}
													//LZHAM_RESTORE_STATE
													/*matchHist0 = this.m_match_hist0; 
													 matchHist1 = this.m_match_hist1; 
													 matchHist2 = this.m_match_hist2; 
													 matchHist3 = this.m_match_hist3;
													 curState = this.m_cur_state; 
													 dstOfs = this.m_dst_ofs;*/
													//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
													arithValue = codec.arithValue;
													arithLength = codec.arithLength; 
													bitBuf = codec.bitBuf; 
													bitCount = codec.bitCount; 
													decodeBufNext = codec.decodeBufNext;
													pModel = codec.savedHuffModel;
													pTables = pModel.m_pDecodeTables;
												}
												//c = 0;
												if (decodeBufNext < codec.decodeBufEnd) c = *decodeBufNext++;
												bitCount += 8;
												bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
											}
										}else{
											//c = LZHAM_READ_BIG_ENDIAN_UINT32(decodeBufNext - sizeof(uint32));
											c = bigEndianToNative!(uint, 4)(*cast(ubyte[4]*)(decodeBufNext - uint.sizeof));
											bitCount += 32;
											bitBuf |= (cast(size_t)(c) << (cBitBufSize - bitCount));
										}
									}
									uint k = cast(uint)((bitBuf >> (cBitBufSize - 16)) + 1);
									uint len;
									if (k <= pTables.tableMaxCode){
										uint t = pTables.lookup[bitBuf >> (cBitBufSize - pTables.tableBits)];
										j = t & ushort.max;//result = t & ushort.max;
										len = t >> 16;
									}else{
										len = pTables.decodeStartCodeSize;
										for ( ; ; ){
											if (k <= pTables.maxCodes[len - 1])
												break;
											len++;
										}
										int valPtr = pTables.valPtrs[len - 1] + cast(int)(bitBuf >> (cBitBufSize - len));
										if ((cast(uint)valPtr >= pModel.mTotalSyms)) valPtr = 0;
										j = pTables.sortedSymbolOrder[valPtr];//result = pTables.mSortedSymbolOrder[valPtr];
									}
									bitBuf <<= len;
									bitCount -= len;
									uint freq = pModel.mSymFreq[j];
									freq++;
									pModel.mSymFreq[j] = cast(ushort)(freq);//pModel.mSymFreq[result] = cast(ushort)(freq);
									assert(freq <= ushort.max);
									if (--pModel.mSymbolsUntilUpdate == 0){
										pModel.updateTables();
									}
								}//LZHAM_SYMBOL_CODEC_DECODE_ADAPTIVE_HUFFMAN END
								extraBits += j;
							}
							
							matchHist3 = matchHist2;
							matchHist2 = matchHist1;
							matchHist1 = matchHist0;
							matchHist0 = lzBase.mLZXPositionBase[matchSlot] + extraBits;
							
							curState = (curState < CLZDecompBase.cNumLitStates) ? CLZDecompBase.cNumLitStates : CLZDecompBase.cNumLitStates + 3;
							
							/*#undef LZHAM_SAVE_LOCAL_STATE
							 #undef LZHAM_RESTORE_LOCAL_STATE
							 #define LZHAM_SAVE_LOCAL_STATE m_match_len = match_len;
							 #define LZHAM_RESTORE_LOCAL_STATE match_len = m_match_len;*/
						}
						
						// We have the match's length and distance, now do the copy.
						
						//#ifdef LZHAM_LZDEBUG
						debug{
							/*LZHAM_VERIFY(matchLen == m_debug_match_len);
							 LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_debug_match_dist, 25);
							 uint d; LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, d, 4);
							 m_debug_match_dist = (m_debug_match_dist << 4) | d;
							 assert(cast(uint)matchHist0 == m_debug_match_dist);*/
						}
						//#endif
						static if(unbuffered){
							if ( (unbuffered) && ((cast(size_t)matchHist0 > dstOfs) || ((dstOfs + matchLen) > outBufSize)) ){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								*inBufSize = cast(size_t)(codec.decodeGetBytesConsumed());
								*this.outBufSize = 0;
								//for ( ; ; ) { LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_FAILED_BAD_CODE); }
								yieldAndThrow(new LZHAMException("Bad code!"));
							}
						}
						
						uint srcOfs;
						ubyte* copySrc;
						srcOfs = (dstOfs - matchHist0) & dictSizeMask;
						copySrc = pDst + srcOfs;
						
						//#undef LZHAM_SAVE_LOCAL_STATE
						//#undef LZHAM_RESTORE_LOCAL_STATE
						//#define LZHAM_SAVE_LOCAL_STATE m_match_len = match_len; m_src_ofs = src_ofs; m_pCopy_src = pCopy_src;
						//#define LZHAM_RESTORE_LOCAL_STATE match_len = m_match_len; src_ofs = m_src_ofs; pCopy_src = m_pCopy_src;
						int helperValue = srcOfs > dstOfs ? srcOfs : dstOfs;//LZHAM_MAX(srcOfs, dst_ofs)
						static if(!unbuffered){
							if ( (helperValue + matchLen) > dictSizeMask ){
								// Match source or destination wraps around the end of the dictionary to the beginning, so handle the copy one byte at a time.
								do{
									pDst[dstOfs++] = *copySrc++;
									
									if (copySrc == pDstEnd)
										copySrc = pDst;
									
									if (dstOfs > dictSizeMask){
										//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
										codec.arithValue = arithValue; 
										codec.arithLength = arithLength; 
										codec.bitBuf = bitBuf; 
										codec.bitCount = bitCount; 
										codec.decodeBufNext = decodeBufNext;
										//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dict_size);
										//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);BEGIN
										//LZHAM_SAVE_STATE;
										/*this.m_match_hist0 = matchHist0; 
										 this.m_match_hist1 = matchHist1; 
										 this.m_match_hist2 = matchHist2; 
										 this.m_match_hist3 = matchHist3;
										 this.m_cur_state = curState; 
										 this.m_dst_ofs = dstOfs;*/
										pFlushSrc = decompBuf + seedBytesToIgnoreWhenFlushing + dstHighwaterOfs;  
										flushNumBytesRemaining = dictSize - seedBytesToIgnoreWhenFlushing - dstHighwaterOfs;
										seedBytesToIgnoreWhenFlushing = 0;
										dstHighwaterOfs = dictSize & dictSizeMask;
										while (flushNumBytesRemaining){
											//m_flush_n = LZHAM_MIN(m_flush_num_bytes_remaining, *m_pOut_buf_size);
											flushN = flushNumBytesRemaining > outBufSize ? origOutBufSize : flushNumBytesRemaining;
											if (0 == (params.decompressFlags & LZHAMDecompressFlags.COMPUTE_ADLER32)){
												memcpy(outBuf, pFlushSrc, flushN);
											}else{
												size_t copyOfs = 0;
												while (copyOfs < flushN){
													const uint cBytesToMemCpyPerIteration = 8192U;
													size_t helperValue0 = flushN - copyOfs;
													size_t bytesToCopy = helperValue0 > cBytesToMemCpyPerIteration ? cBytesToMemCpyPerIteration : helperValue;
													//LZHAM_MIN((size_t)(m_flush_n - copyOfs), cBytesToMemCpyPerIteration);  
													memcpy(outBuf + copyOfs, pFlushSrc + copyOfs, bytesToCopy);
													decompAdler32 = adler32(pFlushSrc + copyOfs, bytesToCopy, decompAdler32);  
													copyOfs += bytesToCopy;  
												}  
											} 
											*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
											*this.outBufSize = flushN;
											//LZHAM_CR_RETURN(m_state, m_flush_n ? LZHAM_DECOMP_STATUS_NOT_FINISHED : LZHAM_DECOMP_STATUS_HAS_MORE_OUTPUT);
											status = LZHAMDecompressionStatus.HAS_MORE_OUTPUT;
											yield();
											this.codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
											pFlushSrc += flushN;
											flushNumBytesRemaining -= flushN;
										}
										//LZHAM_RESTORE_STATE
										/*matchHist0 = this.m_match_hist0; 
										 matchHist1 = this.m_match_hist1; 
										 matchHist2 = this.m_match_hist2; 
										 matchHist3 = this.m_match_hist3;
										 curState = this.m_cur_state; 
										 dstOfs = this.m_dst_ofs;*/
										//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);END
										//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec);
										arithValue = codec.arithValue;
										arithLength = codec.arithLength; 
										bitBuf = codec.bitBuf; 
										bitCount = codec.bitCount; 
										decodeBufNext = codec.decodeBufNext;
										dstOfs = 0;
									}
									
									matchLen--;
								} while (matchLen > 0);
							}else{
								ubyte* copyDst = pDst + dstOfs;
								if (matchHist0 == 1){
									// Handle byte runs.
									ubyte c = *copySrc;
									if (matchLen < 8){
										for (int i = matchLen; i > 0; i--)
											*copyDst++ = c;
									}else{
										memset(copyDst, c, matchLen);
									}
								}else{
									// Handle matches of length 2 or higher.
									if ((matchLen < 8) || (cast(int)matchLen > matchHist0)){
										for (int i = matchLen; i > 0; i--)
											*copyDst++ = *copySrc++;
									}else{
										memcpy(copyDst, copySrc, matchLen);
									}
								}
								dstOfs += matchLen;
							}
						}
					} // lit or match
					
					//#undef LZHAM_SAVE_LOCAL_STATE
					//#undef LZHAM_RESTORE_LOCAL_STATE
					//#define LZHAM_SAVE_LOCAL_STATE
					//#define LZHAM_RESTORE_LOCAL_STATE
				} // for ( ; ; )
				
				//#ifdef LZHAM_LZDEBUG
				uint endSyncMarker; 
				//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, endSyncMarker, 12);
				{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
					while (bitCount < cast(int)(12)){
						uint r;
						if (decodeBufNext == codec.decodeBufEnd){
							if (!codec.decodeBufEOF){
								//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
								codec.arithValue = arithValue; 
								codec.arithLength = arithLength; 
								codec.bitBuf = bitBuf; 
								codec.bitCount = bitCount; 
								codec.decodeBufNext = decodeBufNext;
								//LZHAM_DECODE_NEEDS_BYTES
								//LZHAM_SAVE_STATE
								/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
								//are these even used, or am I in macro hell?
								for ( ; ; ){
									*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
									*this.outBufSize = 0;
									//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
									//what the fuck supposed to be this???
									//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
									status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
									yield();
									codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
									if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
								}
								//LZHAM_RESTORE_STATE
								/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
								//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
								arithValue = codec.arithValue;
								arithLength = codec.arithLength; 
								bitBuf = codec.bitBuf; 
								bitCount = codec.bitCount; 
								decodeBufNext = codec.decodeBufNext;
							}
							r = 0; 
							if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
						}else
							r = *decodeBufNext++;
						bitCount += 8;// DO NOT TOUCH THIS!
						bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
					}
					endSyncMarker = (12) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (12))) : 0;
					bitBuf <<= (12);
					bitCount -= (12);
				}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				assert(endSyncMarker == 366);
				//#endif
				//LZHAM_SYMBOL_CODEC_DECODE_ALIGN_TO_BYTE(codec);
			}else if (blockType == CLZDecompBase.cEOFBlock)	{
				// Received EOF.
				status = LZHAMDecompressionStatus.SUCCESS;
				state2 = LZHAMDecompressionStatus.SUCCESS;
			}else{
				// This block type is currently undefined.
				status = LZHAMDecompressionStatus.FAILED_BAD_CODE;
				state2 = LZHAMDecompressionStatus.FAILED_BAD_CODE;
			}
			
			debug blockIndex++;
			
		}while (state2 == LZHAMDecompressionStatus.NOT_FINISHED);
		static if(!unbuffered)
		if ((dstOfs)){
			
			//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
			codec.arithValue = arithValue; 
			codec.arithLength = arithLength; 
			codec.bitBuf = bitBuf; 
			codec.bitCount = bitCount; 
			codec.decodeBufNext = decodeBufNext;
			//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);
			//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);BEGIN
			//LZHAM_SAVE_STATE;
			/*this.m_match_hist0 = matchHist0; 
			 this.m_match_hist1 = matchHist1; 
			 this.m_match_hist2 = matchHist2; 
			 this.m_match_hist3 = matchHist3;
			 this.m_cur_state = curState; 
			 this.m_dst_ofs = dstOfs;*/
			pFlushSrc = decompBuf + seedBytesToIgnoreWhenFlushing + dstHighwaterOfs;  
			flushNumBytesRemaining = dstOfs - seedBytesToIgnoreWhenFlushing - dstHighwaterOfs;
			seedBytesToIgnoreWhenFlushing = 0;
			dstHighwaterOfs = dstOfs & dictSizeMask;
			while (flushNumBytesRemaining){
				//m_flush_n = LZHAM_MIN(m_flush_num_bytes_remaining, *m_pOut_buf_size);
				flushN = flushNumBytesRemaining > outBufSize ? origOutBufSize : flushNumBytesRemaining;
				if (0 == (params.decompressFlags & LZHAMDecompressFlags.COMPUTE_ADLER32)){
					memcpy(outBuf, pFlushSrc, flushN);
				}else{
					size_t copyOfs = 0;
					while (copyOfs < flushN){
						const uint cBytesToMemCpyPerIteration = 8192U;
						size_t helperValue = flushN - copyOfs;
						size_t bytesToCopy = helperValue > cBytesToMemCpyPerIteration ? cBytesToMemCpyPerIteration : helperValue;
						//LZHAM_MIN((size_t)(m_flush_n - copyOfs), cBytesToMemCpyPerIteration);  
						memcpy(outBuf + copyOfs, pFlushSrc + copyOfs, bytesToCopy);
						decompAdler32 = adler32(pFlushSrc + copyOfs, bytesToCopy, decompAdler32);  
						copyOfs += bytesToCopy;  
					}  
				} 
				*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
				*this.outBufSize = flushN;
				//LZHAM_CR_RETURN(m_state, m_flush_n ? LZHAM_DECOMP_STATUS_NOT_FINISHED : LZHAM_DECOMP_STATUS_HAS_MORE_OUTPUT);
				status = LZHAMDecompressionStatus.HAS_MORE_OUTPUT;
				yield();
				this.codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
				pFlushSrc += flushN;
				flushNumBytesRemaining -= flushN;
			}
			//LZHAM_RESTORE_STATE
			/*matchHist0 = this.m_match_hist0; 
			 matchHist1 = this.m_match_hist1; 
			 matchHist2 = this.m_match_hist2; 
			 matchHist3 = this.m_match_hist3;
			 curState = this.m_cur_state; 
			 dstOfs = this.m_dst_ofs;*/
			//LZHAM_FLUSH_DICT_TO_OUTPUT_BUFFER(dst_ofs);END
			//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec);
			arithValue = codec.arithValue;
			arithLength = codec.arithLength; 
			bitBuf = codec.bitBuf; 
			bitCount = codec.bitCount; 
			decodeBufNext = codec.decodeBufNext;
		}
		
		if (status == LZHAMDecompressionStatus.SUCCESS){
			//LZHAM_SYMBOL_CODEC_DECODE_ALIGN_TO_BYTE(codec);
			
			//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, m_file_src_file_adler32, 16);
			{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				while (bitCount < cast(int)(16)){
					uint r;
					if (decodeBufNext == codec.decodeBufEnd){
						if (!codec.decodeBufEOF){
							//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
							codec.arithValue = arithValue; 
							codec.arithLength = arithLength; 
							codec.bitBuf = bitBuf; 
							codec.bitCount = bitCount; 
							codec.decodeBufNext = decodeBufNext;
							//LZHAM_DECODE_NEEDS_BYTES
							//LZHAM_SAVE_STATE
							/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
							//are these even used, or am I in macro hell?
							for ( ; ; ){
								*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
								*this.outBufSize = 0;
								//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
								//what the fuck supposed to be this???
								//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
								status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
								yield();
								codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
								if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
							}
							//LZHAM_RESTORE_STATE
							/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
							//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
							arithValue = codec.arithValue;
							arithLength = codec.arithLength; 
							bitBuf = codec.bitBuf; 
							bitCount = codec.bitCount; 
							decodeBufNext = codec.decodeBufNext;
						}
						r = 0; 
						if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
					}else
						r = *decodeBufNext++;
					bitCount += 8;// DO NOT TOUCH THIS!
					bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
				}
				fileSrcFileAdler32 = (16) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (16))) : 0;
				bitBuf <<= (16);
				bitCount -= (16);
			}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
			uint l; 
			//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS(codec, l, 16);
			{//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
				while (bitCount < cast(int)(16)){
					uint r;
					if (decodeBufNext == codec.decodeBufEnd){
						if (!codec.decodeBufEOF){
							//LZHAM_SYMBOL_CODEC_DECODE_END(codec)
							codec.arithValue = arithValue; 
							codec.arithLength = arithLength; 
							codec.bitBuf = bitBuf; 
							codec.bitCount = bitCount; 
							codec.decodeBufNext = decodeBufNext;
							//LZHAM_DECODE_NEEDS_BYTES
							//LZHAM_SAVE_STATE
							/*this.m_match_hist0 = matchHist0; 
															 this.m_match_hist1 = matchHist1; 
															 this.m_match_hist2 = matchHist2; 
															 this.m_match_hist3 = matchHist3;
															 this.m_cur_state = curState; 
															 this.m_dst_ofs = dstOfs;*/
							//are these even used, or am I in macro hell?
							for ( ; ; ){
								*inBufSize = cast(size_t)(this.codec.decodeGetBytesConsumed());
								*this.outBufSize = 0;
								//LZHAM_CR_RETURN(m_state, LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT);
								//what the fuck supposed to be this???
								//(state, result) do { state = __LINE__; return (result); case __LINE__:; } while (0)
								status = LZHAMDecompressionStatus.NEEDS_MORE_INPUT;
								yield();
								codec.decodeSetInputBuffer(inBuf, *inBufSize, inBuf, noMoreInputBytesFlag);
								if ((this.codec.decodeBufEOF) || (this.codec.decodeBufSize)) break;
							}
							//LZHAM_RESTORE_STATE
							/*matchHist0 = this.m_match_hist0; 
															 matchHist1 = this.m_match_hist1; 
															 matchHist2 = this.m_match_hist2; 
															 matchHist3 = this.m_match_hist3;
															 curState = this.m_cur_state; 
															 dstOfs = this.m_dst_ofs;*/
							//LZHAM_SYMBOL_CODEC_DECODE_BEGIN(codec)
							arithValue = codec.arithValue;
							arithLength = codec.arithLength; 
							bitBuf = codec.bitBuf; 
							bitCount = codec.bitCount; 
							decodeBufNext = codec.decodeBufNext;
						}
						r = 0; 
						if (decodeBufNext < codec.decodeBufNext) r = *decodeBufNext++;
					}else
						r = *decodeBufNext++;
					bitCount += 8;// DO NOT TOUCH THIS!
					bitBuf |= (cast(size_t)(r) << (SymbolCodec.cBitBufSize - bitCount));// DO NOT TOUCH THIS!
				}
				l = (16) ? cast(uint)(bitBuf >> (SymbolCodec.cBitBufSize - (16))) : 0;
				bitBuf <<= (16);
				bitCount -= (16);
			}//LZHAM_SYMBOL_CODEC_DECODE_GET_BITS
			fileSrcFileAdler32 = (fileSrcFileAdler32 << 16) | l;
			
			if (params.decompressFlags & LZHAMDecompressFlags.COMPUTE_ADLER32){
				static if (unbuffered){
					decompAdler32 = adler32(pDst, dstOfs);
				}
				
				if (fileSrcFileAdler32 != decompAdler32){
					status = LZHAMDecompressionStatus.FAILED_ADLER32;
				}
			}
			else
			{
				decompAdler32 = fileSrcFileAdler32;
			}
		}
		
		//LZHAM_SYMBOL_CODEC_DECODE_END(codec);
		codec.arithValue = arithValue; 
		codec.arithLength = arithLength; 
		codec.bitBuf = bitBuf; 
		codec.bitCount = bitCount; 
		codec.decodeBufNext = decodeBufNext;
		
		*inBufSize = cast(size_t)(codec.stopDecoding());
		*this.outBufSize = unbuffered ? (dstOfs - dstHighwaterOfs) : 0;
		dstHighwaterOfs = dstOfs;
		
		//LZHAM_CR_RETURN(m_state, m_status);
		//yield;
		
		/*for ( ; ; )
		{
			*inBufSize = 0;
			*outBufSize = 0;
			//LZHAM_CR_RETURN(m_state, m_status);
			yield;
		}*/
		
		
		
	}
	
	void resetHuffTables(){
		litTable.reset();
		deltaLitTable.reset();
		
		mainTable.reset();
		
		for (uint i = 0; i < repLenTable.length; i++)
			repLenTable[i].reset();
		
		for (uint i = 0; i < largeLenTable.length; i++)
			largeLenTable[i].reset();
		
		distLsbTable.reset();
	}
	void resetArithTables(){
		for (uint i = 0; i < isMatchModel.length; i++)
			isMatchModel[i].clear();
		
		for (uint i = 0; i < CLZDecompBase.cNumStates; i++)
		{
			isRepModel[i].clear();
			isRep0Model[i].clear();
			isRep0SingleByteModel[i].clear();
			isRep1Model[i].clear();
			isRep2Model[i].clear();
		}
	}
	void resetAllTables(){
		resetHuffTables;
		resetArithTables;
	}
	void resetHuffmanTableUpdateRates(){
		litTable.resetUpdateRate();
		deltaLitTable.resetUpdateRate();
		
		mainTable.resetUpdateRate();
		
		for (uint i ; i < repLenTable.length; i++)
			repLenTable[i].resetUpdateRate();
		
		for (uint i ; i < largeLenTable.length; i++)
			largeLenTable[i].resetUpdateRate();
		
		distLsbTable.resetUpdateRate();
	}
}

package @nogc static bool checkParams(const LZHAMDecompressionParameters *pParams){
	if ((!pParams) || (pParams.structSize != LZHAMDecompressionParameters.sizeof))
		return false;
	
	if ((pParams.dictSizeLog2 < CLZDecompBase.cMinDictSizeLog2) || (pParams.dictSizeLog2 > CLZDecompBase.cMaxDictSizeLog2))
		return false;
	
	if (pParams.numSeedBytes){
		if (((pParams.decompressFlags & LZHAMDecompressFlags.OUTPUT_UNBUFFERED) != 0) || (!pParams.seedBytes))
			return false;
		if (pParams.numSeedBytes > (1U << pParams.dictSizeLog2))
			return false;
	}
	return true;
}
/**
 * Initializes decompressor from parameters.
 */
public LZHAMDecompressor decompressInit(LZHAMDecompressionParameters* params){
	if (!checkParams(params))
		return null;
	
	LZHAMDecompressor decompressor;

	//pState->m_params = *pParams;
	
	if (params.decompressFlags & LZHAMDecompressFlags.OUTPUT_UNBUFFERED){
		decompressor = new LZHAMDecompressor(true);
		decompressor.params = *params;
		decompressor.rawDecompBuf = null;
		decompressor.rawDecompBufSize = 0;
		decompressor.decompBuf = null;
	}else{
		decompressor = new LZHAMDecompressor(false);
		decompressor.params = *params;
		const uint decompBufSize = 1U << decompressor.params.dictSizeLog2;
		decompressor.rawDecompBuf = cast(ubyte*)(malloc(decompBufSize + 15));
		/*if (!pState->m_pRaw_decomp_buf)
		{
			lzham_delete(pState);
			return NULL;
		}*/
		decompressor.rawDecompBufSize = decompBufSize;
		//pState->m_pDecomp_buf = math::align_up_pointer(pState->m_pRaw_decomp_buf, 16);
	}
	
	decompressor.init();
	
	return decompressor;
}
/**
 * Reinitializes decompressor for faster
 */
public LZHAMDecompressor decompressReinit(LZHAMDecompressor decompressor, LZHAMDecompressionParameters* params){
	if (!decompressor)
		return decompressInit(params);
	
	LZHAMDecompressor decomp2 = decompressor;

	if (!checkParams(params))
		return null;
	
	if (decomp2.params.decompressFlags & LZHAMDecompressFlags.OUTPUT_UNBUFFERED){
		free(decomp2.rawDecompBuf);
		decomp2.rawDecompBuf = null;
		decomp2.rawDecompBufSize = 0;
		decomp2.decompBuf = null;
	}else{
		uint newDictSize = 1U << decomp2.params.dictSizeLog2;
		if ((!decomp2.rawDecompBuf) || (decomp2.rawDecompBufSize < newDictSize))
		{
			ubyte *pNewDict = cast(ubyte*)(realloc(decomp2.rawDecompBuf, newDictSize + 15));
			if (!pNewDict)
				return null;
			decomp2.rawDecompBuf = pNewDict;
			decomp2.rawDecompBufSize = newDictSize;
			//decomp2->m_pDecomp_buf = math::align_up_pointer(pState->m_pRaw_decomp_buf, 16);
		}
	}
	
	decomp2.params = *params;
	
	decomp2.init();
	
	decomp2.resetArithTables();
	return decompressor;
}
/**
 * Deinitializes the decompressor.
 * The reference of the decompressor should be set to null, so the garbage collector can destroy it.
 */
public uint decompressDeinit(LZHAMDecompressor decompressor){
	if(decompressor is null)
		return 0;
	free(decompressor.rawDecompBuf);
	return decompressor.decompAdler32;
}
/**
 * Decompresses an LZHAM stream
 */
public LZHAMDecompressionStatus decompress(LZHAMDecompressor decompressor, ubyte* inBuf, size_t* inBufSize, 
				ubyte* outBuf, size_t* outBufSize, bool noMoreInputBytesFlag){
	if ((decompressor is null) || (!decompressor.params.dictSizeLog2) || (!inBufSize) || (!outBufSize)){
		return LZHAMDecompressionStatus.INVALID_PARAMETER;
	}
	
	if ((*inBufSize) && (!inBuf)){
		return LZHAMDecompressionStatus.INVALID_PARAMETER;
	}
	
	if ((*outBufSize) && (!outBuf)){
		return LZHAMDecompressionStatus.INVALID_PARAMETER;
	}
	
	decompressor.inBuf = inBuf;
	decompressor.inBufSize = inBufSize;
	decompressor.outBuf = outBuf;
	decompressor.outBufSize = outBufSize;
	decompressor.noMoreInputBytesFlag = noMoreInputBytesFlag;
	
	if (decompressor.params.decompressFlags & LZHAMDecompressFlags.OUTPUT_UNBUFFERED){
		if (!decompressor.origOutBuf){
			decompressor.origOutBuf = outBuf;
			decompressor.origOutBufSize = *outBufSize;
		}else{
			// In unbuffered mode, the caller is not allowed to move the output buffer and the output pointer MUST always point to the beginning of the output buffer.
			// Also, the output buffer size must indicate the full size of the output buffer. The decompressor will track the current output offset, and during partial/sync
			// flushes it'll report how many bytes it has written since the call. 
			if ((decompressor.origOutBuf != outBuf) || (decompressor.origOutBufSize != *outBufSize)){
				return LZHAMDecompressionStatus.INVALID_PARAMETER;
			}
		}
	}
	
	//LZHAMDecompressionStatus status;
	
	/*if (pState->m_params.m_decompress_flags & LZHAM_DECOMP_FLAG_OUTPUT_UNBUFFERED)
		status = pState->decompress();
	else
		status = pState->decompress<false>();*/
	decompressor.call;


	return decompressor.status;
}
public LZHAMDecompressionStatus decompressMem(LZHAMDecompressionParameters* pParams, ubyte* destBuf, size_t destSize, ubyte* srcBuf, size_t srcSize, uint* pAdler32){
	if (pParams is null)
		return LZHAMDecompressionStatus.INVALID_PARAMETER;
	
	LZHAMDecompressionParameters params = *pParams;
	params.decompressFlags |= LZHAMDecompressFlags.OUTPUT_UNBUFFERED;

	LZHAMDecompressor compressor = decompressInit(&params);
	if (compressor is null)
		return LZHAMDecompressionStatus.FAILED_INITIALIZING;
	
	LZHAMDecompressionStatus status = decompress(compressor, srcBuf, &srcSize, destBuf, &destSize, true);
	
	uint adler32 = decompressDeinit(compressor);
	if (pAdler32 !is null)
		*pAdler32 = adler32;
	
	return status;
}
public int z_inflateInit(LZHAMZStream* pStream){
	return z_inflateInit2(pStream, LZHAM_Z_DEFAULT_WINDOW_BITS);
}
public int z_inflateInit2(LZHAMZStream* pStream, int windowBits){
	if (pStream is null) 
		return LZHAM_Z_STREAM_ERROR;
	int maxWindowBits;// = LZHAM_64BIT_POINTERS ? LZHAM_MAX_DICT_SIZE_LOG2_X64 : LZHAM_MAX_DICT_SIZE_LOG2_X86;
	static if(CPU_64BIT_CAPABLE){
		maxWindowBits = LZHAM_MAX_DICT_SIZE_LOG2_X64;
	}else{
		maxWindowBits = LZHAM_MAX_DICT_SIZE_LOG2_X86;
	}
	if (labs(windowBits) > maxWindowBits)
		return LZHAM_Z_PARAM_ERROR;
	
	if (labs(windowBits) < LZHAM_MIN_DICT_SIZE_LOG2)
		windowBits = (windowBits < 0) ? -1 * LZHAM_MIN_DICT_SIZE_LOG2 : LZHAM_MIN_DICT_SIZE_LOG2;
	
	LZHAMDecompressionParameters params;
	//utils::zero_object(params);
	params.structSize = params.sizeof;
	params.dictSizeLog2 = cast(uint)(labs(windowBits));
	
	params.decompressFlags = LZHAMDecompressFlags.COMPUTE_ADLER32;
	if (windowBits > 0)
		params.decompressFlags |= LZHAMDecompressFlags.READ_ZLIB_STREAM;
	
	LZHAMDecompressor decompressor = decompressInit(&params);
	if (!decompressor)
		return LZHAM_Z_MEM_ERROR;
	pStream.stateDecomp = decompressor;
	
	pStream.data_type = 0;
	pStream.adler = 1;
	pStream.msg = null;
	pStream.total_in = 0;
	pStream.total_out = 0;
	pStream.reserved = 0;
	
	return LZHAM_Z_OK;
}
public int z_inflateReset(LZHAMZStream* pStream){
	if ((pStream is null) || (pStream.stateDecomp is null)) 
		return LZHAM_Z_STREAM_ERROR;
	
	LZHAMDecompressor pDecomp = pStream.stateDecomp;
	//lzham_decompressor *pDecomp = static_cast<lzham_decompressor *>(pState);
	
	LZHAMDecompressionParameters params = pDecomp.params; //LZHAMDecompressionParameters(pDecomp.params);
	
	if (!decompressReinit(pDecomp, &params))
		return LZHAM_Z_STREAM_ERROR;
	
	return LZHAM_Z_OK;
}
public int z_inflate(LZHAMZStream* pStream, int flush){
	if ((pStream is null) || (pStream.stateDecomp is null)) 
		return LZHAM_Z_STREAM_ERROR;
	
	if ((flush == LZHAM_Z_PARTIAL_FLUSH) || (flush == LZHAM_Z_FULL_FLUSH))
		flush = LZHAM_Z_SYNC_FLUSH;
	if (flush){
		if ((flush != LZHAM_Z_SYNC_FLUSH) && (flush != LZHAM_Z_FINISH)) 
			return LZHAM_Z_STREAM_ERROR;
	}

	size_t origAvailIn = pStream.avail_in;
	
	//LZHAMDecompressionStatus pState = pStream.state;
	LZHAMDecompressor pDecomp = pStream.stateDecomp;
	if (pDecomp.lastStatus >= LZHAMCompressionStatus.FIRST_SUCCESS_OR_FAILURE_CODE)
		return LZHAM_Z_DATA_ERROR;

	if (pDecomp.m_z_has_flushed && (flush != LZHAM_Z_FINISH)) 
		return LZHAM_Z_STREAM_ERROR;
	pDecomp.m_z_has_flushed |= (flush == LZHAM_Z_FINISH);
	
	LZHAMDecompressionStatus status;
	for ( ; ; ){
		size_t inBytes = pStream.avail_in;
		size_t outBytes = pStream.avail_out;
		bool noMoreInputBytesFlag = (flush == LZHAM_Z_FINISH);
		status = decompress(pDecomp, pStream.next_in, &inBytes, pStream.next_out, &outBytes, noMoreInputBytesFlag);
		
		pDecomp.lastStatus = status;
		
		pStream.next_in += cast(uint)inBytes; 
		pStream.avail_in -= cast(uint)inBytes;
		pStream.total_in += cast(uint)inBytes; 
		pStream.adler = pDecomp.decompAdler32;
		
		pStream.next_out += cast(uint)outBytes;
		pStream.avail_out -= cast(uint)outBytes;
		pStream.total_out += cast(uint)outBytes;
		
		if (status >= LZHAMCompressionStatus.FIRST_SUCCESS_OR_FAILURE_CODE){
			if (status == LZHAMDecompressionStatus.FAILED_NEED_SEED_BYTES)
				return LZHAM_Z_NEED_DICT;
			else 
				return LZHAM_Z_DATA_ERROR; // Stream is corrupted (there could be some uncompressed data left in the output dictionary - oh well).
		}
		
		if ((status == LZHAMDecompressionStatus.NEEDS_MORE_INPUT) && (!origAvailIn)){
			return LZHAM_Z_BUF_ERROR; // Signal caller that we can't make forward progress without supplying more input, or by setting flush to LZHAM_Z_FINISH.
		}else if (flush == LZHAM_Z_FINISH){
			// Caller has indicated that all remaining input was at next_in, and all remaining output will fit entirely in next_out.
			// (The output buffer at next_out MUST be large to hold the remaining uncompressed data when flush==LZHAM_Z_FINISH).
			if (status == LZHAMDecompressionStatus.SUCCESS)
				return LZHAM_Z_STREAM_END;
			// If status is LZHAM_DECOMP_STATUS_HAS_MORE_OUTPUT, there must be at least 1 more byte on the way but the caller to lzham_decompress() supplied an empty output buffer.
			// Something is wrong because the caller's output buffer should be large enough to hold the entire decompressed stream when flush==LZHAM_Z_FINISH.
			else if (status == LZHAMDecompressionStatus.HAS_MORE_OUTPUT)
				return LZHAM_Z_BUF_ERROR;
		}else if ((status == LZHAMDecompressionStatus.SUCCESS) || (!pStream.avail_in) || (!pStream.avail_out))
			break;
	}
	
	return (status == LZHAMDecompressionStatus.SUCCESS) ? LZHAM_Z_STREAM_END : LZHAM_Z_OK;
}
public int z_inflateEnd(LZHAMZStream* pStream){
	if (pStream is null)
		return LZHAM_Z_STREAM_ERROR;

	//lzham_decompress_state_ptr pState = static_cast<lzham_decompress_state_ptr>(pStream->state);
	if (pStream.stateDecomp !is null){
		pStream.adler = decompressDeinit(pStream.stateDecomp);
		pStream.stateDecomp = null;
	}
	
	return LZHAM_Z_OK;
}
public int z_decompress(ubyte* pDest, ulong* pDest_len, ubyte* pSource, size_t source_len){
	LZHAMZStream stream;
	int status;
	//memset(&stream, 0, stream.sizeof);
	
	// In case lzham_z_ulong is 64-bits (argh I hate longs).
	if ((source_len | *pDest_len) > 0xFFFFFFFFU) 
		return LZHAM_Z_PARAM_ERROR;

	stream.next_in = pSource;
	stream.avail_in = cast(uint)source_len;
	stream.next_out = pDest;
	stream.avail_out = cast(uint)*pDest_len;
	
	status = z_inflateInit(&stream);
	if (status != LZHAM_Z_OK)
		return status;
	
	status = z_inflate(&stream, LZHAM_Z_FINISH);
	if (status != LZHAM_Z_STREAM_END){
		z_inflateEnd(&stream);
		return ((status == LZHAM_Z_BUF_ERROR) && (!stream.avail_in)) ? LZHAM_Z_DATA_ERROR : status;
	}
	*pDest_len = stream.total_out;
	
	return z_inflateEnd(&stream);
}
/**
 * Decided to replace the internal algorithm with an associative array.
 */
public char* z_error(int err){
	/*static struct 
	{ 
		int m_err; 
		const char *m_pDesc; 
	} 
	s_error_descs[] =
	{
		{ LZHAM_Z_OK, "" }, 
		{ LZHAM_Z_STREAM_END, "stream end" }, 
		{ LZHAM_Z_NEED_DICT, "need dictionary" }, 
		{ LZHAM_Z_ERRNO, "file error" }, 
		{ LZHAM_Z_STREAM_ERROR, "stream error" },
		{ LZHAM_Z_DATA_ERROR, "data error" }, 
		{ LZHAM_Z_MEM_ERROR, "out of memory" }, 
		{ LZHAM_Z_BUF_ERROR, "buf error" }, 
		{ LZHAM_Z_VERSION_ERROR, "version error" }, 
		{ LZHAM_Z_PARAM_ERROR, "parameter error" }
	};*/
	/*for (uint i = 0; i < sizeof(s_error_descs) / sizeof(s_error_descs[0]); ++i) 
		if (s_error_descs[i].m_err == err) 
			return s_error_descs[i].m_pDesc;*/
	if(zErrorCodes.get(err, null) is null)
		return null;
	return cast(char*)zErrorCodes[err].ptr;
}

public size_t z_adler32(size_t adler, ubyte* ptr, size_t buf_len){
	return adler32(ptr, buf_len, cast(uint)(adler));
}

public size_t z_crc32(size_t crc, ubyte *ptr, size_t buf_len){
	//return crc32(cast(uint)(crc), ptr, buf_len);
	ubyte[] result = crc32(cast(uint)(crc), ptr, buf_len);
	size_t subresult;
	for(int i; i < result.length; i++){
		subresult |= result[i]<<(i * 8);
	}
	return subresult;
}

package static string[int] zErrorCodes;
static this(){
	zErrorCodes[LZHAM_Z_OK] = "";
	zErrorCodes[LZHAM_Z_STREAM_END] = "stream end";
	zErrorCodes[LZHAM_Z_NEED_DICT] = "need dictionary";
	zErrorCodes[LZHAM_Z_ERRNO] =  "file error";
	zErrorCodes[LZHAM_Z_STREAM_ERROR] =  "stream error";
	zErrorCodes[LZHAM_Z_DATA_ERROR] =  "data error"; 
	zErrorCodes[LZHAM_Z_MEM_ERROR] =  "out of memory";
	zErrorCodes[LZHAM_Z_BUF_ERROR] =  "buf error";
	zErrorCodes[LZHAM_Z_VERSION_ERROR] =  "version error"; 
	zErrorCodes[LZHAM_Z_PARAM_ERROR] =  "parameter error";
}