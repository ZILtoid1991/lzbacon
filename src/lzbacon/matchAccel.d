module lzbacon.matchAccel;

import lzbacon.base;
import lzbacon.system;

//import core.thread;		//might need to change it to something else
import std.parallelism;
import core.atomic;
import core.stdc.string;

const uint cMatchAccelMaxSupportedProbes = 128;

struct Node{
	uint m_left;
	uint m_right;
}

struct DictMatch{
	uint m_dist;
	uint16 m_len;
	
	@nogc @property uint get_dist() const { 
		return m_dist & 0x7FFFFFFF; 
	}
	@nogc @property uint get_len() const { 
		return m_len + 2; 
	}
	@nogc @property bool is_last() const { 
		return cast(int)m_dist < 0; 
	}
}

class SearchAccelerator{
	static ubyte g_hamming_dist[256] =
	[
		0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4,
			1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
			1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
			2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
			1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
			2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
			2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
			3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
			1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
			2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
			2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
			3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
			2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
			3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
			3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
			4, 5, 5, 6, 5, 6, 6, 7, 5, 6, 6, 7, 6, 7, 7, 8
	];
	CLZBase m_pLZBase;
	//task_pool* m_pTask_pool;	//don't know what will replace it yet
	//Thread taskPool;	//I hope this will be good
	uint m_max_helper_threads;
	
	uint m_max_dict_size;
	uint m_max_dict_size_mask;
	
	uint m_lookahead_pos;
	uint m_lookahead_size;
	
	uint m_cur_dict_size;
	
	ubyte[] m_dict;
	
	enum { cHashSize = 65536 };
	uint[] m_hash;
	Node[] m_nodes;
	
	DictMatch[] m_matches;
	uint[] m_match_refs;
	
	ubyte[] m_hash_thread_index;
	
	enum { cDigramHashSize = 4096 };
	uint[] m_digram_hash;
	uint[] m_digram_next;

	uint m_fill_lookahead_pos;
	uint m_fill_lookahead_size;
	uint m_fill_dict_size;

	uint m_max_probes;
	uint m_max_matches;
	
	bool m_all_matches;
	
	uint m_next_match_ref;
	
	uint m_num_completed_helper_threads;
	
	void function(uint64 data, void* pData_ptr) find_all_matches_callback;
	bool function(uint num_bytes) find_all_matches;
	bool function() find_len2_matches;

	this(){

	}

	bool init(CLZBase pLZBase, /*task_pool* pPool,*/ uint max_helper_threads, uint max_dict_size, uint max_matches, bool all_matches, uint max_probes){
		assert(pLZBase);
		assert(max_dict_size && isPowerOf2(max_dict_size));
		assert(max_probes);
		
		//m_max_probes = LZHAM_MIN(cMatchAccelMaxSupportedProbes, max_probes);
		this.m_max_probes = cMatchAccelMaxSupportedProbes > max_probes ? max_probes : cMatchAccelMaxSupportedProbes;
		
		this.m_pLZBase = pLZBase;
		//m_pTask_pool = max_helper_threads ? pPool : null;
		//this.m_max_helper_threads = m_pTask_pool ? max_helper_threads : 0;
		this.m_max_helper_threads = max_helper_threads;
		this.m_max_matches = LZHAM_MIN(m_max_probes, max_matches);
		this.m_all_matches = all_matches;

		this.m_max_dict_size = max_dict_size;
		this.m_max_dict_size_mask = m_max_dict_size - 1;
		this.m_cur_dict_size = 0;
		m_lookahead_size = 0;
		m_lookahead_pos = 0;
		m_fill_lookahead_pos = 0;
		m_fill_lookahead_size = 0;
		m_fill_dict_size = 0;
		m_num_completed_helper_threads = 0;

		m_dict.length = max_dict_size + (m_max_dict_size > CLZBase.cMaxHugeMatchLength ? CLZBase.cMaxHugeMatchLength : m_max_dict_size);
		m_hash.length = cHashSize;
		m_nodes.length = max_dict_size;
		/*if (!m_dict.try_resize_no_construct(max_dict_size + LZHAM_MIN(m_max_dict_size, static_cast<uint>(CLZBase::cMaxHugeMatchLen))))
			return false;
		
		if (!m_hash.try_resize_no_construct(cHashSize))
			return false;
		
		if (!m_nodes.try_resize_no_construct(max_dict_size))
			return false;*/
		
		//memset(m_hash.get_ptr(), 0, m_hash.size_in_bytes());
		
		return true;
	}
	
