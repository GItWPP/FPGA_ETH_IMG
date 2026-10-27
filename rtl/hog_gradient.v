//--------------------------------------------------------------------------------------------------------
// 模块： hog_gradient
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 中心差分、L1幅值与九个无符号方向区间，纯整数斜率比较
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_gradient
(
    input   wire           [7:0]   pixel_left             ,
    input   wire           [7:0]   pixel_right            ,
    input   wire           [7:0]   pixel_up               ,
    input   wire           [7:0]   pixel_down             ,
    output  wire           [9:0]   magnitude              ,
    output  wire           [3:0]   direction
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire    signed [8:0]   gradient_x;
wire    signed [8:0]   gradient_y;
wire           [8:0]   absolute_x;
wire           [8:0]   absolute_y;
wire           [20:0]  scaled_y;
//reg   define
reg            [3:0]   base_bin;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign gradient_x = $signed({1'b0, pixel_right}) - $signed({1'b0, pixel_left});
assign gradient_y = $signed({1'b0, pixel_down}) - $signed({1'b0, pixel_up});
assign absolute_x = gradient_x[8] ? -gradient_x : gradient_x;
assign absolute_y = gradient_y[8] ? -gradient_y : gradient_y;
assign magnitude = {1'b0, absolute_x} + {1'b0, absolute_y};
assign scaled_y = {4'd0, absolute_y, 8'd0};
assign direction = (absolute_y == 9'd0) ? 4'd0
                 : ((gradient_x[8] ^ gradient_y[8]) ? 4'd8 - base_bin : base_bin);

//20/40/60/80度的正切阈值采用Q8整数；垂直方向始终映射到第4区间
always@(*) begin
    base_bin = 4'd4;
    if(scaled_y < absolute_x * 21'd93)
        base_bin = 4'd0;
    else if(scaled_y < absolute_x * 21'd215)
        base_bin = 4'd1;
    else if(scaled_y < absolute_x * 21'd443)
        base_bin = 4'd2;
    else if(scaled_y < absolute_x * 21'd1452)
        base_bin = 4'd3;
end

endmodule
