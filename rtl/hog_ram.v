//--------------------------------------------------------------------------------------------------------
// 模块： hog_ram
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 同步简单双口块RAM，不复位数据存储体
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_ram
#(
    parameter integer ADDR_WIDTH = 17,
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH = 76800
)
(
    input   wire                             sys_clk                ,
    input   wire                             wr_en                  ,
    input   wire           [ADDR_WIDTH-1:0]  wr_addr                ,
    input   wire           [DATA_WIDTH-1:0]  wr_data                ,
    input   wire           [ADDR_WIDTH-1:0]  rd_addr                ,
    output  reg            [DATA_WIDTH-1:0]  rd_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//reg   define
(* ram_style = "block" *) reg [DATA_WIDTH-1:0] memory [0:DEPTH-1];

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always@(posedge sys_clk)
    if(wr_en)
        memory[wr_addr] <= wr_data;

//读数据只在上升沿更新，下游WAIT/GET与该延迟对齐
always@(posedge sys_clk)
    rd_data <= memory[rd_addr];

endmodule
