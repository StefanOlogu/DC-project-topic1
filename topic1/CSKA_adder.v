module fac (input x , y , ci, output sum , co);
    assign sum = x ^ y ^ ci;
    assign co = (x & y) | (x & ci) | (y & ci);
endmodule

module normal_rca #(parameter WIDTH = 8) (input [WIDTH - 1 : 0] x, y, input ci, output [WIDTH - 1 : 0] sum, output co);
    wire [WIDTH : 0] carry;
    assign carry[0] = ci;

    genvar i;

    generate
        for(i = 0;i < WIDTH;i = i + 1) begin : FAC_INITIATION
            fac one_bit_adders(.x(x[i]), .y(y[i]),. ci(carry[i]),.sum(sum[i]),.co(carry[i+1]));    
        end
    endgenerate

    assign co = carry[WIDTH];
endmodule

module skip_rca #(parameter WIDTH = 8) (input [WIDTH - 1 : 0] x, y, input ci, output [WIDTH - 1 : 0] sum, output co, propagate);
    wire [WIDTH : 0] carry;
    assign carry[0] = ci;
    assign propagate= &(x | y);
    genvar i;

    generate
        for(i=0;i<WIDTH;i=i+1) begin : FAC_INITIATION
            fac one_bit_adders(.x(x[i]), .y(y[i]),. ci(carry[i]),.sum(sum[i]),.co(carry[i+1]));    
        end
    endgenerate
    assign co=carry[WIDTH];
endmodule

module cska #(parameter WIDTH = 16) (input [WIDTH - 1 : 0] x, y, input s, output [WIDTH - 1: 0] sum, output co);

    function integer sqrt;
        input integer val;
        integer i;
        begin
            i = 0;
            while (i * i <= val)begin
                i = i + 1;
            end
            sqrt = i - 1;
        end
    endfunction

    localparam OPTIMAL_LENGTH = sqrt(2 * WIDTH) / 2;
    localparam NUMBER_OF_BLOCKS = WIDTH / OPTIMAL_LENGTH;

    localparam LAST_BLOCK_START = (NUMBER_OF_BLOCKS - 1) * OPTIMAL_LENGTH;
    localparam LAST_BLOCK_WIDTH = WIDTH - LAST_BLOCK_START; 

    wire [NUMBER_OF_BLOCKS : 0] block_carry;
    wire [NUMBER_OF_BLOCKS : 0] propagate;
    wire [NUMBER_OF_BLOCKS : 0] ripple_co;
    wire [WIDTH -1 : 0] x_used;
    assign x_used = x ^ {WIDTH{s}};

    assign block_carry[0] = s;

    normal_rca #(OPTIMAL_LENGTH) first (.x(x_used[0 +: OPTIMAL_LENGTH]),.y(y[0 +: OPTIMAL_LENGTH]),. ci(block_carry[0]),.sum(sum[0 +: OPTIMAL_LENGTH]),. co(block_carry[1]));

    genvar i;
    generate
        for(i = 1;i < NUMBER_OF_BLOCKS - 1;i = i + 1) begin : SKIP_RCA_INITIALIZATION
            skip_rca #(OPTIMAL_LENGTH) skip_blocks (.x(x_used[i * OPTIMAL_LENGTH +: OPTIMAL_LENGTH]),.y(y[i * OPTIMAL_LENGTH +: OPTIMAL_LENGTH]),.ci(block_carry[i]),.sum(sum[i * OPTIMAL_LENGTH +: OPTIMAL_LENGTH]),.co(ripple_co[i]),.propagate(propagate[i]));

            assign block_carry[i+1]=(propagate[i] & block_carry[i]) | ripple_co[i];
        end
    endgenerate

    normal_rca #(LAST_BLOCK_WIDTH) last (.x(x_used[LAST_BLOCK_START +: LAST_BLOCK_WIDTH]),.y(y[LAST_BLOCK_START +: LAST_BLOCK_WIDTH]),.ci(block_carry[NUMBER_OF_BLOCKS - 1]),.sum(sum[LAST_BLOCK_START +: LAST_BLOCK_WIDTH]),.co(co));
endmodule


module tb_cska;

    parameter WIDTH = 16;
    
    reg [WIDTH-1:0] x;
    reg [WIDTH-1:0] y;
    reg s;
    
    wire [WIDTH-1:0] sum;
    wire co;

    cska #(WIDTH) uut (.x(x),.y(y),.s(s),.sum(sum),.co(co));

    initial begin
        $display("=====================================================================");
        $display("   Time | Mode |   y   |   x   ||  sum  | co | (Expected sum)");
        $display("=====================================================================");
        $monitor("%7t |  %b   | %5d | %5d || %6d |  %b |", $time, s, y, x, $signed(sum), co);
    end

    initial begin
        x = 0; y = 0; s = 0;
        #10;

        $display("--- Testing Addition (s = 0) => y + x ---");
        s = 0; y = 10; x = 15; #10;
        s = 0; y = 100; x = 50; #10;
        
        $display("--- Testing Subtraction (s = 1) => y - x ---");
        s = 1; y = 20; x = 5;  #10;
        s = 1; y = 100; x = 50; #10;
        
        $display("--- Testing Carry Out / Overflow ---");
        s = 0; y = 16'hFFFF; x = 16'h0001; #10;
        
        $display("--- Testing Negative Result (2's Complement) ---");
        s = 1; y = 10; x = 15; #10;

        $display("=====================================================================");
    end

endmodule