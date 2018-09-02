module lzbacon.dpk;

import std.bitmanip;
import std.digest;
import stc.digest.murmurhash;
import std.file;
import core.stdc.stdio;

public import lzbacon.exceptions;
import lzbacon.common;
import lzbacon.decompression;
import lzbacon.compression;

/**
 * Selects between checksums
 */
public enum DataPakChecksumType : ubyte{
	none				=	0,
	ripeMD				=	1,
	murmurhash32_32		=	2,
	murmurhash128_32	=	3,
	murmurhash128_64	=	4,
	md5					=	10,
}
/**
 * Intended to be used for compressing game and application assets, and information unecessary for such application are not stored
 * such as creation dates and user privileges.
 */
public struct DataPakIndex{
	mixin(bitfields!(
		ubyte, 4, "checksumType",		/* checksum type identifier */
		ubyte, 2, "reserved0",			/* reserved if more fields will be needed in the future */
		bool, 1, "chain",
		bool, 1, "longHeader",
		ushort, 12, "extendedLength",
		uint, 12, "reserved"			/* reserved if more fields will be needed in the future */
	));
	uint			length;	///Stores the length of the file, or the block if chaining is enabled for this file.
	ulong			offset;	///Stores where the file begins.
	char[128-16]	field;	///Stores file name in the front (null terminated) and checksum at the end in hexadecimal format. Can also store compression offset if the codec supports it.
	/**
	 * Returns the filename part of field.
	 */
	string filename(){
		string result;
		for(int i ; i < field.length ; i++){
			if(field[i] == '\x00')
				break;
			result ~ field[i];
		}
		return result;
	}
}
/**
 * Header for the DataPak file. Contains the total length, basic information on layout and compression, also has a checksum to ensure
 * the integrity of the indexes.
 */
public struct DataPakFileHeader{
	ulong			totalLength;	///Total decompressed length of the file in bytes.
	char[8]			compMethod;		///Identifies the algorithm used for compressing the file, "UNCOMPRD" if uncompressed.
	ulong			indexFieldLength;///Total length of the index field.
	uint			numOfIndexes;	///Total number of file indexes.
	mixin(bitfields!(
		bool, 1, "compressedIndex",		/* If true, the indexes are stored in the compressed field. */
		bool, 1, "noLongIndex",		/* If true, none of the indexes contain extended fields, faster loading will be used. */
		uint, 30, "reserved",
	));
	ubyte[4]		checksum;		///Murmurhash32/32 checksum for the header and indexes. When processing, this field should set to all zeroes.
}
/**
 * Compression method IDs
 */
public enum CompMethodID : char[8]{
	uncompressed		=	"UNCOMPRD",
	deflate				=	"DEFLATE ",
	lzham				=	"LZHAM   ",
	dataPakRLE			=	"DPKRLE  ",
}
/**
 * Implements the DataPak file functions as a class
 */
