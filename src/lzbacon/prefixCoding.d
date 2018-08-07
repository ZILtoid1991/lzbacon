module lzbacon.prefixCoding;

import core.stdc.stdlib;

const uint cMaxExpectedCodeSize = 16;
const uint cMaxSupportedSyms = 1024;
      
// This value can be tuned for a specific CPU.
const uint cMaxTableBits = 11;

bool limitMaxCodeSize(uint numSyms, uint8* pCodesizes, uint maxCodeSize){}

bool generateCodes(uint numSyms, const uint8* pCodesizes, uint16* pCodes){}

public class DecoderTables{
	uint mNumSyms;
	uint mTotalUsedSyms;
	uint mTableBits;
	uint mTableShift;
	uint mTableMaxCode;
	uint mDecodeStartCodeSize;

	ubyte mMinCodeSize;
	ubyte mMaxCodeSize;

	uint mMaxCodes[cMaxExpectedCodeSize + 1];
	int mValPtrs[cMaxExpectedCodeSize + 1];

	uint mCurLookupSize;
	uint[] mLookup;

	uint mCurSortedSymbolOrderSize;
	ushort[] mSortedSymbolOrder;
	this(){
	
	}
	DecoderTables opAssign(DecoderTables rhs){
		if(this == rhs)
			return this;
		uint* pCurLookup = mLookup;
		ushort* pCurSortedSymbolOrder = mSortedSymbolOrder;

		memcpy(&this, &rhs, this.sizeof);
		if (rhs.mLookup.length){
			//m_lookup = lzham_new_array<uint32>(m_cur_lookup_size);
			//mLookup.length = 
				
			//memcpy(m_lookup, rhs.m_lookup, sizeof(m_lookup[0]) * m_cur_lookup_size);
			mLookup = rhs.mLookup;
		}

		lzham_delete_array(pCur_sorted_symbol_order);
		m_sorted_symbol_order = NULL;

		if (rhs.mSortedSymbolOrder.length){
			//m_sorted_symbol_order = lzham_new_array<uint16>(m_cur_sorted_symbol_order_size);
			
			//memcpy(m_sorted_symbol_order, rhs.m_sorted_symbol_order, sizeof(m_sorted_symbol_order[0]) * m_cur_sorted_symbol_order_size);
			mSortedSymbolOrder = rhs.mSortedSymbolOrder;
		}
		
		return this;
	}
	@nogc uint getUnshiftedMaxCode(uint len) const{
		assert( (len >= 1) && (len <= cMaxExpectedCodeSize) );
		uint k = mMaxCodes[len - 1];
		if (!k)
			return UINT_MAX;
		else
			return (k - 1) >> (16 - len);
	}
}

bool limitMaxCodeSize(uint numSyms, uint8* pCodesizes, uint maxCodeSize){
	const uint cMaxEverCodeSize = 34;            
         
	if((!numSyms) || (numSyms > cMaxSupportedSyms) || (maxCodeSize < 1) || (maxCodeSize > cMaxEverCodeSize))
		return false;
         
	uint numCodes[cMaxEverCodeSize + 1];
	//utils::zero_object(num_codes);	//we don't need this since D allocates 0 by default

	bool shouldLimit = false;		//https://www.youtube.com/watch?v=RkEXGgdqMz8
         
	for(uint i ; i < numSyms ; i++){
		uint c = pCodesizes[i];
            
		assert(c <= cMaxEverCodeSize);
            
		numCodes[c]++;
			if(c > maxCodeSize)
				shouldLimit = true;	// :'(
		}
         
		if(!shouldLimit)
            return true;
         
		uint ofs = 0;
		uint nextSortedOfs[cMaxEverCodeSize + 1];
		for(uint i = 1; i <= cMaxEverCodeSize; i++){
			nextSortedOfs[i] = ofs;
			ofs += numCodes[i];
		}
            
		if((ofs < 2) || (ofs > cMaxSupportedSyms))
			return true;
         
		if(ofs > (1U << maxCodeSize))
			return false;
                           
		for(uint i = maxCodeSize + 1; i <= cMaxEverCodeSize; i++)
            numCodes[maxCodeSize] += numCodes[i];
         
         // Technique of adjusting tree to enforce maximum code size from LHArc. 
			// (If you remember what LHArc was, you've been doing this for a LONG time.)
         
		uint total = 0;
		for(uint i = maxCodeSize; i; --i)
			total += (numCodes[i] << (maxCodeSize - i));

		if(total == (1U << maxCodeSize))  
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
		}while(total != (1U << maxCodeSize));
         
		ubyte newCodesizes[cMaxSupportedSyms];
		ubyte* p = newCodesizes.ptr;
		for(uint i = 1; i <= maxCodeSize; i++){
            uint n = numCodes[i];
			if (n){
				memset(p, i, n);
				p += n;
			}
		}
                                             
		for(uint i ; i < numSyms; i++){
			const uint c = pCodesizes[i];
			if(c){
				uint nextOfs = nextSortedOfs[c];
				nextSortedOfs[c] = nextOfs + 1;
            
				pCodesizes[i] = cast(ubyte)(newCodesizes[nextOfs]);
            }
		}
            
	return true;
}
            
bool generateCodes(uint numSyms, const uint8* pCodesizes, uint16* pCodes){
	uint numCodes[cMaxExpectedCodeSize + 1];
	//utils::zero_object(num_codes);

	for (uint i = 0; i < num_syms; i++){
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
            
		assert(!c || total_bits(pCodes[i]) <= pCodesizes[i]);
	}
         
	return true;
}
            