	@nogc void reset(){
		m_cur_dict_size = 0;
		m_lookahead_size = 0;
		m_lookahead_pos = 0;
		m_fill_lookahead_pos = 0;
		m_fill_lookahead_size = 0;
		m_fill_dict_size = 0;
		m_num_completed_helper_threads = 0;

		// Clearing the hash tables is only necessary for determinism (otherwise, it's possible the matches returned after a reset will depend on the data processes before the reset).

		if(m_hash.length){
			memset(m_hash.ptr, 0, m_hash.length * uint.sizeof);
		}

		if(m_digram_hash.length){
			memset(m_digram_hash.ptr, 0, m_hash.length * uint.sizeof);
		}
	}
	@nogc void flush(){
		m_cur_dict_size = 0;
	}
	
	@nogc uint get_max_dict_size() const { 
		return m_max_dict_size; 
	}
	@nogc uint get_max_dict_size_mask() const { 
		return m_max_dict_size_mask; 
	}
	@nogc uint get_cur_dict_size() const { 
		return m_cur_dict_size; 
	}
	
	@nogc uint get_lookahead_pos() const { 
		return m_lookahead_pos; 
	}
	@nogc uint get_lookahead_size() const { 
		return m_lookahead_size; 
	}
	
	@nogc uint get_char(int delta_pos) const { 
		return m_dict[(m_lookahead_pos + delta_pos) & m_max_dict_size_mask]; 
	}
	@nogc uint get_char(uint cur_dict_pos, int delta_pos) const { 
		return m_dict[(cur_dict_pos + delta_pos) & m_max_dict_size_mask]; 
	}
	@nogc const uint8* get_ptr(uint pos) const { 
		return &m_dict[pos]; 
	}
	
	@nogc uint get_max_helper_threads() const { 
		return m_max_helper_threads; 
	}
	
	@nogc uint operator[](uint pos) const { 
		return m_dict[pos]; 
	}

	@nogc uint get_max_add_bytes() const{
		uint add_pos = cast(uint)(m_lookahead_pos & (m_max_dict_size - 1));
		return m_max_dict_size - add_pos;
	}

