module lzbacon.prefixCoding;

import lzbacon.system;

import core.stdc.stdlib;
import core.stdc.string;

const uint cMaxExpectedCodeSize = 16;
const uint cMaxSupportedSyms = 1024;
      
// This value can be tuned for a specific CPU.
const uint cMaxTableBits = 11;

static @nogc bool limitMaxCodeSize(uint numSyms, ubyte* pCodesizes, uint maxCodeSize){
	immutable uint cMaxEverCodeSize = 34;            
	
	if ((!numSyms) || (numSyms > cMaxSupportedSyms) || (maxCodeSize < 1) || (maxCodeSize > cMaxEverCodeSize))
		return false;
	
	uint numCodes[cMaxEverCodeSize + 1];
	
	bool shouldLimit = false;
	
	for (uint i = 0; i < numSyms; i++){
		uint c = pCodesizes[i];
		
		assert(c <= cMaxEverCodeSize);
		
		numCodes[c]++;
		if (c > maxCodeSize)
			shouldLimit = true;
	}
	
	if (!shouldLimit)
		return true;
	
	uint ofs = 0;
	uint nextSortedOfs[cMaxEverCodeSize + 1];
	for (uint i = 1; i <= cMaxEverCodeSize; i++){
		nextSortedOfs[i] = ofs;
		ofs += numCodes[i];
	}
	
	if ((ofs < 2) || (ofs > cMaxSupportedSyms))
		return true;
	
	if (ofs > (1U << maxCodeSize))
		return false;
	
	for (uint i = maxCodeSize + 1; i <= cMaxEverCodeSize; i++)
		numCodes[maxCodeSize] += numCodes[i];
	
	// Technique of adjusting tree to enforce maximum code size from LHArc. 
	// (If you remember what LHArc was, you've been doing this for a LONG time.)
	
	uint total = 0;
	for (uint i = maxCodeSize; i; --i)
		total += (numCodes[i] << (maxCodeSize - i));
	
	if (total == (1U << maxCodeSize))  
		return true;
	
	do{
		numCodes[maxCodeSize]--;
		
		uint i;
		for (i = maxCodeSize - 1; i; --i){
			if (!numCodes[i])
				continue;
			numCodes[i]--;          
			numCodes[i + 1] += 2;   
			break;
		}
		if (!i)
			return false;
		
		total--;   
	} while (total != (1U << maxCodeSize));
	
	ubyte newCodesizes[cMaxSupportedSyms];
	ubyte* p = newCodesizes.ptr;
	for (uint i = 1; i <= maxCodeSize; i++){
		uint n = numCodes[i];
		if (n){
			memset(p, i, n);
			p += n;
		}
	}
	
	for (uint i = 0; i < numSyms; i++){
		const uint c = pCodesizes[i];
		if (c){
			uint next_ofs = nextSortedOfs[c];
			nextSortedOfs[c] = next_ofs + 1;
			
			pCodesizes[i] = cast(ubyte)(newCodesizes[next_ofs]);
		}
	}
	
	return true;
}

@nogc bool generateCodes(uint numSyms, const ubyte* pCodesizes, ushort* pCodes){
	uint numCodes[cMaxExpectedCodeSize + 1];
	//utils::zero_object(num_codes);
	
	for (uint i = 0; i < numSyms; i++){
		uint c = pCodesizes[i];
		assert(c <= cMaxExpectedCodeSize);
		numCodes[c]++;
	}
	
	uint code = 0;
	
	uint nextCode[cMaxExpectedCodeSize + 1];
	nextCode[0] = 0;
	
	for (uint i = 1; i <= cMaxExpectedCodeSize; i++){
		nextCode[i] = code;
		
		code = (code + numCodes[i]) << 1;
	}
	
	if (code != (1 << (cMaxExpectedCodeSize + 1))){
		uint t = 0;
		for (uint i = 1; i <= cMaxExpectedCodeSize; i++){
			t += numCodes[i];
			if (t > 1)
				return false;
		}
	}
	
	for (uint i = 0; i < numSyms; i++){
		uint c = pCodesizes[i];
		
		assert(!c || (nextCode[c] <= ushort.max));
		
		pCodes[i] = cast(ushort)(nextCode[c]++);
		
		assert(!c || (total_bits(pCodes[i]) <= pCodesizes[i]));
	}
	
	return true;
}

