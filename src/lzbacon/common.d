/*
 * libLZHAM by Laszlo Szeremi. <laszloszeremi@outlook.com>
 * Original algorithm by Richard Geldreich, Jr. <richgel99@gmail.com>
 * Licensed under Boost License
 */

module lzbacon.common;

import lzbacon.decompression;

//NOTE: These probably will be thrown out
static immutable int LZHAM_MIN_ALLOC_ALIGNMENT = size_t.sizeof*2;
static immutable int LZHAM_MIN_DICT_SIZE_LOG2 = 15;
static immutable int LZHAM_MAX_DICT_SIZE_LOG2_X86 = 26;
static immutable int LZHAM_MAX_DICT_SIZE_LOG2_X64 = 29;

static immutable uint EVEN_NUMBER_ROUNDER = 0xFF_FF_FF_FE;

///Maps directly to the ZLib API flush types
enum LZHAMFlushTypes{
	NO_FLUSH = 0,
	SYNC_FLUSH = 2,
	FULL_FLUSH = 3,
	FINISH = 4,
	TABLE_FLUSH = 10
}
///Defines the state of compression
enum LZHAMCompressionStatus{
	NOT_FINISHED = 0,
	NEEDS_MORE_INPUT,
	HAS_MORE_OUTPUT,

	// All the following enums must indicate failure/success.

	FIRST_SUCCESS_OR_FAILURE_CODE,
	SUCCESS,// = LZHAM_COMP_STATUS_FIRST_SUCCESS_OR_FAILURE_CODE,

	FIRST_FAILURE_CODE,
	FAILED,// = LZHAM_COMP_STATUS_FIRST_FAILURE_CODE,
	FAILED_INITIALIZING,
	INVALID_PARAMETER,
	OUTPUT_BUF_TOO_SMALL,

	FORCE_DWORD = 0xFFFFFFFF
}
///Defines the compression levels
enum LZHAMCompressLevel : uint{
	FASTEST = 0,
	FASTER,
	DEFAULT,
	BETTER,
	UBER,

	LEVELS,

	FORCE_DWORD = 0xFFFFFFFF
}
///Compression flags
enum LZHAMCompressFlags{
	EXTREME_PARSING = 2,         /// Improves ratio by allowing the compressor's parse graph to grow "higher" (up to 4 parent nodes per output node), but is much slower.
	DETERMINISTIC_PARSING = 4,   /// Guarantees that the compressed output will always be the same given the same input and parameters (no variation between runs due to kernel threading scheduling).
	/** If enabled, the compressor is free to use any optimizations which could lower the decompression rate (such as adaptively resetting the Huffman table update rate to maximum frequency, which is costly for the decompressor).*/
	TRADEOFF_DECOMPRESSION_RATE_FOR_COMP_RATIO = 16,
	WRITE_ZLIB_STREAM = 32,
}
///Sets the update rate of the table
enum LZHAMTableUpdateRate{
	INSANELY_SLOW = 1, // 1=insanely slow decompression, here for reference, use 2!
	SLOWEST_TABLE = 2,
	DEFAULT = 8,
	FASTEST = 20
}
/** Compression parameters struct.
 * IMPORTANT: The values of m_dict_size_log2, m_table_update_rate, m_table_max_update_interval, and m_table_update_interval_slow_rate MUST
 * match during compression and decompression. The codec does not verify these values for you, if you don't use the same settings during
 * decompression it will fail (usually with a LZHAM_DECOMP_STATUS_FAILED_BAD_CODE error).
 * The seed buffer's contents and size must match the seed buffer used during decompression.
 */
struct LZHAMCompressionParameters{
	uint struct_size;            // set to LZHAMCompressionParameters.sizeOf
	uint dictSizeLog2;         // set to the log2(dictionary_size), must range between [LZHAM_MIN_DICT_SIZE_LOG2, LZHAM_MAX_DICT_SIZE_LOG2_X86] for x86 LZHAM_MAX_DICT_SIZE_LOG2_X64 for x64
	LZHAMCompressLevel level;          // set to LZHAM_COMP_LEVEL_FASTEST, etc.
	uint tableUpdateRate;		// Controls tradeoff between ratio and decompression throughput. 0=default, or [1,LZHAM_MAX_TABLE_UPDATE_RATE], higher=faster but lower ratio.
	int maxHelperThreads;      // max # of additional "helper" threads to create, must range between [-1,LZHAM_MAX_HELPER_THREADS], where -1=max practical
	uint compressFlags;         // optional compression flags (see lzham_compress_flags enum)
	uint numSeedBytes;         // for delta compression (optional) - number of seed bytes pointed to by m_pSeed_bytes
	const void* pSeedBytes;             // for delta compression (optional) - pointer to seed bytes buffer, must be at least m_num_seed_bytes long
	
