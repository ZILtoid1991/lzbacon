module lzbacon.system;

import core.stdc.string;

version(X86_64){
	static enum CPU_64BIT_CAPABLE = true;
	version(DMD){
		static enum ENABLE_DMD_SIMD = true;
	}
}
version(LDC){
	static enum ENABLE_INTEL_INTRINSICS = true;
	immutable uint[4] negator = [uint.max,uint.max,uint.max,uint.max];
}
version(NEON){
	static enum ENABLE_NEON = true;
}
version(AArch64){
	static enum CPU_64BIT_CAPABLE = true;
	static enum ENABLE_NEON = true;
}

static LZHAMLogger logger;
static bool forceFinish;

public class LZHAMLogger{
	string[] logs;
	void delegate(string s) onMessageLogging;
	public this(){

	}
	public void log(string s){
		logs ~= s;
		if(onMessageLogging !is null)
			onMessageLogging(s);
	}
}


public @nogc uint floor_log2i(int v){
	uint l = 0;
	while (v > 1U){
		v >>= 1;
		l++;
	}
	return l;
}

public @nogc uint ceil_log2i(int v){
	uint l = floor_log2i(v);
	if ((l != cIntBits) && (v > (1U << l)))
		l++;
	return l;
}
public @nogc void zeroObject(T)(T object){
	memset(cast(void*)&T, 0, T.sizeof);
}

public @nogc uint total_bits(uint v){
	ulong l = 0;
	while (v > 0U){
		v >>= 1;
		l++;
	}
	return cast(uint)l;
}

public @nogc bool isPowerOf2(T = uint)(T x){
	return x && ((x & (x - 1U)) == 0U); 
}

/**
 * From "Hackers Delight"
 * val remains unchanged if it is already a power of 2.
 */
public @nogc T nextPow2(T)(T val){
	val--;
	val |= val >> 16;
	val |= val >> 8;
	val |= val >> 4;
	val |= val >> 2;
	val |= val >> 1;
	return val + 1;
}

public T[] ptrToArray(T)(T* ptr, size_t lenght){
	return ptr[0..length];
} 