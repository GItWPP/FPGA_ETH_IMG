//--------------------------------------------------------------------------------------------------------
// 模块： hog_linear_svm_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 遍历495个单尺度窗口，以3780维定点特征及已训练权重计算线性SVM
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_linear_svm_top
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire                   start_valid            ,
    output  wire                   start_ready            ,
    output  wire                   done_flag              ,
    output  wire           [15:0]  feature_rd_addr        ,
    input   wire           [9:0]   feature_rd_data        ,
    output  wire                   score_wr_en            ,
    output  wire           [8:0]   score_wr_addr          ,
    output  wire           [31:0]  score_wr_data          ,
    output  wire           [31:0]  model_id
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [2:0] IDLE             = 3'd0;
localparam [2:0] WAIT             = 3'd1;
localparam [2:0] GET              = 3'd2;
localparam [2:0] MAC              = 3'd3;
localparam [2:0] STORE            = 3'd4;
localparam [2:0] FINISH           = 3'd5;
//wire  define
wire    signed [15:0]  weight_rd_data;
wire    signed [31:0]  bias;
wire                   last_term;
wire    signed [47:0]  extended_product;
wire    signed [47:0]  extended_bias;
//reg   define
reg            [2:0]   state;
reg            [2:0]   next_state;
reg            [5:0]   window_x;
reg            [3:0]   window_y;
reg            [2:0]   block_x;
reg            [3:0]   block_y;
reg            [5:0]   component_index;
reg            [11:0]  weight_rd_addr;
reg            [8:0]   score_index;
reg     signed [26:0]  product;
reg     signed [47:0]  accumulator;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign start_ready = (state == IDLE);
assign done_flag = (state == FINISH);
assign feature_rd_addr = (({12'd0, window_y} + {12'd0, block_y}) * 16'd39
                       + {10'd0, window_x} + {13'd0, block_x}) * 16'd36 + {10'd0, component_index};
assign score_wr_en = (state == STORE);
assign score_wr_addr = score_index;
assign score_wr_data = (accumulator > 48'sd2147483647) ? 32'h7fffffff
                     : (accumulator < -48'sd2147483648) ? 32'h80000000 : accumulator[31:0];
assign last_term = (block_x == 3'd6 && block_y == 4'd14 && component_index == 6'd35);
assign extended_product = {{21{product[26]}}, product};
assign extended_bias = {{16{bias[31]}}, bias};

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_valid) next_state = WAIT;
        WAIT: next_state = GET;
        GET: next_state = MAC;
        MAC: next_state = last_term ? STORE : WAIT;
        STORE: next_state = (score_index == 9'd494) ? FINISH : WAIT;
        FINISH: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        component_index <= 6'd0;
        block_x <= 3'd0;
        block_y <= 4'd0;
        weight_rd_addr <= 12'd0;
    end else if(state == IDLE || state == STORE) begin
        component_index <= 6'd0;
        block_x <= 3'd0;
        block_y <= 4'd0;
        weight_rd_addr <= 12'd0;
    end else if(state == MAC && !last_term) begin
        weight_rd_addr <= weight_rd_addr + 1'b1;
        if(component_index == 6'd35) begin
            component_index <= 6'd0;
            if(block_x == 3'd6) begin
                block_x <= 3'd0;
                block_y <= block_y + 1'b1;
            end else
                block_x <= block_x + 1'b1;
        end else
            component_index <= component_index + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        window_x <= 6'd0;
        window_y <= 4'd0;
        score_index <= 9'd0;
    end else if(state == IDLE) begin
        window_x <= 6'd0;
        window_y <= 4'd0;
        score_index <= 9'd0;
    end else if(state == STORE) begin
        score_index <= score_index + 1'b1;
        if(window_x == 6'd32) begin
            window_x <= 6'd0;
            window_y <= window_y + 1'b1;
        end else
            window_x <= window_x + 1'b1;
    end

//GET捕获同步RAM/ROM数据，下一拍MAC使用该乘积，避免读延迟错位
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        product <= 27'sd0;
    else if(state == GET)
        product <= $signed({1'b0, feature_rd_data}) * weight_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        accumulator <= 48'sd0;
    else if(state == IDLE || state == STORE)
        accumulator <= extended_bias;
    else if(state == MAC)
        accumulator <= accumulator + extended_product;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
hog_svm_model
hog_svm_model_inst
(
    .sys_clk               (sys_clk               ),
    .weight_rd_addr        (weight_rd_addr        ),
    .weight_rd_data        (weight_rd_data        ),
    .bias                  (bias                  ),
    .model_id              (model_id              )
);
endmodule