	// Advanced settings - set to 0 if you don't care.
	// m_table_max_update_interval/m_table_update_interval_slow_rate override m_table_update_rate and allow finer control over the table update settings.
	// If either are non-zero they will override whatever m_table_update_rate is set to. Just leave them 0 unless you are specifically customizing them for your data.
	
	// def=0, typical range 12-128 (LZHAM_DEFAULT_TABLE_UPDATE_RATE=64), controls the max interval between table updates, higher=longer max interval (faster decode/lower ratio). Was 16 in prev. releases.
	uint tableMaxUpdateInterval;
	// def=0, 32 or higher (LZHAM_DEFAULT_TABLE_UPDATE_RATE=64), scaled by 32, controls the slowing of the update update freq, higher=more rapid slowing (faster decode/lower ratio). Was 40 in prev. releases.
	uint tableUpdateIntervalSlowRate;
}
///
enum LZHAMDecompressionStatus{
	// LZHAM_DECOMP_STATUS_NOT_FINISHED indicates that the decompressor is flushing its internal buffer to the caller's output buffer. 
	// There may be more bytes available to decompress on the next call, but there is no guarantee.
	NOT_FINISHED = 0,

	// LZHAM_DECOMP_STATUS_HAS_MORE_OUTPUT indicates that the decompressor is trying to flush its internal buffer to the caller's output buffer, 
	// but the caller hasn't provided any space to copy this data to the caller's output buffer. Call the lzham_decompress() again with a non-empty sized output buffer.
	HAS_MORE_OUTPUT,

	// LZHAM_DECOMP_STATUS_NEEDS_MORE_INPUT indicates that the decompressor has consumed all input bytes, has not encountered an "end of stream" code, 
	// and the caller hasn't set no_more_input_bytes_flag to true, so it's expecting more input to proceed.
	NEEDS_MORE_INPUT,

	// All the following enums always (and MUST) indicate failure/success.
	FIRST_SUCCESS_OR_FAILURE_CODE,

	// LZHAM_DECOMP_STATUS_SUCCESS indicates decompression has successfully completed.
	SUCCESS,// = FIRST_SUCCESS_OR_FAILURE_CODE,

	// The remaining status codes indicate a failure of some sort. Most failures are unrecoverable. TODO: Document which codes are recoverable.
	FIRST_FAILURE_CODE,

	FAILED_INITIALIZING,// = LZHAM_DECOMP_STATUS_FIRST_FAILURE_CODE,
	FAILED_DEST_BUF_TOO_SMALL,
	FAILED_EXPECTED_MORE_RAW_BYTES,
	FAILED_BAD_CODE,
	FAILED_ADLER32,
	FAILED_BAD_RAW_BLOCK,
	FAILED_BAD_COMP_BLOCK_SYNC_CHECK,
	FAILED_BAD_ZLIB_HEADER,
	FAILED_NEED_SEED_BYTES,
	FAILED_BAD_SEED_BYTES,
	FAILED_BAD_SYNC_BLOCK,
	INVALID_PARAMETER,
}
///
enum LZHAMDecompressFlags{
	OUTPUT_UNBUFFERED = 1,
	COMPUTE_ADLER32 = 2,
	READ_ZLIB_STREAM = 4,
}
/// Stores decompression parameters
struct LZHAMDecompressionParameters{
	uint structSize;            // set to sizeof(lzham_decompress_params)
	uint dictSizeLog2;         // set to the log2(dictionary_size), must range between [LZHAM_MIN_DICT_SIZE_LOG2, LZHAM_MAX_DICT_SIZE_LOG2_X86] for x86 LZHAM_MAX_DICT_SIZE_LOG2_X64 for x64
	uint tableUpdateRate;		// Controls tradeoff between ratio and decompression throughput. 0=default, or [1,LZHAM_MAX_TABLE_UPDATE_RATE], higher=faster but lower ratio.
	uint decompressFlags;       // optional decompression flags (see lzham_decompress_flags enum)
	uint numSeedBytes;         // for delta compression (optional) - number of seed bytes pointed to by m_pSeed_bytes
	const void *seedBytes;             // for delta compression (optional) - pointer to seed bytes buffer, must be at least m_num_seed_bytes long