	void find_all_matches_callback(ulong data, void* pData_ptr){
		//scoped_perf_section find_all_matches_timer("find_all_matches_callback");
		
		//LZHAM_NOTE_UNUSED(pData_ptr);
		const uint threadIndex = cast(uint)data;
		
		DictMatch tempMatches[cMatchAccelMaxSupportedProbes * 2];
		
		uint fillLookaheadPos = this.m_fill_lookahead_pos;
		uint fillDictSize = this.m_fill_dict_size;
		uint fillLookaheadSize = this.m_fill_lookahead_size;
		
		uint c0 = 0, c1 = 0;
		if (fillLookaheadSize >= 2){
			c0 = m_dict[fillLookaheadPos & m_max_dict_size_mask];
			c1 = m_dict[(fillLookaheadPos & m_max_dict_size_mask) + 1];
		}
		
		const ubyte* pDict = m_dict.ptr;
		
		while (fillLookaheadSize >= 3){
			uint insertPos = fillLookaheadPos & m_max_dict_size_mask;
			
			uint c2 = pDict[insertPos + 2];
			uint h = hash3_to_16(c0, c1, c2);
			c0 = c1;
			c1 = c2;
			
			assert(!m_hash_thread_index.size() || (m_hash_thread_index[h] != ubyte.max));
			
			// Only process those strings that this worker thread was assigned to - this allows us to manipulate multiple trees in parallel with no worries about synchronization.
			if (m_hash_thread_index.size() && (m_hash_thread_index[h] != threadIndex)){
				fillLookaheadPos++;
				fillLookaheadSize--;
				fillDictSize++;
				continue;
			}
			
			DictMatch* pDstMatch = tempMatches;
			
			uint cur_pos = m_hash[h];
			m_hash[h] = cast(uint)(fillLookaheadPos);
			
			uint *pLeft = &m_nodes[insertPos].m_left;
			uint *pRight = &m_nodes[insertPos].m_right;
			
			//const uint max_match_len = LZHAM_MIN(static_cast<uint>(CLZBase::cMaxMatchLen), fill_lookahead_size);
			const uint max_match_len = (cast(uint)(CLZBase.cMaxMatchLen) > fillLookaheadSize ? fillLookaheadSize : cast(uint)(CLZBase.cMaxMatchLen));
			uint best_match_len = 2;
			
			const ubyte* pIns = &pDict[insertPos];
			
			uint n = m_max_probes;
			for ( ; ; ){
				uint deltaPos = fillLookaheadPos - cur_pos;
				if ((n-- == 0) || (!deltaPos) || (deltaPos >= fillDictSize)){
					*pLeft = 0;
					*pRight = 0;
					break;
				}
				
				uint pos = cur_pos & m_max_dict_size_mask;
				node *pNode = &m_nodes[pos];
				
				// Unfortunately, the initial compare match_len must be 0 because of the way we hash and truncate matches at the end of each block.
				uint matchLen = 0;
				const uint8* pComp = &pDict[pos];
				
//#if LZHAM_PLATFORM_X360 || (LZHAM_USE_UNALIGNED_INT_LOADS == 0)
				for ( ; matchLen < max_match_len; matchLen++)
					if (pComp[matchLen] != pIns[matchLen])
						break;
				if (matchLen > best_match_len){
					pDstMatch->m_len = cast(ushort)(matchLen - CLZBase.cMinMatchLen);
					pDstMatch->m_dist = deltaPos;
					pDstMatch++;
					
					best_match_len = matchLen;
					
					if (matchLen == max_match_len){
						*pLeft = pNode->m_left;
						*pRight = pNode->m_right;
						break;
					}
				}else if (m_all_matches){
					pDstMatch->m_len = cast(ushort)(matchLen - CLZBase.cMinMatchLen);
					pDstMatch->m_dist = deltaPos;
					pDstMatch++;
				}else if ((best_match_len > 2) && (best_match_len == matchLen)){
					uint bestMatchDist = pDstMatch[-1].m_dist;
					uint compMatchDist = deltaPos;
					
					uint bestMatchSlot, bestMatchSlotOfs;
					m_pLZBase->compute_lzx_position_slot(bestMatchDist, bestMatchSlot, bestMatchSlotOfs);
					
					uint compMatchSlot, compMatchOfs;
					m_pLZBase->compute_lzx_position_slot(compMatchDist, compMatchSlot, compMatchOfs);
					
					// If both matches uses the same match slot, choose the one with the offset containing the lowest nibble as these bits separately entropy coded.
					// This could choose a match which is further away in the absolute sense, but closer in a coding sense.
					if ( (compMatchSlot < bestMatchSlot) ||
						((compMatchSlot >= 8) && (compMatchSlot == bestMatchSlot) && ((compMatchOfs & 15) < (bestMatchSlotOfs & 15))) ){
						assert((pDstMatch[-1].m_len + cast(uint)CLZBase.cMinMatchLen) == best_match_len);
						pDstMatch[-1].m_dist = deltaPos;
					}else if ((matchLen < max_match_len) && (compMatchSlot <= bestMatchSlot)){
						// Choose the match which has lowest hamming distance in the mismatch byte for a tiny win on binary files.
						// TODO: This competes against the prev. optimization.
						uint desiredMismatchByte = pIns[matchLen];
						
						uint curMismatchByte = pDict[(insertPos - bestMatchDist + matchLen) & m_max_dict_size_mask];
						uint curMismatchDist = g_hamming_dist[curMismatchByte ^ desiredMismatchByte];
						
						uint newMismatchByte = pComp[matchLen];
						uint newMismatchDist = g_hamming_dist[newMismatchByte ^ desiredMismatchByte];
						if (newMismatchDist < curMismatchDist){
							assert((pDstMatch[-1].m_len + cast(uint)CLZBase.cMinMatchLen) == best_match_len);
							pDstMatch[-1].m_dist = deltaPos;
						}
					}
				}
				
				uint new_pos;
				if (pComp[matchLen] < pIns[matchLen]){
					*pLeft = cur_pos;
					pLeft = &pNode->m_right;
					new_pos = pNode->m_right;
				}else{
					*pRight = cur_pos;
					pRight = &pNode->m_left;
					new_pos = pNode->m_left;
				}
				if (new_pos == cur_pos)
					break;
				cur_pos = new_pos;
			}
			
			const uint num_matches = (uint)(pDstMatch - tempMatches);
			
			if (num_matches){
				pDstMatch[-1].m_dist |= 0x80000000;
				
				const uint num_matches_to_write = LZHAM_MIN(num_matches, m_max_matches);
				
				const uint match_ref_ofs = static_cast<uint>(atomic_exchange_add(&m_next_match_ref, num_matches_to_write));
				
				memcpy(&m_matches[match_ref_ofs],
					tempMatches + (num_matches - num_matches_to_write),
					sizeof(tempMatches[0]) * num_matches_to_write);
				
				// FIXME: This is going to really hurt on platforms requiring export barriers.
				//LZHAM_MEMORY_EXPORT_BARRIER
					
				//atomic_exchange32((atomic32_t*)&m_match_refs[static_cast<uint>(fill_lookahead_pos - m_fill_lookahead_pos)], match_ref_ofs);
			}else{
				//atomic_exchange32((atomic32_t*)&m_match_refs[static_cast<uint>(fill_lookahead_pos - m_fill_lookahead_pos)], -2);
			}
			
			fillLookaheadPos++;
			fillLookaheadSize--;
			fillDictSize++;
		}
		
		while (fillLookaheadSize){
			uint insert_pos = fillLookaheadPos & m_max_dict_size_mask;
			m_nodes[insert_pos].m_left = 0;
			m_nodes[insert_pos].m_right = 0;
			
			//atomic_exchange32((atomic32_t*)&m_match_refs[static_cast<uint>(fill_lookahead_pos - m_fill_lookahead_pos)], -2);
			
			fillLookaheadPos++;
			fillLookaheadSize--;
			fillDictSize++;
		}
		
		//atomic_increment32(&m_num_completed_helper_threads);
		m_num_completed_helper_threads++;
	}
	bool find_len2_matches(){
		if (!m_digram_hash.length){
			m_digram_hash.length = cDigramHashSize;
			/*if (!m_digram_hash.try_resize(cDigramHashSize))
				return false;*/
		}
		
		if (m_digram_next.length < m_lookahead_size){
			m_digram_next.length = m_lookahead_size;
			/*if (!m_digram_next.try_resize(m_lookahead_size))
				return false;*/
		}
		
		uint lookahead_dict_pos = m_lookahead_pos & m_max_dict_size_mask;
		
		for (int lookahead_ofs = 0; lookahead_ofs < (cast(int)m_lookahead_size - 1); ++lookahead_ofs, ++lookahead_dict_pos){
			uint c0 = m_dict[lookahead_dict_pos];
			uint c1 = m_dict[lookahead_dict_pos + 1];
			
			uint h = hash2_to_12(c0, c1) & (cDigramHashSize - 1);
			
			m_digram_next[lookahead_ofs] = m_digram_hash[h];
			m_digram_hash[h] = m_lookahead_pos + lookahead_ofs;
		}
		
		m_digram_next[m_lookahead_size - 1] = 0;
		
		return true;
	}
	bool find_all_matches(uint numBytes){
		/*if (!m_matches.try_resize_no_construct(m_max_probes * num_bytes))
			return false;
		
		if (!m_match_refs.try_resize_no_construct(num_bytes))
			return false;*/
		m_matches.length = m_max_probes * numBytes;
		m_match_refs.length = numBytes;
		
		memset(m_match_refs.ptr, 0xFF, m_match_refs.length * uint.sizeof);
		
		m_fill_lookahead_pos = m_lookahead_pos;
		m_fill_lookahead_size = numBytes;
		m_fill_dict_size = m_cur_dict_size;
		
		m_next_match_ref = 0;
		
		//if (!m_pTask_pool){
		if(m_max_helper_threads == 0){
			find_all_matches_callback(0, NULL);
			
			m_num_completed_helper_threads = 0;
		}else{
			if (!m_hash_thread_index.try_resize_no_construct(0x10000))
				return false;
			
			memset(m_hash_thread_index.ptr, 0xFF, m_hash_thread_index.length);
			
			uint nextThreadIndex = 0;
			const uint8* pDict = &m_dict[m_lookahead_pos & m_max_dict_size_mask];
			uint numUniqueTrigrams = 0;
			
			if (numBytes >= 3){
				uint c0 = pDict[0];
				uint c1 = pDict[1];
				
				const int limit = (cast(int)numBytes - 2);
				for (int i = 0; i < limit; i++){
					uint c2 = pDict[2];
					uint t = hash3_to_16(c0, c1, c2);
					c0 = c1;
					c1 = c2;
					
					pDict++;
					
					if (m_hash_thread_index[t] == ubyte.max){
						numUniqueTrigrams++;
						
						m_hash_thread_index[t] = cast(ubyte)(nextThreadIndex);
						if (++nextThreadIndex == m_max_helper_threads)
							nextThreadIndex = 0;
					}
				}
			}
			
			m_num_completed_helper_threads = 0;
			
			/*if (!m_pTask_pool->queue_multiple_object_tasks(this, &search_accelerator.find_all_matches_callback, 0, m_max_helper_threads))
				return false;*/
			int currentThreads[];
			currentThreads.length = m_max_helper_threads;
			//I might need this in the future
			for(int i; i < currentThreads.length; i++){
				currentThreads[i] = i;
			}
			foreach(threadID; currentThreads.parallel){
				find_all_matches_callback(threadID,null);
			}
		}

		return find_len2_matches();
	}
	bool add_bytes_begin(uint num_bytes, const uint8* pBytes){
		assert(num_bytes <= m_max_dict_size);
		assert(!m_lookahead_size);
		
		uint add_pos = m_lookahead_pos & m_max_dict_size_mask;
		assert((add_pos + num_bytes) <= m_max_dict_size);
		
		memcpy(&m_dict[add_pos], pBytes, num_bytes);
		
		//uint dict_bytes_to_mirror = LZHAM_MIN(cast(uint)(CLZBase.cMaxHugeMatchLen), m_max_dict_size);
		uint dictBytesToMirror = (cast(uint)(CLZBase.cMaxHugeMatchLen) > m_max_dict_size ? m_max_dict_size : cast(uint)(CLZBase.cMaxHugeMatchLen));
		if (add_pos < dictBytesToMirror)
			memcpy(&m_dict[m_max_dict_size], &m_dict[0], dictBytesToMirror);
		
		m_lookahead_size = num_bytes;
		
		uint maxPossibleDictSize = m_max_dict_size - num_bytes;
		//m_cur_dict_size = LZHAM_MIN(m_cur_dict_size, max_possible_dict_size);
		
		m_next_match_ref = 0;
		
		return find_all_matches(num_bytes);
	}
	@nogc uint get_num_completed_helper_threads() const { 
		return m_num_completed_helper_threads; 
	}

