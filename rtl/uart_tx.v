//--------------------------------------------------------------------------------------------------------
// 模块： uart_tx
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 分数计时的8N1发送，支持字节valid/ready握手
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  uart_tx
#(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer UART_BPS = 1_500_000
)
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire           [7:0]   data                   ,   //握手时装入字节
    input   wire                   data_valid             ,

    output  wire                   data_ready             ,
    output  wire                   tx                     //8N1串行输出，空闲为高
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [3:0] STOP_BIT = 4'd9;

//wire  define
wire                   byte_accept;
wire                   bit_tick;

//reg   define
reg                    busy;
reg            [9:0]   shift_data;
reg            [3:0]   bit_cnt;
reg            [31:0]  phase;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign data_ready  = !busy;
assign byte_accept = data_valid && data_ready;
assign bit_tick    = (phase >= CLK_HZ - UART_BPS);
assign tx          = busy ? shift_data[0] : 1'b1;

//busy:停止位完整发送后才允许装入下一个字节
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        busy <= 1'b0;
    else if(byte_accept)
        busy <= 1'b1;
    else if(busy && bit_tick && bit_cnt == STOP_BIT)
        busy <= 1'b0;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        phase <= 32'd0;
    else if(byte_accept)
        phase <= 32'd0;
    else if(busy) begin
        if(bit_tick)
            phase <= phase + UART_BPS - CLK_HZ;
        else
            phase <= phase + UART_BPS;
    end

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        bit_cnt <= 4'd0;
    else if(byte_accept)
        bit_cnt <= 4'd0;
    else if(busy && bit_tick && bit_cnt != STOP_BIT)
        bit_cnt <= bit_cnt + 1'b1;

//shift_data:低位先发送，起始位0、八位数据、停止位1
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        shift_data <= 10'h3ff;
    else if(byte_accept)
        shift_data <= {1'b1, data, 1'b0};
    else if(busy && bit_tick)
        shift_data <= {1'b1, shift_data[9:1]};

endmodule