	// Advanced settings - set to 0 if you don't care.
	// m_table_max_update_interval/m_table_update_interval_slow_rate override m_table_update_rate and allow finer control over the table update settings.
	// If either are non-zero they will override whatever m_table_update_rate is set to. Just leave them 0 unless you are specifically customizing them for your data.

	// def=0, typical range 12-128 (LZHAM_DEFAULT_TABLE_UPDATE_RATE=64), controls the max interval between table updates, higher=longer max interval (faster decode/lower ratio). Was 16 in prev. releases.
	uint tableMaxUpdateInterval;
	// def=0, 32 or higher (LZHAM_DEFAULT_TABLE_UPDATE_RATE=64), scaled by 32, controls the slowing of the update update freq, higher=more rapid slowing (faster decode/lower ratio). Was 40 in prev. releases.
	uint tableUpdateIntervalSlowRate;
}
/// Compression strategies for ZLib compatibility mode.
enum{ 
	LZHAM_Z_DEFAULT_STRATEGY = 0, 
	LZHAM_Z_FILTERED = 1, 
	LZHAM_Z_HUFFMAN_ONLY = 2, 
	LZHAM_Z_RLE = 3, 
	LZHAM_Z_FIXED = 4 
}
/// Flush values for ZLib compatibility mode.
enum{ 
	LZHAM_Z_NO_FLUSH = 0,       // compression/decompression
	LZHAM_Z_PARTIAL_FLUSH = 1,  // compression/decompression, same as LZHAM_Z_SYNC_FLUSH
	LZHAM_Z_SYNC_FLUSH = 2,     // compression/decompression, when compressing: flush current block (if any), always outputs sync block (aligns output to byte boundary, a 0xFFFF0000 marker will appear in the output stream)
	LZHAM_Z_FULL_FLUSH = 3,     // compression/decompression, when compressing: same as LZHAM_Z_SYNC_FLUSH but also forces a full state flush (LZ dictionary, all symbol statistics)
	LZHAM_Z_FINISH = 4,         // compression/decompression
	LZHAM_Z_BLOCK = 5,          // not supported
	LZHAM_Z_TABLE_FLUSH = 10    // compression only, resets all symbol table update rates to maximum frequency (LZHAM extension)
}
/// Return values for ZLib compatibility mode. NOTE: error values might be replaced with exceptions
enum{ 
	LZHAM_Z_OK = 0, 
	LZHAM_Z_STREAM_END = 1, 
	LZHAM_Z_NEED_DICT = 2, 
	LZHAM_Z_ERRNO = -1, 
	LZHAM_Z_STREAM_ERROR = -2, 
	LZHAM_Z_DATA_ERROR = -3, 
	LZHAM_Z_MEM_ERROR = -4, 
	LZHAM_Z_BUF_ERROR = -5, 
	LZHAM_Z_VERSION_ERROR = -6, 
	LZHAM_Z_PARAM_ERROR = -10000 
}
/// Compression levels for ZLib compatibility mode.
enum{ 
	LZHAM_Z_NO_COMPRESSION = 0,
	LZHAM_Z_BEST_SPEED = 1,
	LZHAM_Z_BEST_COMPRESSION = 9,
	LZHAM_Z_UBER_COMPRESSION = 10,      // uber = best with extreme parsing (can be very slow)
	LZHAM_Z_DEFAULT_COMPRESSION = -1 
}
/// Data types for ZLib compatibility.
enum LZHAMZDataTypes{
	BINARY		=	0,
	TEXT		=	1,
	UNKNOWN		=	2,
}
/// Compression/decompression stream.
struct LZHAMZStream{
	ubyte* next_in;           /// pointer to next byte to read
	uint avail_in;                  /// number of bytes available at next_in
	ulong total_in;                 /// total number of bytes consumed so far

	ubyte* next_out;                /// pointer to next byte to write
	uint avail_out;                 /// number of bytes that can be written to next_out
	ulong total_out;                /// total number of bytes produced so far

	LZHAMDecompressor state;   /// originally: internal state, allocated by zalloc/zfree, now a decompression algorithm

