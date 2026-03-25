    module reg_m #(parameter WIDTH = 8) (input clk, rst_b, load_inbus, input [WIDTH - 1 : 0] inbus, output reg [WIDTH - 1 : 0] outbus);// normal register
        always @(posedge clk, negedge rst_b) begin
            if(!rst_b)              outbus <= 0;
            else if(load_inbus)     outbus <= inbus;
        end
    endmodule

    module reg_q #(parameter WIDTH = 8) (input clk, rst_b, shift, load_inbus, clear_q, load_outbus,input [1 : 0] lsb_A, input [WIDTH - 1 : 0] inbus, output [WIDTH - 1 : 0] outbus, output [WIDTH - 1 : -1] q);
        reg [WIDTH - 1 : -1] q_reg;

        always @(posedge clk, negedge rst_b) begin
            if(!rst_b)              q_reg <= 0;
            else if(clear_q)        q_reg <= 0;//check for Q = 0
            else if(load_inbus)     q_reg <= {inbus[WIDTH - 1 : 0],1'b0};//load Q AND the Q[-1] = 0
            else if(shift)          q_reg <= {lsb_A,q_reg[WIDTH - 1 : 1]};//shift twice since radix 4 can add or substract 2*M
        end

        assign outbus = (load_outbus) ? q_reg[WIDTH -1 : 0] : {WIDTH{1'bz}};//let the outbus in high impedance until C6

        assign q = q_reg;
    endmodule

    module reg_a #(parameter WIDTH = 8) (input clk, rst_b, shift, load_reg, load_result, load_outbus, input [WIDTH - 1 : 0] adder_sum, output [WIDTH - 1 : 0] outbus, a, output [1 : 0]lsb_A);
        reg [WIDTH - 1 : 0] a_reg;

        always @(posedge clk, negedge rst_b)begin
            if(!rst_b)              a_reg <= 0;
            else if(load_reg)       a_reg <= 0;//load 0's at C0
            else if(load_result)    a_reg <= adder_sum;//load the addition or substraction with M or 2*M
            else if(shift)          a_reg <= {a_reg[WIDTH-1], a_reg[WIDTH-1], a_reg[WIDTH-1 : 2]};//shift twice
        end

        assign outbus = (load_outbus) ? a_reg : {WIDTH{1'bz}};//high impedance until C5

        assign a = a_reg;
        assign lsb_A=a_reg[1:0];//load the 2 LSB's of A that will be passed to Q
    endmodule

    module cntr #(parameter w=8)(input clk, rst_b, c_up, clr, output reg [w-1:0] q);//redundant for now, i implemented the counter inside the control unit
        always @ (posedge clk, negedge rst_b)
            if (!rst_b)					q <= 0;
            else if (c_up)				q <= q + 1;
            else if (clr)				q <= 0;
    endmodule


    module mux_choice #(parameter WIDTH = 8) (input [WIDTH - 1 : 0] m_in, input c4_select, output [WIDTH : 0]mux_out);//multiplexer to chose if we need M or 2*M
        assign mux_out = (c4_select) ? {m_in,1'b0} : {m_in[WIDTH - 1], m_in};//mux_out on and extra bit because 2M can't be written on normal WIDTH for some numbers
    endmodule

    module Booth_multiplier #(parameter WIDTH = 8) (input clk,rst_b,input begin_sig,input [WIDTH - 1 : 0] inbus,output [WIDTH - 1 : 0] outbus,output reg end_sig);

        wire [7:0] m_out;
        wire [8:0] mux_out;
        wire [8:0] adder_sum;
        wire [8:0] a_full;
        wire [7:-1] q_full;
        wire [1:0] shift_A_to_Q;

        reg c_clear_A, c_load_M, c_load_Q, c_load_adder_to_A;//control signals
        reg c_shift, c_outbus_A, c_outbus_Q, c_mux_sel, c_add_sub,c_clear_Q;//control signals

        //START OF THE CONTROL UNIT

        //States for the control unit
        localparam S_IDLE = 3'b000;
        localparam S_LOAD_M = 3'b001;
        localparam S_LOAD_Q = 3'b010;
        localparam S_CALC = 3'b011;
        localparam S_SHIFT = 3'b100;
        localparam S_OUTPUT_A = 3'b101;
        localparam S_OUTPUT_Q = 3'b110;
        localparam S_CHECK_0 = 3'b111;

        reg [2 : 0] state, next_state;
        reg [2 : 0] shift_counter;//counter for the exit of the program

        // variables to check is either Q or M are 0
        wire m_is_zero = ~|m_out;
        wire q_is_zero = ~|q_full[7:0];

        always @(posedge clk, negedge rst_b) begin
            if (!rst_b) begin
                state <= S_IDLE;
                shift_counter <= 0;
            end else begin
                state <= next_state;
                
                if (state == S_LOAD_Q) shift_counter <= 0 ;
                else if(state == S_SHIFT) shift_counter <= shift_counter + 1; //increment the counter on every shift
            end
        end


        always @(*)begin
            next_state = state;
            c_clear_A = 0;
            c_load_M = 0;
            c_load_Q = 0;
            c_load_adder_to_A = 0;
            c_shift = 0;
            c_outbus_A = 0;
            c_outbus_Q = 0;
            c_mux_sel = 0;
            c_add_sub = 0;
            c_clear_Q = 0;
            end_sig = 0;

            case(state)
                S_IDLE: begin//START
                    if(begin_sig)   next_state = S_LOAD_M;
                end

                S_LOAD_M:begin//C0
                    c_clear_A = 1;
                    c_load_M = 1;
                    next_state = S_LOAD_Q;
                end

                S_LOAD_Q: begin//C1
                    c_load_Q = 1;
                    next_state = S_CHECK_0;
                end

                S_CALC:begin//C2 and C3
                    case(q_full[1 : -1])//check the last 3 bits to see what operation we have to do

                        3'b000, 3'b111: begin
                            //nothing happens, simply shift
                        end

                        3'b001, 3'b010: begin//add M to A
                            c_load_adder_to_A = 1;
                            c_add_sub = 0;
                            c_mux_sel = 0;
                        end

                        3'b011: begin//add 2*M to A
                            c_load_adder_to_A = 1;
                            c_add_sub = 0;
                            c_mux_sel = 1;
                        end

                        3'b101, 3'b110:begin//substract M from A
                            c_load_adder_to_A = 1;
                            c_add_sub = 1;
                            c_mux_sel = 0;
                        end 

                        3'b100:begin//substract 2*m from A
                            c_load_adder_to_A = 1;
                            c_add_sub = 1;
                            c_mux_sel = 1;
                        end
                    endcase
                    next_state = S_SHIFT;//always go to right_shift
                end

                S_SHIFT:begin//C4
                    c_shift = 1;
                    if(shift_counter == 3)begin
                        next_state = S_OUTPUT_A;
                    end
                    else begin
                        next_state = S_CALC;
                    end
                end

                S_OUTPUT_A:begin//C5
                    c_outbus_A = 1;
                    next_state = S_OUTPUT_Q;
                end

                S_OUTPUT_Q:begin//C6
                    c_outbus_Q = 1;
                    end_sig = 1;
                    next_state = S_IDLE;
                end

                S_CHECK_0:begin//checked once in C1
                    if(m_is_zero || q_is_zero)begin
                        c_clear_A = 1;//wipe A
                        c_clear_Q = 1;//wipe Q
                        next_state = S_OUTPUT_A;//go to output which will be 0
                    end else begin
                        next_state = S_CALC;
                    end
                end

                default: next_state = S_IDLE;
            endcase
        end

        reg_m #(8) REG_M (.clk(clk),.rst_b(rst_b),.load_inbus(c_load_M),.inbus(inbus),.outbus(m_out));//initialize M

        mux_choice #(8) MUX_2M(.m_in(m_out),.c4_select(c_mux_sel),.mux_out(mux_out));//initialize the multiplexer for M or 2*M

        cska #(9) ADDER (.x(mux_out),.y(a_full),.s(c_add_sub),.sum(adder_sum),.co());//initialize the carry skip adder

        reg_a #(9) REG_A (.clk(clk), .rst_b(rst_b), .shift(c_shift), .load_reg(c_clear_A), .load_result(c_load_adder_to_A), .load_outbus(c_outbus_A), .adder_sum(adder_sum), .outbus(outbus), .a(a_full), .lsb_A(shift_A_to_Q) );

        reg_q #(8) REG_Q (.clk(clk), .rst_b(rst_b), .shift(c_shift), .load_inbus(c_load_Q), .load_outbus(c_outbus_Q),.clear_q(c_clear_Q),.lsb_A(shift_A_to_Q), .inbus(inbus), .outbus(outbus), .q(q_full));

    endmodule

    module Unified_Radix4_ALU #(parameter WIDTH = 8) (
    input clk,
    input rst_b,
    input begin_sig,
    input opcode,             // 0 = Multiply, 1 = Divide
    input [WIDTH-1:0] inbus,
    output [WIDTH-1:0] outbus,
    output end_sig,
    output reg error
);

    // --- FSM States ---
    localparam S_IDLE     = 4'd0, S_LOAD_1   = 4'd1, S_LOAD_2   = 4'd2, S_PREP     = 4'd3;
    localparam S_NORM     = 4'd4, S_CALC     = 4'd5, S_OUTPUT_1 = 4'd6, S_OUTPUT_2 = 4'd7;

    reg [3:0] state;
    reg op_reg; 

    // --- UNIVERSAL REGISTERS ---
    reg signed [11:0] A;      
    reg [8:0] Q;              
    reg [7:0] M;              
    reg [7:0] dividend_reg;   
    
    reg [2:0] iters;
    reg [2:0] norm_shift;
    reg sign_Q, sign_R;       

    // ==========================================
    //    DATAPATH COMBINATIONAL LOGIC
    // ==========================================
    
    // 1. Extend M (Sign-extend for Mul, Zero-extend for Div)
    wire [11:0] M_ext = (op_reg == 0) ? {{4{M[7]}}, M} : {4'b0, M};

    // 2. SRT Division Shift & Thresholds
    wire signed [11:0] A_shift = {A[9:0], dividend_reg[7:6]};
    wire signed [11:0] half_M = M_ext >>> 1;
    wire signed [11:0] three_half_M = M_ext + half_M;
    wire signed [11:0] double_M = M_ext <<< 1;

    // 3. Independent Math Controllers (Instantly evaluates!)
    wire booth_sel_0M = (Q[2:0] == 3'b000 || Q[2:0] == 3'b111);
    wire booth_sel_2M = (Q[2:0] == 3'b011 || Q[2:0] == 3'b100);
    wire booth_sub    = (Q[2] == 1'b1);

    wire srt_cond_1 = ($signed(A_shift) >= $signed(three_half_M));
    wire srt_cond_2 = ($signed(A_shift) >= $signed(half_M));
    wire srt_cond_3 = ($signed(A_shift) <= -$signed(three_half_M));
    wire srt_cond_4 = ($signed(A_shift) <= -$signed(half_M));

    wire srt_sel_0M = !(srt_cond_1 || srt_cond_2 || srt_cond_3 || srt_cond_4);
    wire srt_sel_2M = srt_cond_1 || srt_cond_3;
    wire srt_sub    = srt_cond_1 || srt_cond_2;

    // 4. Shared Mux & ALU Routing
    wire mux_sel_0M = (op_reg == 0) ? booth_sel_0M : srt_sel_0M;
    wire mux_sel_2M = (op_reg == 0) ? booth_sel_2M : srt_sel_2M;
    wire alu_sub    = (op_reg == 0) ? booth_sub    : srt_sub;
    
    wire [11:0] mux_out_raw  = mux_sel_2M ? (M_ext << 1) : M_ext;
    wire [11:0] shared_mux_out = mux_sel_0M ? 12'd0 : mux_out_raw;
    
    // Fix #3: Booth adds to A, SRT adds to A_shift
    wire [11:0] alu_x = (op_reg == 0) ? A : A_shift; 
    wire [11:0] alu_sum = alu_x + (alu_sub ? ~shared_mux_out : shared_mux_out) + alu_sub;

    // 5. SRT Division Next-Q Predictor
    wire [8:0] next_srt_Q = srt_cond_1 ? ((Q << 2) + 2) :
                            srt_cond_2 ? ((Q << 2) + 1) :
                            srt_cond_3 ? ((Q << 2) - 2) :
                            srt_cond_4 ? ((Q << 2) - 1) :
                                         ((Q << 2));

    // --- Output Fixers (Division Only) ---
    wire A_is_neg = ($signed(A) < 0);
    wire [11:0] A_corr = A_is_neg ? (A + M_ext) : A;
    wire [8:0]  Q_corr = A_is_neg ? (Q - 1)     : Q;
    wire [7:0]  A_denorm = A_corr >> norm_shift;
    
    wire [7:0] div_Q_out = sign_Q ? -$signed(Q_corr[7:0]) : Q_corr[7:0];
    wire [7:0] div_R_out = sign_R ? -$signed(A_denorm)    : A_denorm;

    // --- Bus Controller ---
    assign outbus = (state == S_OUTPUT_1) ? ((op_reg == 0) ? A[7:0] : div_R_out) :
                    (state == S_OUTPUT_2) ? ((op_reg == 0) ? Q[8:1] : div_Q_out) : {WIDTH{1'bz}};
    assign end_sig = (state == S_OUTPUT_2);

    // ==========================================
    //          THE UNIFIED CONTROL UNIT
    // ==========================================
    always @(posedge clk or negedge rst_b) begin
        if (!rst_b) begin
            state <= S_IDLE;
            error <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (begin_sig) begin 
                        state <= S_LOAD_1; 
                        op_reg <= opcode; 
                        error <= 0; 
                    end
                end

                S_LOAD_1: begin 
                    M <= inbus; 
                    state <= S_LOAD_2; 
                end
                
                S_LOAD_2: begin 
                    if (op_reg == 0) begin // MULTIPLY SETUP
                        Q <= {inbus, 1'b0}; 
                        A <= 0;
                        iters <= 4;
                        if (~|M || ~|inbus) begin
                            Q <= 0; // Fix #4: WIPE Q BEFORE SHORTCUT!
                            state <= S_OUTPUT_1; 
                        end else begin
                            state <= S_CALC;
                        end
                    end else begin         // DIVIDE SETUP
                        dividend_reg <= M[7] ? -$signed(M) : M;
                        M <= inbus[7] ? -$signed(inbus) : inbus;
                        sign_Q <= M[7] ^ inbus[7];
                        sign_R <= M[7];
                        A <= 0; Q <= 0; norm_shift <= 0; iters <= 4;
                        if (inbus == 0) begin error <= 1; state <= S_OUTPUT_1; end
                        else state <= S_NORM;
                    end
                end

                S_NORM: begin
                    if (M[7] == 0) begin
                        M <= M << 1; 
                        A <= {A[10:0], dividend_reg[7]};
                        dividend_reg <= dividend_reg << 1; 
                        norm_shift <= norm_shift + 1;
                    end else state <= S_CALC;
                end

                S_CALC: begin
                    if (iters > 0) begin
                        iters <= iters - 1;

                        if (op_reg == 0) begin 
                            // BOOTH MULTIPLIER (Right Shift)
                            A <= {alu_sum[11], alu_sum[11], alu_sum[11:2]};
                            Q <= {alu_sum[1:0], Q[8:2]}; 
                        end else begin
                            // SRT DIVIDER (Left Shift)
                            A <= alu_sum; 
                            Q <= next_srt_Q;
                            dividend_reg <= {dividend_reg[5:0], 2'b00};
                        end
                    end else begin
                        state <= S_OUTPUT_1;
                    end
                end

                S_OUTPUT_1: state <= S_OUTPUT_2;
                S_OUTPUT_2: state <= S_IDLE;
                default:    state <= S_IDLE;
            endcase
        end
    end
endmodule

`timescale 1ns / 1ps

module tb_alu_system;

    // --- System Signals ---
    reg clk;
    reg rst_b;
    
    // --- The Shared System Buses ---
    reg  [7:0] shared_inbus;
    wire [7:0] shared_outbus;
    
    // --- Hardware Control Signals ---
    reg add_enable; 
    
    // NEW: Unified Math Unit Signals
    reg math_begin;
    reg math_opcode;  // 0 = MUL, 1 = DIV
    wire math_end;
    wire math_error;

    // --- Adder Specific Registers ---
    reg [7:0] add_x;
    reg [7:0] add_y;
    reg add_s; 
    wire [7:0] add_sum;
    wire add_co;

    // History register
    reg [7:0] outbus_prev;

    // ==========================================
    //       INSTANTIATE ALL HARDWARE UNITS
    // ==========================================

    // 1. The Unified Radix-4 Math Unit (Replaces Mul & Div!)
    Unified_Radix4_ALU #(8) MATH_UNIT (
        .clk(clk),
        .rst_b(rst_b),
        .begin_sig(math_begin),
        .opcode(math_opcode),
        .inbus(shared_inbus),
        .outbus(shared_outbus),
        .end_sig(math_end),
        .error(math_error)
    );

    // 2. The Pure Combinational Adder/Subtractor
    cska #(8) ADDER_SUBTRACTOR (
        .x(add_x),
        .y(add_y),
        .s(add_s),
        .sum(add_sum),
        .co(add_co)
    );

    // Tri-State Buffer for the Adder
    assign shared_outbus = (add_enable) ? add_sum : 8'hZZ;

    // ==========================================
    //             CLOCK & HISTORY
    // ==========================================
    always #5 clk = ~clk;

    always @(posedge clk) begin
        outbus_prev <= shared_outbus;
    end

    // ==========================================
    //          THE "PLAYER" ALU TASK
    // ==========================================
    task run_alu;
        input [1:0] sys_opcode; // 00=ADD, 01=SUB, 10=MUL, 11=DIV
        input signed [7:0] num1;
        input signed [7:0] num2;
        
        reg signed [15:0] expected_16;
        reg signed [15:0] actual_16;
        reg signed [7:0] expected_8;
        reg signed [7:0] actual_8;
        begin
            @(negedge clk); 
            
            case (sys_opcode)
                2'b00, 2'b01: begin 
                    // --- ADD (00) and SUBTRACT (01) ---
                    add_x = num1;
                    add_y = num2;
                    add_s = (sys_opcode == 2'b01) ? 1'b1 : 1'b0;
                    add_enable = 1'b1; 
                    
                    @(negedge clk); 
                    actual_8 = shared_outbus;
                    expected_8 = (sys_opcode == 2'b00) ? (num2 + num1) : (num2 - num1);
                    
                    if (actual_8 === expected_8)
                        $display("[PASS] %s: %4d %s %4d = %4d", 
                            (sys_opcode==0)?"ADD":"SUB", num2, (sys_opcode==0)? "+":"-", num1, actual_8);
                    else
                        $display("[FAIL] %s: %4d %s %4d = Expected %4d, Got %4d", 
                            (sys_opcode==0)?"ADD":"SUB", num2, (sys_opcode==0)? "+":"-", num1, expected_8, actual_8);
                            
                    add_enable = 1'b0; 
                end

                2'b10: begin 
                    // --- MULTIPLY (10) ---
                    expected_16 = num1 * num2;
                    
                    math_opcode = 1'b0; // Tell the Unified ALU to Multiply
                    math_begin = 1;     
                    @(negedge clk);
                    math_begin = 0;
                    shared_inbus = num1; // Load M
                    
                    @(negedge clk);
                    shared_inbus = num2; // Load Q
                    
                    @(negedge clk);
                    shared_inbus = 8'hZZ; 
                    
                    wait(math_end == 1'b1);
                    @(negedge clk);
                    
                    actual_16 = {outbus_prev, shared_outbus}; 
                    
                    if (actual_16 === expected_16)
                        $display("[PASS] MUL: %4d * %4d = %6d", num1, num2, actual_16);
                    else
                        $display("[FAIL] MUL: %4d * %4d = Expected %6d, Got %6d", num1, num2, expected_16, actual_16);
                end

                2'b11: begin 
                    // --- DIVIDE (11) ---
                    math_opcode = 1'b1; // Tell the Unified ALU to Divide
                    math_begin = 1;      
                    @(negedge clk);
                    math_begin = 0;
                    shared_inbus = num1; // Load Dividend (N)
                    
                    @(negedge clk);
                    shared_inbus = num2; // Load Divisor (D)
                    
                    @(negedge clk);
                    shared_inbus = 8'hZZ; 
                    
                    wait(math_end == 1'b1);
                    @(negedge clk);
                    
                    if (math_error) begin
                        $display("[PASS] DIV: %4d / %4d = DIV_BY_ZERO ERROR CAUGHT", num1, num2);
                    end else begin
                        actual_8 = shared_outbus;      
                        actual_16 = outbus_prev;       
                        
                        expected_8 = num1 / num2;      
                        expected_16 = num1 % num2;     
                        
                        if (actual_8 === expected_8 && actual_16 === expected_16)
                            $display("[PASS] DIV: %4d / %4d = %4d (Rem: %4d)", num1, num2, actual_8, actual_16);
                        else
                            $display("[FAIL] DIV: %4d / %4d = Expected Q:%4d R:%4d, Got Q:%4d R:%4d", 
                                     num1, num2, expected_8, expected_16, actual_8, actual_16);
                    end
                end
            endcase
            @(negedge clk); 
        end
    endtask

    // ==========================================
    //           MAIN SIMULATION SEQUENCE
    // ==========================================
    initial begin
        clk = 0;
        rst_b = 0;
        shared_inbus = 8'hZZ;
        math_begin = 0;
        math_opcode = 0;
        add_enable = 0;
        add_x = 0; add_y = 0; add_s = 0;

        $display("========================================");
        $display("   STARTING UNIFIED ALU SIMULATION      ");
        $display("========================================");

        #15 rst_b = 1;

        $display("\n--- Testing Addition (Opcode 00) ---");
        run_alu(2'b00, 8'd15, 8'd45);
        run_alu(2'b00, -8'd10, 8'd5);

        $display("\n--- Testing Subtraction (Opcode 01) ---");
        run_alu(2'b01, 8'd20, 8'd50); 
        run_alu(2'b01, -8'd15, 8'd10); 

        $display("\n--- Testing Unified Multiplication (Opcode 10) ---");
        run_alu(2'b10, 8'd12, 8'd10);
        run_alu(2'b10, -8'd6, 8'd2);
        run_alu(2'b10, 8'd0, 8'd15);   

        $display("\n--- Testing Unified Division (Opcode 11) ---");
        run_alu(2'b11, 8'd100, 8'd25);
        run_alu(2'b11, 8'd15, 8'd4);
        run_alu(2'b11, 8'd50, 8'd0);   

        $display("\n========================================");
        $display("          SIMULATION COMPLETE           ");
        $display("========================================");
        
        $finish;
    end
endmodule