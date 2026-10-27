//--------------------------------------------------------------------------------------------------------
// 模块： hog_unsigned_div
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 26位无符号恢复除法，固定26拍迭代及输出反压保持
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_unsigned_div
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire           [25:0]  numerator              ,
    input   wire           [16:0]  denominator            ,
    input   wire                   in_valid               ,
    output  wire                   in_ready               ,
    output  reg            [25:0]  quotient               ,
    output  reg                    out_valid              ,
    input   wire                   out_ready
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                   accept_flag;
wire           [17:0]  shifted_remainder;
wire                   subtract_flag;
wire           [25:0]  next_quotient;
//reg   define
reg                    active;
reg            [4:0]   bit_index;
reg            [25:0]  dividend;
reg            [16:0]  divisor;
reg            [17:0]  remainder;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign in_ready = !active && (!out_valid || out_ready);
assign accept_flag = in_valid && in_ready;
assign shifted_remainder = {remainder[16:0], dividend[25]};
assign subtract_flag = shifted_remainder >= {1'b0, divisor};
assign next_quotient = {quotient[24:0], subtract_flag};

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        active <= 1'b0;
    else if(accept_flag)
        active <= 1'b1;
    else if(active && bit_index == 5'd25)
        active <= 1'b0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        bit_index <= 5'd0;
    else if(accept_flag)
        bit_index <= 5'd0;
    else if(active && bit_index != 5'd25)
        bit_index <= bit_index + 1'b1;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0) begin
        dividend <= 26'd0;
        divisor <= 17'd1;
        remainder <= 18'd0;
    end else if(accept_flag) begin
        dividend <= numerator;
        divisor <= (denominator == 17'd0) ? 17'd1 : denominator;
        remainder <= 18'd0;
    end else if(active) begin
        dividend <= {dividend[24:0], 1'b0};
        remainder <= subtract_flag ? shifted_remainder - {1'b0, divisor} : shifted_remainder;
    end

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        quotient <= 26'd0;
    else if(accept_flag)
        quotient <= 26'd0;
    else if(active)
        quotient <= next_quotient;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_valid <= 1'b0;
    else if(active && bit_index == 5'd25)
        out_valid <= 1'b1;
    else if(out_ready)
        out_valid <= 1'b0;

endmodule