	void add_bytes_end(){
		/*if (m_pTask_pool)
		{
			m_pTask_pool->join();
		}*/
		
		assert(cast(uint)m_next_match_ref <= m_matches.length);
	}
	
	// Returns the lookahead's raw position/size/dict_size at the time add_bytes_begin() is called.
	@nogc uint get_fill_lookahead_pos() const { 
		return m_fill_lookahead_pos; 
	}
	@nogc uint get_fill_lookahead_size() const { 
		return m_fill_lookahead_size; 
	}
	@nogc uint get_fill_dict_size() const { 
		return m_fill_dict_size; 
	}
	
	uint get_len2_match(uint lookahead_ofs){
		if ((m_fill_lookahead_size - lookahead_ofs) < 2)
			return 0;
		
		uint cur_pos = m_lookahead_pos + lookahead_ofs;
		
		uint next_match_pos = m_digram_next[cur_pos - m_fill_lookahead_pos];
		
		uint match_dist = cur_pos - next_match_pos;
		
		if ((!match_dist) || (match_dist > CLZBase.cMaxLen2MatchDist) || (match_dist > (m_cur_dict_size + lookahead_ofs)))
			return 0;
		
		const uint8* pCur = &m_dict[cur_pos & m_max_dict_size_mask];
		const uint8* pMatch = &m_dict[next_match_pos & m_max_dict_size_mask];
		
		if ((pCur[0] == pMatch[0]) && (pCur[1] == pMatch[1]))
			return match_dist;
		
		return 0;
	}



