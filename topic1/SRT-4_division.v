module srt4_divider #(parameter WIDTH = 8) (
    input clk,
    input rst_b,
    input start,
    input [WIDTH-1:0] dividend,
    input [WIDTH-1:0] divisor,
    output reg [WIDTH-1:0] quotient,
    output reg [WIDTH-1:0] remainder,
    output reg ready,
    output reg error
);

    // FSM States
    localparam S_IDLE    = 3'd0;
    localparam S_PREP    = 3'd1;
    localparam S_NORM    = 3'd2;
    localparam S_CALC    = 3'd3;
    localparam S_CORRECT = 3'd4;
    localparam S_DENORM  = 3'd5;
    localparam S_FINISH  = 3'd6;

    reg [2:0] state;

    // Datapath Registers
    reg [11:0] A;             // Extended width to hold up to +/- 3M
    reg [7:0] dividend_reg;   
    reg [7:0] M;              // Normalized absolute divisor
    reg [8:0] Q_raw;          // Raw quotient (can be negative during calc)
    reg [2:0] norm_shift;     // Tracks how much we shifted the divisor
    reg [2:0] iters;          // Iteration counter (4 iters for 8-bit)
    reg sign_Q, sign_R;       // Target signs for the final output

    // --- Combinational Threshold Logic ---
    // Extract the top bits of A and the next 2 bits of the dividend
    wire signed [11:0] A_shift = {A[9:0], dividend_reg[7:6]};
    wire signed [11:0] M_signed = {4'b0, M};
    
    // Calculate SRT thresholds: 0.5 * M, 1.5 * M, and 2.0 * M
    wire signed [11:0] half_M = M_signed >>> 1;
    wire signed [11:0] three_half_M = M_signed + half_M;
    wire signed [11:0] double_M = M_signed <<< 1;

    always @(posedge clk or negedge rst_b) begin
        if (!rst_b) begin
            state <= S_IDLE;
            ready <= 0;
            error <= 0;
            quotient <= 0;
            remainder <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_PREP;
                        ready <= 0;
                        error <= 0;
                    end
                end

                S_PREP: begin
                    // 1. Capture absolute values and determine final signs
                    M <= divisor[WIDTH-1] ? -$signed(divisor) : divisor;
                    dividend_reg <= dividend[WIDTH-1] ? -$signed(dividend) : dividend;
                    
                    sign_Q <= dividend[WIDTH-1] ^ divisor[WIDTH-1];
                    sign_R <= dividend[WIDTH-1]; // Remainder takes sign of dividend
                    
                    A <= 0;
                    Q_raw <= 0;
                    norm_shift <= 0;
                    iters <= 4; // 8 bits / 2 bits per cycle = 4 iterations

                    if (divisor == 0) begin
                        error <= 1; // Catch division by zero
                        ready <= 1;
                        state <= S_IDLE;
                    end else begin
                        state <= S_NORM;
                    end
                end

                S_NORM: begin
                    // 2. Normalize Divisor (Shift left until MSB is 1)
                    if (M[7] == 0) begin
                        M <= M << 1;
                        // Shift dividend into A to keep scale balanced
                        A <= {A[10:0], dividend_reg[7]};
                        dividend_reg <= dividend_reg << 1;
                        norm_shift <= norm_shift + 1;
                    end else begin
                        state <= S_CALC;
                    end
                end

                S_CALC: begin
                    // 3. SRT-4 Core Calculation Loop
                    if (iters > 0) begin
                        // Select Quotient Digit (q_i) based on SRT bounds
                        if ($signed(A_shift) >= $signed(three_half_M)) begin
                            A <= A_shift - double_M;
                            Q_raw <= (Q_raw << 2) + 2;
                        end else if ($signed(A_shift) >= $signed(half_M)) begin
                            A <= A_shift - M_signed;
                            Q_raw <= (Q_raw << 2) + 1;
                        end else if ($signed(A_shift) <= -$signed(three_half_M)) begin
                            A <= A_shift + double_M;
                            Q_raw <= (Q_raw << 2) - 2;
                        end else if ($signed(A_shift) <= -$signed(half_M)) begin
                            A <= A_shift + M_signed;
                            Q_raw <= (Q_raw << 2) - 1;
                        end else begin
                            A <= A_shift;
                            Q_raw <= (Q_raw << 2);
                        end

                        // Shift out the processed bits
                        dividend_reg <= {dividend_reg[5:0], 2'b00};
                        iters <= iters - 1;
                    end else begin
                        state <= S_CORRECT;
                    end
                end

                S_CORRECT: begin
                    // 4. Fix negative remainder (Non-Restoring fix)
                    if ($signed(A) < 0) begin
                        A <= A + M_signed;
                        Q_raw <= Q_raw - 1;
                    end
                    state <= S_DENORM;
                end

                S_DENORM: begin
                    // 5. Shift remainder right by the normalization amount
                    A <= A >> norm_shift;
                    state <= S_FINISH;
                end

                S_FINISH: begin
                    // 6. Apply target signs to Q and R
                    quotient  <= sign_Q ? -$signed(Q_raw[7:0]) : Q_raw[7:0];
                    remainder <= sign_R ? -$signed(A[7:0]) : A[7:0];
                    ready <= 1;
                    state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule


module tb_srt4_divider;
    reg clk;
    reg rst_b;
    reg start;
    reg [7:0] dividend;
    reg [7:0] divisor;
    wire [7:0] quotient;
    wire [7:0] remainder;
    wire ready;
    wire error;

    // Instantiate the Divider
    srt4_divider #(8) DUT (
        .clk(clk),
        .rst_b(rst_b),
        .start(start),
        .dividend(dividend),
        .divisor(divisor),
        .quotient(quotient),
        .remainder(remainder),
        .ready(ready),
        .error(error)
    );

    // Clock Generation
    always #5 clk = ~clk;

    task run_division;
        input signed [7:0] test_N;
        input signed [7:0] test_D;
        reg signed [7:0] exp_Q;
        reg signed [7:0] exp_R;
        begin
            if (test_D != 0) begin
                // Truncated towards zero matching integer division logic
                exp_Q = test_N / test_D; 
                exp_R = test_N % test_D;
            end

            @(negedge clk);
            dividend = test_N;
            divisor = test_D;
            start = 1;

            @(negedge clk);
            start = 0;

            wait(ready == 1'b1);
            @(negedge clk);

            if (error && test_D == 0) begin
                $display("[PASS] %4d / %4d = DIV_BY_ZERO ERROR TRIGGERED", test_N, test_D);
            end else if (quotient === exp_Q && remainder === exp_R) begin
                $display("[PASS] %4d / %4d = %4d (Rem: %4d)", test_N, test_D, $signed(quotient), $signed(remainder));
            end else begin
                $display("[FAIL] %4d / %4d | Expected Q:%4d R:%4d | Got Q:%4d R:%4d", 
                         test_N, test_D, exp_Q, exp_R, $signed(quotient), $signed(remainder));
            end
            
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 0;
        rst_b = 0;
        start = 0;
        dividend = 0;
        divisor = 0;

        $display("========================================");
        $display("     STARTING SRT-4 DIVIDER SIM         ");
        $display("========================================");
        
        #15 rst_b = 1;

        // Run Test Cases
        run_division(8'd20,   8'd3);
        run_division(8'd127,  8'd1);
        run_division(8'd15,   8'd4);
        run_division(-8'd15,  8'd4);   // Negative Dividend
        run_division(8'd15,  -8'd4);   // Negative Divisor
        run_division(-8'd8,  -8'd3);   // Double Negative
        run_division(8'd100,  8'd25);  // Exact division
        run_division(8'd50,   8'd0);   // Division by Zero trigger

        $display("========================================");
        $display("          SIMULATION COMPLETE           ");
        $display("========================================");
        $finish;
    end
endmodule