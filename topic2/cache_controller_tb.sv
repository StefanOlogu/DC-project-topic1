`timescale 1ns/1ps

module cache_controller_tb;

   // -------------------------------------------------------------------------
   // Parameters – updated for 4-way set-associative
   // -------------------------------------------------------------------------
   localparam BLOCK_SIZE    = 256;
   localparam ADDRESS_WIDTH = 21;
   localparam INDEX_WIDTH   = 8;    // 256 sets
   localparam TAG_WIDTH     = 10;
   localparam OFFSET_WIDTH  = 3;
   localparam WORD_SIZE     = 32;
   localparam NSETS         = 256;
   localparam WAYS          = 4;
   localparam string MEM_FILE = "mem_data.txt";

   // Clock period 200 ns
   localparam int CLK_PERIOD_NS       = 200;
   // Read miss: IDLE -> MISS -> FETCH -> FILL -> READ_HIT -> IDLE  (6 cycles)
   localparam int MISS_LATENCY_CYCLES = 6;
   localparam int HIT_LATENCY_CYCLES  = 2;

   // -------------------------------------------------------------------------
   // Signals
   // -------------------------------------------------------------------------
   logic                                 clock;
   logic                                 rst_n;

   logic [ADDRESS_WIDTH-1:0]             caddress;
   logic [WORD_SIZE-1:0]                 cdin;
   logic [BLOCK_SIZE-1:0]                mdin;
   logic                                 rden;
   logic                                 wren;
   logic                                 hit;
   logic [WORD_SIZE-1:0]                 cdout;
   logic [BLOCK_SIZE-1:0]                mdout;
   logic [TAG_WIDTH+INDEX_WIDTH-1:0]     maddress;
   logic                                 mrden;
   logic                                 mwren;

   // -------------------------------------------------------------------------
   // Tasks
   // -------------------------------------------------------------------------
   task automatic wait_cycles(input int n);
      repeat (n) @(posedge clock);
   endtask

   task automatic cache_read(input logic [ADDRESS_WIDTH-1:0] addr,
                              input int wait_cycles_n);
      caddress <= addr;
      cdin     <= '0;
      rden     <= 1'b1;
      wren     <= 1'b0;
      wait_cycles(wait_cycles_n);
      rden     <= 1'b0;
      wren     <= 1'b0;
      wait_cycles(1);
   endtask

   task automatic cache_write(input logic [ADDRESS_WIDTH-1:0] addr,
                               input logic [WORD_SIZE-1:0]     data,
                               input int wait_cycles_n);
      caddress <= addr;
      cdin     <= data;
      rden     <= 1'b0;
      wren     <= 1'b1;
      wait_cycles(wait_cycles_n);
      rden     <= 1'b0;
      wren     <= 1'b0;
      wait_cycles(1);
   endtask

   // -------------------------------------------------------------------------
   // Clock generation
   // -------------------------------------------------------------------------
   initial begin
      $dumpfile("cache_controller_tb.vcd");
      $dumpvars;
   end

   always begin
      clock = 1'b1; #(CLK_PERIOD_NS / 2);
      clock = 1'b0; #(CLK_PERIOD_NS / 2);
   end

   // -------------------------------------------------------------------------
   // DUT instantiation
   // -------------------------------------------------------------------------
   cache_controller #(
      .BLOCK_SIZE   (BLOCK_SIZE),
      .ADDRESS_WIDTH(ADDRESS_WIDTH),
      .INDEX_WIDTH  (INDEX_WIDTH),
      .TAG_WIDTH    (TAG_WIDTH),
      .OFFSET_WIDTH (OFFSET_WIDTH),
      .WORD_SIZE    (WORD_SIZE),
      .NSETS        (NSETS),
      .WAYS         (WAYS)
   ) DUT_CACHE (
      .clock   (clock),
      .rst_n   (rst_n),
      .caddress(caddress),
      .cdin    (cdin),
      .mdin    (mdin),
      .rden    (rden),
      .wren    (wren),
      .hit     (hit),
      .cdout   (cdout),
      .mdout   (mdout),
      .maddress(maddress),
      .mrden   (mrden),
      .mwren   (mwren)
   );

   memory #(
      .FILE(MEM_FILE)
   ) DUT_MEM (
      .clock  (clock),
      .din    (mdout),
      .address(maddress),
      .rden   (mrden),
      .wren   (mwren),
      .dout   (mdin)
   );

   // -------------------------------------------------------------------------
   // Stimulus
   // -------------------------------------------------------------------------
   initial begin
      caddress = '0;
      cdin     = '0;
      rden     = 1'b0;
      wren     = 1'b0;
      rst_n    = 1'b0;

      wait_cycles(2);
      rst_n = 1'b1;
      wait_cycles(1);

      // ------------------------------------------------------------------
      // Test 1 – cold read miss, then repeated hits on the same block
      // Addresses 0x004..0x007 share set=0, tag=0, offsets 4..7
      // ------------------------------------------------------------------
      $display("\n=== TEST 1: Cold read miss + same-block hits ===");
      cache_read(21'h00004, MISS_LATENCY_CYCLES); // miss
      cache_read(21'h00004, HIT_LATENCY_CYCLES);  // hit (way 0)
      cache_read(21'h00005, HIT_LATENCY_CYCLES);  // hit – different offset
      cache_read(21'h00006, HIT_LATENCY_CYCLES);
      cache_read(21'h00007, HIT_LATENCY_CYCLES);

      // ------------------------------------------------------------------
      // Test 2 – write miss (write-allocate): fetch block, then write word
      // ------------------------------------------------------------------
      $display("\n=== TEST 2: Write miss (write-allocate) ===");
      // Address 0x100 → set=0x20, tag=0, offset=0  (different set)
      cache_write(21'h00100, 32'hDEADBEEF, MISS_LATENCY_CYCLES);
      // Read it back – should hit
      cache_read (21'h00100, HIT_LATENCY_CYCLES);

      // ------------------------------------------------------------------
      // Test 3 – write hit: block already in cache, just update word
      // ------------------------------------------------------------------
      $display("\n=== TEST 3: Write hit ===");
      cache_write(21'h00100, 32'hCAFEBABE, HIT_LATENCY_CYCLES);
      cache_read (21'h00100, HIT_LATENCY_CYCLES);

      // ------------------------------------------------------------------
      // Test 4 – fill all 4 ways of set 0, then trigger LRU eviction
      // Each address maps to set 0 (index bits [10:3] == 0) but has a
      // different tag (bits [20:11]).  Way ordering: 0,1,2,3 filled first.
      // A 5th address to set 0 must evict the LRU way (way 0).
      //
      // set 0: index field = 0 → addr bits [10:3] = 0
      //   tag 0 → addr = 21'b 0000_0000_00 | 00_0000_00 | 000 = 21'h00000
      //   tag 1 → addr bits [20:11]=1  → addr = 21'h00800
      //   tag 2 → addr bits [20:11]=2  → addr = 21'h01000
      //   tag 3 → addr bits [20:11]=3  → addr = 21'h01800
      //   tag 4 → addr bits [20:11]=4  → addr = 21'h02000 (evicts LRU)
      // ------------------------------------------------------------------
      $display("\n=== TEST 4: LRU eviction (fill 4 ways, force eviction) ===");
      cache_read(21'h00000, MISS_LATENCY_CYCLES); // way 0  (MRU after)
      cache_read(21'h00800, MISS_LATENCY_CYCLES); // way 1
      cache_read(21'h01000, MISS_LATENCY_CYCLES); // way 2
      cache_read(21'h01800, MISS_LATENCY_CYCLES); // way 3

      // Access tag 0 again to make it MRU; tag 1 becomes LRU
      cache_read(21'h00000, HIT_LATENCY_CYCLES);

      // tag 4 → set 0 full, must evict LRU = tag 1 (way 1)
      cache_read(21'h02000, MISS_LATENCY_CYCLES); // evicts way 1

      // tag 1 should now miss (it was evicted)
      cache_read(21'h00800, MISS_LATENCY_CYCLES); // miss after eviction

      // ------------------------------------------------------------------
      // Test 5 – write-back: dirty block eviction writes to memory
      //
      // After Test 4 the set-0 state is (way: tag, age):
      //   way0=tag3(age3/LRU), way1=tag1(age0/MRU), way2=tag4(age1), way3=tag0(age2)
      //
      // Step 1: write tag0 → hits way3, marks dirty, way3 becomes MRU
      //         ages: way0=3, way1=1, way2=2, way3=0
      // Step 2: read tag1 → hits way1,  ages: way0=3, way1=0, way2=3, way3=1
      //         Wait - re-trace:
      //         After write tag0: ages = [3,1,2,0] (way3=MRU)
      // Step 2: read tag1 → way1 hit, age=1 → ways younger (way2=2,way3=0) age++
      //         ages: way0=3, way1=0, way2=3, way3=1  <- way0 & way2 tie at 3
      //         Use: read tag3 then tag4 to bring way3=tag0 to age=3 (LRU)
      //   read tag1:  ages=[3,0,2,1]  (way1=MRU)
      //   read tag3:  ages=[0,1,3,2]  (way0=MRU, way2=LRU? no...)
      //   read tag4:  ages=[1,2,0,3]  (way2=MRU, way3=age3=LRU)  ← tag0 is LRU!
      // Step 5: read tag5 → miss → evicts way3 (dirty tag0) → mwren=1 (write-back!)
      // ------------------------------------------------------------------
      $display("\n=== TEST 5: Write-back on dirty eviction ===");
      // Dirty tag0 (way3), then age it to LRU by accessing the other 3 ways
      cache_write(21'h00000, 32'hBEEFCAFE, HIT_LATENCY_CYCLES); // write hit → dirty
      cache_read (21'h00800, HIT_LATENCY_CYCLES);                // tag1 hit  → ages tag0
      cache_read (21'h01800, HIT_LATENCY_CYCLES);                // tag3 hit  → ages tag0
      cache_read (21'h02000, HIT_LATENCY_CYCLES);                // tag4 hit  → tag0 = LRU
      // tag5 → set0 full, victim = way3 (dirty tag0) → STATE_REPLACE fires mwren=1
      cache_read (21'h02800, MISS_LATENCY_CYCLES + 1);           // miss + write-back

      wait_cycles(4);
      $display("\n=== Simulation complete ===");
      $finish;
   end

   // -------------------------------------------------------------------------
   // Monitor
   // -------------------------------------------------------------------------
   initial begin
      $monitor("time=%6d | addr=%h | rden=%b wren=%b | hit=%b | cdout=%08h | mwren=%b mrden=%b | maddr=%h",
               $time, caddress, rden, wren, hit, cdout, mwren, mrden, maddress);
   end

endmodule
