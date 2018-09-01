module lzbacon.exceptions;

import std.conv;

/**
 * All exceptions in the package derived from this
 */
public class LZHAMException : Exception{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
}
public class BadZLIBHeaderException : LZHAMException{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
}
public class BadSeedBytesException : LZHAMException{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
}
public class BadRawBlockException : LZHAMException{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
	this(T)(T msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super("Bad raw block at address" ~ to!string(msg) ~ "!", file, line, nextInChain);
	}
}
public class BadSyncBlockException : LZHAMException{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
	/*this(string msg, size_t position, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg ~ to!string(position), file, line, nextInChain);
	}*/
}
public class NeedSeedBytesException : LZHAMException{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
}
public class OutputBufferTooSmallException : LZHAMException{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
}
public class TarHeaderException : Exception{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
}
public class DPKException : Exception{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
}
public class ChecksumException : LZHAMException{
	size_t position;

	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		super(msg, file, line, nextInChain);
	}
	this(string msg, size_t position, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null){
		this.position = position;
		super(msg, file, line, nextInChain);
	}
}