bool generateDecoderTables(uint numSyms, const uint8* pCodesizes, DecoderTables pTables, uint tableBits){
	uint minCodes[cMaxExpectedCodeSize];
         
	if ((!numSyms) || (tableBits > cMaxTableBits))
		return false;
            
	pTables->m_num_syms = num_syms;
         
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
	uint minCodeSize = UINT_MAX;
	for (uint i = 1; i <= cMaxExpectedCodeSize; i++){
		const uint n = numCodes[i];
           
		if (!n)
			pTables.mMaxCodes[i - 1] = 0;//UINT_MAX;
		else{
			//minCodeSize = math::minimum(min_code_size, i);
			minCodeSize = (minCodeSize > i ? i : minCodeSize);
			maxCodeSize = (maxCodeSize > i ? maxCodeSize : i);
                 
			minCodes[i - 1] = nextCode;
              
			pTables.mMaxCodes[i - 1] = nextCode + n - 1;
			pTables.mMaxCodes[i - 1] = 1 + ((pTables.mMaxCodes[i - 1] << (16 - i)) | ((1 << (16 - i)) - 1));
              
			pTables.mValPtrs[i - 1] = totalUsedSyms;
              
			sortedPositions[i] = totalUsedSyms;
              
			nextCode += n;
			total_used_syms += n;
		}
			next_code <<= 1;
	}
        
	pTables.mTotalUsedSyms = totalUsedSyms;
		if(totalUsedSyms > pTables.mCurSortedSymbolOrderSize){
		pTables.mCurSortedSymbolOrderSize = totalUsedSyms;
           
		if(!isPowerOf2(totalUsedSyms)){
			uint nP2 = nextPow2(totalUsedSyms);
			pTables.mCurSortedSymbolOrderSize = numSyms > nP2 ? nP2 : numSyms;
		}
		if(pTables.mSortedSymbolOrder.length){
			pTables.mSortedSymbolOrder.length = 0;
		}
            
	}
         
	pTables.mMinCodeSize = cast(ubyte)(minCodeSize);
	pTables.mMaxCodeSize = cast(ubyte)(maxCodeSize);
                  
	for(uint i ; i < numSyms; i++){
		uint c = pCodesizes[i];
		if(c){
			assert(numCodes[c]);
			uint sortedPos = sortedPositions[c]++;
			assert(sortedPos < totalUsedSyms);
			pTables.mSortedSymbolOrder[sortedPos] = cast(ushort)(i);
		}            
	}

	if(tableBits <= pTables.mMinCodeSize)
		tableBits = 0;                                       
	pTables.mTableBits = tableBits;
                  
	if(tableBits){
		uint tableSize = 1 << tableBits;
		if(tableSize > pTables.mCurLookupSize){
			pTables.mCurLookupSize = tableSize;
			if (pTables.mLookup.length){
				pTables.mLookup.length = 0;
			}
                  
			//pTables.mLookup = lzham_new_array<uint32>(table_size);
			pTables.mLookup.length = tableSize;
				
		}
                        
		memset(pTables.mLookup.ptr, 0xFF, pTables.mLookup.length * uint.sizeof); // original was: static_cast<uint>(sizeof(pTables->m_lookup[0])) * (1UL << table_bits)
            
		for(uint codesize = 1 ; codesize <= tableBits ; codesize++){
			if(!numCodes[codesize])
				continue;
               
			const uint fillsize = table_bits - codesize;
			const uint fillnum = 1 << fillsize;
               
			const uint minCode = minCodes[codesize - 1];
			const uint maxCode = pTables.getUnshiftedMaxCode(codesize);
			const uint valPtr = pTables.mValPtrs[codesize - 1];
                      
			for(uint code = minCode; code <= maxCode; code++){
				const uint symIndex = pTables.mSortedSymbolOrder[ valPtr + code - minCode ];
				assert(pCodesizes[sym_index] == codesize);
                  
				for(uint j = 0; j < fillnum; j++){
					const uint t = j + (code << fillsize);
					assert(t < (1U << tableBits));
					assert(pTables.mLookup[t] == uint.max);
                     
					pTables.mLookup[t] = symIndex | (codesize << 16U);
				}
			}
		}
	}         
         
	for(uint i = 0; i < cMaxExpectedCodeSize; i++)
		pTables.mValPtrs[i] -= minCodes[i];
         
	pTables.mTableMaxCode = 0;
	pTables.mDecodeStartCodeSize = pTables.mMinCodeSize;

	if(tableBits){
		uint i;
		for(i = tableBits; i >= 1; i--){
			if(numCodes[i]){
				pTables.mTableMaxCode = pTables.mMaxCodes[i - 1];
				break;
			}
		}
		if(i >= 1){
			pTables.mDecodeStartCodeSize = tableBits + 1;
			for (i = tableBits + 1; i <= maxCodeSize; i++){
				if (numCodes[i]){
					pTables.mDecodeStartCodeSize = i;
					break;
				}
			}
		}
	}

	// sentinels
	pTables.mMaxCodes[cMaxExpectedCodeSize] = uint.max;
	pTables.mValPtrs[cMaxExpectedCodeSize] = 0xFFFFF;

	pTables.mTableShift = 32 - pTables.mTableBits;

	return true;
}