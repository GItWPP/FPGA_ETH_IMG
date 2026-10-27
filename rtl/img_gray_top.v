//--------------------------------------------------------------------------------------------------------
// 模块： img_gray_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： RGB565灰度化顶层，复用亮度子模块
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_gray_top
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire           [15:0]  in_data                ,
    input   wire                   in_valid               ,
    output  wire                   in_ready               ,

    output  reg            [15:0]  out_data               ,
    output  reg                    out_valid              ,
    input   wire                   out_ready
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire           [7:0]   gray;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign in_ready = !out_valid || out_ready;

//反压时保持有效和像素；仅在输入握手时更新输出数据
always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_valid <= 1'b0;
    else if(in_ready)
        out_valid <= in_valid;

always@(posedge sys_clk or negedge sys_rst_n)
    if(sys_rst_n == 1'b0)
        out_data <= 16'd0;
    else if(in_ready && in_valid)
        out_data <= {gray[7:3], gray[7:2], gray[7:3]};

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_rgb565_luma
img_rgb565_luma_inst
(
    .in_data               (in_data               ),
    .gray                  (gray                  )
);
endmodule
