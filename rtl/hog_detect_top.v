//--------------------------------------------------------------------------------------------------------
// 模块： hog_detect_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 单尺度HOG检测算法顶层，仅连接分阶段计算引擎和帧/直方图/特征/得分RAM
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_detect_top
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire                   frame_wr_en            ,
    input   wire           [16:0]  frame_wr_addr          ,
    input   wire           [7:0]   frame_wr_data          ,
    input   wire                   start_valid            ,
    output  wire                   start_ready            ,
    output  wire                   done_flag              ,
    input   wire           [8:0]   score_rd_addr          ,
    output  wire           [31:0]  score_rd_data          ,
    output  wire           [31:0]  model_id
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [2:0] IDLE             = 3'd0;
localparam [2:0] HIST_REQ         = 3'd1;
localparam [2:0] HIST_WAIT        = 3'd2;
localparam [2:0] NORM_REQ         = 3'd3;
localparam [2:0] NORM_WAIT        = 3'd4;
localparam [2:0] SVM_REQ          = 3'd5;
localparam [2:0] SVM_WAIT         = 3'd6;
localparam [2:0] FINISH           = 3'd7;
//wire  define
wire                   hist_ready;
wire                   hist_done;
wire                   norm_ready;
wire                   norm_done;
wire                   svm_ready;
wire                   svm_done;
wire                   hist_phase;
wire           [16:0]  frame_rd_addr;
wire           [7:0]   frame_rd_data;
wire                   hist_wr_en;
wire           [13:0]  hist_wr_addr;
wire           [15:0]  hist_wr_data;
wire           [13:0]  cell_rd_addr;
wire           [13:0]  norm_rd_addr;
wire           [15:0]  hist_rd_data;
wire                   feature_wr_en;
wire           [15:0]  feature_wr_addr;
wire           [9:0]   feature_wr_data;
wire           [15:0]  feature_rd_addr;
wire           [9:0]   feature_rd_data;
wire                   score_wr_en;
wire           [8:0]   score_wr_addr;
wire           [31:0]  score_wr_data;
//reg   define
reg            [2:0]   state;
reg            [2:0]   next_state;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign start_ready = (state == IDLE);
assign done_flag = (state == FINISH);
assign hist_phase = (state == HIST_REQ || state == HIST_WAIT);

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(start_valid) next_state = HIST_REQ;
        HIST_REQ: if(hist_ready) next_state = HIST_WAIT;
        HIST_WAIT: if(hist_done) next_state = NORM_REQ;
        NORM_REQ: if(norm_ready) next_state = NORM_WAIT;
        NORM_WAIT: if(norm_done) next_state = SVM_REQ;
        SVM_REQ: if(svm_ready) next_state = SVM_WAIT;
        SVM_WAIT: if(svm_done) next_state = FINISH;
        FINISH: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
hog_ram
#(
    .ADDR_WIDTH            (17),
    .DATA_WIDTH            (8),
    .DEPTH                 (76800)
)
frame_ram_inst
(
    .sys_clk               (sys_clk),
    .wr_en                 (frame_wr_en && start_ready),
    .wr_addr               (frame_wr_addr),
    .wr_data               (frame_wr_data),
    .rd_addr               (frame_rd_addr),
    .rd_data               (frame_rd_data)
);

hog_ram
#(
    .ADDR_WIDTH            (14),
    .DATA_WIDTH            (16),
    .DEPTH                 (10800)
)
histogram_ram_inst
(
    .sys_clk               (sys_clk),
    .wr_en                 (hist_wr_en),
    .wr_addr               (hist_wr_addr),
    .wr_data               (hist_wr_data),
    .rd_addr               (hist_phase ? cell_rd_addr : norm_rd_addr),
    .rd_data               (hist_rd_data)
);

hog_ram
#(
    .ADDR_WIDTH            (16),
    .DATA_WIDTH            (10),
    .DEPTH                 (40716)
)
feature_ram_inst
(
    .sys_clk               (sys_clk),
    .wr_en                 (feature_wr_en),
    .wr_addr               (feature_wr_addr),
    .wr_data               (feature_wr_data),
    .rd_addr               (feature_rd_addr),
    .rd_data               (feature_rd_data)
);

hog_ram
#(
    .ADDR_WIDTH            (9),
    .DATA_WIDTH            (32),
    .DEPTH                 (495)
)
score_ram_inst
(
    .sys_clk               (sys_clk),
    .wr_en                 (score_wr_en),
    .wr_addr               (score_wr_addr),
    .wr_data               (score_wr_data),
    .rd_addr               (score_rd_addr),
    .rd_data               (score_rd_data)
);

hog_cell_hist_top
hog_cell_hist_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .start_valid           (state == HIST_REQ     ),
    .start_ready           (hist_ready            ),
    .done_flag             (hist_done             ),
    .frame_rd_addr         (frame_rd_addr         ),
    .frame_rd_data         (frame_rd_data         ),
    .hist_wr_en            (hist_wr_en            ),
    .hist_wr_addr          (hist_wr_addr          ),
    .hist_wr_data          (hist_wr_data          ),
    .hist_rd_addr          (cell_rd_addr          ),
    .hist_rd_data          (hist_rd_data          )
);

hog_block_norm_top
hog_block_norm_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .start_valid           (state == NORM_REQ     ),
    .start_ready           (norm_ready            ),
    .done_flag             (norm_done             ),
    .hist_rd_addr          (norm_rd_addr          ),
    .hist_rd_data          (hist_rd_data          ),
    .feature_wr_en         (feature_wr_en         ),
    .feature_wr_addr       (feature_wr_addr       ),
    .feature_wr_data       (feature_wr_data       )
);

hog_linear_svm_top
hog_linear_svm_top_inst
(
    .sys_clk               (sys_clk               ),
    .sys_rst_n             (sys_rst_n             ),
    .start_valid           (state == SVM_REQ      ),
    .start_ready           (svm_ready             ),
    .done_flag             (svm_done              ),
    .feature_rd_addr       (feature_rd_addr       ),
    .feature_rd_data       (feature_rd_data       ),
    .score_wr_en           (score_wr_en           ),
    .score_wr_addr         (score_wr_addr         ),
    .score_wr_data         (score_wr_data         ),
    .model_id              (model_id              )
);
endmodule
