module reg_m #(parameter WIDTH = 8) (input clk, rst_b, load_inbus, input [WIDTH - 1 : 0] inbus, output reg [WIDTH - 1 : 0] outbus);
    always @(posedge clk, negedge rst_b) begin
        if(!rst_b)              outbus <= 0;
        else if(load_inbus)     outbus <= inbus;
    end
endmodule

module reg_q #(parameter WIDTH = 8) (input clk, rst_b, shift, load_inbus, load_outbus, lsb_A, input [WIDTH - 1 : 0] inbus, output [WIDTH - 1 : 0] outbus, output [WIDTH - 1 : -1] q);
    reg [WIDTH - 1 : -1] q_reg;

    always @(posedge clk, negedge rst_b) begin
        if(!rst_b)              q_reg <= 0;
        else if(load_inbus)     q_reg <= {inbus[WIDTH -1 : 0],1'b0};
        else if(shift)          q_reg <= {lsb_A,q[WIDTH-1 : 0]};
    end

       assign outbus = (load_outbus) ? q_reg[WIDTH -1 : 0] : {WIDTH{1'bz}};

       assign q = q_reg;
endmodule

module reg_a #(parameter WIDTH = 8) (input clk, rst_b, shift, load_reg, load_result, load_outbus, input [WIDTH - 1 : 0] adder_sum, output [WIDTH - 1 : 0] outbus, a, output lsb_A);
    reg [WIDTH - 1 : 0] a_reg;

    always @(posedge clk, negedge rst_b)begin
        if(!rst_b)              a_reg <= 0;
        else if(load_reg)       a_reg <= 0;
        else if(load_result)    a_reg <= adder_sum;
        else if(shift)          a_reg <= {a_reg[WIDTH - 1],a_reg[WIDTH - 1 : 1]};
    end

    assign outbus = (load_outbus) ? a_reg : {WIDTH{1'bz}};

    assign a = a_reg;
    assign lsb_A=a_reg[0];
endmodule

module cntr #(parameter w=8)(input clk, rst_b, c_up, clr, output reg [w-1:0] q);
    always @ (posedge clk, negedge rst_b)
        if (!rst_b)					q <= 0;
        else if (c_up)				q <= q + 1;
        else if (clr)				q <= 0;
endmodule