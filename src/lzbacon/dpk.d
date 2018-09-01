module lzbacon.dpk;

import std.bitmanip;
import std.digest;
import stc.digest.murmurhash;
import std.file;
import core.stdc.stdio;

public import lzbacon.exceptions;
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
	ulong			totalLength;	///Total length of the file in bytes.
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
	dataPakRLE			=	"DPAKRLE ",
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
	private ubyte[]					readBuffer;		///Stores uncompressed data temporarily
	private LZHAMDecompressor		lzhamDecomp;	///Decompressor for both LZHAM and DEFLATE
	private LZHAMCompressState*		lzhamComp;		///Compressor for both LZHAM and DEFLATE
	/**
	 * Opens the datastream for reading. <br />
	 * Throws DPKException if the file format invalid, FileException if the file inaccessible.
	 */
	public void openDataStreamForReading(){
		import std.string;
		filestream = fopen(toStringz(filename) , "rb");
		if(!filestream){
			throw new FileException("Cannot open file for reading!");
		}
		fread(cast(void*)header.ptr, DataPakFileHeader.sizeof, 1, filestream);
		indexes.length = header.numOfIndexes;
		if(!header.compressedIndex){
			if(header.noLongIndex){
				fread(cast(void*)indexes.ptr, DataPakIndex.sizeof, header.numOfIndexes, filestream);
			}
		}
		//do a checksum and throw an exception if there's an error.
		if(!calculateChecksum){
			throw new DPKException("Checksum error in header!");
		}
	}
	/**
	 * Closes data stream for both reading and writing. <br />
	 * Throws FileException if it fails to. (TODO)
	 */
	public void closeDataStream(){
		fclose(filestream);
	}
	/**
	 * Gets next file in the package. Returns null if the last index have reached. Throws an exception if the checksum fails and enforceFileChecksum is set.
	 * This is the fastest method for compressed archives. Uncompressed archives have better random access.
	 */
	public ubyte[] getNextFile(){
		if(header.compMethod == CompMethodID.uncompressed){

		}
	}
	/**
	 * Gets file in the package by name. Returns null if not found. Throws an exception if the checksum fails and enforceFileChecksum is set.
	 * This is slower with most compression methods as previous 
	 */
	public ubyte[] getFile(string name){
		uint position;
		for(; position < indexes.length ; position++)
			if(indexes[position].filename = name)
				break;
		if(position >= indexes.length)
			return null;
		if(header.compMethod == CompMethodID.uncompressed){
			fseek(filestream, indexes[position].offset, SEEK_SET);
			readBuffer.length = indexes[position].length;
			if(!fread(cast(void*)readBuffer.ptr, indexes[position].length, 1, filestream)){
				throw new FileException("Cannot read file!");
			}
			return readBuffer;
		}else if(header.compMethod == CompMethodID.deflate || header.compMethod == CompMethodID.lzham){

		}
		return null;
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