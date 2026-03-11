module reg_m #(parameter WIDTH = 8) (input clk, rst_b, load_inbus, input [WIDTH - 1 : 0] inbus, output reg [WIDTH - 1 : 0] outbus);
    always @(posedge clk, negedge rst_b) begin
        if(!rst_b)              outbus <= 0;
        else if(load_inbus)     outbus <= inbus;
    end
endmodule

module reg_q #(parameter WIDTH = 8) (input clk, rst_b, shift, load_inbus, clear_q, load_outbus,input [1 : 0] lsb_A, input [WIDTH - 1 : 0] inbus, output [WIDTH - 1 : 0] outbus, output [WIDTH - 1 : -1] q);
    reg [WIDTH - 1 : -1] q_reg;

    always @(posedge clk, negedge rst_b) begin
        if(!rst_b)              q_reg <= 0;
        else if(clear_q)        q_reg <= 0;
        else if(load_inbus)     q_reg <= {inbus[WIDTH - 1 : 0],1'b0};
        else if(shift)          q_reg <= {lsb_A,q_reg[WIDTH - 1 : 1]};
    end

       assign outbus = (load_outbus) ? q_reg[WIDTH -1 : 0] : {WIDTH{1'bz}};

       assign q = q_reg;
endmodule

module reg_a #(parameter WIDTH = 8) (input clk, rst_b, shift, load_reg, load_result, load_outbus, input [WIDTH - 1 : 0] adder_sum, output [WIDTH - 1 : 0] outbus, a, output [1 : 0]lsb_A);
    reg [WIDTH - 1 : 0] a_reg;

    always @(posedge clk, negedge rst_b)begin
        if(!rst_b)              a_reg <= 0;
        else if(load_reg)       a_reg <= 0;
        else if(load_result)    a_reg <= adder_sum;
        else if(shift)          a_reg <= {a_reg[WIDTH-1], a_reg[WIDTH-1], a_reg[WIDTH-1 : 2]};
    end

    assign outbus = (load_outbus) ? a_reg : {WIDTH{1'bz}};

    assign a = a_reg;
    assign lsb_A=a_reg[1:0];
endmodule

module cntr #(parameter w=8)(input clk, rst_b, c_up, clr, output reg [w-1:0] q);
    always @ (posedge clk, negedge rst_b)
        if (!rst_b)					q <= 0;
        else if (c_up)				q <= q + 1;
        else if (clr)				q <= 0;
endmodule


module mux_choice #(parameter WIDTH = 8) (input [WIDTH - 1 : 0] m_in, input c4_select, output [WIDTH : 0]mux_out);
    assign mux_out = (c4_select) ? {m_in,1'b0} : {m_in[WIDTH - 1], m_in};
endmodule

module Booth_multiplier #(parameter WIDTH = 8) (input clk,rst_b,input begin_sig,input [WIDTH - 1 : 0] inbus,output [WIDTH - 1 : 0] outbus,output reg end_sig);

    wire [7:0] m_out;
    wire [8:0] mux_out;
    wire [8:0] adder_sum;
    wire [8:0] a_full;
    wire [7:-1] q_full;
    wire [1:0] shift_A_to_Q;

    reg c_clear_A, c_load_M, c_load_Q, c_load_adder_to_A;
    reg c_shift, c_outbus_A, c_outbus_Q, c_mux_sel, c_add_sub,c_clear_Q;

    localparam S_IDLE = 3'b000;
    localparam S_LOAD_M = 3'b001;
    localparam S_LOAD_Q = 3'b010;
    localparam S_CALC = 3'b011;
    localparam S_SHIFT = 3'b100;
    localparam S_OUTPUT_A = 3'b101;
    localparam S_OUTPUT_Q = 3'b110;
    localparam S_CHECK_0 = 3'b111;

    reg [2 : 0] state, next_state;
    reg [2 : 0] shift_counter;

    wire m_is_zero = ~|m_out;
    wire q_is_zero = ~|q_full[7:0];

    always @(posedge clk, negedge rst_b) begin
        if (!rst_b) begin
            state <= S_IDLE;
            shift_counter <= 0;
        end else begin
            state <= next_state;
            
            if (state == S_LOAD_Q) shift_counter <= 0 ;
            else if(state == S_SHIFT) shift_counter <= shift_counter + 1; 
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
        end_sig = 0;

        case(state)
            S_IDLE: begin
                if(begin_sig)   next_state = S_LOAD_M;
            end

            S_LOAD_M:begin
                c_clear_A = 1;
                c_load_M = 1;
                next_state = S_LOAD_Q;
            end

            S_LOAD_Q: begin
                c_load_Q = 1;
                next_state = S_CALC;
            end

            S_CALC:begin
                case(q_full[1 : -1])

                    3'b000, 3'b111: begin
                        //nothing
                    end

                    3'b001, 3'b010: begin
                        c_load_adder_to_A = 1;
                        c_add_sub = 0;
                        c_mux_sel = 0;
                    end

                    3'b011: begin
                        c_load_adder_to_A = 1;
                        c_add_sub = 0;
                        c_mux_sel = 1;
                    end

                    3'b101, 3'b110:begin
                        c_load_adder_to_A = 1;
                        c_add_sub = 1;
                        c_mux_sel = 0;
                    end 

                    3'b100:begin
                        c_load_adder_to_A = 1;
                        c_add_sub = 1;
                        c_mux_sel = 1;
                    end
                endcase
                next_state = S_SHIFT;
            end

            S_SHIFT:begin
                c_shift = 1;
                if(shift_counter == 3)begin
                    next_state = S_OUTPUT_A;
                end
                else begin
                    next_state = S_CALC;
                end
            end

            S_OUTPUT_A:begin
                c_outbus_A = 1;
                next_state = S_OUTPUT_Q;
            end

            S_OUTPUT_Q:begin
                c_outbus_Q = 1;
                end_sig = 1;
                next_state = S_IDLE;
            end

            S_CHECK_0:begin
                if(m_is_zero || q_is_zero)begin
                    c_clear_A = 1;
                    c_clear_Q = 1;
                    next_state = S_OUTPUT_A;
                end else begin
                    next_state = S_CALC;
                end
            end

            default: next_state = S_IDLE;
        endcase
    end

    reg_m #(8) REG_M (.clk(clk),.rst_b(rst_b),.load_inbus(c_load_M),.inbus(inbus),.outbus(m_out));

    mux_choice #(8) MUX_2M(.m_in(m_out),.c4_select(c_mux_sel),.mux_out(mux_out));

    cska #(9) ADDER (.x(mux_out),.y(a_full),.s(c_add_sub),.sum(adder_sum),.co());

    reg_a #(9) REG_A (.clk(clk), .rst_b(rst_b), .shift(c_shift), .load_reg(c_clear_A), .load_result(c_load_adder_to_A), .load_outbus(c_outbus_A), .adder_sum(adder_sum), .outbus(outbus), .a(a_full), .lsb_A(shift_A_to_Q) );

    reg_q #(8) REG_Q (.clk(clk), .rst_b(rst_b), .shift(c_shift), .load_inbus(c_load_Q), .load_outbus(c_outbus_Q), .lsb_A(shift_A_to_Q), .inbus(inbus), .outbus(outbus), .q(q_full));

endmodule


module tb_booth_multiplier;

    // --- Signals ---
    reg clk;
    reg rst_b;
    reg begin_sig;
    reg [7:0] inbus;
    
    wire [7:0] outbus;
    wire end_sig;

    // History register to capture 'A' before 'Q' overwrites the bus
    reg [7:0] outbus_prev;

    // --- Instantiate the Device Under Test (DUT) ---
    Booth_multiplier #(8) DUT (
        .clk(clk),
        .rst_b(rst_b),
        .begin_sig(begin_sig),
        .inbus(inbus),
        .outbus(outbus),
        .end_sig(end_sig)
    );

    // --- Clock Generation ---
    always #5 clk = ~clk; // 10ns clock period (100 MHz)

    // --- History Capture Logic ---
    always @(posedge clk) begin
        outbus_prev <= outbus;
    end

    // --- The Testing Task ---
    task run_multiplication;
        input signed [7:0] test_M;
        input signed [7:0] test_Q;
        reg signed [15:0] expected_result;
        reg signed [15:0] actual_result;
        begin
            expected_result = test_M * test_Q;

            // 1. Wake up the FSM safely on the falling edge
            @(negedge clk);
            begin_sig = 1;

            // 2. FSM prepares to load M. Put M on the bus.
            @(negedge clk);
            begin_sig = 0; 
            inbus = test_M; // Stable BEFORE the posedge arrives!

            // 3. FSM prepares to load Q. Put Q on the bus.
            @(negedge clk);
            inbus = test_Q; // Stable BEFORE the posedge arrives!

            // 4. FSM prepares to Calculate. Release the bus.
            @(negedge clk);
            inbus = 8'hZZ;

            // 5. Wait for the multiplier to shout "I'm done!"
            wait(end_sig == 1'b1);
            
            // 6. WAIT HALF A CYCLE FOR THE FLIP-FLOPS TO SETTLE!
            @(negedge clk); 
            
            actual_result = {outbus_prev, outbus};

            // 7. Verify the math
            if (actual_result === expected_result) begin
                $display("[PASS] %d * %d = %d", test_M, test_Q, actual_result);
            end else begin
                $display("[FAIL] %d * %d = Expected %d, but got %d", test_M, test_Q, expected_result, actual_result);
            end

            // Let the FSM return to IDLE safely
            @(negedge clk);
        end
    endtask

    // --- Main Simulation Sequence ---
    initial begin
        clk = 0;
        rst_b = 0;
        begin_sig = 0;
        inbus = 8'hZZ;

        $display("========================================");
        $display("   STARTING RADIX-4 BOOTH SIMULATION    ");
        $display("========================================");

        #15 rst_b = 1;

        // Run the Test Cases
        run_multiplication(8'd5,  8'd3);   
        run_multiplication(8'd12, 8'd10);  
        run_multiplication(8'd7, -8'd4);   
        run_multiplication(-8'd6, 8'd2);   
        run_multiplication(-8'd8, -8'd3);  
        run_multiplication(8'd0,  8'd15);  
        run_multiplication(8'd127, 8'd1);  
        run_multiplication(-8'd128,-8'd1); 

        $display("========================================");
        $display("          SIMULATION COMPLETE           ");
        $display("========================================");
        
    end

endmodule