	DictMatch* find_matches(uint lookahead_ofs, bool spin = true){
		assert(lookahead_ofs < m_lookahead_size);
		
		const uint match_ref_ofs = cast(uint)(m_lookahead_pos - m_fill_lookahead_pos + lookahead_ofs);
		
		int match_ref;
		uint spin_count = 0;
		
		// This may spin until the match finder job(s) catch up to the caller's lookahead position.
		for ( ; ; )
		{
			match_ref = cast(int)(m_match_refs[match_ref_ofs]);
			if (match_ref == -2)
				return NULL;
			else if (match_ref != -1)
				break;
			
			spin_count++;
			const uint cMaxSpinCount = 1000;
			if ((spin) && (spin_count < cMaxSpinCount)){
				/*lzham_yield_processor();
				lzham_yield_processor();
				lzham_yield_processor();
				lzham_yield_processor();
				lzham_yield_processor();
				lzham_yield_processor();
				lzham_yield_processor();
				lzham_yield_processor();*/
				
				//LZHAM_MEMORY_IMPORT_BARRIER
			}else{
				spin_count = cMaxSpinCount;

				//lzham_sleep(1);
			}
		}
		
		//LZHAM_MEMORY_IMPORT_BARRIER
			
		return &m_matches[match_ref];
	}
	
