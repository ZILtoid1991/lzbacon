module lzbacon.compression;

import lzbacon.common;
import lzbacon.base;
import lzbacon.decompbase;
import lzbacon.compInternal;
import lzbacon.system;

import core.stdc.stdlib;
import core.stdc.string;

import conv = std.conv;

static LZHAMCompressionStatus create_internal_init_params(LZCompressor.InitParams* internalParams, const LZHAMCompressionParameters* pParams){
	if ((pParams.dictSizeLog2 < CLZBase.cMinDictSizeLog2) || (pParams.dictSizeLog2 > CLZBase.cMaxDictSizeLog2))
		return LZHAMCompressionStatus.INVALID_PARAMETER;
	
	internalParams.m_dict_size_log2 = pParams.dictSizeLog2;
	
	if (pParams.maxHelperThreads < 0)
		internalParams.m_max_helper_threads = 1;//internalParams.m_max_helper_threads = lzham_get_max_helper_threads();
	else
		internalParams.m_max_helper_threads = pParams.maxHelperThreads;
	//internalParams.m_max_helper_threads = LZHAM_MIN(LZHAM_MAX_HELPER_THREADS, internalParams.m_max_helper_threads);
	
	internalParams.m_lzham_compress_flags = pParams.compressFlags;
	
	if (pParams.numSeedBytes){
		if ((!pParams.pSeedBytes) || (pParams.numSeedBytes > (1U << pParams.dictSizeLog2)))
			return LZHAMCompressionStatus.INVALID_PARAMETER;
		
		internalParams.m_num_seed_bytes = pParams.numSeedBytes;
		internalParams.m_pSeed_bytes = cast(void*)pParams.pSeedBytes;
	}
	internalParams.m_compression_level = pParams.level;
	/*switch (pParams->m_level)
	 {
	 case LZHAM_COMP_LEVEL_FASTEST:   internalParams.m_compression_level = cCompressionLevelFastest; break;
	 case LZHAM_COMP_LEVEL_FASTER:    internalParams.m_compression_level = cCompressionLevelFaster; break;
	 case LZHAM_COMP_LEVEL_DEFAULT:   internalParams.m_compression_level = cCompressionLevelDefault; break;
	 case LZHAM_COMP_LEVEL_BETTER:    internalParams.m_compression_level = cCompressionLevelBetter; break;
	 case LZHAM_COMP_LEVEL_UBER:      internalParams.m_compression_level = cCompressionLevelUber; break;
	 default:
	 return LZHAM_COMP_STATUS_INVALID_PARAMETER;
	 };*/
	
	if (pParams.tableMaxUpdateInterval || pParams.tableUpdateIntervalSlowRate){
		internalParams.m_table_max_update_interval = pParams.tableMaxUpdateInterval;
		internalParams.m_table_update_interval_slow_rate = pParams.tableUpdateIntervalSlowRate;
	}else{
		uint rate = pParams.tableUpdateRate;
		if (!rate)
			rate = LZHAMTableUpdateRate.DEFAULT;
		//rate = math::clamp<uint>(rate, 1, LZHAM_FASTEST_TABLE_UPDATE_RATE) - 1;
		if(rate >= LZHAMTableUpdateRate.FASTEST)
			rate = LZHAMTableUpdateRate.FASTEST;
		else if(rate < 1)
			rate = 1;
		
		internalParams.m_table_max_update_interval = gTableUpdateSettings[rate].maxUpdateInterval;
		internalParams.m_table_update_interval_slow_rate = gTableUpdateSettings[rate].slowRate;
	}
	
	return LZHAMCompressionStatus.SUCCESS;
}

