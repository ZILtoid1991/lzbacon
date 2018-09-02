module lzbacon.compInternal;

import lzbacon.symbolCodec;
import lzbacon.matchAccel;
import lzbacon.base;
import lzbacon.common;
import lzbacon.system;
import lzbacon.checksum;

import core.stdc.string;
import core.stdc.stdlib;

const uint cMaxParseGraphNodes = 3072;
const uint cMaxParseThreads = 8;

enum cCompressionLevelCount = 5;

static uint getHugeMatchCodeLen(uint len){
	assert((len > CLZBase.cMaxMatchLen) && (len <= CLZBase.cMaxHugeMatchLen));
	len -= (CLZBase.cMaxMatchLen + 1);
	
	if (len < 256)
		return 1 + 8;
	else if (len < (256 + 1024))
		return 2 + 10;
	else if (len < (256 + 1024 + 4096))
		return 3 + 12;
	else
		return 3 + 16;
}
static uint getHugeMatchCodeBits(uint len){
	assert((len > CLZBase.cMaxMatchLen) && (len <= CLZBase.cMaxHugeMatchLen));
	len -= (CLZBase.cMaxMatchLen + 1);
	
	uint c;
	if (len < 256)
		c = len;
	else if (len < (256 + 1024)){
		uint r = (len - 256);
		assert(r <= 1023);
		c = r | (2 << 10);
	}else if (len < (256 + 1024 + 4096)){
		uint r = (len - (256 + 1024));
		assert(r <= 4095);
		c = r | (6 << 12);
	}else{
		uint r = (len - (256 + 1024 + 4096));
		assert(r <= 65535);
		c = r | (7 << 16);
	}
	
	return c;
}


struct CompSettings{
	uint m_fast_bytes;
	bool m_fast_adaptive_huffman_updating;
	uint m_match_accel_max_matches_per_probe;
	uint m_match_accel_max_probes;
	
	this(uint fastBytes, bool fastAdaptiveHuffmanUpdating, uint matchAccelMaxMatchesPerProbe, uint matchAccelMaxProbes){
		this.m_fast_bytes = fastBytes;
		this.m_fast_adaptive_huffman_updating = fastAdaptiveHuffmanUpdating;
		this.m_match_accel_max_matches_per_probe = matchAccelMaxMatchesPerProbe;
		this.m_match_accel_max_probes = matchAccelMaxProbes;
	}
}

static const CompSettings sLevelSetting[] = [
	CompSettings(8,true,2,1),
	CompSettings(24,true,6,12),
	CompSettings(32,false,uint.max,16),
	CompSettings(48,false,uint.max,32),
	CompSettings(64,false,uint.max,cMatchAccelMaxSupportedProbes),
];

public class LZCompressor : CLZBase{
	private enum{
		cLitComplexity = 1,
		cRep0Complexity = 2,
		cRep3Complexity = 5,
		
		cLongMatchComplexity = 6,
		cLongMatchComplexityLenThresh = 9,
		
		cShortMatchComplexity = 7
	}
	public struct InitParams{
		enum{
			cMinDictSizeLog2 = CLZBase.cMinDictSizeLog2,
			cMaxDictSizeLog2 = CLZBase.cMaxDictSizeLog2,
			cDefaultBlockSize = 1024U*512U
		}
		
		/*init_params() :
		 m_pTask_pool(NULL),
		 m_max_helper_threads(0),
		 m_compression_level(cCompressionLevelDefault),
		 m_dict_size_log2(22),
		 m_block_size(cDefaultBlockSize),
		 m_lzham_compress_flags(0),
		 m_pSeed_bytes(0),
		 m_num_seed_bytes(0),
		 m_table_max_update_interval(0),
		 m_table_update_interval_slow_rate(0)
		 {
		 }*/
		
		//task_pool* m_pTask_pool;
		uint m_max_helper_threads;
		
		LZHAMCompressLevel m_compression_level = LZHAMCompressLevel.DEFAULT;
		uint m_dict_size_log2 = 22;
		
		uint m_block_size = cDefaultBlockSize;
		
		uint m_lzham_compress_flags;
		
		void *m_pSeed_bytes;
		uint m_num_seed_bytes;
		
		uint m_table_max_update_interval;
		uint m_table_update_interval_slow_rate;
		/*this(){
		 m_compression_level = LZHAMCompressLevel.DEFAULT;
		 m_dict_size_log2 = 22;
		 m_block_size = cDefaultBlockSize;
		 }*/
		void init(){
			m_compression_level = LZHAMCompressLevel.DEFAULT;
			m_dict_size_log2 = 22;
			m_block_size = cDefaultBlockSize;
		}
	}
	private class LZDecision{
		int pos;  // dict position where decision was evaluated
		int len;  // 0 if literal, 1+ if match
		int dist; // <0 if match rep, else >=1 is match dist
		
		@nogc this() { }
		@nogc this(int pos, int len, int dist){ 
			this.pos = pos; 
			this.len = len; 
			this.dist = dist; 
		}
		
		@nogc void init(int pos, int len, int dist) { 
			this.pos = pos; 
			this.len = len; 
			this.dist = dist; 
		}
		
		@nogc bool isLit() const { 
			return !len; 
		}
		@nogc bool isMatch() const { 
			return len > 0; 
		} // may be a rep or full match
		@nogc bool isFullMatch() const { 
			return (len > 0) && (dist >= 1); 
		}
		@nogc uint getLen() const { 
			//return math::maximum<uint>(m_len, 1); 
			return len > 1 ? len : 1;
		}
		@nogc bool isRep() const { 
			return dist < 0; 
		}
		@nogc bool isRep0() const { 
			return dist == -1; 
		}
		
		uint get_match_dist(const State cur_state) const{
			if (!isMatch())
				return 0;
			else if (isRep()){
				int index = -1 * dist - 1;
				assert(index < CLZBase.cMatchHistSize);
				return cur_state.m_match_hist[index];
			}else
				return dist;
		}
		
		@nogc uint getComplexity() const{
			if (isLit())
				return cLitComplexity;
			else if (isRep())
			{
				assert(cRep0Complexity == 2);
				return 1 + -dist;  // 2, 3, 4, or 5
			}
			else if (getLen() >= cLongMatchComplexityLenThresh)
				return cLongMatchComplexity;
			else
				return cShortMatchComplexity;
		}
		
		@nogc uint get_min_codable_len() const{
			if (isLit() || isRep0())
				return 1;
			else
				return CLZBase.cMinMatchLen;
		}
	}
	class LZPricedDecision : LZDecision{
		ulong cost;
		@nogc this() { 
			super();
		}
		@nogc this(int pos, int len, int dist){ 
			super(pos, len, dist);
		}
		@nogc this(int pos, int len, int dist, int cost){
			super(pos, len, dist);
			this.cost = cost;
		}
		
		//inline lzpriced_decision(int pos, int len, int dist) : lzdecision(pos, len, dist) { }
		//inline lzpriced_decision(int pos, int len, int dist, bit_cost_t cost) : lzdecision(pos, len, dist), m_cost(cost) { }
		
		@nogc void init(int pos, int len, int dist, ulong cost) { super.init(pos, len, dist); this.cost = cost; }
		
		@nogc ulong getCost() const { 
			return cost; 
		}
		
		//bit_cost_t m_cost;
	}
	private abstract class StateBase{
		uint m_cur_ofs;
		uint m_cur_state;
		uint m_match_hist[CLZBase.cMatchHistSize];
		
		bool opEquals (const StateBase rhs) const{
			if (m_cur_state != rhs.m_cur_state)
				return false;
			for (uint i = 0; i < CLZBase.cMatchHistSize; i++)
				if (m_match_hist[i] != rhs.m_match_hist[i])
					return false;
			return true;
		}
		
		void partial_advance(LZDecision lzdec){
			if (lzdec.len == 0){
				if (m_cur_state < 4) m_cur_state = 0; else if (m_cur_state < 10) m_cur_state -= 3; else m_cur_state -= 6;
			}else{
				if (lzdec.dist < 0){
					const int match_hist_index = -lzdec.dist - 1;
					
					if (!match_hist_index){
						if (lzdec.len == 1){
							m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 9 : 11;
						}else{
							m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 8 : 11;
						}
					}else{
						if (match_hist_index == 1){
							swap(m_match_hist[0], m_match_hist[1]);
						}else if (match_hist_index == 2){
							const int dist = m_match_hist[2];
							m_match_hist[2] = m_match_hist[1];
							m_match_hist[1] = m_match_hist[0];
							m_match_hist[0] = dist;
						}else{
							assert(match_hist_index == 3);
							
							const int dist = m_match_hist[3];
							m_match_hist[3] = m_match_hist[2];
							m_match_hist[2] = m_match_hist[1];
							m_match_hist[1] = m_match_hist[0];
							m_match_hist[0] = dist;
						}
						
						m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 8 : 11;
					}
				}
				else
				{
					// full
					assert(CLZBase.cMatchHistSize == 4);
					m_match_hist[3] = m_match_hist[2];
					m_match_hist[2] = m_match_hist[1];
					m_match_hist[1] = m_match_hist[0];
					m_match_hist[0] = lzdec.dist;
					
					m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? CLZBase.cNumLitStates : CLZBase.cNumLitStates + 3;
				}
			}
			
			m_cur_ofs = lzdec.pos + lzdec.getLen();
		}
		
		void save_partial_state(StateBase dst){
			dst.m_cur_ofs = m_cur_ofs;
			dst.m_cur_state = m_cur_state;
			memcpy(dst.m_match_hist.ptr, m_match_hist.ptr, m_match_hist.sizeof);
		}
		
		void restore_partial_state(const StateBase src){
			m_cur_ofs = src.m_cur_ofs;
			m_cur_state = src.m_cur_state;
			memcpy(m_match_hist.ptr, src.m_match_hist.ptr, m_match_hist.sizeof);
		}
	}
	private class State : StateBase{
		uint m_block_start_dict_ofs;
		
		AdaptiveBitModel[CLZBase.cNumStates] m_is_match_model;
		
		AdaptiveBitModel[CLZBase.cNumStates] m_is_rep_model;
		AdaptiveBitModel[CLZBase.cNumStates] m_is_rep0_model;
		AdaptiveBitModel[CLZBase.cNumStates] m_is_rep0_single_byte_model;
		AdaptiveBitModel[CLZBase.cNumStates] m_is_rep1_model;
		AdaptiveBitModel[CLZBase.cNumStates] m_is_rep2_model;
		
		QuasiAdaptiveHuffmanDataModel m_lit_table;
		QuasiAdaptiveHuffmanDataModel m_delta_lit_table;
		
		QuasiAdaptiveHuffmanDataModel m_main_table;
		QuasiAdaptiveHuffmanDataModel m_rep_len_table[2];
		QuasiAdaptiveHuffmanDataModel m_large_len_table[2];
		QuasiAdaptiveHuffmanDataModel m_dist_lsb_table;
		
		this(){
			m_match_hist[0] = 1;
			m_match_hist[1] = 1;
			m_match_hist[2] = 1;
			m_match_hist[3] = 1;
		}
		void clear(){
			m_cur_ofs = 0;
			m_cur_state = 0;
			m_block_start_dict_ofs = 0;
			
			for (uint i = 0; i < 2; i++)
			{
				m_rep_len_table[i].clear();
				m_large_len_table[i].clear();
			}
			m_main_table.clear();
			m_dist_lsb_table.clear();
			
			m_lit_table.clear();
			m_delta_lit_table.clear();
			
			m_match_hist[0] = 1;
			m_match_hist[1] = 1;
			m_match_hist[2] = 1;
			m_match_hist[3] = 1;
		}
		bool init(CLZBase lzbase, uint tableMaxUpdateInterval, uint tableUpdateIntervalSlowRate){
			m_cur_ofs = 0;
			m_cur_state = 0;
			
			if (!m_rep_len_table[0].init2(true, CLZBase.cNumHugeMatchCodes + (CLZBase.cMaxMatchLen - CLZBase.cMinMatchLen + 1), tableMaxUpdateInterval, tableUpdateIntervalSlowRate, null))
				return false;
			if (!m_rep_len_table[1].assign(m_rep_len_table[0])) 
				return false;
			
			if (!m_large_len_table[0].init2(true, CLZBase.cNumHugeMatchCodes + CLZBase.cLZXNumSecondaryLengths, tableMaxUpdateInterval, tableUpdateIntervalSlowRate, null))
				return false;
			if (!m_large_len_table[1].assign(m_large_len_table[0])) 
				return false;
			
			if (!m_main_table.init2(true, CLZBase.cLZXNumSpecialLengths + (lzbase.mNumLZXSlots - CLZBase.cLZXLowestUsableMatchSlot) * 8, tableMaxUpdateInterval, tableUpdateIntervalSlowRate, null))
				return false;
			if (!m_dist_lsb_table.init2(true, 16, tableMaxUpdateInterval, tableUpdateIntervalSlowRate, null))
				return false;
			
			if (!m_lit_table.init2(true, 256, tableMaxUpdateInterval, tableUpdateIntervalSlowRate, null))
				return false;
			
			if (!m_delta_lit_table.init2(true, 256, tableMaxUpdateInterval, tableUpdateIntervalSlowRate, null))
				return false;
			
			m_match_hist[0] = 1;
			m_match_hist[1] = 1;
			m_match_hist[2] = 1;
			m_match_hist[3] = 1;
			
			return true;
		}
		void reset(){
			m_cur_ofs = 0;
			m_cur_state = 0;
			m_block_start_dict_ofs = 0;
			
			for (uint i = 0; i < m_is_match_model.length; i++) 
				m_is_match_model[i].clear();
			for (uint i = 0; i < m_is_rep_model.length; i++) 
				m_is_rep_model[i].clear();
			for (uint i = 0; i < m_is_rep0_model.length; i++) 
				m_is_rep0_model[i].clear();
			for (uint i = 0; i < m_is_rep0_single_byte_model.length; i++) 
				m_is_rep0_single_byte_model[i].clear();
			for (uint i = 0; i < m_is_rep1_model.length; i++) 
				m_is_rep1_model[i].clear();
			for (uint i = 0; i < m_is_rep2_model.length; i++) 
				m_is_rep2_model[i].clear();
			
			for (uint i = 0; i < 2; i++)
			{
				m_rep_len_table[i].reset();
				m_large_len_table[i].reset();
			}
			m_main_table.reset();
			m_dist_lsb_table.reset();
			
			m_lit_table.reset();
			m_delta_lit_table.reset();
			
			m_match_hist[0] = 1;
			m_match_hist[1] = 1;
			m_match_hist[2] = 1;
			m_match_hist[3] = 1;
		}
		ulong get_cost(CLZBase lzbase, SearchAccelerator dict, LZDecision lzdec) const{
			uint isMatchModelIndex = m_cur_state;
			assert(isMatchModelIndex < m_is_match_model.length);
			ulong cost = m_is_match_model[isMatchModelIndex].getCost(lzdec.isMatch());
			
			if (!lzdec.isMatch()){
				uint lit = dict[lzdec.pos];
				
				if (m_cur_state < CLZBase.cNumLitStates){
					// literal
					cost += m_lit_table.getCost(lit);
				}else{
					// delta literal
					uint repLit0 = dict[(lzdec.pos - m_match_hist[0]) & dict.m_max_dict_size_mask];
					
					uint deltaLit = repLit0 ^ lit;
					
					cost += m_delta_lit_table.getCost(deltaLit);
				}
			}else{
				// match
				if (lzdec.dist < 0){
					// rep match
					cost += m_is_rep_model[m_cur_state].getCost(1);
					
					int matchHistIndex = -1 * lzdec.dist - 1;
					
					if (!matchHistIndex){
						// rep0 match
						cost += m_is_rep0_model[m_cur_state].getCost(1);
						
						if (lzdec.len == 1){
							// single byte rep0
							cost += m_is_rep0_single_byte_model[m_cur_state].getCost(1);
						}else{
							// normal rep0
							cost += m_is_rep0_single_byte_model[m_cur_state].getCost(0);
							
							if (lzdec.len > CLZBase.cMaxMatchLen){
								cost += getHugeMatchCodeLen(lzdec.len) + m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates].getCost((CLZBase.cMaxMatchLen + 1) - CLZBase.cMinMatchLen);
							}else{
								cost += m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates].getCost(lzdec.len - CLZBase.cMinMatchLen);
							}
						}
					}else{
						if (lzdec.len > CLZBase.cMaxMatchLen)	{
							cost += getHugeMatchCodeLen(lzdec.len) + m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates].getCost((CLZBase.cMaxMatchLen + 1) - CLZBase.cMinMatchLen);
						}else{
							cost += m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates].getCost(lzdec.len - CLZBase.cMinMatchLen);
						}
						