	// LZHAM does not support per-stream heap callbacks. Use lzham_set_memory_callbacks() instead.
	// These members are ignored - they are here for backwards compatibility with zlib.
	void* function() zalloc;              /// optional heap allocation function (defaults to malloc)
	void function() zfree;                /// optional heap free function (defaults to free)
	void* opaque;                           /// heap alloc function user pointer

	int data_type;                          /// data_type (unused)
	ulong adler;                    /// adler32 of the source or uncompressed data
	ulong reserved;                 /// not used
}

static immutable int LZHAM_Z_DEFLATED = 8;
static immutable int LZHAM_Z_LZHAM = 14;

static immutable string LZHAM_Z_VERSION = "10.8.1";
static immutable int LZHAM_Z_VERNUM = 0xA810;
static immutable int LZHAM_Z_VER_MAJOR = 10;
static immutable int LZHAM_Z_VER_MINOR = 8;
static immutable int LZHAM_Z_VER_REVISION = 1;
static immutable int LZHAM_Z_VER_SUBREVISION = 0;

/// Class implementation of the LZHAM codec
public class LZHAM{
	public uint delegate() getVersion;
	public uint delegate(void* function(void* opaque, void* address, size_t items, size_t size)) setMemoryCallbacks;

	public LZHAMCompressionStatus* delegate(LZHAMCompressionParameters* params) compressInit;
	public LZHAMCompressionStatus* delegate(LZHAMCompressionStatus* state) compressReinit;
	public uint delegate(LZHAMCompressStatus* state) compressDeinit;
	public LZHAMCompressionStatus delegate(LZHAMCompressionStatus* state, const ubyte* inBuf, size_t inBufSize, ubyte* outBuf, size_t outBufSize, bool noMoreInputBytesFlag) compress;
	public LZHAMCompressionStatus delegate(LZHAMCompressionStatus* state, const ubyte* inBuf, size_t inBufSize, ubyte* outBuf, size_t outBufSize, LZHAMFlushTypes flushType) compress2;
	public LZHAMCompressionStatus delegate(LZHAMCompressionStatus* state, ubyte* destBuf, size_t destSize, const ubyte srcDuf, size_t srcSize, uint* pAdler32) compressMem;

	public LZHAMDecompressionStatus* delegate(LZHAMDecompressionParameters* params) decompressInit;
	public LZHAMDecompressionStatus* delegate(LZHAMDecompressionStatus* state, LZHAMDecompressionParameters* params) decompressReinit;
	public uint delegate(LZHAMDecompressStatus*) decompressDeinit;
	public LZHAMDecompressionStatus delegate(LZHAMDecompressionStatus* state, const ubyte* inBuf, size_t inBufSize, ubyte* outBuf, size_t outBufSize, bool noMoreInputBytesFlag) decompress;
	public LZHAMDecompressionStatus delegate(LZHAMDecompressionStatus* state, ubyte* destBuf, size_t destSize, const ubyte srcDuf, size_t srcSize, uint* pAdler32) decompressMem;

	public const char* delegate() z_version;
	public int delegate(LZHAMZStream* pStream, int level) z_deflateInit;
	public int delegate(LZHAMZStream* pStream, int level, int method, int window_bits, int mem_level, int strategy) z_deflateInit2;
	public int delegate(LZHAMZStream* pStream) z_deflateReset;
	public int delegate(LZHAMZStream* pStream, int flush) z_deflate;
	public int delegate(LZHAMZStream* pStream) z_deflateEnd;
	public ulong delegate(LZHAMZStream* pStream, ulong source_len) z_deflateBound;
	public int delegate(ubyte* pDest, ulong pDest_len, const ubyte* pSource, ulong pSource_len) z_compress;
	public int delegate(ubyte* pDest, ulong pDest_len, const ubyte* pSource, ulong pSource_len, int level) z_compress2;
	public ulong delegate(ulong source_len) z_compressBound;
	public int delegate(LZHAMZStream* pStream) z_inflateInit;
	public int delegate(LZHAMZStream* pStream, int window_bits) z_inflateInit2;
	public int delegate(LZHAMZStream* pStream) z_inflateReset;
	public int delegate(LZHAMZStream* pStream, int flush) z_inflate;
	public int delegate(LZHAMZStream* pStream) z_inflateEnd;
	public int delegate(ubyte* pDest, ulong pDest_len, const ubyte* pSource, ulong pSource_len) z_decompress;
	public const char* delegate(int error) z_version;
	this(){
		
	}
	public void clear(){
		
	}

}