bool generateDecoderTables(uint numSyms, const ubyte* pCodesizes, DecoderTables pTables, uint tableBits){
	uint minCodes[cMaxExpectedCodeSize];
	
	if ((!numSyms) || (tableBits > cMaxTableBits))
		return false;
	
	pTables.numSyms = numSyms;
	
	uint numCodes[cMaxExpectedCodeSize + 1];
	//utils::zero_object(num_codes);
	
	for (uint i = 0; i < numSyms; i++){
		uint c = pCodesizes[i];
		numCodes[c]++;
	}
	
	uint sortedPositions[cMaxExpectedCodeSize + 1];
	
	uint nextCode = 0;
	
	uint totalUsedSyms = 0;
	uint maxCodeSize = 0;
	uint minCodeSize = uint.max;
	for (uint i = 1; i <= cMaxExpectedCodeSize; i++){
		const uint n = numCodes[i];
		
		if (!n)
			pTables.maxCodes[i - 1] = 0;//UINT_MAX;
		else{
			//minCodeSize = math::minimum(min_code_size, i);
			minCodeSize = (minCodeSize > i ? i : minCodeSize);
			maxCodeSize = (maxCodeSize > i ? maxCodeSize : i);
			
			minCodes[i - 1] = nextCode;
			
			pTables.maxCodes[i - 1] = nextCode + n - 1;
			pTables.maxCodes[i - 1] = 1 + ((pTables.maxCodes[i - 1] << (16 - i)) | ((1 << (16 - i)) - 1));
			
			pTables.valPtrs[i - 1] = totalUsedSyms;
			
			sortedPositions[i] = totalUsedSyms;
			
			nextCode += n;
			totalUsedSyms += n;
		}
		nextCode <<= 1;
	}
	
	pTables.totalUsedSyms = totalUsedSyms;
	if(totalUsedSyms > pTables.curSortedSymbolOrderSize){
		pTables.curSortedSymbolOrderSize = totalUsedSyms;
		
		if(!isPowerOf2(totalUsedSyms)){
			uint nP2 = nextPow2(totalUsedSyms);
			pTables.curSortedSymbolOrderSize = numSyms > nP2 ? nP2 : numSyms;
		}
		if(pTables.sortedSymbolOrder.length){
			pTables.sortedSymbolOrder.length = 0;
		}
		
	}
	
	pTables.minCodeSize = cast(ubyte)(minCodeSize);
	pTables.maxCodeSize = cast(ubyte)(maxCodeSize);
	
	for(uint i ; i < numSyms; i++){
		uint c = pCodesizes[i];
		if(c){
			assert(numCodes[c]);
			uint sortedPos = sortedPositions[c]++;
			assert(sortedPos < totalUsedSyms);
			pTables.sortedSymbolOrder[sortedPos] = cast(ushort)(i);
		}            
	}
	
	if(tableBits <= pTables.minCodeSize)
		tableBits = 0;                                       
	pTables.tableBits = tableBits;
	
	if(tableBits){
		uint tableSize = 1 << tableBits;
		if(tableSize > pTables.curLookupSize){
			pTables.curLookupSize = tableSize;
			if (pTables.lookup.length){
				pTables.lookup.length = 0;
			}
			
			//pTables.mLookup = lzham_new_array<uint32>(table_size);
			pTables.lookup.length = tableSize;
			
		}
		
		memset(pTables.lookup.ptr, 0xFF, pTables.lookup.length * uint.sizeof); // original was: static_cast<uint>(sizeof(pTables->m_lookup[0])) * (1UL << table_bits)
		
		for(uint codesize = 1 ; codesize <= tableBits ; codesize++){
			if(!numCodes[codesize])
				continue;
			
			const uint fillsize = tableBits - codesize;
			const uint fillnum = 1 << fillsize;
			
			const uint minCode = minCodes[codesize - 1];
			const uint maxCode = pTables.getUnshiftedMaxCode(codesize);
			const uint valPtr = pTables.valPtrs[codesize - 1];
			
			for(uint code = minCode; code <= maxCode; code++){
				const uint symIndex = pTables.sortedSymbolOrder[ valPtr + code - minCode ];
				assert(pCodesizes[symIndex] == codesize);
				
				for(uint j = 0; j < fillnum; j++){
					const uint t = j + (code << fillsize);
					assert(t < (1U << tableBits));
					assert(pTables.lookup[t] == uint.max);
					
					pTables.lookup[t] = symIndex | (codesize << 16U);
				}
			}
		}
	}         
	
	for(uint i = 0; i < cMaxExpectedCodeSize; i++)
		pTables.valPtrs[i] -= minCodes[i];
	
	pTables.tableMaxCode = 0;
	pTables.decodeStartCodeSize = pTables.minCodeSize;
	
	if(tableBits){
		uint i;
		for(i = tableBits; i >= 1; i--){
			if(numCodes[i]){
				pTables.tableMaxCode = pTables.maxCodes[i - 1];
				break;
			}
		}
		if(i >= 1){
			pTables.decodeStartCodeSize = tableBits + 1;
			for (i = tableBits + 1; i <= maxCodeSize; i++){
				if (numCodes[i]){
					pTables.decodeStartCodeSize = i;
					break;
				}
			}
		}
	}
	
	// sentinels
	pTables.maxCodes[cMaxExpectedCodeSize] = uint.max;
	pTables.valPtrs[cMaxExpectedCodeSize] = 0xFFFFF;
	
	pTables.tableShift = 32 - pTables.tableBits;
	
	return true;
}

public class DecoderTables{
	uint numSyms;
	uint totalUsedSyms;
	uint tableBits;
	uint tableShift;
	uint tableMaxCode;
	uint decodeStartCodeSize;

	ubyte minCodeSize;
	ubyte maxCodeSize;

	uint maxCodes[cMaxExpectedCodeSize + 1];
	int valPtrs[cMaxExpectedCodeSize + 1];

	uint curLookupSize;
	uint[] lookup;

	uint curSortedSymbolOrderSize;
	ushort[] sortedSymbolOrder;
	this(){
	
	}
	DecoderTables assign(DecoderTables rhs){
		if(this == rhs)
			return this;
		static foreach(i, v ; DecoderTables.tupleof){
			this.tupleof[i] = rhs.tupleof[i];
		}

		
		return this;
	}
	@nogc uint getUnshiftedMaxCode(uint len) const{
		assert( (len >= 1) && (len <= cMaxExpectedCodeSize) );
		uint k = maxCodes[len - 1];
		if (!k)
			return uint.max;
		else
			return (k - 1) >> (16 - len);
	}
}