						// rep1-rep3 match
						cost += m_is_rep0_model[m_cur_state].getCost(0);
						
						if (matchHistIndex == 1){
							// rep1
							cost += m_is_rep1_model[m_cur_state].getCost(1);
						}else{
							cost += m_is_rep1_model[m_cur_state].getCost(0);
							
							if (matchHistIndex == 2){
								// rep2
								cost += m_is_rep2_model[m_cur_state].getCost(1);
							}else{
								assert(matchHistIndex == 3);
								// rep3
								cost += m_is_rep2_model[m_cur_state].getCost(0);
							}
						}
					}
				}else{
					cost += m_is_rep_model[m_cur_state].getCost(0);
					
					assert(lzdec.len >= CLZBase.cMinMatchLen);
					
					// full match
					uint matchSlot, matchExtra;
					lzbase.computeLZXPositionSlot(lzdec.dist, matchSlot, matchExtra);
					
					uint matchLowSym = 0;
					if (lzdec.len >= 9){
						matchLowSym = 7;
						if (lzdec.len > CLZBase.cMaxMatchLen){
							cost += getHugeMatchCodeLen(lzdec.len) + m_large_len_table[m_cur_state >= CLZBase.cNumLitStates].getCost((CLZBase.cMaxMatchLen + 1) - 9);
						}else{
							cost += m_large_len_table[m_cur_state >= CLZBase.cNumLitStates].getCost(lzdec.len - 9);
						}
					}else
						matchLowSym = lzdec.len - 2;
					
					uint matchHighSym = 0;
					
					assert(matchSlot >= CLZBase.cLZXLowestUsableMatchSlot && (matchSlot < lzbase.mNumLZXSlots));
					matchHighSym = matchSlot - CLZBase.cLZXLowestUsableMatchSlot;
					
					uint main_sym = matchLowSym | (matchHighSym << 3);
					
					cost += m_main_table.getCost(CLZBase.cLZXNumSpecialLengths + main_sym);
					
					uint numExtraBits = lzbase.mLZXPositionExtraBits[matchSlot];
					if (numExtraBits < 3)
						cost += convertToScaledBitcost(numExtraBits);
					else
					{
						if (numExtraBits > 4)
							cost += convertToScaledBitcost(numExtraBits - 4);
						
						cost += m_dist_lsb_table.getCost(matchExtra & 15);
					}
				}
			}
			
			return cost;
		}
		ulong get_len2_match_cost(CLZBase lzbase, uint dictPos, uint len2MatchDist, uint isMatchModelIndex){
			ulong cost = m_is_match_model[isMatchModelIndex].getCost(1);
			
			cost += m_is_rep_model[m_cur_state].getCost(0);
			
			// full match
			uint matchSlot, matchExtra;
			lzbase.computeLZXPositionSlot(len2MatchDist, matchSlot, matchExtra);
			
			const uint matchLen = 2;
			uint matchLowSym = matchLen - 2;
			
			uint matchHighSym = 0;
			
			assert(matchSlot >= CLZBase.cLZXLowestUsableMatchSlot && (matchSlot < lzbase.mNumLZXSlots));
			matchHighSym = matchSlot - CLZBase.cLZXLowestUsableMatchSlot;
			
			uint mainSym = matchLowSym | (matchHighSym << 3);
			
			cost += m_main_table.getCost(CLZBase.cLZXNumSpecialLengths + mainSym);
			
			uint numExtraBits = lzbase.mLZXPositionExtraBits[matchSlot];
			if (numExtraBits < 3)
				cost += convertToScaledBitcost(numExtraBits);
			else{
				if (numExtraBits > 4)
					cost += convertToScaledBitcost(numExtraBits - 4);
				
				cost += m_dist_lsb_table.getCost(matchExtra & 15);
			}
			
			return cost;
		}
		ulong get_lit_cost(CLZBase lzbase, const SearchAccelerator dict, uint dictPos, uint litPred0, uint isMatchModelIndex) const{
			ulong cost = m_is_match_model[isMatchModelIndex].getCost(0);
			
			uint lit = dict[dictPos];
			
			if (m_cur_state < CLZBase.cNumLitStates){
				// literal
				cost += m_lit_table.getCost(lit);
			}else{
				// delta literal
				const uint repLit0 = dict[(dictPos - m_match_hist[0]) & dict.m_max_dict_size_mask];
				
				uint deltaLit = repLit0 ^ lit;
				
				cost += m_delta_lit_table.getCost(deltaLit);
			}
			
			return cost;
		}
		// Returns actual cost.
		void get_rep_match_costs(uint dict_pos, ulong *pBitcosts, uint matchHistIndex, int minLen, int maxLen, uint isMatchModelIndex) const{
			// match
			
			const QuasiAdaptiveHuffmanDataModel repLenTable = m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates];
			
			ulong baseCost = m_is_match_model[isMatchModelIndex].getCost(1);
			
			baseCost += m_is_rep_model[m_cur_state].getCost(1);
			
			if (!matchHistIndex){
				// rep0 match
				baseCost += m_is_rep0_model[m_cur_state].getCost(1);
			}else{
				// rep1-rep3 matches
				baseCost += m_is_rep0_model[m_cur_state].getCost(0);
				
				if (matchHistIndex == 1){
					// rep1
					baseCost += m_is_rep1_model[m_cur_state].getCost(1);
				}else{
					baseCost += m_is_rep1_model[m_cur_state].getCost(0);
					
					if (matchHistIndex == 2){
						// rep2
						baseCost += m_is_rep2_model[m_cur_state].getCost(1);
					}else{
						// rep3
						baseCost += m_is_rep2_model[m_cur_state].getCost(0);
					}
				}
			}
			
			// rep match
			if (!matchHistIndex){
				if (minLen == 1){
					// single byte rep0
					pBitcosts[1] = baseCost + m_is_rep0_single_byte_model[m_cur_state].getCost(1);
					minLen++;
				}
				
				ulong rep0MatchBaseCost = baseCost + m_is_rep0_single_byte_model[m_cur_state].getCost(0);
				for (int matchLen = minLen; matchLen <= maxLen; matchLen++){
					// normal rep0
					if (matchLen > CLZBase.cMaxMatchLen){
						pBitcosts[matchLen] = getHugeMatchCodeLen(matchLen) + rep0MatchBaseCost + repLenTable.getCost((CLZBase.cMaxMatchLen + 1) - CLZBase.cMinMatchLen);
					}else{
						pBitcosts[matchLen] = rep0MatchBaseCost + repLenTable.getCost(matchLen - CLZBase.cMinMatchLen);
					}
				}
			}else{
				for (int matchLen = minLen; matchLen <= maxLen; matchLen++){
					if (matchLen > CLZBase.cMaxMatchLen){
						pBitcosts[matchLen] = getHugeMatchCodeLen(matchLen) + baseCost + repLenTable.getCost((CLZBase.cMaxMatchLen + 1) - CLZBase.cMinMatchLen);
					}else{
						pBitcosts[matchLen] = baseCost + repLenTable.getCost(matchLen - CLZBase.cMinMatchLen);
					}
				}
			}
		}
		void get_full_match_costs(CLZBase lzbase, uint dictPos, ulong *pBitcosts, uint matchDist, int minLen, int maxLen, uint isMatchModelIndex) const{
			ulong cost = m_is_match_model[isMatchModelIndex].getCost(1);
			
			cost += m_is_rep_model[m_cur_state].getCost(0);
			
			uint matchSlot, matchExtra;
			lzbase.computeLZXPositionSlot(matchDist, matchSlot, matchExtra);
			assert(matchSlot >= CLZBase.cLZXLowestUsableMatchSlot && (matchSlot < lzbase.mNumLZXSlots));
			
			uint numExtraBits = lzbase.mLZXPositionExtraBits[matchSlot];
			
			if (numExtraBits < 3)
				cost += convertToScaledBitcost(numExtraBits);
			else{
				if (numExtraBits > 4)
					cost += convertToScaledBitcost(numExtraBits - 4);
				
				cost += m_dist_lsb_table.getCost(matchExtra & 15);
			}
			
			uint matchHighSym = matchSlot - CLZBase.cLZXLowestUsableMatchSlot;
			
			const QuasiAdaptiveHuffmanDataModel largeLenTable = m_large_len_table[m_cur_state >= CLZBase.cNumLitStates];
			
			for (int matchLen = minLen; matchLen <= maxLen; matchLen++){
				ulong lenCost = cost;
				
				uint matchLowSym = 0;
				if (matchLen >= 9){
					matchLowSym = 7;
					if (matchLen > CLZBase.cMaxMatchLen){
						lenCost += getHugeMatchCodeLen(matchLen) + largeLenTable.getCost((CLZBase.cMaxMatchLen + 1) - 9);
					}else{
						lenCost += largeLenTable.getCost(matchLen - 9);
					}
				}else
					matchLowSym = matchLen - 2;
				
				uint mainSym = matchLowSym | (matchHighSym << 3);
				
				pBitcosts[matchLen] = lenCost + m_main_table.getCost(CLZBase.cLZXNumSpecialLengths + mainSym);
			}
		}
		/**
		 * Couldn't find the implementation of this function, so I left it blank with a single return value.
		 */
		ulong update_stats(CLZBase lzbase, const SearchAccelerator dict, const LZDecision lzdec){
			return 0;	
		}
		
		bool advance(CLZBase lzbase, const SearchAccelerator dict, const LZDecision lzdec){
			uint isMatchModelIndex = m_cur_state;
			m_is_match_model[isMatchModelIndex].update(lzdec.isMatch());
			
			if (!lzdec.isMatch()){
				const uint lit = dict[lzdec.pos];
				
				if (m_cur_state < CLZBase.cNumLitStates){
					// literal
					if (!m_lit_table.updateSym(lit)) return false;
				}else{
					// delta literal
					const uint repLit0 = dict[(lzdec.pos - m_match_hist[0]) & dict.m_max_dict_size_mask];
					
					uint deltaLit = repLit0 ^ lit;
					
					if (!m_delta_lit_table.updateSym(deltaLit)) return false;
				}
				
				if (m_cur_state < 4) m_cur_state = 0; else if (m_cur_state < 10) m_cur_state -= 3; else m_cur_state -= 6;
			}else{
				// match
				if (lzdec.dist < 0){
					// rep match
					m_is_rep_model[m_cur_state].update(1);
					
					int matchHistIndex = -lzdec.dist - 1;
					
					if (!matchHistIndex){
						// rep0 match
						m_is_rep0_model[m_cur_state].update(1);
						
						if (lzdec.len == 1){
							// single byte rep0
							m_is_rep0_single_byte_model[m_cur_state].update(1);
							
							m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 9 : 11;
						}else{
							// normal rep0
							m_is_rep0_single_byte_model[m_cur_state].update(0);
							
							if (lzdec.len > CLZBase.cMaxMatchLen){
								if (!m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates].updateSym((CLZBase.cMaxMatchLen + 1) - CLZBase.cMinMatchLen)) return false;
							}else{
								if (!m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates].updateSym(lzdec.len - CLZBase.cMinMatchLen)) return false;
							}
							
							m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 8 : 11;
						}
					}else{
						// rep1-rep3 match
						m_is_rep0_model[m_cur_state].update(0);
						
						if (lzdec.len > CLZBase.cMaxMatchLen){
							if (!m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates].updateSym((CLZBase.cMaxMatchLen + 1) - CLZBase.cMinMatchLen)) return false;
						}else{
							if (!m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates].updateSym(lzdec.len - CLZBase.cMinMatchLen)) return false;
						}
						
						if (matchHistIndex == 1){
							// rep1
							m_is_rep1_model[m_cur_state].update(1);
							
							swap(m_match_hist[0], m_match_hist[1]);
						}else{
							m_is_rep1_model[m_cur_state].update(0);
							
							if (matchHistIndex == 2){
								// rep2
								m_is_rep2_model[m_cur_state].update(1);
								
								int dist = m_match_hist[2];
								m_match_hist[2] = m_match_hist[1];
								m_match_hist[1] = m_match_hist[0];
								m_match_hist[0] = dist;
							}else{
								// rep3
								m_is_rep2_model[m_cur_state].update(0);
								
								int dist = m_match_hist[3];
								m_match_hist[3] = m_match_hist[2];
								m_match_hist[2] = m_match_hist[1];
								m_match_hist[1] = m_match_hist[0];
								m_match_hist[0] = dist;
							}
						}
						
						m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 8 : 11;
					}
				}else{
					m_is_rep_model[m_cur_state].update(0);
					
					assert(lzdec.len >= CLZBase.cMinMatchLen);
					
					// full match
					uint matchSlot, matchExtra;
					lzbase.computeLZXPositionSlot(lzdec.dist, matchSlot, matchExtra);
					
					uint matchLowSym = 0;
					int largeLenSym = -1;
					if (lzdec.len >= 9){
						matchLowSym = 7;
						
						largeLenSym = lzdec.len - 9;
					}else
						matchLowSym = lzdec.len - 2;
					
					uint matchHighSym = 0;
					
					assert(matchSlot >= CLZBase.cLZXLowestUsableMatchSlot && (matchSlot < lzbase.mNumLZXSlots));
					matchHighSym = matchSlot - CLZBase.cLZXLowestUsableMatchSlot;
					
					uint mainSym = matchLowSym | (matchHighSym << 3);
					
					if (!m_main_table.updateSym(CLZBase.cLZXNumSpecialLengths + mainSym)) return false;
					
					if (largeLenSym >= 0)
					{
						if (lzdec.len > CLZBase.cMaxMatchLen){
							if (!m_large_len_table[m_cur_state >= CLZBase.cNumLitStates].updateSym((CLZBase.cMaxMatchLen + 1) - 9)) return false;
						}else{
							if (!m_large_len_table[m_cur_state >= CLZBase.cNumLitStates].updateSym(largeLenSym)) return false;
						}
					}
					
					uint numExtraBits = lzbase.mLZXPositionExtraBits[matchSlot];
					if (numExtraBits >= 3){
						if (!m_dist_lsb_table.updateSym(matchExtra & 15)) return false;
					}
					
					update_match_hist(lzdec.dist);
					
					m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? CLZBase.cNumLitStates : CLZBase.cNumLitStates + 3;
				}
			}
			
			m_cur_ofs = lzdec.pos + lzdec.getLen();
			return true;
		}
		bool encode(SymbolCodec codec, CLZBase lzbase, const SearchAccelerator dict, const LZDecision lzdec){
			uint isMatchModelIndex = (m_cur_state);
			if (!codec.encode(lzdec.isMatch(), m_is_match_model[isMatchModelIndex])) return false;
			
			if (!lzdec.isMatch()){
				const uint lit = dict[lzdec.pos];
				
				/*#ifdef LZHAM_LZDEBUG
				 if (!codec.encode_bits(lit, 8)) return false;
				 #endif*/
				
				if (m_cur_state < CLZBase.cNumLitStates){
					// literal
					if (!codec.encode(lit, m_lit_table)) return false;
				}else{
					// delta literal
					const uint repLit0 = dict[(lzdec.pos - m_match_hist[0]) & dict.m_max_dict_size_mask];
					
					uint deltaLit = repLit0 ^ lit;
					
					/*#ifdef LZHAM_LZDEBUG
					 if (!codec.encode_bits(rep_lit0, 8)) return false;
					 #endif*/
					
					if (!codec.encode(deltaLit, m_delta_lit_table)) return false;
				}
				
				if (m_cur_state < 4) m_cur_state = 0; else if (m_cur_state < 10) m_cur_state -= 3; else m_cur_state -= 6;
			}else{
				// match
				if (lzdec.dist < 0){
					// rep match
					if (!codec.encode(1, m_is_rep_model[m_cur_state])) return false;
					
					int matchHistIndex = -1 * lzdec.dist - 1;
					
					if (!matchHistIndex){
						// rep0 match
						if (!codec.encode(1, m_is_rep0_model[m_cur_state])) return false;
						
						if (lzdec.len == 1){
							// single byte rep0
							if (!codec.encode(1, m_is_rep0_single_byte_model[m_cur_state])) return false;
							
							m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 9 : 11;
						}else{
							// normal rep0
							if (!codec.encode(0, m_is_rep0_single_byte_model[m_cur_state])) return false;
							
							if (lzdec.len > CLZBase.cMaxMatchLen){
								if (!codec.encode((CLZBase.cMaxMatchLen + 1) - CLZBase.cMinMatchLen, m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates])) return false;
								if (!codec.encodeBits(getHugeMatchCodeBits(lzdec.len), getHugeMatchCodeLen(lzdec.len))) return false;
							}else{
								if (!codec.encode(lzdec.len - CLZBase.cMinMatchLen, m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates])) return false;
							}
							
							m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 8 : 11;
						}
					}else{
						// rep1-rep3 match
						if (!codec.encode(0, m_is_rep0_model[m_cur_state])) return false;
						
						if (lzdec.len > CLZBase.cMaxMatchLen){
							if (!codec.encode((CLZBase.cMaxMatchLen + 1) - CLZBase.cMinMatchLen, m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates])) return false;
							if (!codec.encodeBits(getHugeMatchCodeBits(lzdec.len), getHugeMatchCodeLen(lzdec.len))) return false;
						}else{
							if (!codec.encode(lzdec.len - CLZBase.cMinMatchLen, m_rep_len_table[m_cur_state >= CLZBase.cNumLitStates])) return false;
						}
						
						if (matchHistIndex == 1){
							// rep1
							if (!codec.encode(1, m_is_rep1_model[m_cur_state])) return false;
							
							swap(m_match_hist[0], m_match_hist[1]);
						}else{
							if (!codec.encode(0, m_is_rep1_model[m_cur_state])) return false;
							
							if (matchHistIndex == 2){
								// rep2
								if (!codec.encode(1, m_is_rep2_model[m_cur_state])) return false;
								
								int dist = m_match_hist[2];
								m_match_hist[2] = m_match_hist[1];
								m_match_hist[1] = m_match_hist[0];
								m_match_hist[0] = dist;
							}else{
								// rep3
								if (!codec.encode(0, m_is_rep2_model[m_cur_state])) return false;
								
								int dist = m_match_hist[3];
								m_match_hist[3] = m_match_hist[2];
								m_match_hist[2] = m_match_hist[1];
								m_match_hist[1] = m_match_hist[0];
								m_match_hist[0] = dist;
							}
						}
						
						m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? 8 : 11;
					}
				}else{
					if (!codec.encode(0, m_is_rep_model[m_cur_state])) return false;
					
					assert(lzdec.len >= CLZBase.cMinMatchLen);
					
					// full match
					uint matchSlot, matchExtra;
					lzbase.computeLZXPositionSlot(lzdec.dist, matchSlot, matchExtra);
					
					uint matchLowSym = 0;
					int largeLenSym = -1;
					if (lzdec.len >= 9){
						matchLowSym = 7;
						
						largeLenSym = lzdec.len - 9;
					}else
						matchLowSym = lzdec.len - 2;
					
					uint matchHighSym = 0;
					
					assert(matchSlot >= CLZBase.cLZXLowestUsableMatchSlot && (matchSlot < lzbase.mNumLZXSlots));
					matchHighSym = matchSlot - CLZBase.cLZXLowestUsableMatchSlot;
					
					uint mainSym = matchLowSym | (matchHighSym << 3);
					
					if (!codec.encode(CLZBase.cLZXNumSpecialLengths + mainSym, m_main_table)) return false;
					
					if (largeLenSym >= 0){
						if (lzdec.len > CLZBase.cMaxMatchLen){
							if (!codec.encode((CLZBase.cMaxMatchLen + 1) - 9, m_large_len_table[m_cur_state >= CLZBase.cNumLitStates])) return false;
							if (!codec.encodeBits(getHugeMatchCodeBits(lzdec.len), getHugeMatchCodeLen(lzdec.len))) return false;
						}else{
							if (!codec.encode(largeLenSym, m_large_len_table[m_cur_state >= CLZBase.cNumLitStates])) return false;
						}
					}
					
					uint numExtraBits = lzbase.mLZXPositionExtraBits[matchSlot];
					if (numExtraBits < 3){
						if (!codec.encodeBits(matchExtra, numExtraBits)) return false;
					}else{
						if (numExtraBits > 4){
							if (!codec.encodeBits((matchExtra >> 4), numExtraBits - 4)) return false;
						}
						
						if (!codec.encode(matchExtra & 15, m_dist_lsb_table)) return false;
					}
					
					update_match_hist(lzdec.dist);
					
					m_cur_state = (m_cur_state < CLZBase.cNumLitStates) ? CLZBase.cNumLitStates : CLZBase.cNumLitStates + 3;
				}
				
				/*#ifdef LZHAM_LZDEBUG
				 if (!codec.encode_bits(m_match_hist[0], 29)) return false;
				 #endif*/
			}
			
			m_cur_ofs = lzdec.pos + lzdec.getLen();
			return true;
		}
		
		void print(SymbolCodec codec, CLZBase lzbase, SearchAccelerator dict, LZDecision lzdec){
			import core.stdc.stdio;
			const uint litPred0 = get_pred_char(dict, lzdec.pos, 1);
			
			uint isMatchModelIndex = m_cur_state;
			
			debug printf("  pos: %u, state: %u, match_pred: %u, is_match_model_index: %u, is_match: %u, cost: %f\n",
				lzdec.pos,
				m_cur_state,
				litPred0, isMatchModelIndex, lzdec.isMatch(), get_cost(lzbase, dict, lzdec) / cast(float)cBitCostScale);
			
			if (!lzdec.isMatch()){
				const uint lit = dict[lzdec.pos];
				
				if (m_cur_state < CLZBase.cNumLitStates){
					debug printf("---Regular lit: %u '%c'\n",
						lit, ((lit >= 32) && (lit <= 127)) ? lit : '.');
				}else{
					// delta literal
					const uint repLit0 = dict[(lzdec.pos - m_match_hist[0]) & dict.m_max_dict_size_mask];
					
					uint deltaLit = repLit0 ^ lit;
					
					debug printf("***Delta lit: %u '%c', Mismatch: %u '%c', Delta: 0x%02X\n",
						lit, ((lit >= 32) && (lit <= 127)) ? lit : '.',
						repLit0, ((repLit0 >= 32) && (repLit0 <= 127)) ? repLit0 : '.',
						deltaLit);
				}
			}else{
				uint actualMatchLen = dict.get_match_len(0, lzdec.get_match_dist(this), CLZBase.cMaxMatchLen);
				assert(actualMatchLen >= lzdec.getLen());
				
				// match
				if (lzdec.dist < 0){
					int match_hist_index = -lzdec.dist - 1;
					
					if (!match_hist_index){
						if (lzdec.len == 1){
							debug printf("!!!Rep 0 len1\n");
						}
						else{
							debug printf("!!!Rep 0 full len %u\n", lzdec.len);
						}
					}else{
						debug printf("!!!Rep %u full len %u\n", match_hist_index, lzdec.len);
					}
				}else{
					assert(lzdec.len >= CLZBase.cMinMatchLen);
					
					// full match
					uint matchSlot, matchExtra;
					lzbase.computeLZXPositionSlot(lzdec.dist, matchSlot, matchExtra);
					
					uint matchLowSym = 0; //LZHAM_NOTE_UNUSED(match_low_sym);
					int largeLenSym = -1; //LZHAM_NOTE_UNUSED(large_len_sym);
					if (lzdec.len >= 9){
						matchLowSym = 7;
						
						largeLenSym = lzdec.len - 9;
					}else
						matchLowSym = lzdec.len - 2;
					
					uint matchHighSym = 0; //LZHAM_NOTE_UNUSED(match_high_sym);
					
					assert(matchSlot >= CLZBase.cLZXLowestUsableMatchSlot && (matchSlot < lzbase.mNumLZXSlots));
					matchHighSym = matchSlot - CLZBase.cLZXLowestUsableMatchSlot;
					
					//uint main_sym = match_low_sym | (match_high_sym << 3);
					
					uint numExtraBits = lzbase.mLZXPositionExtraBits[matchSlot];
					printf("^^^Full match Len %u Dist %u, Slot %u, ExtraBits: %u", lzdec.len, lzdec.dist, matchSlot, numExtraBits);
					
					if (numExtraBits < 3){
					}else{
						debug printf("  (Low 4 bits: %u vs. %u)", lzdec.dist & 15, matchExtra & 15);
					}
					debug printf("\n");
				}
				
				if (actualMatchLen > lzdec.getLen()){
					printf("  TRUNCATED match, actual len is %u, shortened by %u\n", actualMatchLen, actualMatchLen - lzdec.getLen());
				}
			}
		}
		
		bool encode_eob(SymbolCodec codec, const SearchAccelerator dict, uint dictPos){
			//const uint match_pred = get_pred_char(dict, dict_pos, 1);
			uint isMatchModelIndex = (m_cur_state);
			if (!codec.encode(1, m_is_match_model[isMatchModelIndex])) return false;
			
			// full match
			if (!codec.encode(0, m_is_rep_model[m_cur_state])) return false;
			
			return codec.encode(CLZBase.cLZXSpecialCodeEndOfBlockCode, m_main_table);
		}
		bool encode_reset_state_partial(SymbolCodec codec, const SearchAccelerator dict, uint dict_pos){
			//const uint match_pred = get_pred_char(dict, dict_pos, 1);
			uint isMatchModelIndex = (m_cur_state);
			if (!codec.encode(1, m_is_match_model[isMatchModelIndex])) return false;
			
			// full match
			if (!codec.encode(0, m_is_rep_model[m_cur_state])) return false;
			
			if (!codec.encode(CLZBase.cLZXSpecialCodePartialStateReset, m_main_table))
				return false;
			
			reset_state_partial();
			return true;
		}
		
		@nogc void update_match_hist(uint match_dist){
			assert(CLZBase.cMatchHistSize == 4);
			m_match_hist[3] = m_match_hist[2];
			m_match_hist[2] = m_match_hist[1];
			m_match_hist[1] = m_match_hist[0];
			m_match_hist[0] = match_dist;
		}
		@nogc int find_match_dist(uint matchDist) const{
			for (uint matchHistIndex = 0; matchHistIndex < CLZBase.cMatchHistSize; matchHistIndex++)
				if (matchDist == m_match_hist[matchHistIndex])
					return matchHistIndex;
			
			return -1;
		}
		
		@nogc void reset_state_partial(){
			m_match_hist[0] = 1;
			m_match_hist[1] = 1;
			m_match_hist[2] = 1;
			m_match_hist[3] = 1;
			m_cur_state = 0;
		}
		@nogc void start_of_block(const SearchAccelerator dict, uint curOfs, uint blockIndex){
			reset_state_partial();
			
			m_cur_ofs = curOfs;
			m_block_start_dict_ofs = curOfs;
		}
		
		void reset_update_rate(){
			m_lit_table.resetUpdateRate();
			m_delta_lit_table.resetUpdateRate();
			
			m_main_table.resetUpdateRate();
			
			for (uint i = 0; i < m_rep_len_table.length; i++)
				m_rep_len_table[i].resetUpdateRate();
			
			for (uint i = 0; i < m_large_len_table.length; i++)
				m_large_len_table[i].resetUpdateRate();
			
			m_dist_lsb_table.resetUpdateRate();
		}
		
		uint get_pred_char(SearchAccelerator dict, int pos, int backward_ofs) const{
			assert(pos >= cast(int)m_block_start_dict_ofs);
			int limit = pos - m_block_start_dict_ofs;
			if (backward_ofs > limit)
				return 0;
			return dict[pos - backward_ofs];
		}
		
		@nogc bool will_reference_last_match(const LZDecision lzdec) const{
			return (!lzdec.isMatch()) &&  (m_cur_state >= CLZBase.cNumLitStates);
		}
		
		
	}
	private State m_start_of_block_state;             /// state at start of block
	
	private State m_state;                            /// main thread's current coding state
	private class TrackedStat{
		private ulong m_num;
		private double m_total;
		private double m_total2;
		private double m_min_val;
		private double m_max_val;
		
		this() { 
			clear(); 
		}
		
		@nogc void clear() {
			m_num = 0; 
			m_total = 0.0f; 
			m_total2 = 0.0f; 
			m_min_val = 9e+99; 
			m_max_val = -9e+99; 
		}
		
		void update(double val) { 
			m_num++; m_total += val; 
			m_total2 += val * val; 
			//m_min_val = LZHAM_MIN(m_min_val, val); 
			m_min_val = m_min_val > val ? val : m_min_val;
			//m_max_val = LZHAM_MAX(m_max_val, val); 
			m_max_val = m_max_val > val ? m_max_val : val;
		}
		
		//TrackedStat operator += (double val) { update(val); return *this; }
		//operator double() const { return m_total; }
		
		@nogc @property ulong get_number_of_values() { 
			return m_num; 
		}
		@nogc uint get_number_of_values32() { 
			return cast(uint)(uint.max > m_num ? m_num : uint.max); 
		}
		@nogc @property double get_total() const { 
			return m_total; 
		}
		@nogc double get_average() const { 
			return m_num ? m_total / m_num : 0.0f; 
		}
		@nogc double get_std_dev() const { 
			import core.stdc.math;
			return m_num ? sqrt( m_num * m_total2 - m_total * m_total ) / m_num: 0.0f; 
		}
		@nogc double get_min_val() const { 
			return m_num ? m_min_val : 0.0f; 
		}
		@nogc double get_max_val() const { 
			return m_num ? m_max_val : 0.0f; 
		}
	}
	private struct CodingStats{
		uint m_total_bytes;
		uint m_total_contexts;
		double m_total_cost;
		
		TrackedStat m_context_stats;
		
		double m_total_match_bits_cost;
		double m_worst_match_bits_cost;
		double m_total_is_match0_bits_cost;
		double m_total_is_match1_bits_cost;
		
		uint m_total_truncated_matches;
		uint[CLZBase.cMaxMatchLen + 1] m_match_truncation_len_hist;
		uint[CLZBase.cMaxMatchLen + 1] m_match_truncation_hist;
		uint[CLZBase.cNumStates][5] m_match_type_truncation_hist;
		uint[CLZBase.cNumStates][5] m_match_type_was_not_truncated_hist;
		
		uint m_total_nonmatches;
		uint m_total_matches;
		
		TrackedStat m_lit_stats;
		TrackedStat m_delta_lit_stats;
		
		TrackedStat[CLZBase.cMatchHistSize] m_rep_stats;
		TrackedStat m_rep0_len1_stats;
		TrackedStat m_rep0_len2_plus_stats;
		
		TrackedStat[cMaxMatchLen + 1] m_full_match_stats;
		
		uint m_total_far_len2_matches;
		uint m_total_near_len2_matches;
		
		uint m_total_update_rate_resets;
		
		uint m_max_len2_dist;
		/*this() { 
		 clear(); 
		 }*/
		
		@nogc void clear(){
			m_total_bytes = 0;
			m_total_contexts = 0;
			m_total_match_bits_cost = 0;
			m_worst_match_bits_cost = 0;
			m_total_is_match0_bits_cost = 0;
			m_total_is_match1_bits_cost = 0;
			m_context_stats.clear();
			
			m_total_nonmatches = 0;
			m_total_matches = 0;
			m_total_cost = 0.0f;
			
			m_lit_stats.clear();
			m_delta_lit_stats.clear();
			
			m_rep0_len1_stats.clear();
			for (uint i = 0; i < CLZBase.cMatchHistSize; i++)
				m_rep_stats[i].clear();
			m_rep0_len1_stats.clear();
			m_rep0_len2_plus_stats.clear();
			
			for (uint i = 0; i <= CLZBase.cMaxMatchLen; i++)
				m_full_match_stats[i].clear();
			
			m_total_far_len2_matches = 0;
			m_total_near_len2_matches = 0;
			
			m_total_truncated_matches = 0;
			/*utils::zero_object(m_match_truncation_len_hist);
			 utils::zero_object(m_match_truncation_hist);
			 utils::zero_object(m_match_type_truncation_hist);
			 utils::zero_object(m_match_type_was_not_truncated_hist);*/
			memset(cast(void*)m_match_truncation_len_hist.ptr, 0, m_match_truncation_len_hist.length * uint.sizeof);
			memset(cast(void*)m_match_truncation_hist.ptr, 0, m_match_truncation_hist.length * uint.sizeof);
			memset(cast(void*)m_match_type_truncation_hist.ptr, 0, m_match_type_truncation_hist.length * uint.sizeof);
			memset(cast(void*)m_match_type_was_not_truncated_hist.ptr, 0, m_match_type_was_not_truncated_hist.length * uint.sizeof);
			
			m_total_update_rate_resets = 0;
			
			m_max_len2_dist = 0;
		}
		
		void update(LZDecision lzdec, State curState, SearchAccelerator dict, ulong cost){
			m_total_bytes += lzdec.getLen();
			m_total_contexts++;
			
			float cost_in_bits = cost / cast(float)cBitCostScale;
			assert(cost_in_bits > 0.0f);
			m_total_cost += cost_in_bits;
			
			m_context_stats.update(cost_in_bits);
			
			//uint match_pred = cur_state.get_pred_char(dict, lzdec.m_pos, 1);
			uint isMatchModelIndex = (curState.m_cur_state);
			
			if (lzdec.len == 0){
				float match_bit_cost = curState.m_is_match_model[isMatchModelIndex].getCost(0) / cast(float)cBitCostScale;
				
				m_total_is_match0_bits_cost += match_bit_cost;
				m_total_match_bits_cost += match_bit_cost;
				m_worst_match_bits_cost = maximum(m_worst_match_bits_cost, cast(double)(match_bit_cost));
				m_total_nonmatches++;
				
				if (curState.m_cur_state < CLZBase.cNumLitStates){
					m_lit_stats.update(cost_in_bits);
				}else{
					m_delta_lit_stats.update(cost_in_bits);
				}
			}else if (lzdec.len <= CLZBase.cMaxMatchLen){
				const uint match_len = lzdec.getLen();
				
				{
					uint match_dist = lzdec.get_match_dist(curState);
					
					uint cur_lookahead_size = dict.get_lookahead_size();
					
					uint actual_match_len = dict.get_match_len(0, match_dist, minimum(cur_lookahead_size, cast(uint)(CLZBase.cMaxMatchLen)));
					assert(match_len <= actual_match_len);
					
					m_total_truncated_matches += match_len < actual_match_len;
					m_match_truncation_len_hist[maximum(0, actual_match_len - match_len)]++;
					
					uint type_index = 4;
					if (!lzdec.isFullMatch()){
						assert(CLZBase.cMatchHistSize == 4);
						type_index = -lzdec.dist - 1;
					}
					
					if (actual_match_len > match_len){
						m_match_truncation_hist[match_len]++;
						
						m_match_type_truncation_hist[curState.m_cur_state][type_index]++;
					}else{
						m_match_type_was_not_truncated_hist[curState.m_cur_state][type_index]++;
					}
				}
				
				float matchBitCost = curState.m_is_match_model[isMatchModelIndex].getCost(1) / cast(float)cBitCostScale;
				m_total_is_match1_bits_cost += matchBitCost;
				m_total_match_bits_cost += matchBitCost;
				m_worst_match_bits_cost = maximum(m_worst_match_bits_cost, cast(double)(matchBitCost));
				m_total_matches++;
				
				if (lzdec.dist < 0)
				{
					// rep match
					int match_hist_index = -1 * lzdec.dist - 1;
					assert(match_hist_index < CLZBase.cMatchHistSize);
					
					m_rep_stats[match_hist_index].update(cost_in_bits);
					
					if (!match_hist_index)
					{
						// rep0 match
						if (lzdec.len == 1)
						{
							m_rep0_len1_stats.update(cost_in_bits);
						}
						else
						{
							m_rep0_len2_plus_stats.update(cost_in_bits);
						}
					}
				}
				else
				{
					m_full_match_stats[minimum(cMaxMatchLen, match_len)].update(cost_in_bits);
					
					if (match_len == 2)
					{
						if (lzdec.dist <= 512)
							m_total_near_len2_matches++;
						else
							m_total_far_len2_matches++;
						
						m_max_len2_dist = maximum(cast(int)m_max_len2_dist, lzdec.dist);
					}
				}
			}
			else
			{
				// TODO: Handle huge matches.
			}
		}
		@nogc void print(){
			import core.stdc.stdio;
			debug{
				if (!m_total_contexts)
					return;
				
				printf("-----------\n");
				printf("Coding statistics:\n");
				printf("Total update rate resets: %u\n", m_total_update_rate_resets);
				printf("Total Bytes: %u, Total Contexts: %u, Total Cost: %f bits (%f bytes)\nContext ave cost: %f StdDev: %f Min: %f Max: %f\n", m_total_bytes, m_total_contexts, m_total_cost, m_total_cost / 8.0f, m_context_stats.get_average(), m_context_stats.get_std_dev(), m_context_stats.get_min_val(), m_context_stats.get_max_val());
				printf("Ave bytes per context: %f\n", m_total_bytes / cast(float)m_total_contexts);
				
				printf("IsMatch:\n");
				printf("  Total: %u, Cost: %f (%f bytes), Ave. Cost: %f, Worst Cost: %f\n",
					m_total_contexts, m_total_match_bits_cost, m_total_match_bits_cost / 8.0f, m_total_match_bits_cost / maximum(1, m_total_contexts), m_worst_match_bits_cost);
				
				printf("  IsMatch(0): %u, Cost: %f (%f bytes), Ave. Cost: %f\n",
					m_total_nonmatches, m_total_is_match0_bits_cost, m_total_is_match0_bits_cost / 8.0f, m_total_is_match0_bits_cost / maximum(1, m_total_nonmatches));
				
				printf("  IsMatch(1): %u, Cost: %f (%f bytes), Ave. Cost: %f\n",
					m_total_matches, m_total_is_match1_bits_cost, m_total_is_match1_bits_cost / 8.0f, m_total_is_match1_bits_cost / maximum(1, m_total_matches));
				
				printf("Literal stats:\n");
				printf("  Count: %u, Cost: %f (%f bytes), Ave: %f StdDev: %f Min: %f Max: %f\n", m_lit_stats.get_number_of_values32(), m_lit_stats.get_total(), m_lit_stats.get_total() / 8.0f, m_lit_stats.get_average(), m_lit_stats.get_std_dev(), m_lit_stats.get_min_val(), m_lit_stats.get_max_val());
				
				printf("Delta literal stats:\n");
				printf("  Count: %u, Cost: %f (%f bytes), Ave: %f StdDev: %f Min: %f Max: %f\n", m_delta_lit_stats.get_number_of_values32(), m_delta_lit_stats.get_total(), m_delta_lit_stats.get_total() / 8.0f, m_delta_lit_stats.get_average(), m_delta_lit_stats.get_std_dev(), m_delta_lit_stats.get_min_val(), m_delta_lit_stats.get_max_val());
				
				printf("Rep0 Len1 stats:\n");
				printf("  Count: %u, Cost: %f (%f bytes), Ave. Cost: %f StdDev: %f Min: %f Max: %f\n", m_rep0_len1_stats.get_number_of_values32(), m_rep0_len1_stats.get_total(), m_rep0_len1_stats.get_total() / 8.0f, m_rep0_len1_stats.get_average(), m_rep0_len1_stats.get_std_dev(), m_rep0_len1_stats.get_min_val(), m_rep0_len1_stats.get_max_val());
				
				printf("Rep0 Len2+ stats:\n");
				printf("  Count: %u, Cost: %f (%f bytes), Ave. Cost: %f StdDev: %f Min: %f Max: %f\n", m_rep0_len2_plus_stats.get_number_of_values32(), m_rep0_len2_plus_stats.get_total(), m_rep0_len2_plus_stats.get_total() / 8.0f, m_rep0_len2_plus_stats.get_average(), m_rep0_len2_plus_stats.get_std_dev(), m_rep0_len2_plus_stats.get_min_val(), m_rep0_len2_plus_stats.get_max_val());
				
				for (uint i = 0; i < CLZBase.cMatchHistSize; i++){
					printf("Rep %u stats:\n", i);
					printf("  Count: %u, Cost: %f (%f bytes), Ave. Cost: %f StdDev: %f Min: %f Max: %f\n", m_rep_stats[i].get_number_of_values32(), m_rep_stats[i].get_total(), m_rep_stats[i].get_total() / 8.0f, m_rep_stats[i].get_average(), m_rep_stats[i].get_std_dev(), m_rep_stats[i].get_min_val(), m_rep_stats[i].get_max_val());
				}
				
				for (uint i = CLZBase.cMinMatchLen; i <= CLZBase.cMaxMatchLen; i++){
					printf("Match %u: Total: %u, Cost: %f (%f bytes), Ave: %f StdDev: %f Min: %f Max: %f\n", i,
						m_full_match_stats[i].get_number_of_values32(), m_full_match_stats[i].get_total(), m_full_match_stats[i].get_total() / 8.0f,
						m_full_match_stats[i].get_average(), m_full_match_stats[i].get_std_dev(), m_full_match_stats[i].get_min_val(), m_full_match_stats[i].get_max_val());
				}
				
				printf("Total near len2 matches: %u, total far len2 matches: %u\n", m_total_near_len2_matches, m_total_far_len2_matches);
				printf("Total matches: %u, truncated matches: %u\n", m_total_matches, m_total_truncated_matches);
				printf("Max full match len2 distance: %u\n", m_max_len2_dist);
			}
		}
		
	}
	private InitParams m_params;
	private CompSettings m_settings;
	
	private long m_src_size;
	private uint m_src_adler32;
	
	private SearchAccelerator m_accel;
	
	private SymbolCodec m_codec;
	
	private CodingStats m_stats;
	
	private ubyte[] m_block_buf;
	private ubyte[] m_comp_buf;
	
	private uint m_step;
	
	private uint m_block_start_dict_ofs;
	
	private uint m_block_index;
	
	private bool m_finished;
	private bool m_use_task_pool;
	
	private struct NodeState{
		@nogc void clear()
		{
			m_total_cost = cBitCostMax; //math::cNearlyInfinite;
			m_total_complexity = uint.max;
		}
		
		// the lzdecision that led from parent to this node_state
		LZDecision m_lzdec;                 
		
		// This is either the state of the parent node (optimal parsing), or the state of the child node (extreme parsing).
		StateBase m_saved_state;     
		
		// Total cost to arrive at this node state.
		ulong m_total_cost;                 
		uint m_total_complexity;
		
		// Parent node index.
		short m_parent_index;               
		
		// Parent node state index (only valid when extreme parsing).
		byte m_parent_state_index;          
	}
	private struct Node{
		uint m_num_node_states;                                    
		enum { 
			cMaxNodeStates = 4 
		}
		NodeState m_node_states[cMaxNodeStates];
		
		@nogc void clear(){
			m_num_node_states = 0;
		}
		
		void add_state(int parentIndex, int parentStateIndex, LZDecision lzdec, State parentState, ulong totalCost, uint totalComplexity){
			StateBase trialState;
			parentState.save_partial_state(trialState);
			trialState.partial_advance(lzdec);
			
			for (int i = m_num_node_states - 1; i >= 0; i--){
				NodeState* curNodeState = &m_node_states[i];
				if (curNodeState.m_saved_state == trialState){
					if ( (totalCost < curNodeState.m_total_cost) ||
						((totalCost == curNodeState.m_total_cost) && 
							(totalComplexity < curNodeState.m_total_complexity)) ){
						curNodeState.m_parent_index = cast(short)(parentIndex);
						curNodeState.m_parent_state_index = cast(byte)(parentStateIndex);
						curNodeState.m_lzdec = lzdec;
						curNodeState.m_total_cost = totalCost;
						curNodeState.m_total_complexity = totalComplexity;
						
						while (i > 0){
							if ((m_node_states[i].m_total_cost < m_node_states[i - 1].m_total_cost) ||
								((m_node_states[i].m_total_cost == m_node_states[i - 1].m_total_cost) && 
									(m_node_states[i].m_total_complexity < m_node_states[i - 1].m_total_complexity))){
								swap(m_node_states[i], m_node_states[i - 1]);
								i--;
							}else
								break;
						}
					}
					
					return;
				}
			}
			
			int insertIndex;
			for (insertIndex = m_num_node_states; insertIndex > 0; insertIndex--){
				NodeState* curNodeState = &m_node_states[insertIndex - 1];
				
				if ( (totalCost > curNodeState.m_total_cost) ||
					((totalCost == curNodeState.m_total_cost) &&
						(totalComplexity >= curNodeState.m_total_complexity)) ){
					break;
				}
			}
			
			if (insertIndex == cMaxNodeStates)
				return;
			
			uint numBehind = m_num_node_states - insertIndex;
			uint numToMove = (m_num_node_states < cMaxNodeStates) ? numBehind : (numBehind - 1);
			if (numToMove){
				assert((insertIndex + 1 + numToMove) <= cMaxNodeStates);
				memmove( &m_node_states[insertIndex + 1], &m_node_states[insertIndex], NodeState.sizeof * numToMove);
			}
			
			NodeState* newNodeState = &m_node_states[insertIndex];
			newNodeState.m_parent_index = cast(short)(parentIndex);
			newNodeState.m_parent_state_index = cast(byte)(parentStateIndex);
			newNodeState.m_lzdec = lzdec;
			newNodeState.m_total_cost = totalCost;
			newNodeState.m_total_complexity = totalComplexity;
			newNodeState.m_saved_state = trialState;
			
			//m_num_node_states = LZHAM_MIN(m_num_node_states + 1, static_cast<uint>(cMaxNodeStates));
			m_num_node_states = m_num_node_states + 1 > cast(uint)(cMaxNodeStates) ? cast(uint)(cMaxNodeStates) : m_num_node_states + 1;
		}
	}
	private align(128) struct ParseThreadState{
		uint m_start_ofs;
		uint m_bytes_to_match;
		
		State m_initial_state;
		
		Node m_nodes[cMaxParseGraphNodes + 1];
		
		LZDecision[] m_best_decisions;
		bool m_emit_decisions_backwards;
		
		LZPricedDecision[] m_temp_decisions;
		
		uint m_max_greedy_decisions;
		uint m_greedy_parse_total_bytes_coded;
		bool m_greedy_parse_gave_up;
		
		bool m_issue_reset_state_partial;
		bool m_failed;
	}
	private uint m_num_parse_threads;
	private ParseThreadState m_parse_thread_state[cMaxParseThreads + 1]; // +1 extra for the greedy parser thread (only used for delta compression)
	
	private uint m_parse_jobs_remaining;
	//semaphore m_parse_jobs_complete;
	
	private enum { 
		cMaxBlockHistorySize = 6, 
		cBlockHistoryCompRatioScale = 1000U 
	}
	private struct BlockHistory{
		uint m_comp_size;
		uint m_src_size;
		uint m_ratio;
		bool m_raw_block;
		bool m_reset_update_rate;
	}
	private BlockHistory m_block_history[cMaxBlockHistorySize];
	private uint m_block_history_size;
	private uint m_block_history_next;
	
	this(){
		m_src_size = -1;
		//m_parse_jobs_complete
		
	}
	/// See http://www.gzip.org/zlib/rfc-zlib.html
	/// Method is set to 14 (LZHAM) and CINFO is (window_size - 15).
	bool send_zlib_header(){
		if ((m_params.m_lzham_compress_flags & LZHAMCompressFlags.WRITE_ZLIB_STREAM) == 0)
			return true;
		
		// set CM (method) and CINFO (dictionary size) fields
		int cmf = LZHAM_Z_LZHAM | ((m_params.m_dict_size_log2 - 15) << 4);
		
		// set FLEVEL by mapping LZHAM's compression level to zlib's
		int flg = 0;
		switch (m_params.m_compression_level){
			case LZHAMCompressLevel.FASTEST:
				flg = 0 << 6;
				break;
			case LZHAMCompressLevel.FASTER:
				flg = 1 << 6;
				break;
			case LZHAMCompressLevel.DEFAULT, LZHAMCompressLevel.BETTER:
				flg = 2 << 6;
				break;
			default:
				flg = 3 << 6;
				break;
				
		}
		
		// set FDICT flag
		if (m_params.m_pSeed_bytes)
			flg |= 32;
		
		int check = ((cmf << 8) + flg) % 31;
		if (check)
			flg += (31 - check);
		
		assert(0 == (((cmf << 8) + flg) % 31));
		/*if (!m_comp_buf.try_push_back(cast(ubyte)(cmf)))
		 return false;
		 if (!m_comp_buf.try_push_back(cast(ubyte)(flg)))
		 return false;*/
		m_comp_buf ~= cast(ubyte)(cmf);
		m_comp_buf ~= cast(ubyte)(flg);
		
		if (m_params.m_pSeed_bytes){
			// send adler32 of DICT
			uint dictAdler32 = adler32(cast(ubyte*)m_params.m_pSeed_bytes, m_params.m_num_seed_bytes);
			for (uint i = 0; i < 4; i++)
			{
				/*if (!m_comp_buf.try_push_back(cast(ubyte)(dictAdler32 >> 24)))
				 return false;*/
				m_comp_buf ~= cast(ubyte)(dictAdler32 >> 24);
				dictAdler32 <<= 8;
			}
		}
		
		return true;
	}
	bool init_seed_bytes(){
		uint curSeedOfs = 0;
		
		while (curSeedOfs < m_params.m_num_seed_bytes){
			uint totalBytesRemaining = m_params.m_num_seed_bytes - curSeedOfs;
			//uint num_bytes_to_add = math::minimum(total_bytes_remaining, m_params.m_block_size);
			uint numBytesToAdd = totalBytesRemaining > m_params.m_block_size ? m_params.m_block_size : totalBytesRemaining;
			
			if (!m_accel.add_bytes_begin(numBytesToAdd, cast(const ubyte*)(m_params.m_pSeed_bytes) + curSeedOfs))
				return false;
			m_accel.add_bytes_end();
			
			m_accel.advance_bytes(numBytesToAdd);
			
			curSeedOfs += numBytesToAdd;
		}
		
		return true;
	}
	bool send_final_block(){
		if (!m_codec.startEncoding(16))
			return false;
		/*debug{
		 if (!m_codec.encodeBits(166, 12))
		 return false;
		 }*/
		if (!m_block_index)
		{
			if (!send_configuration())
				return false;
		}
		
		if (!m_codec.encodeBits(cEOFBlock, cBlockHeaderBits))
			return false;
		
		if (!m_codec.encodeAlignToByte())
			return false;
		
		if (!m_codec.encodeBits(m_src_adler32, 32))
			return false;
		
		if (!m_codec.stopEncoding(true))
			return false;
		
		if (!m_comp_buf.length){
			m_comp_buf = (m_codec.getEncodingBuf());
		}else{
			/*if (!m_comp_buf.append(m_codec.get_encoding_buf()))
			 return false;*/
			m_comp_buf ~= m_codec.getEncodingBuf();
		}
		
		m_block_index++;
		return true;
	}
	bool send_configuration(){
		// TODO: Currently unused.
		//if (!m_codec.encode_bits(m_settings.m_fast_adaptive_huffman_updating, 1))
		//   return false;
		//if (!m_codec.encode_bits(0, 1))
		//   return false;
		
		return true;
	}
	/// The "extreme" parser tracks the best node::cMaxNodeStates (4) candidate LZ decisions per lookahead character.
	/// This allows the compressor to make locally suboptimal decisions that ultimately result in a better parse.
	/// It assumes the input statistics are locally stationary over the input block to parse.
	bool extreme_parse(ParseThreadState* parseState){
		assert(parseState.m_bytes_to_match <= cMaxParseGraphNodes);
		
		parseState.m_failed = false;
		parseState.m_emit_decisions_backwards = true;
		
		Node* pNodes = parseState.m_nodes.ptr;
		for (uint i = 0; i <= cMaxParseGraphNodes; i++){
			pNodes[i].clear();
		}
		
		State approxState = parseState.m_initial_state;
		
		pNodes[0].m_num_node_states = 1;
		NodeState* firstNodeState = &(pNodes[0].m_node_states[0]);
		approxState.save_partial_state(firstNodeState.m_saved_state);
		firstNodeState.m_parent_index = -1;
		firstNodeState.m_parent_state_index = -1;
		firstNodeState.m_total_cost = 0;
		firstNodeState.m_total_complexity = 0;
		
		const uint bytesToParse = parseState.m_bytes_to_match;
		
		const uint lookaheadStartOfs = m_accel.get_lookahead_pos() & m_accel.get_max_dict_size_mask();
		
		uint curDictOfs = parseState.m_start_ofs;
		uint curLookaheadOfs = curDictOfs - lookaheadStartOfs;
		uint curNodeIndex = 0;
		
		enum { cMaxFullMatches = cMatchAccelMaxSupportedProbes };
		uint matchLens[cMaxFullMatches];
		uint matchDistances[cMaxFullMatches];
		
		ulong lzdec_bitcosts[cMaxMatchLen + 1];
		
		Node prevLitNode;
		prevLitNode.clear();
		
		while (curNodeIndex < bytesToParse){
			Node* curNode = &pNodes[curNodeIndex];
			
			//const uint max_admissable_match_len = LZHAM_MIN(static_cast<uint>(CLZBase::cMaxMatchLen), bytesToParse - curNodeIndex);
			uint helperval = bytesToParse - curNodeIndex;
			const uint maxAdmissableMatchLen = cast(uint)(CLZBase.cMaxMatchLen) > helperval ? helperval : cast(uint)(CLZBase.cMaxMatchLen);
			const uint findDictSize = m_accel.get_cur_dict_size() + curLookaheadOfs;
			
			const uint litPred0 = approxState.get_pred_char(m_accel, curDictOfs, 1);
			
			const ubyte* pLookahead = &m_accel.m_dict[curDictOfs];
			
			// full matches
			uint maxFullMatchLen = 0;
			uint numFullMatches = 0;
			uint len2MatchDist = 0;
			
			if (maxAdmissableMatchLen >= CLZBase.cMinMatchLen){
				DictMatch* pMatches = m_accel.find_matches(curLookaheadOfs);
				if (pMatches){
					for ( ; ; ){
						uint matchLen = pMatches.get_len();
						assert((pMatches.get_dist() > 0) && (pMatches.get_dist() <= dictSize));
						//matchLen = LZHAM_MIN(matchLen, maxAdmissableMatchLen);
						matchLen = matchLen > maxAdmissableMatchLen ? maxAdmissableMatchLen : matchLen;
						
						if (matchLen > maxFullMatchLen){
							maxFullMatchLen = matchLen;
							
							matchLens[numFullMatches] = matchLen;
							matchDistances[numFullMatches] = pMatches.get_dist();
							numFullMatches++;
						}
						
						if (pMatches.is_last())
							break;
						pMatches++;
					}
				}
				
				len2MatchDist = m_accel.get_len2_match(curLookaheadOfs);
			}
			
			for (uint curNodeStateIndex = 0; curNodeStateIndex < curNode.m_num_node_states; curNodeStateIndex++){
				NodeState* curNodeState = &curNode.m_node_states[curNodeStateIndex];
				
				if (curNodeIndex){
					assert(curNodeState.m_parent_index >= 0);
					
					approxState.restore_partial_state(curNodeState.m_saved_state);
				}
				
				uint isMatchModelIndex = (approxState.m_cur_state);
				
				const ulong curNodeTotalCost = curNodeState.m_total_cost;
				const uint curNodeTotalComplexity = curNodeState.m_total_complexity;
				
				// rep matches
				uint matchHistMaxLen = 0;
				uint matchHistMinMatchLen = 1;
				for (uint repMatchIndex = 0; repMatchIndex < cMatchHistSize; repMatchIndex++){
					uint histMatchLen = 0;
					
					uint dist = approxState.m_match_hist[repMatchIndex];
					if (dist <= findDictSize){
						const uint compPos = cast(uint)((m_accel.m_lookahead_pos + curLookaheadOfs - dist) & m_accel.m_max_dict_size_mask);
						const ubyte* pComp = &m_accel.m_dict[compPos];
						
						for (histMatchLen = 0; histMatchLen < maxAdmissableMatchLen; histMatchLen++)
							if (pComp[histMatchLen] != pLookahead[histMatchLen])
								break;
					}
					
					if (histMatchLen >= matchHistMinMatchLen){
						//matchHistMaxLen = math::maximum(matchHistMaxLen, histMatchLen);
						
						approxState.get_rep_match_costs(curDictOfs, lzdec_bitcosts.ptr, repMatchIndex, matchHistMinMatchLen, histMatchLen, isMatchModelIndex);
						
						uint repMatchTotalComplexity = curNodeTotalComplexity + (cRep0Complexity + repMatchIndex);
						for (uint l = matchHistMinMatchLen; l <= histMatchLen; l++){
							Node* dstNode = &curNode[l];
							
							ulong repMatchTotalCost = curNodeTotalCost + lzdec_bitcosts[l];
							
							dstNode.add_state(curNodeIndex, curNodeStateIndex, new LZDecision(curDictOfs, l, -1 * (cast(int)repMatchIndex + 1)), approxState, repMatchTotalCost, repMatchTotalComplexity);
						}
					}
					
					matchHistMinMatchLen = CLZBase.cMinMatchLen;
				}
				
				uint minTruncateMatchLen = matchHistMaxLen;
				
				// nearest len2 match
				if (len2MatchDist){
					LZDecision lzdec = new LZDecision(curDictOfs, 2, len2MatchDist);
					ulong actualCost = approxState.get_cost(this, m_accel, lzdec);
					curNode[2].add_state(curNodeIndex, curNodeStateIndex, lzdec, approxState, curNodeTotalCost + actualCost, curNodeTotalComplexity + cShortMatchComplexity);
					
					//minTruncateMatchLen = LZHAM_MAX(minTruncateMatchLen, 2);
					minTruncateMatchLen = minTruncateMatchLen > 2 ? minTruncateMatchLen : 2;
				}
				
				// full matches
				if (maxFullMatchLen > minTruncateMatchLen){
					//uint prevMaxMatchLen = LZHAM_MAX(1, minTruncateMatchLen);
					uint prevMaxMatchLen = 1 > minTruncateMatchLen ? 1 : minTruncateMatchLen;
					for (uint fullMatchIndex = 0; fullMatchIndex < numFullMatches; fullMatchIndex++){
						uint endLen = matchLens[fullMatchIndex];
						if (endLen <= minTruncateMatchLen)
							continue;
						
						uint startLen = prevMaxMatchLen + 1;
						uint matchDist = matchDistances[fullMatchIndex];
						
						assert(startLen <= endLen);
						
						approxState.get_full_match_costs(this, curDictOfs, lzdec_bitcosts.ptr, matchDist, startLen, endLen, isMatchModelIndex);
						
						for (uint l = startLen; l <= endLen; l++){
							uint matchComplexity = (l >= cLongMatchComplexityLenThresh) ? cLongMatchComplexity : cShortMatchComplexity;
							
							Node* dstNode = &curNode[l];
							
							ulong matchTotalCost = curNodeTotalCost + lzdec_bitcosts[l];
							uint matchTotalComplexity = curNodeTotalComplexity + matchComplexity;
							
							dstNode.add_state( curNodeIndex, curNodeStateIndex, new LZDecision(curDictOfs, l, matchDist), approxState, matchTotalCost, matchTotalComplexity);
						}
						
						prevMaxMatchLen = endLen;
					}
				}
				
				// literal
				ulong litCost = approxState.get_lit_cost(this, m_accel, curDictOfs, litPred0, isMatchModelIndex);
				ulong litTotalCost = curNodeTotalCost + litCost;
				uint litTotalComplexity = curNodeTotalComplexity + cLitComplexity;
				
				
				curNode[1].add_state( curNodeIndex, curNodeStateIndex, new LZDecision(curDictOfs, 0, 0), approxState, litTotalCost, litTotalComplexity);
				
			} // cur_node_state_index
			
			curDictOfs++;
			curLookaheadOfs++;
			curNodeIndex++;
		}
		
		// Now get the optimal decisions by starting from the goal node.
		// m_best_decisions is filled backwards.
		/*if (!parseState.m_best_decisions.length = bytesToParse){
		 parseState.m_failed = true;
		 return false;
		 }*/
		parseState.m_best_decisions.length = bytesToParse;
		
		ulong lowestFinalCost = cBitCostMax; //math::cNearlyInfinite;
		int nodeStateIndex = 0;
		NodeState* lastNodeStates = pNodes[bytesToParse].m_node_states.ptr;
		for (uint i = 0; i < pNodes[bytesToParse].m_num_node_states; i++){
			if (lastNodeStates[i].m_total_cost < lowestFinalCost){
				lowestFinalCost = lastNodeStates[i].m_total_cost;
				nodeStateIndex = i;
			}
		}
		
		int nodeIndex = bytesToParse;
		LZDecision *dstDec = parseState.m_best_decisions.ptr;
		do{
			assert((nodeIndex >= 0) && (nodeIndex <= cast(int)cMaxParseGraphNodes));
			
			Node* curNode = &pNodes[nodeIndex];
			NodeState* curNodeState = &curNode.m_node_states[nodeStateIndex];
			
			*dstDec++ = curNodeState.m_lzdec;
			
			nodeIndex = curNodeState.m_parent_index;
			nodeStateIndex = curNodeState.m_parent_state_index;
			
		} while (nodeIndex > 0);
		
		parseState.m_best_decisions.length = (cast(uint)(dstDec - parseState.m_best_decisions.ptr));
		
		return true;
	}
	/// Parsing notes:
	/// The regular "optimal" parser only tracks the single cheapest candidate LZ decision per lookahead character.
	/// This function finds the shortest path through an extremely dense node graph using a streamlined/simplified Dijkstra's algorithm with some coding heuristics.
	/// Graph edges are LZ "decisions", cost is measured in fractional bits needed to code each graph edge, and graph nodes are lookahead characters.
	/// There is no need to track visited/unvisted nodes, or find the next cheapest unvisted node in each iteration. The search always proceeds sequentially, visiting each lookahead character in turn from left/right.
	/// The major CPU expense of this function is the complexity of LZ decision cost evaluation, so a lot of implementation effort is spent here reducing this overhead.
	/// To simplify the problem, it assumes the input statistics are locally stationary over the input block to parse. (Otherwise, it would need to store, track, and update
	/// unique symbol statistics for each lookahead character, which would be very costly.)
	/// This function always sequentially pushes "forward" the unvisited node horizon. This horizon frequently collapses to a single node, which guarantees that the shortest path through the
	/// graph must pass through this node. LZMA tracks cumulative bitprices relative to this node, while LZHAM currently always tracks cumulative bitprices relative to the first node in the lookahead buffer.
	/// In very early versions of LZHAM the parse was much more understandable (straight Dijkstra with almost no bit price optimizations or coding heuristics).
	bool optimal_parse(ParseThreadState* parseState){
		assert(parseState.m_bytes_to_match <= cMaxParseGraphNodes);
		
		parseState.m_failed = false;
		parseState.m_emit_decisions_backwards = true;
		
		NodeState *pNodes = cast(NodeState*)(parseState.m_nodes);
		pNodes[0].m_parent_index = -1;
		pNodes[0].m_total_cost = 0;
		pNodes[0].m_total_complexity = 0;
		
		memset( &pNodes[1], 0xFF, cMaxParseGraphNodes * NodeState.sizeof);
		
		State approxState = parseState.m_initial_state;
		
		const uint bytesToParse = parseState.m_bytes_to_match;
		
		const uint lookaheadStartOfs = m_accel.get_lookahead_pos() & m_accel.get_max_dict_size_mask();
		
		uint curDictOfs = parseState.m_start_ofs;
		uint curLookaheadOfs = curDictOfs - lookaheadStartOfs;
		uint curNodeIndex = 0;
		
		enum { cMaxFullMatches = cMatchAccelMaxSupportedProbes };
		uint[cMaxFullMatches] matchLens;
		uint[cMaxFullMatches] matchDistances;
		
		ulong[cMaxMatchLen + 1] lzdecBitcosts;
		
		while (curNodeIndex < bytesToParse){
			NodeState* pCurNode = &pNodes[curNodeIndex];
			uint helperVal = bytesToParse - curNodeIndex;
			//const uint maxAdmissableMatchLen = LZHAM_MIN(static_cast<uint>(CLZBase::cMaxMatchLen), bytesToParse - curNodeIndex);
			const uint maxAdmissableMatchLen = cast(uint)(CLZBase.cMaxMatchLen) > helperVal ? helperVal : cast(uint)(CLZBase.cMaxMatchLen);
			const uint findDictSize = m_accel.m_cur_dict_size + curLookaheadOfs;
			
			if (curNodeIndex){
				assert(pCurNode.m_parent_index >= 0);
				
				// Move to this node's state using the lowest cost LZ decision found.
				approxState.restore_partial_state(pCurNode.m_saved_state);
				approxState.partial_advance(pCurNode.m_lzdec);
			}
			
			const ulong curNodeTotalCost = pCurNode.m_total_cost;
			// This assert includes a fudge factor - make sure we don't overflow our scaled costs.
			assert((cBitCostMax - curNodeTotalCost) > (cBitCostScale * 64));
			const uint curNodeTotalComplexity = pCurNode.m_total_complexity;
			
			const uint litPred0 = approxState.get_pred_char(m_accel, curDictOfs, 1);
			uint isMatchModelIndex = approxState.m_cur_state;
			
			const ubyte* pLookahead = &m_accel.m_dict[curDictOfs];
			
			// rep matches
			uint matchHistMaxLen = 0;
			uint matchHistMinMatchLen = 1;
			for (uint repMatchIndex = 0; repMatchIndex < cMatchHistSize; repMatchIndex++){
				uint histMatchLen = 0;
				
				uint dist = approxState.m_match_hist[repMatchIndex];
				if (dist <= findDictSize){
					const uint compPos = cast(uint)((m_accel.m_lookahead_pos + curLookaheadOfs - dist) & m_accel.m_max_dict_size_mask);
					const ubyte* pComp = &m_accel.m_dict[compPos];
					
					for (histMatchLen = 0; histMatchLen < maxAdmissableMatchLen; histMatchLen++)
						if (pComp[histMatchLen] != pLookahead[histMatchLen])
							break;
				}
				
				if (histMatchLen >= matchHistMinMatchLen){
					//matchHistMaxLen = math::maximum(matchHistMaxLen, histMatchLen);
					
					approxState.get_rep_match_costs(curDictOfs, lzdecBitcosts.ptr, repMatchIndex, matchHistMinMatchLen, histMatchLen, isMatchModelIndex);
					
					uint rep_match_total_complexity = curNodeTotalComplexity + (cRep0Complexity + repMatchIndex);
					for (uint l = matchHistMinMatchLen; l <= histMatchLen; l++){
						/*#if LZHAM_VERIFY_MATCH_COSTS
						 {
						 lzdecision actual_dec(cur_dict_ofs, l, -((int)rep_match_index + 1));
						 bit_cost_t actual_cost = approx_state.get_cost(*this, m_accel, actual_dec);
						 LZHAM_ASSERT(actual_cost == lzdec_bitcosts[l]);
						 }
						 #endif*/
						NodeState* dstNode = &pCurNode[l];
						
						ulong repMatchTotalCost = curNodeTotalCost + lzdecBitcosts[l];
						
						if ((repMatchTotalCost > dstNode.m_total_cost) || ((repMatchTotalCost == dstNode.m_total_cost) && (rep_match_total_complexity >= dstNode.m_total_complexity)))
							continue;
						
						dstNode.m_total_cost = repMatchTotalCost;
						dstNode.m_total_complexity = rep_match_total_complexity;
						dstNode.m_parent_index = cast(ushort)curNodeIndex;
						approxState.save_partial_state(dstNode.m_saved_state);
						dstNode.m_lzdec.init(curDictOfs, l, -1 * (cast(int)repMatchIndex + 1));
						dstNode.m_lzdec.len = l;
					}
				}
				
				matchHistMinMatchLen = CLZBase.cMinMatchLen;
			}
			
			uint maxMatchLen = matchHistMaxLen;
			
			if (maxMatchLen >= m_settings.m_fast_bytes){
				curDictOfs += maxMatchLen;
				curLookaheadOfs += maxMatchLen;
				curNodeIndex += maxMatchLen;
				continue;
			}
			
			// full matches
			if (maxAdmissableMatchLen >= CLZBase.cMinMatchLen){
				uint numFullMatches = 0;
				
				if (matchHistMaxLen < 2){
					// Get the nearest len2 match if we didn't find a rep len2.
					uint len2MatchDist = m_accel.get_len2_match(curLookaheadOfs);
					if (len2MatchDist){
						ulong cost = approxState.get_len2_match_cost(this, curDictOfs, len2MatchDist, isMatchModelIndex);
						
						/*#if LZHAM_VERIFY_MATCH_COSTS
						 {
						 lzdecision actual_dec(cur_dict_ofs, 2, len2_match_dist);
						 bit_cost_t actual_cost = approx_state.get_cost(*this, m_accel, actual_dec);
						 LZHAM_ASSERT(actual_cost == cost);
						 }
						 #endif*/
						
						NodeState* dstNode = &pCurNode[2];
						
						ulong matchTotalCost = curNodeTotalCost + cost;
						uint matchTotalComplexity = curNodeTotalComplexity + cShortMatchComplexity;
						
						if ((matchTotalCost < dstNode.m_total_cost) || ((matchTotalCost == dstNode.m_total_cost) && (matchTotalComplexity < dstNode.m_total_complexity))){
							dstNode.m_total_cost = matchTotalCost;
							dstNode.m_total_complexity = matchTotalComplexity;
							dstNode.m_parent_index = cast(ushort)curNodeIndex;
							approxState.save_partial_state(dstNode.m_saved_state);
							dstNode.m_lzdec.init(curDictOfs, 2, len2MatchDist);
						}
						
						maxMatchLen = 2;
					}
				}
				
				const uint minTruncateMatchLen = maxMatchLen;
				
				// Now get all full matches: the nearest matches at each match length. (Actually, we don't
				// always get the nearest match. The match finder favors those matches which have the lowest value
				// in the nibble of each match distance, all other things being equal, to help exploit how the lowest
				// nibble of match distances is separately coded.)
				DictMatch* pMatches = m_accel.find_matches(curLookaheadOfs);
				if (pMatches){
					for ( ; ; ){
						uint matchLen = pMatches.get_len();
						assert((pMatches.get_dist() > 0) && (pMatches.get_dist() <= dictSize));
						//match_len = LZHAM_MIN(match_len, maxAdmissableMatchLen);
						matchLen = matchLen < maxAdmissableMatchLen ? matchLen : maxAdmissableMatchLen;
						
						if (matchLen > maxMatchLen){
							maxMatchLen = matchLen;
							
							matchLens[numFullMatches] = matchLen;
							matchDistances[numFullMatches] = pMatches.get_dist();
							numFullMatches++;
						}
						
						if (pMatches.is_last())
							break;
						pMatches++;
					}
				}
				
				if (numFullMatches){
					//uint prev_max_match_len = LZHAM_MAX(1, minTruncateMatchLen);
					uint prevMaxMatchLen = 1 > minTruncateMatchLen ? 1 : minTruncateMatchLen;
					for (uint fullMatchIndex = 0; fullMatchIndex < numFullMatches; fullMatchIndex++){
						uint startLen = prevMaxMatchLen + 1;
						uint endLen = matchLens[fullMatchIndex];
						uint matchDist = matchDistances[fullMatchIndex];
						
						assert(startLen <= endLen);
						
						approxState.get_full_match_costs(this, curDictOfs, lzdecBitcosts.ptr, matchDist, startLen, endLen, isMatchModelIndex);
						
						for (uint l = startLen; l <= endLen; l++){
							uint match_complexity = (l >= cLongMatchComplexityLenThresh) ? cLongMatchComplexity : cShortMatchComplexity;
							
							/*#if LZHAM_VERIFY_MATCH_COSTS
							 {
							 lzdecision actual_dec(cur_dict_ofs, l, match_dist);
							 bit_cost_t actual_cost = approx_state.get_cost(*this, m_accel, actual_dec);
							 LZHAM_ASSERT(actual_cost == lzdec_bitcosts[l]);
							 }
							 #endif*/
							NodeState* dstNode = &pCurNode[l];
							
							ulong matchTotalCost = curNodeTotalCost + lzdecBitcosts[l];
							uint matchTotalComplexity = curNodeTotalComplexity + match_complexity;
							
							if ((matchTotalCost > dstNode.m_total_cost) || ((matchTotalCost == dstNode.m_total_cost) && (matchTotalComplexity >= dstNode.m_total_complexity)))
								continue;
							
							dstNode.m_total_cost = matchTotalCost;
							dstNode.m_total_complexity = matchTotalComplexity;
							dstNode.m_parent_index = cast(ushort)curNodeIndex;
							approxState.save_partial_state(dstNode.m_saved_state);
							dstNode.m_lzdec.init(curDictOfs, l, matchDist);
						}
						
						prevMaxMatchLen = endLen;
					}
				}
			}
			
			if (maxMatchLen >= m_settings.m_fast_bytes){
				curDictOfs += maxMatchLen;
				curLookaheadOfs += maxMatchLen;
				curNodeIndex += maxMatchLen;
				continue;
			}
			
			// literal
			ulong litCost = approxState.get_lit_cost(this, m_accel, curDictOfs, litPred0, isMatchModelIndex);
			ulong litTotalCost = curNodeTotalCost + litCost;
			uint litTotalComplexity = curNodeTotalComplexity + cLitComplexity;
			/*#if LZHAM_VERIFY_MATCH_COSTS
			 {
			 lzdecision actual_dec(cur_dict_ofs, 0, 0);
			 bit_cost_t actual_cost = approx_state.get_cost(*this, m_accel, actual_dec);
			 LZHAM_ASSERT(actual_cost == lit_cost);
			 }
			 #endif*/
			if ((litTotalCost < pCurNode[1].m_total_cost) || ((litTotalCost == pCurNode[1].m_total_cost) && (litTotalComplexity < pCurNode[1].m_total_complexity))){
				pCurNode[1].m_total_cost = litTotalCost;
				pCurNode[1].m_total_complexity = litTotalComplexity;
				pCurNode[1].m_parent_index = cast(short)curNodeIndex;
				approxState.save_partial_state(pCurNode[1].m_saved_state);
				pCurNode[1].m_lzdec.init(curDictOfs, 0, 0);
			}
			
			curDictOfs++;
			curLookaheadOfs++;
			curNodeIndex++;
			
		} // graph search
		
		// Now get the optimal decisions by starting from the goal node.
		// m_best_decisions is filled backwards.
		/*if (!parseState.m_best_decisions.try_reserve(bytesToParse)){
		 parseState.m_failed = true;
		 return false;
		 }*/
		parseState.m_best_decisions.length = bytesToParse;
		
		int nodeIndex = bytesToParse;
		LZDecision* dstDec = parseState.m_best_decisions.ptr;
		do{
			assert((nodeIndex >= 0) && (nodeIndex <= cast(int)cMaxParseGraphNodes));
			NodeState* curNode = &pNodes[nodeIndex];
			
			*dstDec++ = curNode.m_lzdec;
			
			nodeIndex = curNode.m_parent_index;
			
		} while (nodeIndex > 0);
		
		//parseState.m_best_decisions.try_resize(cast(uint)(dstDec - parseState.m_best_decisions.get_ptr()));
		parseState.m_best_decisions.length = (cast(uint)(dstDec - parseState.m_best_decisions.ptr));
		
		return true;
	}
	/// ofs is the absolute dictionary offset, must be >= the lookahead offset.
	/// TODO: Doesn't find len2 matches
	int enumerate_lz_decisions(uint ofs, const State curState, ref LZPricedDecision[] decisions, uint minMatchLen, uint maxMatchLen){
		assert(minMatchLen >= 1);
		
		uint startOfs = m_accel.get_lookahead_pos() & m_accel.get_max_dict_size_mask();
		assert(ofs >= startOfs);
		const uint lookaheadOfs = ofs - startOfs;
		
		uint largestIndex = 0;
		uint largestLen;
		ulong largestCost;
		
		if (minMatchLen <= 1){
			/*if (!decisions.try_resize(1))
			 return -1;*/
			decisions.length = 1;
			
			LZPricedDecision litDec = decisions[0];
			litDec.init(ofs, 0, 0, 0);
			litDec.cost = curState.get_cost(this, m_accel, litDec);
			largestCost = litDec.cost;
			
			largestLen = 1;
		}else{
			/*if (!decisions.try_resize(0))
			 return -1;*/
			decisions.length = 0;
			
			largestLen = 0;
			largestCost = cBitCostMax;
		}
		
		uint matchHistMaxLen = 0;
		
		// Add rep matches.
		for (uint i = 0; i < cMatchHistSize; i++){
			uint histMatchLen = m_accel.get_match_len(lookaheadOfs, curState.m_match_hist[i], maxMatchLen);
			if (histMatchLen < minMatchLen)
				continue;
			
			if ( ((histMatchLen == 1) && (i == 0)) || (histMatchLen >= CLZBase.cMinMatchLen) ){
				//matchHistMaxLen = math::maximum(matchHistMaxLen, histMatchLen);
				matchHistMaxLen = (matchHistMaxLen > histMatchLen ? matchHistMaxLen : histMatchLen);
				
				LZPricedDecision dec = new LZPricedDecision(ofs, histMatchLen, -1 * (cast(int)i + 1));
				dec.cost = curState.get_cost(this, m_accel, dec);
				
				/*if (!decisions.try_push_back(dec))
				 return -1;*/
				decisions ~= dec;
				
				if ( (histMatchLen > largestLen) || ((histMatchLen == largestLen) && (dec.cost < largestCost)) ){
					largestIndex = decisions.length - 1;
					largestLen = histMatchLen;
					largestCost = dec.cost;
				}
			}
		}
		
		// Now add full matches.
		if ((maxMatchLen >= CLZBase.cMinMatchLen) && (matchHistMaxLen < m_settings.m_fast_bytes)){
			DictMatch* pMatches = m_accel.find_matches(lookaheadOfs);
			
			if (pMatches){
				for ( ; ; ){
					//uint match_len = math::minimum(pMatches->get_len(), maxMatchLen);
					uint matchLen = pMatches.get_len() > maxMatchLen ? maxMatchLen : pMatches.get_len();
					assert((pMatches.get_dist() > 0) && (pMatches.get_dist() <= dictSize));
					
					// Full matches are very likely to be more expensive than rep matches of the same length, so don't bother evaluating them.
					if ((matchLen >= minMatchLen) && (matchLen > matchHistMaxLen)){
						if ((maxMatchLen > CLZBase.cMaxMatchLen) && (matchLen == CLZBase.cMaxMatchLen)){
							matchLen = m_accel.get_match_len(lookaheadOfs, pMatches.get_dist(), maxMatchLen, CLZBase.cMaxMatchLen);
						}
						
						LZPricedDecision dec = new LZPricedDecision(ofs, matchLen, pMatches.get_dist());
						dec.cost = curState.get_cost(this, m_accel, dec);
						
						/*if (!decisions.try_push_back(dec))
						 return -1;*/
						decisions ~= dec;
						
						if ( (matchLen > largestLen) || ((matchLen == largestLen) && (dec.getCost() < largestCost)) ){
							largestIndex = decisions.length - 1;
							largestLen = matchLen;
							largestCost = dec.getCost();
						}
					}
					if (pMatches.is_last())
						break;
					pMatches++;
				}
			}
		}
		
		return largestIndex;
	}
	bool greedy_parse(ParseThreadState* parseState){
		parseState.m_failed = true;
		parseState.m_emit_decisions_backwards = false;
		
		const uint bytesToParse = parseState.m_bytes_to_match;
		
		const uint lookaheadStartOfs = m_accel.get_lookahead_pos() & m_accel.get_max_dict_size_mask();
		
		uint curDictOfs = parseState.m_start_ofs;
		uint curLookaheadOfs = curDictOfs - lookaheadStartOfs;
		uint curOfs = 0;
		
		State approxState = parseState.m_initial_state;
		
		LZPricedDecision[] decisions = parseState.m_temp_decisions;
		
		/*if (!decisions.try_reserve(384))
		 return false;*/
		decisions.length = 384;
		
		/*if (!parseState.m_best_decisions.try_resize(0))
		 return false;*/
		parseState.m_best_decisions.length = 0;
		
		while (curOfs < bytesToParse){
			const uint max_admissable_match_len = minimum(cast(uint)(CLZBase.cMaxHugeMatchLen), bytesToParse - curOfs);
			
			int largestDecIndex = enumerate_lz_decisions(curDictOfs, approxState, decisions, 1, max_admissable_match_len);
			if (largestDecIndex < 0)
				return false;
			
			LZPricedDecision dec = decisions[largestDecIndex];
			
			/*if (!parseState.m_best_decisions.try_push_back(dec))
			 return false;*/
			parseState.m_best_decisions ~= dec;
			
			approxState.partial_advance(dec);
			
			uint matchLen = dec.getLen();
			assert(matchLen <= max_admissable_match_len);
			curDictOfs += matchLen;
			curLookaheadOfs += matchLen;
			curOfs += matchLen;
			
			if (parseState.m_best_decisions.length >= parseState.m_max_greedy_decisions){
				parseState.m_greedy_parse_total_bytes_coded = curOfs;
				parseState.m_greedy_parse_gave_up = true;
				return false;
			}
		}
		
		parseState.m_greedy_parse_total_bytes_coded = curOfs;
		
		assert(curOfs == bytesToParse);
		
		parseState.m_failed = false;
		
		return true;
	}
	void parse_job_callback(ulong data, void* dataPtr){
		const uint parseJobIndex = cast(uint)data;
		//scoped_perf_section parse_job_timer(cVarArgs, "parse_job_callback %u", parse_job_index);
		
		//(void)pData_ptr;
		
		ParseThreadState* parseState = &m_parse_thread_state[parseJobIndex];
		
		if ((m_params.m_lzham_compress_flags & LZHAMCompressFlags.EXTREME_PARSING) && (m_params.m_compression_level == LZHAMCompressLevel.UBER))
			extreme_parse(parseState);
		else
			optimal_parse(parseState);
		
		//LZHAM_MEMORY_EXPORT_BARRIER
		
		/*if (atomic_decrement32(&m_parse_jobs_remaining) == 0){
		 m_parse_jobs_complete.release();
		 }*/
		/*if(--m_parse_jobs_remaining == 0)
		 m_parse_jobs_complete.release();*/
	}
	bool compress_block(void* pBuf, uint bufLen){
		uint curOfs = 0;
		uint bytesRemaining = bufLen;
		while (bytesRemaining){
			//uint bytes_to_compress = math::minimum(m_accel.get_max_add_bytes(), bytesRemaining);
			uint bytesToCompress = m_accel.get_max_add_bytes() > bytesRemaining ? bytesRemaining : m_accel.get_max_add_bytes();
			if (!compress_block_internal((pBuf) + curOfs, bytesToCompress))
				return false;
			
			curOfs += bytesToCompress;
			bytesRemaining -= bytesToCompress;
		}
		return true;
	}
	void update_block_history(uint compSize, uint srcSize, uint ratio, bool rawBlock, bool resetUpdateRate){
		BlockHistory* curBlockHistory = &m_block_history[m_block_history_next];
		m_block_history_next++;
		m_block_history_next %= cMaxBlockHistorySize;
		
		curBlockHistory.m_comp_size = compSize;
		curBlockHistory.m_src_size = srcSize;
		curBlockHistory.m_ratio = ratio;
		curBlockHistory.m_raw_block = rawBlock;
		curBlockHistory.m_reset_update_rate = resetUpdateRate;
		
		//m_block_history_size = LZHAM_MIN(m_block_history_size + 1, static_cast<uint>(cMaxBlockHistorySize));
		m_block_history_size = m_block_history_size + 1 > cast(uint)(cMaxBlockHistorySize) ? cast(uint)(cMaxBlockHistorySize) : m_block_history_size + 1;
	}
	uint get_recent_block_ratio(){
		if (!m_block_history_size)
			return 0;
		
		ulong totalScaledRatio = 0;
		for (uint i = 0; i < m_block_history_size; i++)
			totalScaledRatio += m_block_history[i].m_ratio;
		totalScaledRatio /= m_block_history_size;
		
		return cast(uint)(totalScaledRatio);
	}
	uint get_min_block_ratio(){
		if (!m_block_history_size)
			return 0;
		uint minScaledRatio = uint.max;
		for (uint i = 0; i < m_block_history_size; i++){
			if(minScaledRatio > m_block_history[i].m_ratio)
				minScaledRatio = m_block_history[i].m_ratio;
		}
		//minScaledRatio = LZHAM_MIN(m_block_history[i].m_ratio, minScaledRatio);
		return minScaledRatio;
	}
	uint get_max_block_ratio(){
		if (!m_block_history_size)
			return 0;
		uint minScaledRatio = uint.max;
		for (uint i = 0; i < m_block_history_size; i++){
			if(minScaledRatio < m_block_history[i].m_ratio)
				minScaledRatio = m_block_history[i].m_ratio;
		}
		//minScaledRatio = LZHAM_MIN(m_block_history[i].m_ratio, minScaledRatio);
		return minScaledRatio;
	}
	uint get_total_recent_reset_update_rate(){
		uint totalResets = 0;
		for (uint i = 0; i < m_block_history_size; i++)
			totalResets += m_block_history[i].m_reset_update_rate;
		return totalResets;
	}
	bool compress_block_internal(void* pBuf, uint bufLen){
		//scoped_perf_section compress_block_timer(cVarArgs, "****** compress_block %u", m_block_index);
		
		assert(pBuf);
		assert(bufLen <= m_params.m_block_size);
		
		assert(m_src_size >= 0);
		if (m_src_size < 0)
			return false;
		
		m_src_size += bufLen;
		
		// Important: Don't do any expensive work until after add_bytes_begin() is called, to increase parallelism.
		if (!m_accel.add_bytes_begin(bufLen, cast(const ubyte*)(pBuf)))
			return false;
		
		m_start_of_block_state = m_state;
		
		m_src_adler32 = adler32(cast(ubyte*)pBuf, bufLen, m_src_adler32);
		
		m_block_start_dict_ofs = m_accel.get_lookahead_pos() & (m_accel.get_max_dict_size() - 1);
		
		uint curDictOfs = m_block_start_dict_ofs;
		
		uint bytesToMatch = bufLen;
		
		if (!m_codec.startEncoding((bufLen * 9) / 8))
			return false;
		
		if (!m_block_index){
			if (!send_configuration())
				return false;
		}
		
		if (!m_codec.encodeBits(cCompBlock, cBlockHeaderBits))
			return false;
		
		if (!m_codec.encodeArithInit())
			return false;
		
		m_state.start_of_block(m_accel, curDictOfs, m_block_index);
		
		bool emitResetUpdateRateCommand = false;
		
		// Determine if it makes sense to reset the Huffman table update frequency back to their initial (maximum) rates.
		if ((m_block_history_size) && (m_params.m_lzham_compress_flags & LZHAMCompressFlags.TRADEOFF_DECOMPRESSION_RATE_FOR_COMP_RATIO)){
			BlockHistory* prevBlockHistory = &m_block_history[m_block_history_next ? (m_block_history_next - 1) : (cMaxBlockHistorySize - 1)];
			
			if (prevBlockHistory.m_raw_block)
				emitResetUpdateRateCommand = true;
			else if (get_total_recent_reset_update_rate() == 0){
				if (get_recent_block_ratio() > (cBlockHistoryCompRatioScale * 95U / 100U))
					emitResetUpdateRateCommand = true;
				else{
					uint recent_min_block_ratio = get_min_block_ratio();
					//uint recent_max_block_ratio = get_max_block_ratio();
					
					// Compression ratio has recently dropped quite a bit - slam the table update rates back up.
					if (prevBlockHistory.m_ratio > (recent_min_block_ratio * 3U) / 2U){
						//printf("Emitting reset: %u %u\n", prev_block_history.m_ratio, recent_min_block_ratio);
						emitResetUpdateRateCommand = true;
					}
				}
			}
		}
		
		if (emitResetUpdateRateCommand)
			m_state.reset_update_rate();
		
		m_codec.encodeBits(emitResetUpdateRateCommand ? 1 : 0, cBlockFlushTypeBits);
		
		//coding_stats initial_stats(m_stats);
		
		uint initialStep = m_step;
		
		while (bytesToMatch){
			const uint cAvgAcceptableGreedyMatchLen = 384;
			if ((m_params.m_pSeed_bytes) && (bytesToMatch >= cAvgAcceptableGreedyMatchLen)){
				ParseThreadState* greedyParseState = &m_parse_thread_state[cMaxParseThreads];
				
				greedyParseState.m_initial_state = m_state;
				greedyParseState.m_initial_state.m_cur_ofs = curDictOfs;
				
				greedyParseState.m_issue_reset_state_partial = false;
				greedyParseState.m_start_ofs = curDictOfs;
				//greedyParseState.m_bytes_to_match = LZHAM_MIN(bytesToMatch, static_cast<uint>(CLZBase::cMaxHugeMatchLen));
				greedyParseState.m_bytes_to_match = bytesToMatch > cast(uint)(CLZBase.cMaxHugeMatchLen) ? cast(uint)(CLZBase.cMaxHugeMatchLen) : bytesToMatch;
				
				greedyParseState.m_max_greedy_decisions = maximum((bytesToMatch / cAvgAcceptableGreedyMatchLen), 2);
				greedyParseState.m_greedy_parse_gave_up = false;
				greedyParseState.m_greedy_parse_total_bytes_coded = 0;
				
				if (!greedy_parse(greedyParseState))
				{
					if (!greedyParseState.m_greedy_parse_gave_up)
						return false;
				}
				
				uint numGreedyDecisionsToCode = 0;
				
				LZDecision[] bestDecisions = greedyParseState.m_best_decisions; 
				
				if (!greedyParseState.m_greedy_parse_gave_up)
					numGreedyDecisionsToCode = bestDecisions.length;
				else{
					uint numSmallDecisions = 0;
					uint totalMatchLen = 0;
					uint maxMatchLen = 0;
					
					uint i;
					for (i = 0; i < bestDecisions.length; i++){
						const LZDecision dec = bestDecisions[i];
						if (dec.getLen() <= CLZBase.cMaxMatchLen){
							numSmallDecisions++;
							if (numSmallDecisions > 16)
								break;
						}
						
						totalMatchLen += dec.getLen();
						//maxMatchLen = LZHAM_MAX(maxMatchLen, dec.get_len());
						maxMatchLen = maxMatchLen > dec.getLen() ? maxMatchLen : dec.getLen();
					}
					
					if (maxMatchLen > CLZBase.cMaxMatchLen){
						if ((totalMatchLen / i) >= cAvgAcceptableGreedyMatchLen){
							numGreedyDecisionsToCode = i;
						}
					}
				}
				
				if (numGreedyDecisionsToCode){
					for (uint i = 0; i < numGreedyDecisionsToCode; i++){
						assert(bestDecisions[i].pos == cast(int)curDictOfs);
						//LZHAM_ASSERT(i >= 0);
						assert(i < bestDecisions.length);
						
						/*#if LZHAM_UPDATE_STATS
						 bit_cost_t cost = m_state.get_cost(*this, m_accel, best_decisions[i]);
						 m_stats.update(best_decisions[i], m_state, m_accel, cost);
						 #endif*/
						
						if (!code_decision(bestDecisions[i], curDictOfs, bytesToMatch))
							return false;
					}
					
					if ((!greedyParseState.m_greedy_parse_gave_up) || (!bytesToMatch))
						continue;
				}
			}
			
			uint numParseJobs = minimum(m_num_parse_threads, (bytesToMatch + cMaxParseGraphNodes - 1) / cMaxParseGraphNodes);
			if ((m_params.m_lzham_compress_flags & LZHAMCompressFlags.DETERMINISTIC_PARSING) == 0){
				if (m_use_task_pool && m_accel.get_max_helper_threads()){
					// Increase the number of active parse jobs as the match finder finishes up to keep CPU utilization up.
					numParseJobs += m_accel.get_num_completed_helper_threads();
					numParseJobs = minimum(numParseJobs, cMaxParseThreads);
				}
			}
			if (bytesToMatch < 1536)
				numParseJobs = 1;
			
			// Reduce block size near the beginning of the file so statistical models get going a bit faster.
			bool forceSmallBlock = false;
			if ((!m_block_index) && ((curDictOfs - m_block_start_dict_ofs) < cMaxParseGraphNodes)){
				numParseJobs = 1;
				forceSmallBlock = true;
			}
			
			uint parseThreadStartOfs = curDictOfs;
			//uint parse_thread_total_size = LZHAM_MIN(bytesToMatch, cMaxParseGraphNodes * numParseJobs);
			uint helperVal = cMaxParseGraphNodes * numParseJobs;
			uint parseThreadTotalSize = bytesToMatch > helperVal ? helperVal : bytesToMatch;
			if (forceSmallBlock){
				//parseThreadTotalSize = LZHAM_MIN(parseThreadTotalSize, 1536);
				parseThreadTotalSize = parseThreadTotalSize > 1536 ? 1536 : parseThreadTotalSize;
			}
			
			uint parseThreadRemaining = parseThreadTotalSize;
			for (uint parseThreadIndex = 0; parseThreadIndex < numParseJobs; parseThreadIndex++){
				ParseThreadState* parseThread = &m_parse_thread_state[parseThreadIndex];
				
				parseThread.m_initial_state = m_state;
				parseThread.m_initial_state.m_cur_ofs = parseThreadStartOfs;
				
				if (parseThreadIndex > 0){
					parseThread.m_initial_state.reset_state_partial();
					parseThread.m_issue_reset_state_partial = true;
				}else{
					parseThread.m_issue_reset_state_partial = false;
				}
				
				parseThread.m_start_ofs = parseThreadStartOfs;
				if (parseThreadIndex == (numParseJobs - 1))
					parseThread.m_bytes_to_match = parseThreadRemaining;
				else
					parseThread.m_bytes_to_match = parseThreadTotalSize / numParseJobs;
				
				//parseThread.m_bytes_to_match = LZHAM_MIN(parseThread.m_bytes_to_match, cMaxParseGraphNodes);
				parseThread.m_bytes_to_match = parseThread.m_bytes_to_match > cMaxParseGraphNodes ? cMaxParseGraphNodes : parseThread.m_bytes_to_match;
				assert(parseThread.m_bytes_to_match > 0);
				
				parseThread.m_max_greedy_decisions = uint.max;
				parseThread.m_greedy_parse_gave_up = false;
				
				parseThreadStartOfs += parseThread.m_bytes_to_match;
				parseThreadRemaining -= parseThread.m_bytes_to_match;
			}
			
			{
				//scoped_perf_section parse_timer("parsing");
				
				if ((m_use_task_pool) && (numParseJobs > 1)){
					m_parse_jobs_remaining = numParseJobs;
					
					{
						//scoped_perf_section queue_task_timer("queuing parse tasks");
						
						/*if (!m_params.m_pTask_pool->queue_multiple_object_tasks(this, parse_job_callback, 1, numParseJobs - 1))
						 return false;*/
					}
					
					parse_job_callback(0, null);
					
					{
						//scoped_perf_section wait_timer("waiting for jobs");
						
						//m_parse_jobs_complete.wait();
					}
				}else{
					m_parse_jobs_remaining = int.max;
					for (uint parseThreadIndex = 0; parseThreadIndex < numParseJobs; parseThreadIndex++){
						parse_job_callback(parseThreadIndex, null);
					}
				}
			}
			
			{
				//scoped_perf_section coding_timer("coding");
				
				for (uint parse_thread_index = 0; parse_thread_index < numParseJobs; parse_thread_index++){
					ParseThreadState* parseThread = &m_parse_thread_state[parse_thread_index];
					if (parseThread.m_failed)
						return false;
					
					LZDecision[] bestDecisions = parseThread.m_best_decisions;
					
					if (parseThread.m_issue_reset_state_partial){
						if (!m_state.encode_reset_state_partial(m_codec, m_accel, curDictOfs))
							return false;
						m_step++;
					}
					
					if (bestDecisions.length){
						int i = 0;
						int endDecIndex = cast(int)(bestDecisions.length) - 1;
						int decStep = 1;
						if (parseThread.m_emit_decisions_backwards){
							i = cast(int)(bestDecisions.length) - 1;
							endDecIndex = 0;
							decStep = -1;
							assert(bestDecisions[$-1].pos == cast(int)parseThread.m_start_ofs);
						}else{
							//assert(bestDecisions.front().m_pos == cast(int)parseThread.m_start_ofs);
							assert(bestDecisions[0].pos == cast(int)parseThread.m_start_ofs);
						}
						
						// Loop rearranged to avoid bad x64 codegen problem with MSVC2008.
						for ( ; ; ){
							assert(bestDecisions[i].pos == cast(int)curDictOfs);
							assert(i >= 0);
							assert(i < cast(int)bestDecisions.length);
							
							/*#if LZHAM_UPDATE_STATS
							 bit_cost_t cost = m_state.get_cost(*this, m_accel, best_decisions[i]);
							 m_stats.update(best_decisions[i], m_state, m_accel, cost);
							 //m_state.print(m_codec, *this, m_accel, best_decisions[i]);
							 #endif*/
							
							if (!code_decision(bestDecisions[i], curDictOfs, bytesToMatch))
								return false;
							if (i == endDecIndex)
								break;
							i += decStep;
						}
						
						//LZHAM_NOTE_UNUSED(i);
					}
					
					assert(curDictOfs == parseThread.m_start_ofs + parseThread.m_bytes_to_match);
					
				} // parse_thread_index
				
			}
		}
		
		{
			//scoped_perf_section add_bytes_timer("add_bytes_end");
			m_accel.add_bytes_end();
		}
		
		if (!m_state.encode_eob(m_codec, m_accel, curDictOfs))
			return false;
		
		/*#ifdef LZHAM_LZDEBUG
		 if (!m_codec.encode_bits(366, 12)) return false;
		 #endif*/
		
		{
			//scoped_perf_section stop_encoding_timer("stop_encoding");
			if (!m_codec.stopEncoding(true)) return false;
		}
		
		// Coded the entire block - now see if it makes more sense to just send a raw/uncompressed block.
		
		uint compressedSize = m_codec.getEncodingBuf().length;
		//LZHAM_NOTE_UNUSED(compressed_size);
		
		bool usedRawBlock = false;
		
		/*#if !LZHAM_FORCE_ALL_RAW_BLOCKS
		 #if (defined(LZHAM_DISABLE_RAW_BLOCKS) || defined(LZHAM_LZDEBUG))
		 if (0)
		 #else
		 // TODO: Allow the user to control this threshold, i.e. if less than 1% then just store uncompressed.
		 if (compressed_size >= buf_len)
		 #endif
		 #endif*/
		{
			// Failed to compress the block, so go back to our original state and just code a raw block.
			m_state = m_start_of_block_state;
			m_step = initialStep;
			//m_stats = initial_stats;
			
			m_codec.reset();
			
			if (!m_codec.startEncoding(bufLen + 16))
				return false;
			
			if (!m_block_index)
			{
				if (!send_configuration())
					return false;
			}
			
			/*#ifdef LZHAM_LZDEBUG
			 if (!m_codec.encode_bits(166, 12))
			 return false;
			 #endif*/
			
			if (!m_codec.encodeBits(cRawBlock, cBlockHeaderBits))
				return false;
			
			assert(bufLen <= 0x1000000);
			if (!m_codec.encodeBits(bufLen - 1, 24))
				return false;
			
			// Write buf len check bits, to help increase the probability of detecting corrupted data more early.
			uint bufLen0 = (bufLen - 1) & 0xFF;
			uint bufLen1 = ((bufLen - 1) >> 8) & 0xFF;
			uint bufLen2 = ((bufLen - 1) >> 16) & 0xFF;
			if (!m_codec.encodeBits((bufLen0 ^ bufLen1) ^ bufLen2, 8))
				return false;
			
			if (!m_codec.encodeAlignToByte())
				return false;
			
			ubyte* pSrc = m_accel.get_ptr(m_block_start_dict_ofs);
			
			for (uint i = 0; i < bufLen; i++){
				if (!m_codec.encodeBits(*pSrc++, 8))
					return false;
			}
			
			if (!m_codec.stopEncoding(true))
				return false;
			
			usedRawBlock = true;
			emitResetUpdateRateCommand = false;
		}
		
		uint compSize = cast(uint)m_codec.getEncodingBuf().length;
		uint scaledRatio =  (compSize * cBlockHistoryCompRatioScale) / bufLen;
		update_block_history(compSize, bufLen, scaledRatio, usedRawBlock, emitResetUpdateRateCommand);
		
		//printf("\n%u, %u, %u, %u\n", m_block_index, 500*emit_reset_update_rate_command, scaled_ratio, get_recent_block_ratio());
		
		{
			//scoped_perf_section append_timer("append");
			
			if (m_comp_buf.length == 0){
				swap(m_comp_buf, m_codec.getEncodingBuf());
				
			}else{
				/*if (!m_comp_buf.append(m_codec.get_encoding_buf()))
				 return false;*/
				m_comp_buf ~= m_codec.getEncodingBuf();
			}
		}
		/*#if LZHAM_UPDATE_STATS
		 LZHAM_VERIFY(m_stats.m_total_bytes == m_src_size);
		 if (emit_reset_update_rate_command)
		 m_stats.m_total_update_rate_resets++;
		 #endif*/
		
		m_block_index++;
		
		return true;
	}
	bool code_decision(LZDecision lzdec, uint curOfs, uint bytesToMatch){
		/*debug{
		 if (!m_codec.encode_bits(CLZBase.cLZHAMDebugSyncMarkerValue, CLZBase.cLZHAMDebugSyncMarkerBits)) return false;
		 if (!m_codec.encode_bits(lzdec.is_match(), 1)) return false;
		 if (!m_codec.encode_bits(lzdec.get_len(), 17)) return false;
		 if (!m_codec.encode_bits(m_state.m_cur_state, 4)) return false;
		 }*/
		const uint len = lzdec.getLen();
		
		if (!m_state.encode(m_codec, this, m_accel, lzdec))
			return false;
		
		curOfs += len;
		assert(bytesToMatch >= len);
		bytesToMatch -= len;
		
		m_accel.advance_bytes(len);
		
		m_step++;
		
		return true;
	}
	bool send_sync_block(LZHAMFlushTypes flushType){
		m_codec.reset();
		
		if (!m_codec.startEncoding(128))
			return false;
		
		/*debug{
		 if (!m_codec.encode_bits(166, 12))
		 return false;
		 }*/
		
		if (!m_codec.encodeBits(cSyncBlock, cBlockHeaderBits))
			return false;
		
		int flushCode = 0;
		
		switch (flushType){
			case LZHAMFlushTypes.FULL_FLUSH://LZHAM_FULL_FLUSH:
				flushCode = 2;
				break;
			case LZHAMFlushTypes.TABLE_FLUSH://LZHAM_TABLE_FLUSH:
				flushCode = 1;
				break;
			case LZHAMFlushTypes.SYNC_FLUSH://LZHAM_SYNC_FLUSH:
				flushCode = 3;
				break;
				//case LZHAM_NO_FLUSH:
				//case LZHAM_FINISH:
			default:
				flushCode = 0;
				break;
		}
		if (!m_codec.encodeBits(flushCode, cBlockFlushTypeBits))
			return false;
		
		if (!m_codec.encodeAlignToByte())
			return false;
		if (!m_codec.encodeBits(0x0000, 16))
			return false;
		if (!m_codec.encodeBits(0xFFFF, 16))
			return false;
		if (!m_codec.stopDecoding())
			return false;
		/*if (!m_comp_buf.append(m_codec.get_encoding_buf()))
		 return false;*/
		m_comp_buf ~= m_codec.getEncodingBuf();
		
		m_block_index++;
		return true;
	}
	
	bool init(InitParams params){
		clear();
		
		if ((params.m_dict_size_log2 < CLZBase.cMinDictSizeLog2) || (params.m_dict_size_log2 > CLZBase.cMaxDictSizeLog2))
			return false;
		if ((params.m_compression_level < 0) || (params.m_compression_level > cCompressionLevelCount))
			return false;
		
		this.m_params = params;
		//m_use_task_pool = (m_params.m_pTask_pool) && (m_params.m_pTask_pool.get_num_threads() != 0) && (m_params.m_max_helper_threads > 0);
		
		if (!m_use_task_pool)
			m_params.m_max_helper_threads = 0;
		
		m_settings = sLevelSetting[params.m_compression_level];
		
		const uint dictSize = 1U << m_params.m_dict_size_log2;
		
		if (params.m_num_seed_bytes){
			if (!params.m_pSeed_bytes)
				return false;
			if (params.m_num_seed_bytes > dictSize)
				return false;
		}
		
		uint maxBlockSize = dictSize / 8;
		if (this.m_params.m_block_size > maxBlockSize){
			this.m_params.m_block_size = maxBlockSize;
		}
		
		m_num_parse_threads = 1;
		static if(false){
			if (this.m_params.m_max_helper_threads > 0){
				assert(cMaxParseThreads >= 4);
				
				if (m_params.m_block_size < 16384){
					//m_num_parse_threads = LZHAM_MIN(cMaxParseThreads, m_params.m_max_helper_threads + 1);
					m_num_parse_threads = cMaxParseThreads > this.m_params.m_max_helper_threads + 1 ? this.m_params.m_max_helper_threads + 1 : cMaxParseThreads;
				}else{
					if ((this.m_params.m_max_helper_threads == 1) || (this.m_params.m_compression_level == cCompressionLevelFastest)){
						m_num_parse_threads = 1;
					}else if (m_params.m_max_helper_threads <= 3){
						m_num_parse_threads = 2;
					}else if (m_params.m_max_helper_threads <= 7){
						if ((this.m_params.m_lzham_compress_flags & LZHAMCompressFlags.EXTREME_PARSING) && (m_params.m_compression_level == LZHAMCompressLevel.UBER))
							m_num_parse_threads = 4;
						else
							m_num_parse_threads = 2;
					}else{
						// 8-16
						m_num_parse_threads = 4;
					}
				}
			}
		}
		int numParseJobs = m_num_parse_threads - 1;
		//uint match_accel_helper_threads = LZHAM_MAX(0, (int)m_params.m_max_helper_threads - num_parse_jobs);
		uint matchAccelHelperThreads = 0 > cast(int)(m_params.m_max_helper_threads - numParseJobs) ? 0 : cast(int)(m_params.m_max_helper_threads - numParseJobs);
		
		assert(m_num_parse_threads >= 1);
		assert(m_num_parse_threads <= cMaxParseThreads);
		
		if (!m_use_task_pool){
			assert(!matchAccelHelperThreads && (m_num_parse_threads == 1));
		}else{
			assert((matchAccelHelperThreads + (m_num_parse_threads - 1)) <= m_params.m_max_helper_threads);
		}
		
		if (!m_accel.init(this, /*params.m_pSeed_bytes,*/ matchAccelHelperThreads, dictSize, m_settings.m_match_accel_max_matches_per_probe, false, m_settings.m_match_accel_max_probes))
			return false;
		
		initPositionSlots(params.m_dict_size_log2);
		initSlotTabs();
		
		//m_settings.m_fast_adaptive_huffman_updating
		if (!m_state.init(this, m_params.m_table_max_update_interval, m_params.m_table_update_interval_slow_rate))
			return false;
		
		/*if (!m_block_buf.try_reserve(m_params.m_block_size))
		 return false;
		 
		 if (!m_comp_buf.try_reserve(m_params.m_block_size*2))
		 return false;*/
		m_block_buf.reserve(m_params.m_block_size);
		m_comp_buf.reserve(m_params.m_block_size * 2);
		
		for (uint i = 0; i < m_num_parse_threads; i++){
			//m_settings.m_fast_adaptive_huffman_updating
			if (!m_parse_thread_state[i].m_initial_state.init(this, m_params.m_table_max_update_interval, m_params.m_table_update_interval_slow_rate))
				return false;
		}
		
		m_block_history_size = 0;
		m_block_history_next = 0;
		
		if (params.m_num_seed_bytes)
		{
			if (!init_seed_bytes())
				return false;
		}
		
		if (!send_zlib_header())
			return false;
		
		m_src_size = 0;
		
		return true;
	}
	void clear(){
		m_codec.clear();
		m_src_size = -1;
		m_src_adler32 = 1;
		/*m_block_buf.clear();
		 m_comp_buf.clear();*/
		m_block_buf.length = 0;
		m_comp_buf.length = 0;
		m_step = 0;
		m_finished = false;
		m_use_task_pool = false;
		m_block_start_dict_ofs = 0;
		m_block_index = 0;
		m_state.clear();
		m_num_parse_threads = 0;
		m_parse_jobs_remaining = 0;
		
		for (uint i = 0; i < cMaxParseThreads; i++){
			ParseThreadState* parseState = &m_parse_thread_state[i];
			parseState.m_initial_state.clear();
			
			for (uint j = 0; j <= cMaxParseGraphNodes; j++)
				parseState.m_nodes[j].clear();
			
			parseState.m_start_ofs = 0;
			parseState.m_bytes_to_match = 0;
			//parseState.m_best_decisions.clear();
			parseState.m_best_decisions.length = 0;
			parseState.m_issue_reset_state_partial = false;
			parseState.m_emit_decisions_backwards = false;
			parseState.m_failed = false;
		}
		
		m_block_history_size = 0;
		m_block_history_next = 0;
	}
	
	// sync, or sync+dictionary flush 
	bool flush(LZHAMFlushTypes flushType){
		assert(!m_finished);
		if (m_finished)
			return false;
		
		bool status = true;
		if (m_block_buf.length){
			status = compress_block(m_block_buf.ptr, m_block_buf.length);
			
			m_block_buf.length = 0;
		}
		
		if (status){
			status = send_sync_block(flushType);
			
			if (flushType == LZHAMFlushTypes.FULL_FLUSH){
				m_accel.flush();
				m_state.reset();
			}
		}
		
		//lzham_flush_buffered_printf();
		
		return status;
	}
	
	bool reset(){
		if (m_src_size < 0)
			return false;
		
		m_accel.reset();
		m_codec.reset();
		m_stats.clear();
		m_src_size = 0;
		m_src_adler32 = 1;
		//m_block_buf.try_resize(0);
		m_block_buf.length = 0;
		m_comp_buf.length = 0;
		
		m_step = 0;
		m_finished = false;
		m_block_start_dict_ofs = 0;
		m_block_index = 0;
		m_state.reset();
		
		m_block_history_size = 0;
		m_block_history_next = 0;
		
		if (m_params.m_num_seed_bytes){
			if (!init_seed_bytes())
				return false;
		}
		
		return send_zlib_header();
	}
	
	bool put_bytes(const void* pBuf, uint bufLen){
		assert(!m_finished);
		if (m_finished)
			return false;
		
		bool status = true;
		
		if (!pBuf){
			// Last block - flush whatever's left and send the final block.
			if (m_block_buf.length){
				status = compress_block(m_block_buf.ptr, m_block_buf.length);
				
				m_block_buf.length = 0;
			}
			
			if (status){
				if (!send_final_block()){
					status = false;
				}
			}
			
			m_finished = true;
		}else{
			// Compress blocks.
			ubyte *pSrcBuf = cast(ubyte*)(pBuf);
			uint numSrcBytesRemaining = bufLen;
			
			while (numSrcBytesRemaining){
				//const uint num_bytes_to_copy = LZHAM_MIN(numSrcBytesRemaining, m_params.m_block_size - m_block_buf.size());
				uint helperVal = m_params.m_block_size - m_block_buf.length;
				uint numBytesToCopy = numSrcBytesRemaining > helperVal ? helperVal : numSrcBytesRemaining;
				
				if (numBytesToCopy == m_params.m_block_size){
					assert(!m_block_buf.length);
					
					// Full-block available - compress in-place.
					status = compress_block(pSrcBuf, numBytesToCopy);
				}else{
					// Less than a full block available - append to already accumulated bytes.
					/*if (!m_block_buf.append(cast(const ubyte*)(pSrcBuf), numBytesToCopy))
					 return false;*/
					m_block_buf ~= pSrcBuf[0..numBytesToCopy];
					
					assert(m_block_buf.length <= m_params.m_block_size);
					
					if (m_block_buf.length == m_params.m_block_size){
						status = compress_block(m_block_buf.ptr, m_block_buf.length);
						
						m_block_buf.length = 0;
					}
				}
				
				if (!status)
					return false;
				
				pSrcBuf += numBytesToCopy;
				numSrcBytesRemaining -= numBytesToCopy;
			}
		}
		
		//lzham_flush_buffered_printf();
		
		return status;
	}
	
	/*@nogc @property const ref ubyte[] get_compressed_data(){ 
		return m_comp_buf; 
	}*/
	@nogc @property ref ubyte[] get_compressed_data(){ 
		return m_comp_buf; 
	}
	
	@nogc @property uint get_src_adler32() const { 
		return m_src_adler32; 
	}
}