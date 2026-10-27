//--------------------------------------------------------------------------------------------------------
// 模块： hog_block_norm_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 四cell组成block，逐特征恢复除法实现L1定点Q10归一化
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_block_norm_top
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire                   start_valid            ,
    output  wire                   start_ready            ,
    output  wire                   done_flag              ,
    output  wire           [13:0]  hist_rd_addr           ,
    input   wire           [15:0]  hist_rd_data           ,
    output  wire                   feature_wr_en          ,
    output  wire           [15:0]  feature_wr_addr        ,
    output  wire           [9:0]   feature_wr_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [2:0] IDLE             = 3'd0;
localparam [2:0] SUMWAIT          = 3'd1;
localparam [2:0] SUMGET           = 3'd2;
localparam [2:0] DIVREQ           = 3'd3;
localparam [2:0] DIVWAIT          = 3'd4;
localparam [2:0] WRITE            = 3'd5;
localparam [2:0] FINISH           = 3'd6;
//wire  define
wire                   div_in_ready;
wire                   div_out_valid;
wire           [25:0]  quotient;
wire           [25:0]  numerator;
wire           [16:0]  denominator;
//reg   define
reg            [2:0]   state;
reg            [2:0]   next_state;
reg            [5:0]   block_x;
reg            [4:0]   block_y;
reg            [5:0]   sample_index;
reg            [5:0]   value_index;
reg            [16:0]  block_sum;
reg            [15:0]  value_cache [0:35];
reg            [15:0]  feature_addr;
reg            [9:0]   feature_value;
reg            [5:0]   cell_x;
reg            [4:0]   cell_y;
reg            [3:0]   bin_index;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign start_ready = (state == IDLE);
assign done_flag = (state == FINISH);
assign hist_rd_addr = (({9'd0, cell_y} * 14'd40) + {8'd0, cell_x}) * 14'd9 + {10'd0, bin_index};
assign numerator = {value_cache[value_index], 10'd0};
assign denominator = block_sum + 1'b1;
assign feature_wr_en = (state == WRITE);
assign feature_wr_addr = feature_addr;
assign feature_wr_data = feature_value;

always@(*) begin
    cell_x = block_x;
    cell_y = block_y;
    bin_index = sample_index[3:0];
    if(sample_index >= 6'd27) begin
        cell_x = block_x + 1'b1;
        cell_y = block_y + 1'b1;
        bin_index = sample_index - 6'd27;
    end else if(sample_index >= 6'd18) begin
        cell_y = block_y + 1'b1;
        bin_index = sample_index - 6'd18;
    end else if(sample_index >= 6'd9) begin
        cell_x = block_x + 1'b1;
        bin_index = sample_index - 6'd9;
    end
end

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_valid) next_state = SUMWAIT;
        SUMWAIT: next_state = SUMGET;
        SUMGET: next_state = (sample_index == 6'd35) ? DIVREQ : SUMWAIT;
        DIVREQ: if(div_in_ready) next_state = DIVWAIT;
        DIVWAIT: if(div_out_valid) next_state = WRITE;
        WRITE: if(value_index == 6'd35)
                   next_state = (block_x == 6'd38 && block_y == 5'd28) ? FINISH : SUMWAIT;
               else next_state = DIVREQ;
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
        block_x <= 6'd0;
        block_y <= 5'd0;
    end else if(state == IDLE) begin
        block_x <= 6'd0;
        block_y <= 5'd0;
    end else if(state == WRITE && value_index == 6'd35) begin
        if(block_x == 6'd38) begin
            block_x <= 6'd0;
            block_y <= block_y + 1'b1;
        end else
            block_x <= block_x + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        sample_index <= 6'd0;
        block_sum <= 17'd0;
    end else if(state == IDLE || (state == WRITE && value_index == 6'd35)) begin
        sample_index <= 6'd0;
        block_sum <= 17'd0;
    end else if(state == SUMGET) begin
        block_sum <= block_sum + {1'b0, hist_rd_data};
        if(sample_index != 6'd35) sample_index <= sample_index + 1'b1;
    end

//36个缓存元素在使用前全部重写，数据阵列不加复位
always@(posedge sys_clk)
    if(state == SUMGET)
        value_cache[sample_index] <= hist_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        value_index <= 6'd0;
        feature_addr <= 16'd0;
    end else if(state == IDLE) begin
        value_index <= 6'd0;
        feature_addr <= 16'd0;
    end else if(state == WRITE) begin
        value_index <= (value_index == 6'd35) ? 6'd0 : value_index + 1'b1;
        feature_addr <= feature_addr + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        feature_value <= 10'd0;
    else if(state == DIVWAIT && div_out_valid)
        feature_value <= quotient[9:0];

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
hog_unsigned_div
hog_unsigned_div_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .numerator             (numerator             ),
    .denominator           (denominator           ),
    .in_valid              (state == DIVREQ       ),
    .in_ready              (div_in_ready          ),
    .quotient              (quotient              ),
    .out_valid             (div_out_valid         ),
    .out_ready             (state == DIVWAIT      )
);
endmodule
