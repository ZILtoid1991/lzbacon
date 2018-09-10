module lzbacon.app;

public import lzbacon.exceptions;
import lzbacon.common;
import lzbacon.decompression;
import lzbacon.compression;
import lzbacon.system;

import core.stdc.stdio;
import core.stdc.stdlib;
import stdio = std.stdio;
import std.string;

void main(string[] args){
	try{
		stdio.stdout.flush();
		stdio.writeln(args);
		stdio.writeln("LZBACON");
		stdio.writeln("LZHAM Algorithm by Richard Geldreich, Jr.");
		stdio.writeln("implementation; tar and datapak handling by Laszlo Szeremi.");
		stdio.writeln("Usecase: lzbacon [filename]: Decompresses LZHAM file.");
		//stdio.writeln("lzbacon [filename] --untar: Decompresses .tar.lzham file.");
		stdio.writeln("lzbacon [filename] --compress: Compresses file into LZHAM.");
		//stdio.writeln("lzbacon [filename] --compress --tar [file1;file2;...]: creates a .tar.lzham archive.");
		stdio.writeln("Handling tar and datapak files not yet implemented.");
		int argPos = 1;
		string file;
		bool comp, decomp = true, deflate, deflate64, tar, dpk, parseInputFile;
		for(; argPos < args.length ; argPos++){
			
			switch(args[argPos]){
				case "--compress":
					decomp = false;
					comp = true;
					break;
				default:
					file = args[argPos];
					break;
			}
		}
		size_t inBufSize = 1024*1024, outBufSize = 1024*1024;
		if(decomp){
			if(file.length == 0){
				stdio.writeln("No input file specified!");
				return;
			}
			FILE* input, output;
			ubyte* inBuf = cast(ubyte*)malloc(inBufSize), outBuf = cast(ubyte*)malloc(outBufSize);
			bool noMoreInputBytesFlag;
			input = fopen(toStringz(file), "rb");
			output = fopen(toStringz(file[0 .. $-6]), "wb");
			if(!input || !output){
				stdio.writeln("Error accessing the files!");
				return;
			}
			LZHAMDecompressionParameters params = LZHAMDecompressionParameters();
			LZHAMDecompressor decompressor = decompressInit(&params);
			do{
				if(decompressor.status == LZHAMDecompressionStatus.NEEDS_MORE_INPUT)
					if(fread(inBuf.ptr, inBufSize, 1, input) < inBufSize)
						noMoreInputBytesFlag = true;
				decompress(decompressor, inBuf.ptr, &inBufSize, outBuf.ptr, &outBufSize, noMoreInputBytesFlag);
				if(decompressor.status == LZHAMDecompressionStatus.HAS_MORE_OUTPUT)
					fwrite(outBuf.ptr, outBufSize, 1, output);
			}while(decompressor.status < LZHAMDecompressionStatus.FIRST_SUCCESS_OR_FAILURE_CODE);
			if(decompressor.status > LZHAMDecompressionStatus.FIRST_FAILURE_CODE){
				stdio.writeln("Failed decompressing file!");
			}
			fclose(input);
			fclose(output);
		}else if(comp){
			if(file.length == 0){
				stdio.writeln("No input file specified!");
				return;
			}
			FILE* input, output;
			ubyte* inBuf = cast(ubyte*)malloc(inBufSize), outBuf = cast(ubyte*)malloc(outBufSize);
			
			bool noMoreInputBytesFlag;
			input = fopen(toStringz(file), "rb");
			output = fopen(toStringz(file ~ ".lzham"), "wb");
			if(!input || !output){
				stdio.writeln("Error accessing the files!");
				return;
			}
			LZHAMCompressionParameters params = LZHAMCompressionParameters();
			LZHAMCompressState* compressor = compressInit(&params);
			do{
				if(compressor.status == LZHAMCompressionStatus.NEEDS_MORE_INPUT)
					if(fread(inBuf, inBufSize, 1, input) < inBufSize)
						noMoreInputBytesFlag = true;
				compress(compressor, inBuf, &inBufSize, outBuf, &outBufSize, noMoreInputBytesFlag);
				if(compressor.status == LZHAMCompressionStatus.HAS_MORE_OUTPUT)
					fwrite(outBuf, outBufSize, 1, output);
				stdio.writeln(compressor.toString);
			}while(compressor.status < LZHAMCompressionStatus.FIRST_SUCCESS_OR_FAILURE_CODE);
			if(compressor.status > LZHAMDecompressionStatus.FIRST_FAILURE_CODE){
				stdio.writeln("Failed compressing file!");
			}
			fclose(input);
			fclose(output);
		}
	}catch(Exception e){
		stdio.writeln(e);
	}
}
/+void main(){
	stdio.writeln("application entered into main function");
}+/