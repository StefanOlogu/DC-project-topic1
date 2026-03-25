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

`timescale 1ns / 1ps

module tb_alu_system;

    // --- System Signals ---
    reg clk;
    reg rst_b;
    
    // --- The Shared System Buses ---
    reg  [7:0] shared_inbus;
    wire [7:0] shared_outbus;
    
    // --- Hardware Control Signals ---
    reg mul_begin;
    reg div_begin;
    reg add_enable; // Controls the Adder's tri-state buffer
    
    // --- Hardware Status Wires ---
    wire mul_end;
    wire div_end;
    wire div_error;

    // --- Adder Specific Registers ---
    reg [7:0] add_x;
    reg [7:0] add_y;
    reg add_s; // 0 = Add, 1 = Subtract
    wire [7:0] add_sum;
    wire add_co;

    // History register to capture the first byte of 16-bit answers
    reg [7:0] outbus_prev;

    // ==========================================
    //       INSTANTIATE ALL HARDWARE UNITS
    // ==========================================

    // 1. The Radix-4 Booth Multiplier
    Booth_multiplier #(8) MULTIPLIER (
        .clk(clk),
        .rst_b(rst_b),
        .begin_sig(mul_begin),
        .inbus(shared_inbus),
        .outbus(shared_outbus), // Drives Z when idle
        .end_sig(mul_end)
    );

    // 2. The SRT-4 Divider
    srt4_divider #(8) DIVIDER (
        .clk(clk),
        .rst_b(rst_b),
        .begin_sig(div_begin),
        .inbus(shared_inbus),
        .outbus(shared_outbus), // Drives Z when idle
        .end_sig(div_end),
        .error(div_error)
    );

    // 3. The Carry-Skip Adder (CSKA)
    cska #(8) ADDER_SUBTRACTOR (
        .x(add_x),
        .y(add_y),
        .s(add_s),
        .sum(add_sum),
        .co(add_co)
    );

    // Tri-State Buffer to connect the Combinational Adder to the Shared Bus
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
    // Opcodes: 0=ADD, 1=SUB, 2=MUL, 3=DIV
    task run_alu;
        input [1:0] opcode;
        input signed [7:0] num1;
        input signed [7:0] num2;
        
        reg signed [15:0] expected_16;
        reg signed [15:0] actual_16;
        reg signed [7:0] expected_8;
        reg signed [7:0] actual_8;
        begin
            @(negedge clk); // Align to safe edge
            
            case (opcode)
                2'b00, 2'b01: begin 
                    // --- ADD (00) and SUBTRACT (01) ---
                    add_x = num1;
                    add_y = num2;
                    add_s = (opcode == 2'b01) ? 1'b1 : 1'b0;
                    add_enable = 1'b1; // Put answer on the shared bus
                    
                    @(negedge clk); // Wait 1 cycle for combinational logic
                    actual_8 = shared_outbus;
                    expected_8 = (opcode == 2'b00) ? (num2 + num1) : (num2 - num1);
                    
                    if (actual_8 === expected_8)
                        $display("[PASS] %s: %4d %s %4d = %4d", 
                            (opcode==0)?"ADD":"SUB", num2, (opcode==0)? "+":"-", num1, actual_8);
                    else
                        $display("[FAIL] %s: %4d %s %4d = Expected %4d, Got %4d", 
                            (opcode==0)?"ADD":"SUB", num2, (opcode==0)? "+":"-", num1, expected_8, actual_8);
                            
                    add_enable = 1'b0; // Release the bus!
                end

                2'b10: begin 
                    // --- MULTIPLY (10) ---
                    expected_16 = num1 * num2;
                    
                    mul_begin = 1;      // Wake up Multiplier
                    @(negedge clk);
                    mul_begin = 0;
                    shared_inbus = num1; // Load M
                    
                    @(negedge clk);
                    shared_inbus = num2; // Load Q
                    
                    @(negedge clk);
                    shared_inbus = 8'hZZ; // Release Bus
                    
                    wait(mul_end == 1'b1);
                    @(negedge clk);
                    
                    actual_16 = {outbus_prev, shared_outbus}; // {A, Q}
                    
                    if (actual_16 === expected_16)
                        $display("[PASS] MUL: %4d * %4d = %6d", num1, num2, actual_16);
                    else
                        $display("[FAIL] MUL: %4d * %4d = Expected %6d, Got %6d", num1, num2, expected_16, actual_16);
                end

                2'b11: begin 
                    // --- DIVIDE (11) ---
                    div_begin = 1;      // Wake up Divider
                    @(negedge clk);
                    div_begin = 0;
                    shared_inbus = num1; // Load Dividend (N)
                    
                    @(negedge clk);
                    shared_inbus = num2; // Load Divisor (D)
                    
                    @(negedge clk);
                    shared_inbus = 8'hZZ; // Release Bus
                    
                    wait(div_end == 1'b1);
                    @(negedge clk);
                    
                    if (div_error) begin
                        $display("[PASS] DIV: %4d / %4d = DIV_BY_ZERO ERROR CAUGHT", num1, num2);
                    end else begin
                        actual_8 = shared_outbus;      // Quotient is currently on bus
                        actual_16 = outbus_prev;       // Remainder was on bus last cycle
                        
                        expected_8 = num1 / num2;      // Expected Quotient
                        expected_16 = num1 % num2;     // Expected Remainder
                        
                        if (actual_8 === expected_8 && actual_16 === expected_16)
                            $display("[PASS] DIV: %4d / %4d = %4d (Rem: %4d)", num1, num2, actual_8, actual_16);
                        else
                            $display("[FAIL] DIV: %4d / %4d = Expected Q:%4d R:%4d, Got Q:%4d R:%4d", 
                                     num1, num2, expected_8, expected_16, actual_8, actual_16);
                    end
                end
            endcase
            @(negedge clk); // Buffer cycle between operations
        end
    endtask

    // ==========================================
    //           MAIN SIMULATION SEQUENCE
    // ==========================================
    initial begin
        // Initialize everything safely
        clk = 0;
        rst_b = 0;
        shared_inbus = 8'hZZ;
        mul_begin = 0;
        div_begin = 0;
        add_enable = 0;
        add_x = 0; add_y = 0; add_s = 0;

        $display("========================================");
        $display("   STARTING UNIFIED ALU SIMULATION      ");
        $display("========================================");

        #15 rst_b = 1;

        // --- The "Player's Choice" Tests ---
        // Format: run_alu(Opcode, Number1, Number2);
        
        $display("\n--- Testing Addition (Opcode 00) ---");
        run_alu(2'b00, 8'd15, 8'd45);
        run_alu(2'b00, -8'd10, 8'd5);

        $display("\n--- Testing Subtraction (Opcode 01) ---");
        run_alu(2'b01, 8'd20, 8'd50); // 50 - 20
        run_alu(2'b01, -8'd15, 8'd10); // 10 - (-15)

        $display("\n--- Testing Multiplication (Opcode 10) ---");
        run_alu(2'b10, 8'd12, 8'd10);
        run_alu(2'b10, -8'd6, 8'd2);
        run_alu(2'b10, 8'd0, 8'd15);   // Tests your early exit shortcut!

        $display("\n--- Testing Division (Opcode 11) ---");
        run_alu(2'b11, 8'd100, 8'd25);
        run_alu(2'b11, 8'd15, 8'd4);
        run_alu(2'b11, 8'd50, 8'd0);   // Tests division by zero!

        $display("\n========================================");
        $display("          SIMULATION COMPLETE           ");
        $display("========================================");
        
    end

endmodule