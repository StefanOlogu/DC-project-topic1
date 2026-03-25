module srt4_divider #(parameter WIDTH = 8) (
    input clk,
    input rst_b,
    input begin_sig,
    input [WIDTH-1:0] inbus,
    output [WIDTH-1:0] outbus,
    output end_sig,
    output reg error
);

    // FSM States (Slimmed down to 8 states!)
    localparam S_IDLE     = 3'd0, S_LOAD_N   = 3'd1, S_LOAD_D   = 3'd2, S_PREP     = 3'd3;
    localparam S_NORM     = 3'd4, S_CALC     = 3'd5, S_OUTPUT_R = 3'd6, S_OUTPUT_Q = 3'd7;

    reg [2:0] state;
    reg [7:0] N_in, D_in, dividend_reg, M;
    reg [11:0] A;         
    reg [8:0] Q_raw;      
    reg [2:0] norm_shift, iters;
    reg sign_Q, sign_R;   

    // --- Combinational SRT Thresholds ---
    wire signed [11:0] A_shift = {A[9:0], dividend_reg[7:6]};
    wire signed [11:0] M_signed = {4'b0, M};
    wire signed [11:0] half_M = M_signed >>> 1;
    wire signed [11:0] three_half_M = M_signed + half_M;
    wire signed [11:0] double_M = M_signed <<< 1;

    // --- Combinational Correction & Denorm (Saves 2 Clock Cycles!) ---
    wire A_is_neg = ($signed(A) < 0);
    wire [11:0] A_corr = A_is_neg ? (A + M_signed) : A;
    wire [8:0]  Q_corr = A_is_neg ? (Q_raw - 1)    : Q_raw;
    wire [7:0]  A_denorm = A_corr >> norm_shift;

    // --- Output Assignments ---
    wire [7:0] final_quotient  = sign_Q ? -$signed(Q_corr[7:0]) : Q_corr[7:0];
    wire [7:0] final_remainder = sign_R ? -$signed(A_denorm)    : A_denorm;

    assign outbus  = (state == S_OUTPUT_R) ? final_remainder :
                     (state == S_OUTPUT_Q) ? final_quotient  : {WIDTH{1'bz}};
    assign end_sig = (state == S_OUTPUT_Q);

    // --- State Machine ---
    always @(posedge clk or negedge rst_b) begin
        if (!rst_b) begin
            state <= S_IDLE;
            error <= 0;
        end else begin
            case (state)
                S_IDLE:   if (begin_sig) begin state <= S_LOAD_N; error <= 0; end
                S_LOAD_N: begin N_in <= inbus; state <= S_LOAD_D; end
                S_LOAD_D: begin D_in <= inbus; state <= S_PREP;   end

                S_PREP: begin
                    M <= D_in[7] ? -$signed(D_in) : D_in;
                    dividend_reg <= N_in[7] ? -$signed(N_in) : N_in;
                    sign_Q <= N_in[7] ^ D_in[7];
                    sign_R <= N_in[7]; 
                    A <= 0; Q_raw <= 0; norm_shift <= 0; iters <= 4; 
                    
                    if (D_in == 0) begin error <= 1; state <= S_OUTPUT_R; end 
                    else state <= S_NORM;
                end

                S_NORM: begin
                    if (M[7] == 0) begin
                        M <= M << 1; A <= {A[10:0], dividend_reg[7]};
                        dividend_reg <= dividend_reg << 1; norm_shift <= norm_shift + 1;
                    end else state <= S_CALC;
                end

                S_CALC: begin
                    if (iters > 0) begin
                        // Tabular Logic: Easy to read, matches hardware LUT exactly
                        if      ($signed(A_shift) >=  $signed(three_half_M)) begin A <= A_shift - double_M; Q_raw <= (Q_raw << 2) + 2; end
                        else if ($signed(A_shift) >=  $signed(half_M))       begin A <= A_shift - M_signed; Q_raw <= (Q_raw << 2) + 1; end
                        else if ($signed(A_shift) <= -$signed(three_half_M)) begin A <= A_shift + double_M; Q_raw <= (Q_raw << 2) - 2; end
                        else if ($signed(A_shift) <= -$signed(half_M))       begin A <= A_shift + M_signed; Q_raw <= (Q_raw << 2) - 1; end
                        else                                                 begin A <= A_shift;            Q_raw <= (Q_raw << 2);     end

                        dividend_reg <= {dividend_reg[5:0], 2'b00};
                        iters <= iters - 1;
                    end else begin
                        state <= S_OUTPUT_R; // Math is done, go straight to output!
                    end
                end

                S_OUTPUT_R: state <= S_OUTPUT_Q;
                S_OUTPUT_Q: state <= S_IDLE;
                default:    state <= S_IDLE;
            endcase
        end
    end
endmodule