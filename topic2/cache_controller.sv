`timescale 1ns/1ps

// =============================================================================
// cache_controller.sv
//
// 32 KiB | 4-way set-associative | 8-word block | 32-bit word
// Write-back | Write-allocate | LRU replacement
//
// Address layout  [20:11] tag (10b) | [10:3] index (8b) | [2:0] offset (3b)
// Memory address = {tag, index} = 18 bits  (unchanged from direct-mapped)
// =============================================================================

module cache_controller
  #(
    parameter BLOCK_SIZE    = 256,   // bits  (8 words × 32 bits)
    parameter ADDRESS_WIDTH = 21,    // bits
    parameter INDEX_WIDTH   = 8,     // bits  ? 256 sets
    parameter TAG_WIDTH     = 10,    // bits
    parameter OFFSET_WIDTH  = 3,     // bits  ? 8 words/block
    parameter WORD_SIZE     = 32,    // bits
    parameter NSETS         = 256,   // 2^INDEX_WIDTH
    parameter WAYS          = 4
  )
  (
    input  logic                                  clock,
    input  logic                                  rst_n,

    // CPU-side
    input  logic [ADDRESS_WIDTH-1:0]              caddress,
    input  logic [WORD_SIZE-1:0]                  cdin,
    input  logic                                  rden,
    input  logic                                  wren,
    output logic                                  hit,
    output logic [WORD_SIZE-1:0]                  cdout,

    // Memory-side
    input  logic [BLOCK_SIZE-1:0]                 mdin,
    output logic [BLOCK_SIZE-1:0]                 mdout,
    output logic [TAG_WIDTH+INDEX_WIDTH-1:0]      maddress,
    output logic                                  mrden,
    output logic                                  mwren
  );

  // ---------------------------------------------------------------------------
  // Address field positions
  // ---------------------------------------------------------------------------
  localparam TAG_MSB          = 20;
  localparam TAG_LSB          = 11;
  localparam INDEX_MSB        = 10;
  localparam INDEX_LSB        = 3;
  localparam BLOCK_OFFSET_MSB = 2;
  localparam BLOCK_OFFSET_LSB = 0;

  // ---------------------------------------------------------------------------
  // FSM states (identical to direct-mapped version)
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    STATE_IDLE,
    STATE_READ_HIT,
    STATE_READ_MISS,
    STATE_WRITE_HIT,
    STATE_WRITE_MISS,
    STATE_REPLACE,
    STATE_FETCH,
    STATE_FILL
  } state_t;

  state_t current_state, next_state;

  // ---------------------------------------------------------------------------
  // Cache arrays  [set][way]
  // ---------------------------------------------------------------------------
  logic                  cache_valid [0:NSETS-1][0:WAYS-1];
  logic                  cache_dirty [0:NSETS-1][0:WAYS-1];
  logic [TAG_WIDTH-1:0]  cache_tag   [0:NSETS-1][0:WAYS-1];
  logic [BLOCK_SIZE-1:0] cache_mem   [0:NSETS-1][0:WAYS-1];

  // LRU age counters: 2-bit age per way per set.
  // age == WAYS-1 (2'b11) ? least recently used (victim).
  // age == 0              ? most recently used.
  logic [1:0] lru_age [0:NSETS-1][0:WAYS-1];

  // ---------------------------------------------------------------------------
  // Latched request registers
  // ---------------------------------------------------------------------------
  logic [ADDRESS_WIDTH-1:0] req_addr;
  logic                     req_read;
  logic                     req_write;
  logic [WORD_SIZE-1:0]     req_wdata;
  logic [1:0]               req_victim; // victim way snapshotted at request time

  // ---------------------------------------------------------------------------
  // Active address decode
  // ---------------------------------------------------------------------------
  logic [ADDRESS_WIDTH-1:0] active_addr;
  logic [INDEX_WIDTH-1:0]   active_index;
  logic [TAG_WIDTH-1:0]     active_tag;
  logic [OFFSET_WIDTH-1:0]  active_offset;

  assign active_addr   = (current_state == STATE_IDLE) ? caddress : req_addr;
  assign active_index  = active_addr[INDEX_MSB:INDEX_LSB];
  assign active_tag    = active_addr[TAG_MSB:TAG_LSB];
  assign active_offset = active_addr[BLOCK_OFFSET_MSB:BLOCK_OFFSET_LSB];

  // ---------------------------------------------------------------------------
  // Per-way hit detection
  // ---------------------------------------------------------------------------
  logic way_hit [0:WAYS-1];

  always_comb begin
    for (int w = 0; w < WAYS; w++)
      way_hit[w] = cache_valid[active_index][w] &&
                   (cache_tag[active_index][w] == active_tag);
  end

  logic      lookup_hit;
  logic [1:0] hit_way;

  always_comb begin
    lookup_hit = 1'b0;
    hit_way    = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (way_hit[w]) begin
        lookup_hit = 1'b1;
        hit_way    = w[1:0]; // FIXED: Replaced 2'(w) with standard bit slicing
      end
    end
  end

  // ---------------------------------------------------------------------------
  // LRU victim: way whose age == WAYS-1
  // ---------------------------------------------------------------------------
  logic [1:0] victim_way;

  always_comb begin
    victim_way = '0;
    for (int w = 0; w < WAYS; w++)
      if (lru_age[active_index][w] == (WAYS-1)) // FIXED: Removed explicit cast
        victim_way = w[1:0]; // FIXED: Replaced 2'(w) with w[1:0]
  end

  // ---------------------------------------------------------------------------
  // Helper functions (unchanged from original)
  // ---------------------------------------------------------------------------
  function automatic logic [WORD_SIZE-1:0] block_get_word(
    input logic [BLOCK_SIZE-1:0]  block,
    input logic [OFFSET_WIDTH-1:0] word_offset
  );
    return block[32 * word_offset +: WORD_SIZE];
  endfunction

  function automatic logic [BLOCK_SIZE-1:0] block_set_word(
    input logic [BLOCK_SIZE-1:0]  block,
    input logic [OFFSET_WIDTH-1:0] word_offset,
    input logic [WORD_SIZE-1:0]   word
  );
    logic [BLOCK_SIZE-1:0] result;
    result = block;
    result[32 * word_offset +: WORD_SIZE] = word;
    return result;
  endfunction

  logic [WORD_SIZE-1:0] read_data;

  assign read_data = block_get_word(cache_mem[active_index][hit_way], active_offset);

  // ---------------------------------------------------------------------------
  // Combinational FSM output + next-state  (structure identical to original)
  // ---------------------------------------------------------------------------
  always_comb begin
    next_state = current_state;
    hit        = 1'b0;
    cdout      = '0;
    mdout      = '0;
    maddress   = '0;
    mrden      = 1'b0;
    mwren      = 1'b0;

    case (current_state)

      STATE_IDLE: begin
        if      (rden && lookup_hit)  next_state = STATE_READ_HIT;
        else if (rden)                next_state = STATE_READ_MISS;
        else if (wren && lookup_hit)  next_state = STATE_WRITE_HIT;
        else if (wren)                next_state = STATE_WRITE_MISS;
      end

      STATE_READ_HIT: begin
        hit        = 1'b1;
        cdout      = read_data;
        next_state = STATE_IDLE;
      end

      // On a miss, check if the victim way is dirty before fetching
      STATE_READ_MISS: begin
        if (cache_dirty[active_index][req_victim]) next_state = STATE_REPLACE;
        else                                        next_state = STATE_FETCH;
      end

      STATE_WRITE_MISS: begin
        if (cache_dirty[active_index][req_victim]) next_state = STATE_REPLACE;
        else                                        next_state = STATE_FETCH;
      end

      // Write-back dirty victim to main memory
      STATE_REPLACE: begin
        mwren      = 1'b1;
        maddress   = {cache_tag[active_index][req_victim], active_index};
        mdout      = cache_mem[active_index][req_victim];
        next_state = STATE_FETCH;
      end

      // Issue memory read for the new block
      STATE_FETCH: begin
        mrden      = 1'b1;
        maddress   = {active_tag, active_index};
        next_state = STATE_FILL;
      end

      // Block has arrived on mdin; resume original operation next cycle
      STATE_FILL: begin
        if      (req_read)  next_state = STATE_READ_HIT;
        else if (req_write) next_state = STATE_WRITE_HIT;
        else                next_state = STATE_IDLE;
      end

      STATE_WRITE_HIT: begin
        hit        = 1'b1;
        next_state = STATE_IDLE;
      end

      default: next_state = STATE_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Initialisation (simulation only)
  // ---------------------------------------------------------------------------
  integer s, w;

  initial begin
    for (s = 0; s < NSETS; s++) begin
      for (w = 0; w < WAYS; w++) begin
        cache_valid[s][w] = 1'b0;
        cache_dirty[s][w] = 1'b0;
        cache_tag  [s][w] = '0;
        cache_mem  [s][w] = '0;
        lru_age    [s][w] = w[1:0]; // FIXED: Replaced 2'(w)
        // initial ages: 0,1,2,3
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Sequential block
  // ---------------------------------------------------------------------------
  always_ff @(posedge clock) begin
    if (!rst_n) begin
      current_state <= STATE_IDLE;
      req_read      <= 1'b0;
      req_write     <= 1'b0;

      for (int rs = 0; rs < NSETS; rs++) begin
        for (int rw = 0; rw < WAYS; rw++) begin
          cache_valid[rs][rw] <= 1'b0;
          cache_dirty[rs][rw] <= 1'b0;
          cache_tag  [rs][rw] <= '0;
          cache_mem  [rs][rw] <= '0;
          lru_age    [rs][rw] <= rw[1:0]; // FIXED: Replaced 2'(rw)
        end
      end
    end else begin
      current_state <= next_state;

      // --------------------------------------------------------------
      // Latch request when leaving IDLE
      // --------------------------------------------------------------
      if (current_state == STATE_IDLE && (rden || wren)) begin
        req_addr   <= caddress;
        req_read   <= rden;
        req_write  <= wren;
        req_wdata  <= cdin;
        req_victim <= victim_way; // snapshot LRU victim at request time
      end

      // --------------------------------------------------------------
      // FILL: install fetched block into the victim way
      // --------------------------------------------------------------
      if (current_state == STATE_FILL) begin
        cache_mem  [active_index][req_victim] <= mdin;
        cache_tag  [active_index][req_victim] <= active_tag;
        cache_valid[active_index][req_victim] <= 1'b1;
        cache_dirty[active_index][req_victim] <= 1'b0;
      end

      // --------------------------------------------------------------
      // WRITE_HIT: update word in hit way, mark dirty
      // --------------------------------------------------------------
      if (current_state == STATE_WRITE_HIT) begin
        cache_mem  [active_index][hit_way] <=
          block_set_word(cache_mem[active_index][hit_way], active_offset, req_wdata);
        cache_dirty[active_index][hit_way] <= 1'b1;
      end

      // --------------------------------------------------------------
      // LRU update on every completed access (READ_HIT or WRITE_HIT)
      // Accessed way ? age 0; ways younger than accessed way age by 1.
      // --------------------------------------------------------------
      if (current_state == STATE_READ_HIT || current_state == STATE_WRITE_HIT) begin
        for (int lw = 0; lw < WAYS; lw++) begin
          if (lw[1:0] == hit_way) // FIXED: Replaced 2'(lw)
            lru_age[active_index][lw] <= 2'd0;
          else if (lru_age[active_index][lw] < lru_age[active_index][hit_way])
            lru_age[active_index][lw] <= lru_age[active_index][lw] + 2'd1;
        end
      end

    end
  end

endmodule