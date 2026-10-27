//--------------------------------------------------------------------------------------------------------
// 模块： img_sharpen_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 彩色十字核3x3锐化，分量独立有符号计算并钳位
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_sharpen_top
(
    input   wire                    sys_clk                ,
    input   wire                    sys_rst_n              ,
    input   wire           [143:0]  window_data            ,
    input   wire                    in_valid               ,
    output  wire                    in_ready               ,

    output  reg            [15:0]   out_data               ,
    output  reg                     out_valid              ,
    input   wire                    out_ready
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire    signed [11:0]   gradient_red;
wire           [4:0]    sharp_red;
wire    signed [11:0]   gradient_green;
wire           [5:0]    sharp_green;
wire    signed [11:0]   gradient_blue;
wire           [4:0]    sharp_blue;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign gradient_red = ($signed({7'd0, window_data[79:75]}) <<< 2) + $signed({7'd0, window_data[79:75]})
                        - $signed({7'd0, window_data[31:27]})                        - $signed({7'd0, window_data[63:59]})                        - $signed({7'd0, window_data[95:91]})                        - $signed({7'd0, window_data[127:123]});
assign sharp_red = (gradient_red < 12'sd0) ? 5'd0
                  : ((gradient_red > 12'sd31) ? 5'd31 : gradient_red[4:0]);
assign gradient_green = ($signed({6'd0, window_data[74:69]}) <<< 2) + $signed({6'd0, window_data[74:69]})
                        - $signed({6'd0, window_data[26:21]})                        - $signed({6'd0, window_data[58:53]})                        - $signed({6'd0, window_data[90:85]})                        - $signed({6'd0, window_data[122:117]});
assign sharp_green = (gradient_green < 12'sd0) ? 6'd0
                  : ((gradient_green > 12'sd63) ? 6'd63 : gradient_green[5:0]);
assign gradient_blue = ($signed({7'd0, window_data[68:64]}) <<< 2) + $signed({7'd0, window_data[68:64]})
                        - $signed({7'd0, window_data[20:16]})                        - $signed({7'd0, window_data[52:48]})                        - $signed({7'd0, window_data[84:80]})                        - $signed({7'd0, window_data[116:112]});
assign sharp_blue = (gradient_blue < 12'sd0) ? 5'd0
                  : ((gradient_blue > 12'sd31) ? 5'd31 : gradient_blue[4:0]);
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
        out_data <= {sharp_red, sharp_green, sharp_blue};

endmodule