public LZHAMCompressState* compressInit(LZHAMCompressionParameters* params){
	if (!params)
		return null;

	if ((params.dictSizeLog2 < CLZBase.cMinDictSizeLog2) || (params.dictSizeLog2 > CLZBase.cMaxDictSizeLog2))
		return null;
	
	LZCompressor.InitParams internalParams;
	LZHAMCompressionStatus status = create_internal_init_params(&internalParams, params);
	if (status != LZHAMCompressionStatus.SUCCESS)
		return null;
	
	LZHAMCompressState* state = cast(LZHAMCompressState*)malloc(LZHAMCompressState.sizeof);
	if (!state)
		return null;

	state.params = *params;
	
	state.inBuf = null;
	state.inBufSize = null;
	state.outBuf = null;
	state.outBufSize = null;
	state.status = LZHAMCompressionStatus.NOT_FINISHED;
	state.compDataOfs = 0;
	state.finishedCompression = false;
	
	if (internalParams.m_max_helper_threads){
		/*if (!state.m_tp.init(internalParams.m_max_helper_threads))	{
			free(state);
			return null;
		}*/
		/*if (state.m_tp.get_num_threads() >= internalParams.m_max_helper_threads){
			internalParams.m_pTask_pool = &state->m_tp;
		}else{
			internalParams.m_max_helper_threads = 0;
		}*/
	}
	state.compressor = new LZCompressor();
	if (!state.compressor._init(internalParams)){
		free(state);
		return null;
	}
	
	return state;
}
public LZHAMCompressState* compressReinit(LZHAMCompressState* state){
	//lzham_compress_state *pState = static_cast<lzham_compress_state*>(p);
	if (state){
		if (!state.compressor.reset())
			return null;
		
		state.inBuf = null;
		state.inBufSize = null;
		state.outBuf = null;
		state.outBufSize = null;
		state.status = LZHAMCompressionStatus.NOT_FINISHED;
		state.compDataOfs = 0;
		state.finishedCompression= false;
	}
	
	return state;
}
public uint compressDeinit(LZHAMCompressState* state){
	if (!state)
		return 0;
	
	uint adler32 = state.compressor.get_src_adler32();
	state.compressor.destroy();
	free(state);
	
	return adler32;
}
public LZHAMCompressionStatus compress(LZHAMCompressState* state, ubyte* inBuf, size_t* inBufSize, ubyte* outBuf, 
		size_t* outBufSize, bool noMoreInputBytesFlag){
	return compress2(state, inBuf, inBufSize, outBuf, outBufSize, noMoreInputBytesFlag ? LZHAMFlushTypes.FINISH : 
			LZHAMFlushTypes.NO_FLUSH);
}
public LZHAMCompressionStatus compress2(LZHAMCompressState* state, ubyte* inBuf, size_t* inBufSize, ubyte* outBuf, 
		size_t* outBufSize, LZHAMFlushTypes flushType){
	//lzham_compress_state *pState = static_cast<lzham_compress_state*>(p);
	//if(state.inBuf != inBuf){
	/*state.inBuf = inBuf;
	state.inBufSize = inBufSize;
	state.outBuf = outBuf;
	state.outBufSize = outBufSize;*/
	//}
	
	if ((!state) || (!state.params.dictSizeLog2) || (state.status >= LZHAMCompressionStatus.FIRST_SUCCESS_OR_FAILURE_CODE) 
			|| (!inBufSize) || (!outBufSize))
		return LZHAMCompressionStatus.INVALID_PARAMETER;
	
	if ((*inBufSize) && (!inBuf))
		return LZHAMCompressionStatus.INVALID_PARAMETER;
	
	if ((!*outBufSize) || (!outBuf))
		return LZHAMCompressionStatus.INVALID_PARAMETER;
	
	ubyte[] compData = state.compressor.get_compressed_data();
	size_t numBytesWrittenToOutBuf = 0;
	if (state.compDataOfs < compData.length){
		size_t helperVal = compData.length - state.compDataOfs;
		//size_t n = LZHAM_MIN(compData.size() - state->m_comp_data_ofs, *pOut_buf_size);
		size_t n = helperVal < *outBufSize ? helperVal : *outBufSize;

		memcpy(outBuf, compData.ptr + state.compDataOfs, n);
		
		state.compDataOfs += n;
		
		const bool hasNoMoreOutput = (state.compDataOfs >= compData.length);
		if (hasNoMoreOutput){
			outBuf += n;
			*outBufSize -= n;
			numBytesWrittenToOutBuf += n;
		}else{
			*inBufSize = 0;
			*outBufSize = n;
			state.status = LZHAMCompressionStatus.HAS_MORE_OUTPUT;
			return state.status;
		}
	}
	
	compData.length = 0;
	state.compDataOfs = 0;
	
	if (state.finishedCompression){
		if ((*inBufSize) || (flushType != LZHAMFlushTypes.FINISH)){
			state.status = LZHAMCompressionStatus.INVALID_PARAMETER;
			return state.status;
		}
		
		*inBufSize = 0;
		*outBufSize = numBytesWrittenToOutBuf;
		
		state.status = LZHAMCompressionStatus.SUCCESS;
		return state.status;
	}
	
	const size_t cMaxBytesToPutPerIteration = 4*1024*1024;
	//size_t bytesToPut = LZHAM_MIN(cMaxBytesToPutPerIteration, *pIn_buf_size);
	size_t bytesToPut = cMaxBytesToPutPerIteration < *inBufSize ? cMaxBytesToPutPerIteration : *inBufSize;
	const bool consumedEntireInputBuf = (bytesToPut == *inBufSize);
	
	if (bytesToPut){
		if (!state.compressor.put_bytes(inBuf, cast(uint)bytesToPut)){
			*inBufSize = 0;
			*outBufSize = numBytesWrittenToOutBuf;
			state.status = LZHAMCompressionStatus.FAILED;
			return state.status;
		}
	}

	if ((consumedEntireInputBuf) && (flushType != LZHAMFlushTypes.NO_FLUSH)){
		//if ((flushType == LZHAMFlushTypes.SYNC_FLUSH) || (flushType == LZHAMFlushTypes.FULL_FLUSH) || (flushType == LZHAMFlushTypes.TABLE_FLUSH)){
		if (flushType != LZHAMFlushTypes.FINISH){
			if (!state.compressor.flush(flushType)){
				*inBufSize = 0;
				*outBufSize = numBytesWrittenToOutBuf;
				state.status = LZHAMCompressionStatus.FAILED;
				return state.status;
			}
		}else if (!state.finishedCompression){
			if (!state.compressor.put_bytes(null, 0)){
				*inBufSize = 0;
				*outBufSize = numBytesWrittenToOutBuf;
				state.status = LZHAMCompressionStatus.FAILED;
				return state.status;
			}
			state.finishedCompression = true;
		}
	}
	
	//size_t numCompBytesToOutput = LZHAM_MIN(compData.size() - state->m_comp_data_ofs, *pOut_buf_size);
	size_t helperVal0 = compData.length - state.compDataOfs;
	size_t numCompBytesToOutput = helperVal0 < *outBufSize ? helperVal0 : *outBufSize;
	if (numCompBytesToOutput){
		memcpy(outBuf, compData.ptr + state.compDataOfs, numCompBytesToOutput);
		
		state.compDataOfs += numCompBytesToOutput;
	}
	
	*inBufSize = bytesToPut;
	*outBufSize = numBytesWrittenToOutBuf + numCompBytesToOutput;
	
	const bool hasNoMoreOutput = (state.compDataOfs >= compData.length);
	if ((hasNoMoreOutput) && (flushType == LZHAMFlushTypes.FINISH) && (state.finishedCompression))
		state.status = LZHAMCompressionStatus.SUCCESS;
	else if ((hasNoMoreOutput) && (consumedEntireInputBuf) && (flushType == LZHAMFlushTypes.NO_FLUSH))
		state.status = LZHAMCompressionStatus.NEEDS_MORE_INPUT;
	else
		state.status = hasNoMoreOutput ? LZHAMCompressionStatus.NOT_FINISHED : LZHAMCompressionStatus.HAS_MORE_OUTPUT;
	
	return state.status;
}
LZHAMCompressionStatus compressMemory(LZHAMCompressionParameters *params, ubyte* dstBuf, size_t* dstLen, ubyte* srcBuf, 
		size_t srcLen, uint* adler32){
	if ((!params) || (!dstLen))
		return LZHAMCompressionStatus.INVALID_PARAMETER;
	
	if (srcLen){
		if (!srcBuf)
			return LZHAMCompressionStatus.INVALID_PARAMETER;
	}
	
	static if (size_t.sizeof > uint.sizeof){
		if (srcLen > uint.max)
			return LZHAMCompressionStatus.INVALID_PARAMETER;
	}
	
	LZCompressor.InitParams internalParams;
	LZHAMCompressionStatus status = create_internal_init_params(&internalParams, params);
	if (status != LZHAMCompressionStatus.SUCCESS)
		return status;
	
	//task_pool *pTP = NULL;
	if (internalParams.m_max_helper_threads){
		/*pTP = lzham_new<task_pool>();
		if (!pTP->init(internalParams.m_max_helper_threads))
			return LZHAM_COMP_STATUS_FAILED;
		
		internalParams.m_pTask_pool = pTP;*/
	}
	
	LZCompressor compressor = new LZCompressor();
	if (!compressor){
		//lzham_delete(pTP);
		return LZHAMCompressionStatus.FAILED;
	}
	
	if (!compressor._init(internalParams)){
		//lzham_delete(pTP);
		//lzham_delete(compressor);
		return LZHAMCompressionStatus.INVALID_PARAMETER;
	}
	
	if (srcLen){
		if (!compressor.put_bytes(srcBuf, cast(uint)(srcLen))){
			*dstLen = 0;
			//lzham_delete(pTP);
			//lzham_delete(compressor);
			return LZHAMCompressionStatus.FAILED;
		}
	}
	
	if (!compressor.put_bytes(null, 0)){
		*dstLen = 0;
		//lzham_delete(pTP);
		//lzham_delete(compressor);
		return LZHAMCompressionStatus.FAILED;
	}
	
	ubyte[] compData = compressor.get_compressed_data();

	size_t dstBufSize = *dstLen;
	*dstLen = compData.length;
	
	if (adler32)
		*adler32 = compressor.get_src_adler32();
	
	if (compData.length > dstBufSize){
		//lzham_delete(pTP);
		//lzham_delete(compressor);
		return LZHAMCompressionStatus.OUTPUT_BUF_TOO_SMALL;
	}
	
	memcpy(dstBuf, compData.ptr, compData.length);
	
	//lzham_delete(pTP);
	//lzham_delete(compressor);
	return LZHAMCompressionStatus.SUCCESS;
}
public int z_deflateInit(LZHAMZStream* pStream, int level){
	return z_deflateInit2(pStream, level, LZHAM_Z_LZHAM, LZHAM_Z_DEFAULT_WINDOW_BITS, 9, LZHAM_Z_DEFAULT_STRATEGY);
}
public int z_deflateInit2(LZHAMZStream* pStream, int level, int method, int windowBits, int memLevel, int strategy){
	if (!pStream)
		return LZHAM_Z_STREAM_ERROR;
	if ((memLevel < 1) || (memLevel > 9))
		return LZHAM_Z_PARAM_ERROR;
	if ((method != LZHAM_Z_DEFLATED) && (method != LZHAM_Z_LZHAM))
		return LZHAM_Z_PARAM_ERROR;
	
	if (level == LZHAM_Z_DEFAULT_COMPRESSION)
		level = 9;
	
	if (method == LZHAM_Z_DEFLATED){
		// Force Deflate to LZHAM with default window_bits.
		method = LZHAM_Z_LZHAM;
		windowBits = LZHAM_Z_DEFAULT_WINDOW_BITS;
	}
	static if(CPU_64BIT_CAPABLE){
		int maxWindowBits = LZHAM_MAX_DICT_SIZE_LOG2_X64;
	}else{
		int maxWindowBits = LZHAM_MAX_DICT_SIZE_LOG2_X86;
	}
	if ((labs(windowBits) < LZHAM_MIN_DICT_SIZE_LOG2) || (labs(windowBits) > maxWindowBits))
		return LZHAM_Z_PARAM_ERROR;
	
	LZHAMCompressionParameters compParams = LZHAMCompressionParameters();

	//comp_params.m_struct_size = sizeof(lzham_compress_params);
	
	compParams.level = LZHAMCompressLevel.UBER;
	if (level <= 1)
		compParams.level = LZHAMCompressLevel.FASTEST;
	else if (level <= 3)
		compParams.level = LZHAMCompressLevel.FASTER;
	else if (level <= 5)
		compParams.level = LZHAMCompressLevel.DEFAULT;
	else if (level <= 7)
		compParams.level = LZHAMCompressLevel.BETTER;
	
	if (level == 10)
		compParams.compressFlags |= LZHAMCompressFlags.EXTREME_PARSING;
	
	// Use all CPU's. TODO: This is not always the best idea depending on the dictionary size and the # of bytes to compress.
	compParams.maxHelperThreads = -1;
	
	compParams.dictSizeLog2 = cast(uint)(labs(windowBits));
	
	if (windowBits > 0)
		compParams.compressFlags |= LZHAMCompressFlags.WRITE_ZLIB_STREAM;
	
	pStream.data_type = 0;
	pStream.adler = 1;//LZHAM_Z_ADLER32_INIT;
	pStream.msg = null;
	pStream.reserved = 0;
	pStream.total_in = 0;
	pStream.total_out = 0;
	
	LZHAMCompressState* pComp = compressInit(&compParams);
	if (!pComp)
		return LZHAM_Z_PARAM_ERROR;
	
	pStream.stateComp = pComp;// = (struct lzham_z_internal_state *)pComp;
	
	return LZHAM_Z_OK;
}
public int z_deflateReset(LZHAMZStream* pStream){
	if (!pStream)
		return LZHAM_Z_STREAM_ERROR;
	
	LZHAMCompressState* pComp = pStream.stateComp;
	if (!pComp)
		return LZHAM_Z_STREAM_ERROR;
	
	pComp = compressReinit(pComp);
	if (!pComp)
		return LZHAM_Z_STREAM_ERROR;
	
	//pStream->state = (struct lzham_z_internal_state *)pComp;
	
	return LZHAM_Z_OK;
}
public int z_deflate(LZHAMZStream* pStream, int flush){
	if ((!pStream) || (!pStream.stateComp) || (flush < 0) || (flush > LZHAM_Z_FINISH) || (!pStream.next_out))
		return LZHAM_Z_STREAM_ERROR;
	
	if (!pStream.avail_out)
		return LZHAM_Z_BUF_ERROR;
	
	if (flush == LZHAM_Z_PARTIAL_FLUSH)
		flush = LZHAM_Z_SYNC_FLUSH;

	int lzhamStatus = LZHAM_Z_OK;
	ulong origTotalIn = pStream.total_in, origTotalOut = pStream.total_out;
	for ( ; ; ){
		size_t inBytes = pStream.avail_in, outBytes = pStream.avail_out;
		
		LZHAMCompressState* pComp = pStream.stateComp;
		//lzham_compress_state *pState = static_cast<lzham_compress_state*>(pComp);
		
		LZHAMCompressionStatus status = compress2(
			pComp,
			pStream.next_in, &inBytes,
			pStream.next_out, &outBytes,
			cast(LZHAMFlushTypes)flush);
		
		pStream.next_in += cast(uint)inBytes;
		pStream.avail_in -= cast(uint)inBytes;
		pStream.total_in += cast(uint)inBytes;
		
		pStream.next_out += cast(uint)outBytes;
		pStream.avail_out -= cast(uint)outBytes;
		pStream.total_out += cast(uint)outBytes;
		
		pStream.adler = pComp.compressor.get_src_adler32();
		
		if (status >= LZHAMCompressionStatus.FIRST_FAILURE_CODE){
			lzhamStatus = LZHAM_Z_STREAM_ERROR;
			break;
		}else if (status == LZHAMCompressionStatus.SUCCESS){
			lzhamStatus = LZHAM_Z_STREAM_END;
			break;
		}else if (!pStream.avail_out){
			break;
		}else if ((!pStream.avail_in) && (flush != LZHAM_Z_FINISH)){
			if ((flush) || (pStream.total_in != origTotalIn) || (pStream.total_out != origTotalOut))
				break;
			return LZHAM_Z_BUF_ERROR; // Can't make forward progress without some input.
		}
	}
	return lzhamStatus;
}
public int z_deflateEnd(LZHAMZStream* pStream){
	if (!pStream)
		return LZHAM_Z_STREAM_ERROR;
	
	LZHAMCompressState* pComp = pStream.stateComp;
	if (pComp){
		pStream.adler = compressDeinit(pComp);
		
		pStream.stateComp = null;
	}
	
	return LZHAM_Z_OK;
}
public ulong z_deflateBound(LZHAMZStream* pStream, ulong source_len){
	return 64 + source_len + ((source_len + 4095) / 4096) * 4;
}
public int z_compress(ubyte* dest, ulong* destLen, ubyte* source, ulong sourceLen){
	return z_compress2(dest, destLen, source, sourceLen, LZHAMCompressLevel.DEFAULT);
}
public int z_compress2(ubyte* dest, ulong* destLen, ubyte* source, ulong sourceLen, int level) {
	int status;
	LZHAMZStream stream;
	memset(&stream, 0, stream.sizeof);
	
	// In case lzham_z_ulong is 64-bits (argh I hate longs).
	if ((sourceLen | *destLen) > 0xFFFFFFFFU)
		return LZHAM_Z_PARAM_ERROR;
	
	stream.next_in = source;
	stream.avail_in = cast(uint)sourceLen;
	stream.next_out = dest;
	stream.avail_out = cast(uint)*destLen;
	
	status = z_deflateInit(&stream, level);
	if (status != LZHAM_Z_OK)
		return status;
	
	status = z_deflate(&stream, LZHAM_Z_FINISH);
	if (status != LZHAM_Z_STREAM_END)
	{
		z_deflateEnd(&stream);
		return (status == LZHAM_Z_OK) ? LZHAM_Z_BUF_ERROR : status;
	}
	
	*destLen = stream.total_out;
	return z_deflateEnd(&stream);
}
public ulong z_compressBound(ulong source_len) {
	return z_deflateBound(null, source_len);
}

/*class LZCompressor : LZbase{
 
 }*/

struct LZHAMCompressState{
	// task_pool requires 8 or 16 alignment
	//task_pool mTp; // replaced by D's own parallelization library
	LZCompressor compressor;
	uint dictSizeLog2;
	ubyte* inBuf;
	size_t* inBufSize;
	ubyte* outBuf;
	size_t* outBufSize;
	
	size_t compDataOfs;
	
	bool finishedCompression;
	LZHAMCompressionParameters params;
	LZHAMCompressionStatus status;
	public string toString(){
		return "[compressor:" ~ conv.to!string(compressor) ~ ";dictSizeLog2:" ~ conv.to!string(dictSizeLog2) ~ ";inBuf:" 
		~ conv.to!string(inBuf) ~ ";inBufSize:" ~ conv.to!string(inBufSize) ~ ";outBuf:" ~ conv.to!string(outBuf) ~ 
		";outBufSize:" ~ conv.to!string(outBufSize) ~ ";compDataOfs:" ~ conv.to!string(compDataOfs) ~ ";finishedCompression:" 
		~ conv.to!string(finishedCompression) ~ ";params:" ~ conv.to!string(params) ~ ";status:" ~
		conv.to!string(status) ~ "]";

	}
}