public class DataPak{
	private DataPakFileHeader		header;			///Stores file header information
	private DataPakIndex[]			indexes;		///File index data
	private char[][int]				extraFields;	///Extra file fields if any exists
	private string					filename;		///Name of the file
	private FILE*					filestream;		///Filestream for read and write operation
	private uint					position;		///Current file position
	private bool					isReading;		///Specifies if the file is being read(true)
	private bool					isWriting;		///Specifies if the file is being written(true)
	private bool					directWrite;	///If true, the output is getting written directly to the file, if false it writes it to a memory buffer
	private ubyte[]					writeBuffer;	///Stores temporary data if directwriting is disabled in openDataStreamForWriting()
	private ubyte*					readBuffer;		///Stores read data temporarily
	private size_t					readBufferSize;	///Stores read data buffer size
	private size_t					readPos;		///Stores the position in the buffer for decompression
	private ubyte*					outBuf;			///Stores compressed or decompressed data temporarily
	private	size_t					outBufSize;		///Compression buffer size
	private size_t					compPos;		///Compression position
	private LZHAMDecompressor		lzhamDecomp;	///Decompressor for both LZHAM and DEFLATE
	private LZHAMCompressState*		lzhamComp;		///Compressor for both LZHAM and DEFLATE
	public static uint				readSize;		///Sets the max size of a single read or write (default is 1024kB)
	public static uint				compSize;		///Sets the max size of a single compression or decompression(default is 1024kB)
	/**
	 * Creates a DataPak object. Does not initializes a file for either reading or writing.
	 */
	public this(string filename){
		this.filename = filename;
	}
	static this(){
		readSize = 1024*1024;
		compSize = 1024*1024;
	}
	~this(){
		if(lzhamDecomp){
			decompressDeinit(lzhamDecomp);
		}
		if(lzhamComp){
			compressDeinit(lzhamComp);
		}
		free(cast(void*)readBuffer);
		free(cast(void*)outBuf)	;
	}
	/**
	 * Opens the datastream for writing.
	 * Initialize parameters by specifying a header with the parameters, including the number of indexes
	 */
	public void openDataStreamForWriting(DataPakFileHeader header, bool directWrite = true){
		this.header = header;
		this.directWrite = directWrite;
		filestream = fopen(toStringz(filename) , "wb");
	}
	/**
	 * Reinitializes reading onto another file.
	 * If the compression algorithm matches, it can save some initialization time.
	 */
	public void reinitReadingToAnotherFile(string filename){
		this.filename = filename;
		openDataStreamForReading;
	}
	/**
	 * Opens the datastream for reading. <br />
	 * Throws DPKException if the file format invalid, FileException if the file inaccessible.
	 */
	public void openDataStreamForReading(){
		import std.string;
		if(isWriting)
			throw new DPKException("File is already opened for writing! Close it first before proceeding.");
		filestream = fopen(toStringz(filename) , "rb");
		if(!filestream){
			throw new DPKException("Cannot open file for reading!");
		}
		readBuffer = cast(ubyte*)malloc(readSize);
		readBufferSize = readSize;
		outBuf 	= cast(ubyte*)malloc(compSize);
		outBufSize = compSize;
		fread(cast(void*)header.ptr, DataPakFileHeader.sizeof, 1, filestream);
		indexes.length = header.numOfIndexes;
		if(!header.compressedIndex){
			if(header.noLongIndex){
				fread(cast(void*)indexes.ptr, DataPakIndex.sizeof, header.numOfIndexes, filestream);
			}
		}else if(header.compMethod == CompMethodID.lzham || header.compMethod == CompMethodID.deflate){
			initLZHAMDecomp();
			size_t tempLen = indexes.length * DataPakIndex.sizeof;
			do{
				bool noMoreInputBytesFlag;
				if(lzhamDecomp.lastStatus != LZHAMDecompressionStatus.HAS_MORE_OUTPUT)
					noMoreInputBytesFlag = fread(cast(void*)readBuffer, 1, readBufferSize, filestream) < readBufferSize;
				decompress(lzhamDecomp, readBuffer, &readBufferSize, cast(ubyte*)indexes.ptr, &tempLen,
						noMoreInputBytesFlag);
			} while (lzhamDecomp.lastStatus == LZHAMDecompressionStatus.NEEDS_MORE_INPUT);
			if(lzhamDecomp.lastStatus > LZHAMDecompressionStatus.FIRST_FAILURE_CODE){
				throw new DPKException("Decompression error!");
			}
		}
		//do a checksum and throw an exception if there's an error.
		if(!calculateChecksum){
			throw new DPKException("Checksum error in header!");
		}
	}
	/**
	 * Initializes the LZHAM decompressor for reading
	 */
	private void initLZHAMDecomp(){
		LZHAMDecompressionParameters params = LZHAMDecompressionParameters();
		LZHAMFileHeader lzheader;
		fread(cast(void*)&lzheader, LZHAMFileHeader.sizeof, 1, filestream);
		params.dictSizeLog2 = lzheader.dictSizeLog2;
		params.tableUpdateRate = lzheader.tableUpdateRate;
		params.tableMaxUpdateInterval = lzheader.tableMaxUpdateInterval;
		params.tableUpdateIntervalSlowRate = lzheader.tableUpdateIntervalSlowRate;
		params.decompressFlags |= header.compMethod == CompMethodID.deflate ? LZHAMDecompressFlags.READ_ZLIB_STREAM : 0;
		if(!lzhamDecomp)
			lzhamDecomp = decompressInit(&params);
		else
			decompressReinit(lzhamDecomp, &params);
		//throw exception if failed to initialize
	}
	/**
	 * Closes data stream for both reading and writing. <br />
	 * Throws FileException if it fails to. (TODO)
	 */
	public void closeDataStream(bool deinitCompression = true){
		fclose(filestream);
		if(isWriting){
			if(header.compMethod == CompMethodID.deflate || header.compMethod == CompMethodID.lzham){
				compressDeinit(lzhamComp);
			}
		}else if(isReading){
			if(header.compMethod == CompMethodID.deflate || header.compMethod == CompMethodID.lzham){
				if(deinitCompression){
					decompressDeinit(lzhamDecomp);
					lzhamDecomp = null;
				}
			}
		}
	}
	/**
	 * Gets next file in the package. Returns null if the last index have reached. Throws an exception if the checksum fails and enforceFileChecksum is set.
	 * This is the fastest method for compressed archives. Uncompressed archives have better random access.
	 */
	public ubyte[] getNextFile(){
		if(position >= header.numOfIndexes)
			return null;
		if(!isReading || isWriting){
			throw new DPKException("Reading has not been initialized!");
		}
		if(outBufSize < indexes[position].length){
			outBufSize = indexes[pos].length;
			outBuf 	= cast(ubyte*)realloc(cast(ubyte*)outBuf, outBufSize);
		}else{
			outBufSize = indexes[pos].length;//Redundant a bit, but I need to check the original size of the comp
		}
		if(header.compMethod == CompMethodID.uncompressed){
			//Read directly to the output buffer, throw an exception if an error happened.
			if(fread(cast(void*)outBuf, 1, outBufSize, filestream) < outBufSize){
				throw new DPKException("File structure error! Missing data or corrupted index!");
			}
		}else if(header.compMethod == CompMethodID.lzham || header.compMethod == CompMethodID.deflate){
			size_t tempLen = outBufSize;
			do{
				bool noMoreInputBytesFlag;
				if(lzhamDecomp.lastStatus != LZHAMDecompressionStatus.HAS_MORE_OUTPUT)
					noMoreInputBytesFlag = fread(cast(void*)readBuffer, 1, readBufferSize, filestream) < readBufferSize;
				decompress(lzhamDecomp, readBuffer, &readBufferSize, cast(ubyte*)indexes.ptr, &tempLen,
						noMoreInputBytesFlag);
			} while (lzhamDecomp.lastStatus == LZHAMDecompressionStatus.NEEDS_MORE_INPUT);
			if(lzhamDecomp.lastStatus > LZHAMDecompressionStatus.FIRST_FAILURE_CODE){
				throw new DPKException("Decompression error!");
			}
		}
		//add implementation for checksums in the future here
		position++;
		return outBuf[0 .. outBufSize];
	}
	/**
	 * Skips next file. Decompresses it if needed to go forward, but won't return anything.
	 */
	public void skipNextFile(){
		if(header.compMethod == CompMethodID.uncompressed)
			position++;
		else
			getNextFile;
	}
	/**
	 * Gets file in the package by name. Returns null if not found. Throws an exception if the checksum fails and enforceFileChecksum is set.
	 * This is slower with most compression methods as previous 
	 */
	public ubyte[] getFile(string name){
		uint pos;
		for(; pos < indexes.length ; pos++)
			if(indexes[pos].filename = name)
				break;
		if(pos >= indexes.length)
			return null;
		if(pos == position)
			return outBuf[0 .. outBufSize];
		if(header.compMethod == CompMethodID.uncompressed){
			fseek(filestream, indexes[pos].offset, SEEK_SET);
			readBufferSize = indexes[pos].length;
			readBuffer = cast(ubyte*)realloc(cast(ubyte*)readBuffer, readBufferSize);
			if(!fread(cast(void*)readBuffer, indexes[pos].length, 1, filestream)){
				throw new DPKException("Cannot read file!");
			}
			return readBuffer[0 .. readBufferSize];
		}else if(header.compMethod == CompMethodID.deflate || header.compMethod == CompMethodID.lzham){
			
		}
		return null;
	}
	/**
	 * Returns the name of the current file.
	 */
	public string getNameOfCurrentIndex(){
		return indexes[position].filename;
	}
	/**
	 * Returns the index list as a ref const.
	 * The only accepted way to edit the indexes is when writing, please keep that in mind
	 */
	public ref DataPakIndex[] getIndexes() const{
		return indexes;
	}
	/**
	 * Calculates checksum for the file and the indexes.
	 * Returns true if the checksum is correct.
	 */
	private bool calculateChecksum(){
		ubyte[4] lChks = header.checksum;
		header.checksum = [0,0,0,0];
		ubyte[4] newChks = digest!(Murmurhash3!32)(cast(ubyte[])(cast(void[])(header) ~ cast(void[])(indexes)));
		if(*cast(uint*)(lChks.ptr) != *cast(uint*)(newChks.ptr)){
			header.checksum = newChks;
			return false;
		}
		return true;
	}
}