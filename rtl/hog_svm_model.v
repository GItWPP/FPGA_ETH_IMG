//--------------------------------------------------------------------------------------------------------
// 模块： hog_svm_model
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 整数HOG专用已训练线性SVM权重ROM与模型标识
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_svm_model
(
    input   wire                   sys_clk                ,
    input   wire           [11:0]  weight_rd_addr         ,
    output  reg     signed [15:0]  weight_rd_data         ,
    output  wire    signed [31:0]  bias                   ,
    output  wire           [31:0]  model_id
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//reg   define
(* rom_style = "block" *) reg signed [15:0] weights [0:3779];

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign bias = 32'hffa0dce8;
assign model_id = 32'h7803ac83;

//训练工具导出，与软件参考使用同一模型；文件纳入Vivado工程
initial
    $readmemh("hog_svm_weights.mem", weights);

always@(posedge sys_clk)
    weight_rd_data <= weights[weight_rd_addr];

endmodule