	void advance_bytes(uint numBytes){
		assert(numBytes <= m_lookahead_size);
		
		m_lookahead_pos += numBytes;
		m_lookahead_size -= numBytes;
		
		m_cur_dict_size += numBytes;
		assert(m_cur_dict_size <= m_max_dict_size);

	}

	public const @nogc uint get_match_len(uint lookahead_ofs, int dist, uint max_match_len, uint start_match_len = 0){
		assert(lookahead_ofs < m_lookahead_size);
		assert(start_match_len <= max_match_len);
		assert(max_match_len <= (get_lookahead_size() - lookahead_ofs));
		
		const int find_dict_size = m_cur_dict_size + lookahead_ofs;
		if (dist > find_dict_size)
			return 0;

		const uint compPos = static_cast<uint>((m_lookahead_pos + lookahead_ofs - dist) & m_max_dict_size_mask);
		const uint lookaheadPos = (m_lookahead_pos + lookahead_ofs) & m_max_dict_size_mask;
		
		const uint8* pComp = &m_dict[compPos];
		const uint8* pLookahead = &m_dict[lookaheadPos];
		
		uint matchLen;
		for (matchLen = start_match_len; matchLen < max_match_len; matchLen++)
			if (pComp[matchLen] != pLookahead[matchLen])
				break;
		
		return matchLen;
	}
}

static @nogc uint hash2_to_12(uint c0, uint c1)
{
	return c0 ^ (c1 << 4);
}

static @nogc uint hash3_to_16(uint c0, uint c1, uint c2)
{
	return (c0 | (c1 << 8)) ^ (c2 << 4);
}