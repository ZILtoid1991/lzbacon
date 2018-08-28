module lzbacon.compInternal;

import lzbacon.symbolCodec;
import lzbacon.matchAccel;
import lzbacon.base;
import lzbacon.common;

const uint cMaxParseGraphNodes = 3072;
const uint cMaxParseThreads = 8;

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
		
		LZHAMCompressLevel m_compression_level;
		uint m_dict_size_log2;
		
		uint m_block_size;
		
		uint m_lzham_compress_flags;
		
		const void *m_pSeed_bytes;
		uint m_num_seed_bytes;
		
		uint m_table_max_update_interval;
		uint m_table_update_interval_slow_rate;
		this(){
			m_compression_level = LZHAMCompressLevel.DEFAULT;
			m_dict_size_log2 = 22;
			m_block_size = cDefaultBlockSize;
		}
	}
	private class LZDecision{
		int m_pos;  // dict position where decision was evaluated
		int m_len;  // 0 if literal, 1+ if match
		int m_dist; // <0 if match rep, else >=1 is match dist
		
		@nogc this() { }
		@nogc this(int pos, int len, int dist){ 
			init(pos, len, init);
		}
		
		@nogc void init(int pos, int len, int dist) { 
			m_pos = pos; 
			m_len = len; 
			m_dist = dist; 
		}
		
		@nogc bool is_lit() const { 
			return !m_len; 
		}
		@nogc bool is_match() const { 
			return m_len > 0; 
		} // may be a rep or full match
		@nogc bool is_full_match() const { 
			return (m_len > 0) && (m_dist >= 1); 
		}
		@nogc uint get_len() const { 
			//return math::maximum<uint>(m_len, 1); 
			return m_len > 1 ? m_len : 1;
		}
		@nogc bool is_rep() const { 
			return m_dist < 0; 
		}
		@nogc bool is_rep0() const { 
			return m_dist == -1; 
		}
		
		uint get_match_dist(const state s) const{
			
		}
		
		@nogc uint get_complexity() const{
			if (is_lit())
				return cLitComplexity;
			else if (is_rep())
			{
				LZHAM_ASSUME(cRep0Complexity == 2);
				return 1 + -m_dist;  // 2, 3, 4, or 5
			}
			else if (get_len() >= cLongMatchComplexityLenThresh)
				return cLongMatchComplexity;
			else
				return cShortMatchComplexity;
		}
		
		@nogc uint get_min_codable_len() const{
			if (is_lit() || is_rep0())
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
			super(pos, len, init);
		}
		@nogc this(int pos, int len, int dist, int cost){
			super(pos, len, init);
			this.cost = cost;
		}
		
		//inline lzpriced_decision(int pos, int len, int dist) : lzdecision(pos, len, dist) { }
		//inline lzpriced_decision(int pos, int len, int dist, bit_cost_t cost) : lzdecision(pos, len, dist), m_cost(cost) { }
		
		//inline void init(int pos, int len, int dist, bit_cost_t cost) { lzdecision::init(pos, len, dist); m_cost = cost; }
		
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
		
		void partial_advance(const LZDecision lzdec);
		
		void save_partial_state(StateBase dst){
			dst.m_cur_ofs = m_cur_ofs;
			dst.m_cur_state = m_cur_state;
			memcpy(dst.m_match_hist, m_match_hist, sizeof(m_match_hist));
		}
		
		void restore_partial_state(const StateBase src){
			m_cur_ofs = src.m_cur_ofs;
			m_cur_state = src.m_cur_state;
			memcpy(m_match_hist, src.m_match_hist, sizeof(m_match_hist));
		}
	}
	private class State : StateBase{
		uint m_block_start_dict_ofs;
		
		AdaptiveBitModel m_is_match_model[CLZBase.cNumStates];
		
		AdaptiveBitModel m_is_rep_model[CLZBase.cNumStates];
		AdaptiveBitModel m_is_rep0_model[CLZBase.cNumStates];
		AdaptiveBitModel m_is_rep0_single_byte_model[CLZBase.cNumStates];
		AdaptiveBitModel m_is_rep1_model[CLZBase.cNumStates];
		AdaptiveBitModel m_is_rep2_model[CLZBase.cNumStates];
		
		QuasiAdaptiveHuffmanDataModel m_lit_table;
		QuasiAdaptiveHuffmanDataModel m_delta_lit_table;
		
		QuasiAdaptiveHuffmanDataModel m_main_table;
		QuasiAdaptiveHuffmanDataModel m_rep_len_table[2];
		QuasiAdaptiveHuffmanDataModel m_large_len_table[2];
		QuasiAdaptiveHuffmanDataModel m_dist_lsb_table;
		
		this(){
			
		}
		void clear(){
			
		}
		bool init(CLZBase lzbase, uint table_max_update_interval, uint table_update_interval_slow_rate){
			
		}
		void reset(){
			
		}
		ulong get_cost(CLZBase lzbase, const SearchAccelerator dict, const LZDecision lzdec) const{
			
		}
		ulong get_len2_match_cost(CLZBase lzbase, uint dict_pos, uint len2_match_dist, uint is_match_model_index){
			
		}
		ulong get_lit_cost(CLZBase lzbase, const SearchAccelerator dict, uint dict_pos, uint lit_pred0, uint is_match_model_index) const{
			
		}
		// Returns actual cost.
		void get_rep_match_costs(uint dict_pos, bit_cost_t *pBitcosts, uint match_hist_index, int min_len, int max_len, uint is_match_model_index) const;
		void get_full_match_costs(CLZBase lzbase, uint dict_pos, bit_cost_t *pBitcosts, uint match_dist, int min_len, int max_len, uint is_match_model_index) const;
		
		bit_cost_t update_stats(CLZBase lzbase, const search_accelerator dict, const lzdecision lzdec);
		
		bool advance(CLZBase lzbase, const search_accelerator dict, const lzdecision lzdec);
		bool encode(SymbolCodec codec, CLZBase lzbase, const search_accelerator dict, const LZDecision lzdec);
		
		void print(SymbolCodec codec, CLZBase lzbase, const search_accelerator dict, const LZDecision lzdec);
		
		bool encode_eob(SymbolCodec codec, const SearchAccelerator dict, uint dict_pos);
		bool encode_reset_state_partial(SymbolCodec codec, const SearchAccelerator dict, uint dict_pos);
		
		void update_match_hist(uint match_dist);
		int find_match_dist(uint match_hist) const;
		
		void reset_state_partial();
		void start_of_block(const SearchAccelerator dict, uint cur_ofs, uint block_index);
		
		void reset_update_rate();
		
		uint get_pred_char(const SearchAccelerator dict, int pos, int backward_ofs) const;
		
		@nogc bool will_reference_last_match(const LZDecision lzdec) const{
			return (!lzdec.is_match()) &&  (m_cur_state >= CLZBase.cNumLitStates);
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
		
		ulong get_number_of_values() { 
			return m_num; 
		}
		uint get_number_of_values32() { 
			return cast(uint)(uint.max > m_num ? m_num : uint.max); 
		}
		double get_total() const { 
			return m_total; 
		}
		double get_average() const { 
			return m_num ? m_total / m_num : 0.0f; 
		}
		double get_std_dev() const { 
			return m_num ? sqrt( m_num * m_total2 - m_total * m_total ) / m_num: 0.0f; 
		}
		double get_min_val() const { 
			return m_num ? m_min_val : 0.0f; 
		}
		double get_max_val() const { 
			return m_num ? m_max_val : 0.0f; 
		}
	}
	private struct CodingStats{
		uint m_total_bytes;
		uint m_total_contexts;
		double m_total_cost;
		
		tracked_stat m_context_stats;
		
		double m_total_match_bits_cost;
		double m_worst_match_bits_cost;
		double m_total_is_match0_bits_cost;
		double m_total_is_match1_bits_cost;
		
		uint m_total_truncated_matches;
		uint m_match_truncation_len_hist[CLZBase.cMaxMatchLen + 1];
		uint m_match_truncation_hist[CLZBase.cMaxMatchLen + 1];
		uint m_match_type_truncation_hist[CLZBase.cNumStates][5];
		uint m_match_type_was_not_truncated_hist[CLZBase.cNumStates][5];
		
		uint m_total_nonmatches;
		uint m_total_matches;
		
		tracked_stat m_lit_stats;
		tracked_stat m_delta_lit_stats;
		
		tracked_stat m_rep_stats[CLZBase.cMatchHistSize];
		tracked_stat m_rep0_len1_stats;
		tracked_stat m_rep0_len2_plus_stats;
		
		tracked_stat m_full_match_stats[cMaxMatchLen + 1];
		
		uint m_total_far_len2_matches;
		uint m_total_near_len2_matches;
		
		uint m_total_update_rate_resets;
		
		uint m_max_len2_dist;
		this() { 
			clear(); 
		}
		
		void clear(){
			
		}
		
		void update(const LZDecision lzdec, const State cur_state, const SearchAccelerator dict, ulong cost){
			
		}
		void print(){
			
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
			m_total_complexity = UINT_MAX;
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
		
		void add_state(int parentIndex, int parentStateIndex, const LZDecision lzdec, State parentState, ulong totalCost, uint totalComplexity){
			StateBase trialState;
			parentState.save_partial_state(trialState);
			trialState.partial_advance(lzdec);
			
			for (int i = m_num_node_states - 1; i >= 0; i--){
				ref NodeState curNodeState = m_node_states[i];
				if (curNodeState.m_saved_state == trialState){
					if ( (totalCost < curNodeState.m_total_cost) ||
							((totalCost == curNodeState.m_total_cost) && 
							(totalComplexity < curNodeState.m_total_complexity)) ){
						curNodeState.m_parent_index = cast(short)(parentIndex);
						curNodeState.m_parent_state_index = cast(short)(parentStateIndex);
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
				ref NodeState curNodeState = m_node_states[insertIndex - 1];
				
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
			
			ref NodeState *newNodeState = m_node_states[insertIndex];
			newNodeState.m_parent_index = cast(short)(parentIndex);
			newNodeState.m_parent_state_index = cast(short)(parentStateIndex);
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
		
		LZDecision[] m_temp_decisions;
		
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
		if ((m_params.m_lzham_compress_flags & LZHAM_COMP_FLAG_WRITE_ZLIB_STREAM) == 0)
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
		if (!m_comp_buf.try_push_back(cast(ubyte)(cmf)))
			return false;
		if (!m_comp_buf.try_push_back(cast(ubyte)(flg)))
			return false;
		
		if (m_params.m_pSeed_bytes){
			// send adler32 of DICT
			uint dictAdler32 = adler32(m_params.m_pSeed_bytes, m_params.m_num_seed_bytes);
			for (uint i = 0; i < 4; i++)
			{
				if (!m_comp_buf.try_push_back(cast(ubyte)(dictAdler32 >> 24)))
					return false;
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
	bool extreme_parse(ParseThreadState parseState){
		assert(parseState.m_bytes_to_match <= cMaxParseGraphNodes);
		
		parseState.m_failed = false;
		parseState.m_emit_decisions_backwards = true;
		
		Node* pNodes = parseState.m_nodes.ptr;
		for (uint i = 0; i <= cMaxParseGraphNodes; i++){
			pNodes[i].clear();
		}

		State approxState = parseState.m_initial_state;
		
		pNodes[0].m_num_node_states = 1;
		ref NodeState firstNodeState = pNodes[0].m_node_states[0];
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
				const DictMatch* pMatches = m_accel.find_matches(curLookaheadOfs);
				if (pMatches){
					for ( ; ; ){
						uint matchLen = pMatches->get_len();
						assert((pMatches->get_dist() > 0) && (pMatches->get_dist() <= m_dict_size));
						//matchLen = LZHAM_MIN(matchLen, maxAdmissableMatchLen);
						matchLen = matchLen > maxAdmissableMatchLen ? maxAdmissableMatchLen : matchLen;
						
						if (matchLen > maxFullMatchLen){
							maxFullMatchLen = matchLen;
							
							matchLens[numFullMatches] = matchLen;
							matchDistances[numFullMatches] = pMatches->get_dist();
							numFullMatches++;
						}
						
						if (pMatches->is_last())
							break;
						pMatches++;
					}
				}
				
				len2MatchDist = m_accel.get_len2_match(curLookaheadOfs);
			}
			
			for (uint curNodeStateIndex = 0; curNodeStateIndex < curNode.m_num_node_states; curNodeStateIndex++){
				ref NodeState curNodeState = curNode.m_node_states[curNodeStateIndex];

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
						
						approxState.get_rep_match_costs(curDictOfs, lzdec_bitcosts, repMatchIndex, matchHistMinMatchLen, histMatchLen, isMatchModelIndex);
						
						uint repMatchTotalComplexity = curNodeTotalComplexity + (cRep0Complexity + repMatchIndex);
						for (uint l = matchHistMinMatchLen; l <= histMatchLen; l++){
							ref Node dstNode = curNode[l];
							
							ulong repMatchTotalCost = curNodeTotalCost + lzdec_bitcosts[l];
							
							dstNode.add_state(curNodeIndex, curNodeStateIndex, lzdecision(curDictOfs, l, -1 * (cast(int)repMatchIndex + 1)), approxState, repMatchTotalCost, repMatchTotalComplexity);
						}
					}
					
					matchHistMinMatchLen = CLZBase.cMinMatchLen;
				}
				
				uint minTruncateMatchLen = matchHistMaxLen;
				
				// nearest len2 match
				if (len2MatchDist){
					LZDecision lzdec = LZDecision(cur_dict_ofs, 2, len2MatchDist);
					ulong actualCost = approxState.get_cost(*this, m_accel, lzdec);
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
						
						approxState.get_full_match_costs(*this, curDictOfs, lzdec_bitcosts, matchDist, startLen, endLen, isMatchModelIndex);
						
						for (uint l = startLen; l <= endLen; l++){
							uint matchComplexity = (l >= cLongMatchComplexityLenThresh) ? cLongMatchComplexity : cShortMatchComplexity;

							ref Node dstNode = curNode[l];
							
							ulong matchTotalCost = curNodeTotalCost + lzdec_bitcosts[l];
							uint matchTotalComplexity = curNodeTotalComplexity + matchComplexity;
							
							dstNode.add_state( curNodeIndex, curNodeStateIndex, lzdecision(curDictOfs, l, matchDist), approxState, matchTotalCost, matchTotalComplexity);
						}
						
						prevMaxMatchLen = endLen;
					}
				}
				
				// literal
				ulong litCost = approxState.get_lit_cost(*this, m_accel, curDictOfs, litPred0, isMatchModelIndex);
				ulong litTotalCost = curNodeTotalCost + litCost;
				uint litTotalComplexity = curNodeTotalComplexity + cLitComplexity;

				
				curNode[1].add_state( curNodeIndex, curNodeStateIndex, lzdecision(curDictOfs, 0, 0), approxState, litTotalCost, litTotalComplexity);
				
			} // cur_node_state_index
			
			curDictOfs++;
			curLookaheadOfs++;
			curNodeIndex++;
		}
		
		// Now get the optimal decisions by starting from the goal node.
		// m_best_decisions is filled backwards.
		if (!parseState.m_best_decisions.try_reserve(bytesToParse))
		{
			parseState.m_failed = true;
			return false;
		}
		
		ulong lowestFinalCost = cBitCostMax; //math::cNearlyInfinite;
		int nodeStateIndex = 0;
		NodeState* lastNodeStates = pNodes[bytesToParse].m_node_states;
		for (uint i = 0; i < pNodes[bytesToParse].m_num_node_states; i++){
			if (lastNodeStates[i].m_total_cost < lowestFinalCost){
				lowestFinalCost = lastNodeStates[i].m_total_cost;
				nodeStateIndex = i;
			}
		}
		
		int nodeIndex = bytesToParse;
		LZDecision *dstDec = parseState.m_best_decisions.get_ptr();
		do{
			LZHAM_ASSERT((nodeIndex >= 0) && (nodeIndex <= cast(int)cMaxParseGraphNodes));
			
			ref Node curNode = pNodes[nodeIndex];
			const ref NodeState curNodeState = curNode.m_node_states[nodeStateIndex];
			
			*dstDec++ = curNodeState.m_lzdec;
			
			nodeIndex = curNodeState.m_parent_index;
			nodeStateIndex = curNodeState.m_parent_state_index;
			
		} while (nodeIndex > 0);
		
		parseState.m_best_decisions.try_resize(static_cast<uint>(dstDec - parseState.m_best_decisions.get_ptr()));
		
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
	bool optimal_parse(ParseThreadState parseState){
		assert(parseState.m_bytes_to_match <= cMaxParseGraphNodes);
		
		parseState.m_failed = false;
		parseState.m_emit_decisions_backwards = true;
		
		NodeState *pNodes = cast(NodeState*)(parseState.m_nodes);
		pNodes[0].m_parent_index = -1;
		pNodes[0].m_total_cost = 0;
		pNodes[0].m_total_complexity = 0;

		memset( &pNodes[1], 0xFF, cMaxParseGraphNodes * sizeof(node_state));

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
				assert(pCurNode->m_parent_index >= 0);
				
				// Move to this node's state using the lowest cost LZ decision found.
				approxState.restore_partial_state(pCurNode->m_saved_state);
				approxState.partial_advance(pCurNode->m_lzdec);
			}
			
			const ulong curNodeTotalCost = pCurNode.m_total_cost;
			// This assert includes a fudge factor - make sure we don't overflow our scaled costs.
			assert((cBitCostMax - curNodeTotalCost) > (cBitCostScale * 64));
			const uint curNodeTotalComplexity = pCurNode->m_total_complexity;
			
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
					
					approxState.get_rep_match_costs(curDictOfs, lzdecBitcosts, repMatchIndex, matchHistMinMatchLen, histMatchLen, isMatchModelIndex);
					
					uint rep_match_total_complexity = curNodeTotalComplexity + (cRep0Complexity + repMatchIndex);
					for (uint l = matchHistMinMatchLen; l <= histMatchLen; l++){
/*#if LZHAM_VERIFY_MATCH_COSTS
						{
							lzdecision actual_dec(cur_dict_ofs, l, -((int)rep_match_index + 1));
							bit_cost_t actual_cost = approx_state.get_cost(*this, m_accel, actual_dec);
							LZHAM_ASSERT(actual_cost == lzdec_bitcosts[l]);
						}
#endif*/
						ref NodeState dstNode = pCurNode[l];

						ulong repMatchTotalCost = curNodeTotalCost + lzdecBitcosts[l];
						
						if ((repMatchTotalCost > dstNode.m_total_cost) || ((repMatchTotalCost == dstNode.m_total_cost) && (rep_match_total_complexity >= dstNode.m_total_complexity)))
							continue;
						
						dstNode.m_total_cost = repMatchTotalCost;
						dstNode.m_total_complexity = rep_match_total_complexity;
						dstNode.m_parent_index = cast(ushort)curNodeIndex;
						approxState.save_partial_state(dstNode.m_saved_state);
						dstNode.m_lzdec.init(curDictOfs, l, -1 * (cast(int)repMatchIndex + 1));
						dstNode.m_lzdec.m_len = l;
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
						ulong cost = approxState.get_len2_match_cost(*this, curDictOfs, len2MatchDist, isMatchModelIndex);
						
/*#if LZHAM_VERIFY_MATCH_COSTS
						{
							lzdecision actual_dec(cur_dict_ofs, 2, len2_match_dist);
							bit_cost_t actual_cost = approx_state.get_cost(*this, m_accel, actual_dec);
							LZHAM_ASSERT(actual_cost == cost);
						}
#endif*/
						
						ref NodeState dstNode = pCurNode[2];
						
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
				const DictMatch* pMatches = m_accel.find_matches(curLookaheadOfs);
				if (pMatches){
					for ( ; ; ){
						uint match_len = pMatches->get_len();
						LZHAM_ASSERT((pMatches->get_dist() > 0) && (pMatches->get_dist() <= m_dict_size));
						match_len = LZHAM_MIN(match_len, maxAdmissableMatchLen);
						
						if (match_len > maxMatchLen){
							maxMatchLen = match_len;
							
							matchLens[numFullMatches] = match_len;
							matchDistances[numFullMatches] = pMatches->get_dist();
							numFullMatches++;
						}
						
						if (pMatches->is_last())
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
						
						approxState.get_full_match_costs(*this, curDictOfs, lzdecBitcosts, matchDist, startLen, endLen, isMatchModelIndex);
						
						for (uint l = startLen; l <= endLen; l++){
							uint match_complexity = (l >= cLongMatchComplexityLenThresh) ? cLongMatchComplexity : cShortMatchComplexity;
							
/*#if LZHAM_VERIFY_MATCH_COSTS
							{
								lzdecision actual_dec(cur_dict_ofs, l, match_dist);
								bit_cost_t actual_cost = approx_state.get_cost(*this, m_accel, actual_dec);
								LZHAM_ASSERT(actual_cost == lzdec_bitcosts[l]);
							}
#endif*/
							ref NodeState dstNode = pCurNode[l];
							
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
			ulong litCost = approxState.get_lit_cost(*this, m_accel, curDictOfs, litPred0, isMatchModelIndex);
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
				pCurNode[1].m_parent_index = (int16)curNodeIndex;
				approxState.save_partial_state(pCurNode[1].m_saved_state);
				pCurNode[1].m_lzdec.init(curDictOfs, 0, 0);
			}
			
			curDictOfs++;
			curLookaheadOfs++;
			curNodeIndex++;
			
		} // graph search
		
		// Now get the optimal decisions by starting from the goal node.
		// m_best_decisions is filled backwards.
		if (!parseState.m_best_decisions.try_reserve(bytesToParse)){
			parseState.m_failed = true;
			return false;
		}
		
		int nodeIndex = bytesToParse;
		LZDecision dstDec = parseState.m_best_decisions.get_ptr();
		do{
			assert((nodeIndex >= 0) && (nodeIndex <= cast(int)cMaxParseGraphNodes));
			node_state& cur_node = pNodes[nodeIndex];
			
			*dstDec++ = cur_node.m_lzdec;
			
			nodeIndex = cur_node.m_parent_index;
			
		} while (nodeIndex > 0);
		
		parseState.m_best_decisions.try_resize(static_cast<uint>(dstDec - parseState.m_best_decisions.get_ptr()));
		
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

			lzpriced_decision& lit_dec = decisions[0];
			lit_dec.init(ofs, 0, 0, 0);
			lit_dec.m_cost = curState.get_cost(*this, m_accel, lit_dec);
			largestCost = lit_dec.m_cost;
			
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
				
				LZPricedDecision dec = new LZPricedDecision(ofs, hist_match_len, -1 * (cast(int)i + 1));
				dec.m_cost = curState.get_cost(*this, m_accel, dec);
				
				if (!decisions.try_push_back(dec))
					return -1;
				
				if ( (histMatchLen > largestLen) || ((histMatchLen == largestLen) && (dec.m_cost < largestCost)) ){
					largestIndex = decisions.size() - 1;
					largestLen = histMatchLen;
					largestCost = dec.m_cost;
				}
			}
		}
		
		// Now add full matches.
		if ((maxMatchLen >= CLZBase.cMinMatchLen) && (matchHistMaxLen < m_settings.m_fast_bytes)){
			const DictMatch* pMatches = m_accel.find_matches(lookaheadOfs);

			if (pMatches){
				for ( ; ; ){
					//uint match_len = math::minimum(pMatches->get_len(), maxMatchLen);
					uint matchLen = pMatches.get_len() > maxMatchLen ? maxMatchLen : pMatches.get_len();
					assert((pMatches->get_dist() > 0) && (pMatches->get_dist() <= m_dict_size));
					
					// Full matches are very likely to be more expensive than rep matches of the same length, so don't bother evaluating them.
					if ((matchLen >= minMatchLen) && (matchLen > matchHistMaxLen)){
						if ((maxMatchLen > CLZBase.cMaxMatchLen) && (matchLen == CLZBase.cMaxMatchLen)){
							matchLen = m_accel.get_match_len(lookaheadOfs, pMatches->get_dist(), maxMatchLen, CLZBase.cMaxMatchLen);
						}
						
						LZPricedDecision dec = new LZPricedDecision(ofs, matchLen, pMatches.get_dist());
						dec.m_cost = curState.get_cost(*this, m_accel, dec);
						
						if (!decisions.try_push_back(dec))
							return -1;
						
						if ( (matchLen > largestLen) || ((matchLen == largestLen) && (dec.get_cost() < largestCost)) ){
							largestIndex = decisions.size() - 1;
							largestLen = matchLen;
							largestCost = dec.get_cost();
						}
					}
					if (pMatches->is_last())
						break;
					pMatches++;
				}
			}
		}
		
		return largestIndex;
	}
	bool greedy_parse(ParseThreadState parseState){
		parseState.m_failed = true;
		parseState.m_emit_decisions_backwards = false;
		
		const uint bytesToParse = parseState.m_bytes_to_match;
		
		const uint lookaheadStartOfs = m_accel.get_lookahead_pos() & m_accel.get_max_dict_size_mask();
		
		uint curDictOfs = parseState.m_start_ofs;
		uint curLookaheadOfs = curDictOfs - lookaheadStartOfs;
		uint curOfs = 0;
		
		ref State approxState = parseState.m_initial_state;
		
		ref LZPricedDecision[] decisions = parseState.m_temp_decisions;
		
		if (!decisions.try_reserve(384))
			return false;
		
		if (!parseState.m_best_decisions.try_resize(0))
			return false;
		
		while (curOfs < bytesToParse){
			const uint max_admissable_match_len = LZHAM_MIN(static_cast<uint>(CLZBase::cMaxHugeMatchLen), bytesToParse - curOfs);
			
			int largest_dec_index = enumerate_lz_decisions(curDictOfs, approxState, decisions, 1, max_admissable_match_len);
			if (largest_dec_index < 0)
				return false;
			
			const ref LZPricedDecision dec = decisions[largest_dec_index];
			
			if (!parseState.m_best_decisions.try_push_back(dec))
				return false;
			
			approxState.partial_advance(dec);
			
			uint matchLen = dec.get_len();
			assert(matchLen <= max_admissable_match_len);
			curDictOfs += matchLen;
			curLookaheadOfs += matchLen;
			curOfs += matchLen;
			
			if (parseState.m_best_decisions.size() >= parseState.m_max_greedy_decisions){
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
		
		ref ParseThreadState parseState = m_parse_thread_state[parseJobIndex];
		
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
	bool compress_block(const void* pBuf, uint bufLen){
		uint curOfs = 0;
		uint bytesRemaining = bufLen;
		while (bytesRemaining){
			//uint bytes_to_compress = math::minimum(m_accel.get_max_add_bytes(), bytesRemaining);
			uint bytesToCompress = m_accel.get_max_add_bytes() > bytesRemaining ? bytesRemaining : m_accel.get_max_add_bytes();
			if (!compress_block_internal(cast(const ubyte*)(pBuf) + curOfs, bytesToCompress))
				return false;
			
			curOfs += bytesToCompress;
			bytesRemaining -= bytesToCompress;
		}
		return true;
	}
	void update_block_history(uint compSize, uint srcSize, uint ratio, bool rawBlock, bool resetUpdateRate){
		ref BlockHistory curBlockHistory = m_block_history[m_block_history_next];
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
	bool compress_block_internal(const void* pBuf, uint bufLen){
		//scoped_perf_section compress_block_timer(cVarArgs, "****** compress_block %u", m_block_index);
		
		assert(pBuf);
		assert(bufLen <= m_params.m_block_size);
		
		assert(m_src_size >= 0);
		if (m_src_size < 0)
			return false;
		
		m_src_size += bufLen;
		
		// Important: Don't do any expensive work until after add_bytes_begin() is called, to increase parallelism.
		if (!m_accel.add_bytes_begin(bufLen, static_cast<const uint8*>(pBuf)))
			return false;
		
		m_start_of_block_state = m_state;
		
		m_src_adler32 = adler32(pBuf, bufLen, m_src_adler32);
		
		m_block_start_dict_ofs = m_accel.get_lookahead_pos() & (m_accel.get_max_dict_size() - 1);
		
		uint curDictOfs = m_block_start_dict_ofs;
		
		uint bytesToMatch = bufLen;
		
		if (!m_codec.startEncoding((bufLen * 9) / 8))
			return false;
		
		if (!m_block_index){
			if (!send_configuration())
				return false;
		}

		if (!m_codec.encode_bits(cCompBlock, cBlockHeaderBits))
			return false;
		
		if (!m_codec.encode_arith_init())
			return false;
		
		m_state.start_of_block(m_accel, curDictOfs, m_block_index);
		
		bool emitResetUpdateRateCommand = false;
		
		// Determine if it makes sense to reset the Huffman table update frequency back to their initial (maximum) rates.
		if ((m_block_history_size) && (m_params.m_lzham_compress_flags & LZHAMCompressFlags.TRADEOFF_DECOMPRESSION_RATE_FOR_COMP_RATIO)){
			const ref BlockHistory prevBlockHistory = m_block_history[m_block_history_next ? (m_block_history_next - 1) : (cMaxBlockHistorySize - 1)];
			
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
		
		m_codec.encode_bits(emitResetUpdateRateCommand ? 1 : 0, cBlockFlushTypeBits);
		
		//coding_stats initial_stats(m_stats);
		
		uint initialStep = m_step;
		
		while (bytesToMatch){
			const uint cAvgAcceptableGreedyMatchLen = 384;
			if ((m_params.m_pSeed_bytes) && (bytesToMatch >= cAvgAcceptableGreedyMatchLen)){
				ref ParseThreadState greedyParseState = m_parse_thread_state[cMaxParseThreads];
				
				greedyParseState.m_initial_state = m_state;
				greedyParseState.m_initial_state.m_cur_ofs = curDictOfs;
				
				greedyParseState.m_issue_reset_state_partial = false;
				greedyParseState.m_start_ofs = curDictOfs;
				//greedyParseState.m_bytes_to_match = LZHAM_MIN(bytesToMatch, static_cast<uint>(CLZBase::cMaxHugeMatchLen));
				greedyParseState.m_bytes_to_match = bytesToMatch > cast(uint)(CLZBase.cMaxHugeMatchLen) ? cast(uint)(CLZBase.cMaxHugeMatchLen) : bytesToMatch;

				greedyParseState.m_max_greedy_decisions = LZHAM_MAX((bytesToMatch / cAvgAcceptableGreedyMatchLen), 2);
				greedyParseState.m_greedy_parse_gave_up = false;
				greedyParseState.m_greedy_parse_total_bytes_coded = 0;
				
				if (!greedy_parse(greedyParseState))
				{
					if (!greedyParseState.m_greedy_parse_gave_up)
						return false;
				}
				
				uint numGreedyDecisionsToCode = 0;
				
				const ref LZDecision[] bestDecisions = greedyParseState.m_best_decisions; 
				
				if (!greedyParseState.m_greedy_parse_gave_up)
					numGreedyDecisionsToCode = bestDecisions.size();
				else{
					uint numSmallDecisions = 0;
					uint totalMatchLen = 0;
					uint maxMatchLen = 0;
					
					uint i;
					for (i = 0; i < bestDecisions.size(); i++){
						const ref LZDecision dec = bestDecisions[i];
						if (dec.get_len() <= CLZBase.cMaxMatchLen){
							numSmallDecisions++;
							if (numSmallDecisions > 16)
								break;
						}
						
						totalMatchLen += dec.get_len();
						//maxMatchLen = LZHAM_MAX(maxMatchLen, dec.get_len());
						maxMatchLen = maxMatchLen > dec.get_len() ? maxMatchLen : dec.get_len();
					}
					
					if (maxMatchLen > CLZBase.cMaxMatchLen){
						if ((totalMatchLen / i) >= cAvgAcceptableGreedyMatchLen){
							numGreedyDecisionsToCode = i;
						}
					}
				}
				
				if (numGreedyDecisionsToCode){
					for (uint i = 0; i < numGreedyDecisionsToCode; i++){
						assert(bestDecisions[i].m_pos == cast(int)curDictOfs);
						//LZHAM_ASSERT(i >= 0);
						assert(i < bestDecisions.size());
						
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
			
			uint numParseJobs = LZHAM_MIN(m_num_parse_threads, (bytesToMatch + cMaxParseGraphNodes - 1) / cMaxParseGraphNodes);
			if ((m_params.m_lzham_compress_flags & LZHAMCompressFlags.DETERMINISTIC_PARSING) == 0){
				if (m_use_task_pool && m_accel.get_max_helper_threads()){
					// Increase the number of active parse jobs as the match finder finishes up to keep CPU utilization up.
					numParseJobs += m_accel.get_num_completed_helper_threads();
					numParseJobs = LZHAM_MIN(numParseJobs, cMaxParseThreads);
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
				parseThreadTotalSize = parseThreadTotalSize > 1536 ? 1536 ? parseThreadTotalSize;
			}
			
			uint parseThreadRemaining = parseThreadTotalSize;
			for (uint parseThreadIndex = 0; parseThreadIndex < numParseJobs; parseThreadIndex++){
				ref ParseThreadState parseThread = m_parse_thread_state[parseThreadIndex];
				
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
					
					parse_job_callback(0, NULL);
					
					{
						//scoped_perf_section wait_timer("waiting for jobs");
						
						m_parse_jobs_complete.wait();
					}
				}else{
					m_parse_jobs_remaining = int.max;
					for (uint parseThreadIndex = 0; parseThreadIndex < numParseJobs; parseThreadIndex++){
						parse_job_callback(parseThreadIndex, NULL);
					}
				}
			}
			
			{
				//scoped_perf_section coding_timer("coding");
				
				for (uint parse_thread_index = 0; parse_thread_index < numParseJobs; parse_thread_index++){
					ref ParseThreadState parseThread = m_parse_thread_state[parse_thread_index];
					if (parseThread.m_failed)
						return false;
					
					const ref LZDecision bestDecisions = parseThread.m_best_decisions;
					
					if (parseThread.m_issue_reset_state_partial){
						if (!m_state.encode_reset_state_partial(m_codec, m_accel, curDictOfs))
							return false;
						m_step++;
					}
					
					if (bestDecisions.size()){
						int i = 0;
						int endDecIndex = cast(int)(bestDecisions.size()) - 1;
						int decStep = 1;
						if (parseThread.m_emit_decisions_backwards){
							i = cast(int)(bestDecisions.size()) - 1;
							endDecIndex = 0;
							decStep = -1;
							assert(bestDecisions.back().m_pos == cast(int)parseThread.m_start_ofs);
						}else{
							assert(bestDecisions.front().m_pos == cast(int)parseThread.m_start_ofs);
						}
						
						// Loop rearranged to avoid bad x64 codegen problem with MSVC2008.
						for ( ; ; ){
							assert(bestDecisions[i].m_pos == cast(int)curDictOfs);
							assert(i >= 0);
							assert(i < cast(int)bestDecisions.size());
							
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
			if (!m_codec.stop_encoding(true)) return false;
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
			
			if (!m_codec.encode_bits(cRawBlock, cBlockHeaderBits))
				return false;
			
			assert(bufLen <= 0x1000000);
			if (!m_codec.encode_bits(bufLen - 1, 24))
				return false;
			
			// Write buf len check bits, to help increase the probability of detecting corrupted data more early.
			uint bufLen0 = (bufLen - 1) & 0xFF;
			uint bufLen1 = ((bufLen - 1) >> 8) & 0xFF;
			uint bufLen2 = ((bufLen - 1) >> 16) & 0xFF;
			if (!m_codec.encode_bits((bufLen0 ^ bufLen1) ^ bufLen2, 8))
				return false;
			
			if (!m_codec.encode_align_to_byte())
				return false;
			
			const ubyte* pSrc = m_accel.get_ptr(m_block_start_dict_ofs);
			
			for (uint i = 0; i < bufLen; i++){
				if (!m_codec.encode_bits(*pSrc++, 8))
					return false;
			}
			
			if (!m_codec.stop_encoding(true))
				return false;
			
			usedRawBlock = true;
			emitResetUpdateRateCommand = false;
		}
		
		uint compSize = m_codec.get_encoding_buf().size();
		uint scaledRatio =  (compSize * cBlockHistoryCompRatioScale) / bufLen;
		update_block_history(compSize, bufLen, scaledRatio, usedRawBlock, emitResetUpdateRateCommand);
		
		//printf("\n%u, %u, %u, %u\n", m_block_index, 500*emit_reset_update_rate_command, scaled_ratio, get_recent_block_ratio());
		
		{
			//scoped_perf_section append_timer("append");
			
			if (m_comp_buf.empty()){
				m_comp_buf.swap(m_codec.get_encoding_buf());
			}else{
				if (!m_comp_buf.append(m_codec.get_encoding_buf()))
					return false;
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
		const uint len = lzdec.get_len();
		
		if (!m_state.encode(m_codec, *this, m_accel, lzdec))
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

		if (!m_codec.encode_bits(cSyncBlock, cBlockHeaderBits))
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
		if (!m_codec.stopDecoding(true))
			return false;
		if (!m_comp_buf.append(m_codec.get_encoding_buf()))
			return false;
		
		m_block_index++;
		return true;
	}
	
	bool init(const InitParams params){
		clear();
		
		if ((params.m_dict_size_log2 < CLZBase.cMinDictSizeLog2) || (params.m_dict_size_log2 > CLZBase.cMaxDictSizeLog2))
			return false;
		if ((params.m_compression_level < 0) || (params.m_compression_level > cCompressionLevelCount))
			return false;
		
		this.m_params = params;
		m_use_task_pool = (m_params.m_pTask_pool) && (m_params.m_pTask_pool->get_num_threads() != 0) && (m_params.m_max_helper_threads > 0);
		
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
		
		if (!m_accel.init(this, params.m_pTask_pool, matchAccelHelperThreads, dictSize, m_settings.m_match_accel_max_matches_per_probe, false, m_settings.m_match_accel_max_probes))
			return false;
		
		init_position_slots(params.m_dict_size_log2);
		init_slot_tabs();
		
		//m_settings.m_fast_adaptive_huffman_updating
		if (!m_state.init(*this, m_params.m_table_max_update_interval, m_params.m_table_update_interval_slow_rate))
			return false;
		
		if (!m_block_buf.try_reserve(m_params.m_block_size))
			return false;
		
		if (!m_comp_buf.try_reserve(m_params.m_block_size*2))
			return false;
		
		for (uint i = 0; i < m_num_parse_threads; i++){
			//m_settings.m_fast_adaptive_huffman_updating
			if (!m_parse_thread_state[i].m_initial_state.init(*this, m_params.m_table_max_update_interval, m_params.m_table_update_interval_slow_rate))
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
		m_src_adler32 = cInitAdler32;
		m_block_buf.clear();
		m_comp_buf.clear();
		
		m_step = 0;
		m_finished = false;
		m_use_task_pool = false;
		m_block_start_dict_ofs = 0;
		m_block_index = 0;
		m_state.clear();
		m_num_parse_threads = 0;
		m_parse_jobs_remaining = 0;
		
		for (uint i = 0; i < cMaxParseThreads; i++){
			parse_thread_state &parse_state = m_parse_thread_state[i];
			parse_state.m_initial_state.clear();
			
			for (uint j = 0; j <= cMaxParseGraphNodes; j++)
				parse_state.m_nodes[j].clear();
			
			parse_state.m_start_ofs = 0;
			parse_state.m_bytes_to_match = 0;
			parse_state.m_best_decisions.clear();
			parse_state.m_issue_reset_state_partial = false;
			parse_state.m_emit_decisions_backwards = false;
			parse_state.m_failed = false;
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
		if (m_block_buf.size()){
			status = compress_block(m_block_buf.get_ptr(), m_block_buf.size());

			m_block_buf.length = 0;
		}
		
		if (status){
			status = send_sync_block(flushType);
			
			if (LZHAM_FULL_FLUSH == flushType)
			{
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
		m_src_adler32 = cInitAdler32;
		m_block_buf.try_resize(0);
		m_comp_buf.try_resize(0);
		
		m_step = 0;
		m_finished = false;
		m_block_start_dict_ofs = 0;
		m_block_index = 0;
		m_state.reset();
		
		m_block_history_size = 0;
		m_block_history_next = 0;
		
		if (m_params.m_num_seed_bytes)
		{
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
			if (m_block_buf.size()){
				status = compress_block(m_block_buf.get_ptr(), m_block_buf.size());
				
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
			const uint8 *pSrcBuf = cast(const ubyte*)(pBuf);
			uint numSrcBytesRemaining = bufLen;
			
			while (numSrcBytesRemaining){
				//const uint num_bytes_to_copy = LZHAM_MIN(numSrcBytesRemaining, m_params.m_block_size - m_block_buf.size());
				uint helperVal = m_params.m_block_size - m_block_buf.size();
				const uint numBytesToCopy = numSrcBytesRemaining > helperVal ? helperVal : numSrcBytesRemaining;
				
				if (numBytesToCopy == m_params.m_block_size){
					assert(!m_block_buf.size());
					
					// Full-block available - compress in-place.
					status = compress_block(pSrcBuf, numBytesToCopy);
				}else{
					// Less than a full block available - append to already accumulated bytes.
					if (!m_block_buf.append(cast(const ubyte*)(pSrcBuf), numBytesToCopy))
						return false;
					
					assert(m_block_buf.size() <= m_params.m_block_size);
					
					if (m_block_buf.size() == m_params.m_block_size){
						status = compress_block(m_block_buf.get_ptr(), m_block_buf.size());
						
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
	
	const ref ubyte[] get_compressed_data() const{ 
		return m_comp_buf; 
	}
	ref ubyte[] get_compressed_data(){ 
		return m_comp_buf; 
	}
	
	uint get_src_adler32() const { 
		return m_src_adler32; 
	}
}