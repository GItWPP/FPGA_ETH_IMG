//--------------------------------------------------------------------------------------------------------
// 模块： img_block_buffer
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 单时钟简单双端口块缓存，同步读取，不复位存储阵列
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_block_buffer
#(
    parameter integer ADDR_WIDTH = 10
)
(
    input   wire                             sys_clk                ,
    input   wire                             wr_en                  ,
    input   wire           [ADDR_WIDTH-1:0]  wr_addr                ,
    input   wire           [7:0]             wr_data                ,
    input   wire           [ADDR_WIDTH-1:0]  rd_addr                ,

    output  reg            [7:0]             rd_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam integer DEPTH = 2 ** ADDR_WIDTH;

//reg   define
(* ram_style = "block" *) reg [7:0] mem [0:DEPTH-1];

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
//存储阵列不复位；读数据延迟一个时钟，由外部有效状态屏蔽未写入内容
always@(posedge sys_clk)
    if(wr_en)
        mem[wr_addr] <= wr_data;

always@(posedge sys_clk)
    rd_data <= mem[rd_addr];

endmodule
