module lzbacon.huffmanCodes;

import lzbacon.common;
import core.stdc.string;

static immutable uint cHuffmanMaxSupportedSyms = 1024;
/**
 * Stores the frequency of the occurences of symbols.
 */
struct SymFreq{
	uint mFreq;
	ushort mLeft;
	ushort mRight;

	public @nogc int opCmp(SymFreq rhs){
		if(mFreq > rhs.mFreq){
			return 1;
		}else if(mFreq > rhs.mFreq){
			return -1;
		}else{
			return 0;
		}
	}
}

static @nogc SymFreq* radixSortSyms(uint numSyms, SymFreq* syms0, SymFreq* syms1){
	const uint cMaxPasses = 2;
	uint[256 * cMaxPasses] hist;

	{
		SymFreq* p = syms0;
		SymFreq* q = syms0 + (numSyms & EVEN_NUMBER_ROUNDER);
		for( ; p != q ; p+=2){
			uint freq0 = p[0].mFreq;
			uint freq1 = p[1].mFreq;

			hist[freq0 & 0xFF]++;
			hist[256 + ((freq0>>8) & 0xFF)]++;
			hist[freq1 & 0xFF]++;
			hist[256 + ((freq1>>8) & 0xFF)]++;
		}
		if(numSyms & 1){
			uint freq0 = p.mFreq;

			hist[freq0 & 0xFF]++;
			hist[256 + ((freq0>>8) & 0xFF)]++;
		}
		
	}
	SymFreq* pCurSyms = syms0;
	SymFreq* pNewSyms = syms1;

	const uint totalPasses = (hist[256] == numSyms) ? 1 : cMaxPasses;

	for(uint pass ; pass < totalPasses ; pass++){
		uint* pHist = &hist[pass << 8];

		uint[256] offsets;

		uint cur_ofs = 0;
		for(int i ; i < 256 ; i+=2){
			offsets[i] = cur_ofs;
            cur_ofs += pHist[i];

            offsets[i+1] = cur_ofs;
            cur_ofs += pHist[i+1];
		}

		uint passShift = pass << 3;

		SymFreq* p = pCurSyms;
		SymFreq* q = pCurSyms + (numSyms & EVEN_NUMBER_ROUNDER);

		for ( ; p != q; p += 2){
			uint c0 = p[0].mFreq;
			uint c1 = p[1].mFreq;
            
			if (pass){
               c0 >>= 8;
               c1 >>= 8;
            }
            
            c0 &= 0xFF;
            c1 &= 0xFF;

            if (c0 == c1){
				uint dstOffset0 = offsets[c0];

				offsets[c0] = dstOffset0 + 2;

				pNewSyms[dstOffset0] = p[0];
				pNewSyms[dstOffset0 + 1] = p[1];
			}else{
               uint dstOffset0 = offsets[c0]++;
               uint dstOffset1 = offsets[c1]++;

               pNewSyms[dstOffset0] = p[0];
               pNewSyms[dstOffset1] = p[1];
            }
         }

         if (numSyms & 1){
            uint c = ((p.mFreq) >> passShift) & 0xFF;

            uint dstOffset = offsets[c];
            offsets[c] = dstOffset + 1;

            pNewSyms[dstOffset] = *p;
         }

         SymFreq* t = pCurSyms;
         pCurSyms = pNewSyms;
         pNewSyms = t;
	}
	return pCurSyms;
}
struct HuffmanWorkTables{
	enum{
		cMaxInternalNodes = cHuffmanMaxSupportedSyms
	}
	SymFreq[cHuffmanMaxSupportedSyms + 1 + cMaxInternalNodes] syms0;
	SymFreq[cHuffmanMaxSupportedSyms + 1 + cMaxInternalNodes] syms1;
}
/**
 * DEPRACATED, use HuffmanWorkTables.sizeof instead!
 */
static deprecated @nogc uint getGenerateHuffmanCodesTableSize(){
	return HuffmanWorkTables.sizeof;
}

/** 
 * calculate_minimum_redundancy() written by Alistair Moffat, alistair@cs.mu.oz.au, Jyrki Katajainen, jyrki@diku.dk November 1996.|
 * Ported to D by Laszlo Szeremi under the name calculateMinimumRedundancy.
 */
static @nogc void calculateMinimumRedundancy(int* A, int n){
	int root;                  /** next root node to be used */
	int leaf;                  /** next leaf to be used */
	int next;                  /** next value to be assigned */
	int avbl;                  /** number of available nodes */
	int used;                  /** number of internal nodes */
	int dpth;                  /** current depth of leaves */

	/* check for pathological cases */
	if (n==0) { return; }
	if (n==1) { A[0] = 0; return; }

	/* first pass, left to right, setting parent pointers */
	A[0] += A[1]; root = 0; leaf = 2;
	for (next=1; next < n-1; next++) {
		/* select first item for a pairing */
		if (leaf>=n || A[root]<A[leaf]) {
			A[next] = A[root]; A[root++] = next;
		} else
			A[next] = A[leaf++];

		/* add on the second item */
		if (leaf>=n || (root<next && A[root]<A[leaf])) {
			A[next] += A[root]; A[root++] = next;
		} else
			A[next] += A[leaf++];
	}

	/* second pass, right to left, setting internal depths */
	A[n-2] = 0;
	for (next=n-3; next>=0; next--)
		A[next] = A[A[next]]+1;

	/* third pass, right to left, setting leaf depths */
	avbl = 1; used = dpth = 0; root = n-2; next = n-1;
	while (avbl>0) {
		while (root>=0 && A[root]==dpth) {
			used++; root--;
		}
		while (avbl>used) {
			A[next--] = dpth; avbl--;
		}
		avbl = 2*used; dpth++; used = 0;
	}
}

static @nogc bool generateHuffmanCodes(void* pContext, uint numSyms, const ushort* pFreq, ubyte* pCodesizes, 
			out uint maxCodeSize, out uint totalFreqRet){
	//import core.stdc.math;
	if ((!numSyms) || (numSyms > cHuffmanMaxSupportedSyms))
		return false;

	HuffmanWorkTables* state = cast(HuffmanWorkTables*)pContext;

	uint maxFreq = 0;
	uint totalFreq = 0;
      
	uint numUsedSyms = 0;

	for (uint i = 0; i < numSyms; i++){
		uint freq = pFreq[i];
         
		if (!freq)
			pCodesizes[i] = 0;
		else{
			totalFreq += freq;
			maxFreq = maxFreq > freq ? maxFreq : freq;
            
			SymFreq* sf = &state.syms0[numUsedSyms];
			sf.mLeft = cast(ushort)i;
			sf.mRight = ushort.max;
			sf.mFreq = freq;
			numUsedSyms++;
		}            
	}
	
	totalFreqRet = totalFreq;
	if (numUsedSyms == 1){
		pCodesizes[state.syms0[0].mLeft] = 1;
		return true;
	}

	SymFreq* syms = radixSortSyms(numUsedSyms, state.syms0.ptr, state.syms1.ptr);

	int[cHuffmanMaxSupportedSyms] x;	//this was int in the original code, it probably should work
	for(uint i = 0 ; i < numUsedSyms ; i++){
		x[i] = syms[i].mFreq;
	}
	calculateMinimumRedundancy(x.ptr, numUsedSyms);

	uint maxLen = 0;
	for (uint i = 0; i < numUsedSyms; i++){
		uint len = x[i];
		maxLen = len > maxLen ? len : maxLen;
		pCodesizes[syms[i].mLeft] = cast(ubyte)len;
	}
	maxCodeSize = maxLen;

	return true;
}