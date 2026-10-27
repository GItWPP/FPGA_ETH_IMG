//--------------------------------------------------------------------------------------------------------
// 模块： img_gamma_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 固定Gamma暗部提亮，黑白端点保持
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_gamma_top
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

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
//gamma=0.5，原生颜色分量的精确整数查找表
function [4:0] gamma5;
    input [4:0] value;
    begin
        case(value)
            5'd0: gamma5 = 5'd0;
            5'd1: gamma5 = 5'd5;
            5'd2: gamma5 = 5'd7;
            5'd3: gamma5 = 5'd9;
            5'd4: gamma5 = 5'd11;
            5'd5: gamma5 = 5'd12;
            5'd6: gamma5 = 5'd13;
            5'd7: gamma5 = 5'd14;
            5'd8: gamma5 = 5'd15;
            5'd9: gamma5 = 5'd16;
            5'd10: gamma5 = 5'd17;
            5'd11: gamma5 = 5'd18;
            5'd12: gamma5 = 5'd19;
            5'd13: gamma5 = 5'd20;
            5'd14: gamma5 = 5'd20;
            5'd15: gamma5 = 5'd21;
            5'd16: gamma5 = 5'd22;
            5'd17: gamma5 = 5'd22;
            5'd18: gamma5 = 5'd23;
            5'd19: gamma5 = 5'd24;
            5'd20: gamma5 = 5'd24;
            5'd21: gamma5 = 5'd25;
            5'd22: gamma5 = 5'd26;
            5'd23: gamma5 = 5'd26;
            5'd24: gamma5 = 5'd27;
            5'd25: gamma5 = 5'd27;
            5'd26: gamma5 = 5'd28;
            5'd27: gamma5 = 5'd28;
            5'd28: gamma5 = 5'd29;
            5'd29: gamma5 = 5'd29;
            5'd30: gamma5 = 5'd30;
            5'd31: gamma5 = 5'd31;
            default: gamma5 = 5'd0;
        endcase
    end
endfunction

//gamma=0.5，原生颜色分量的精确整数查找表
function [5:0] gamma6;
    input [5:0] value;
    begin
        case(value)
            6'd0: gamma6 = 6'd0;
            6'd1: gamma6 = 6'd7;
            6'd2: gamma6 = 6'd11;
            6'd3: gamma6 = 6'd13;
            6'd4: gamma6 = 6'd15;
            6'd5: gamma6 = 6'd17;
            6'd6: gamma6 = 6'd19;
            6'd7: gamma6 = 6'd21;
            6'd8: gamma6 = 6'd22;
            6'd9: gamma6 = 6'd23;
            6'd10: gamma6 = 6'd25;
            6'd11: gamma6 = 6'd26;
            6'd12: gamma6 = 6'd27;
            6'd13: gamma6 = 6'd28;
            6'd14: gamma6 = 6'd29;
            6'd15: gamma6 = 6'd30;
            6'd16: gamma6 = 6'd31;
            6'd17: gamma6 = 6'd32;
            6'd18: gamma6 = 6'd33;
            6'd19: gamma6 = 6'd34;
            6'd20: gamma6 = 6'd35;
            6'd21: gamma6 = 6'd36;
            6'd22: gamma6 = 6'd37;
            6'd23: gamma6 = 6'd38;
            6'd24: gamma6 = 6'd38;
            6'd25: gamma6 = 6'd39;
            6'd26: gamma6 = 6'd40;
            6'd27: gamma6 = 6'd41;
            6'd28: gamma6 = 6'd42;
            6'd29: gamma6 = 6'd42;
            6'd30: gamma6 = 6'd43;
            6'd31: gamma6 = 6'd44;
            6'd32: gamma6 = 6'd44;
            6'd33: gamma6 = 6'd45;
            6'd34: gamma6 = 6'd46;
            6'd35: gamma6 = 6'd46;
            6'd36: gamma6 = 6'd47;
            6'd37: gamma6 = 6'd48;
            6'd38: gamma6 = 6'd48;
            6'd39: gamma6 = 6'd49;
            6'd40: gamma6 = 6'd50;
            6'd41: gamma6 = 6'd50;
            6'd42: gamma6 = 6'd51;
            6'd43: gamma6 = 6'd52;
            6'd44: gamma6 = 6'd52;
            6'd45: gamma6 = 6'd53;
            6'd46: gamma6 = 6'd53;
            6'd47: gamma6 = 6'd54;
            6'd48: gamma6 = 6'd54;
            6'd49: gamma6 = 6'd55;
            6'd50: gamma6 = 6'd56;
            6'd51: gamma6 = 6'd56;
            6'd52: gamma6 = 6'd57;
            6'd53: gamma6 = 6'd57;
            6'd54: gamma6 = 6'd58;
            6'd55: gamma6 = 6'd58;
            6'd56: gamma6 = 6'd59;
            6'd57: gamma6 = 6'd59;
            6'd58: gamma6 = 6'd60;
            6'd59: gamma6 = 6'd60;
            6'd60: gamma6 = 6'd61;
            6'd61: gamma6 = 6'd61;
            6'd62: gamma6 = 6'd62;
            6'd63: gamma6 = 6'd63;
            default: gamma6 = 6'd0;
        endcase
    end
endfunction
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
        out_data <= {gamma5(in_data[15:11]), gamma6(in_data[10:5]), gamma5(in_data[4:0])};

endmodule
