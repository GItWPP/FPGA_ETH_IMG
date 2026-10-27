//--------------------------------------------------------------------------------------------------------
// 模块： band_decode_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： Band独立解码顶层，互连灰度帧缓存、点检测、行缓存和网格判决
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  band_decode_top
#(
    parameter integer USE_ULTRARAM = 0
)
(
    input   wire            sys_clk        ,
    input   wire            sys_rst_n      ,
    input   wire            frame_wr_en    ,
    input   wire    [17:0]  frame_wr_addr  ,
    input   wire    [7:0]   frame_wr_data  ,
    input   wire    [9:0]   image_width    ,
    input   wire    [9:0]   image_height   ,
    input   wire            start_valid    ,
    output  wire            start_ready    ,
    output  wire            done_flag      ,
    output  wire    [15:0]  result_count   ,
    output  wire    [7:0]   result_rows    ,
    output  wire    [15:0]  pitch_q8       ,
    output  wire    [7:0]   result_status  ,
    output  wire    [15:0]  detected_dots  ,
    input   wire    [11:0]  result_rd_addr ,
    output  reg     [31:0]  result_rd_data
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                    detector_ready;
wire                    accept_flag;
wire           [17:0]   frame_rd_addr;
wire           [7:0]    frame_rd_data;
wire                    dot_valid;
wire           [8:0]    dot_x;
wire           [8:0]    dot_y;
wire           [7:0]    dot_contrast;
wire                    scan_done_flag;
wire                    store_done_flag;
wire                    overflow_flag;
wire           [11:0]   dot_count;
wire           [6:0]    row_count;
wire           [10:0]   dot_rd_addr;
wire           [25:0]   dot_rd_data;
wire           [5:0]    row_rd_addr;
wire           [43:0]   row_rd_data;
wire                    result_wr_en;
wire           [11:0]   result_wr_addr;
wire           [31:0]   result_wr_data;
//reg   define
reg                     busy;
(* ram_style = "block" *) reg [31:0] result_mem [0:4095];

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign start_ready = detector_ready && !busy;
assign accept_flag = start_valid && start_ready;
assign detected_dots = {4'd0, dot_count};

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        busy <= 1'b0;
    else if(accept_flag)
        busy <= 1'b1;
    else if(done_flag)
        busy <= 1'b0;

always@(posedge sys_clk) begin
    if(result_wr_en)
        result_mem[result_wr_addr] <= result_wr_data;
    result_rd_data <= result_mem[result_rd_addr];
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
generate
    if(USE_ULTRARAM) begin : ultra_frame
img_byte_uram
#(
    .ADDR_WIDTH     (18             )
)
band_frame_ram_inst
(
    .sys_clk        (sys_clk        ),
    .wr_en          (frame_wr_en    ),
    .wr_addr        (frame_wr_addr  ),
    .wr_data        (frame_wr_data  ),
    .rd_addr        (frame_rd_addr  ),
    .rd_data        (frame_rd_data  )
);
    end else begin : block_frame
img_block_buffer
#(
    .ADDR_WIDTH     (18             )
)
band_frame_ram_inst
(
    .sys_clk        (sys_clk        ),
    .wr_en          (frame_wr_en    ),
    .wr_addr        (frame_wr_addr  ),
    .wr_data        (frame_wr_data  ),
    .rd_addr        (frame_rd_addr  ),
    .rd_data        (frame_rd_data  )
);
    end
endgenerate

band_dot_detect
band_dot_detect_inst
(
    .sys_clk        (sys_clk        ),
    .sys_rst_n      (sys_rst_n      ),
    .start_valid    (accept_flag    ),
    .start_ready    (detector_ready ),
    .image_width    (image_width    ),
    .image_height   (image_height   ),
    .frame_rd_addr  (frame_rd_addr  ),
    .frame_rd_data  (frame_rd_data  ),
    .dot_valid      (dot_valid      ),
    .dot_x          (dot_x          ),
    .dot_y          (dot_y          ),
    .dot_contrast   (dot_contrast   ),
    .done_flag      (scan_done_flag )
);

band_row_store
band_row_store_inst
(
    .sys_clk        (sys_clk        ),
    .sys_rst_n      (sys_rst_n      ),
    .clear_flag     (accept_flag    ),
    .dot_valid      (dot_valid      ),
    .dot_x          (dot_x          ),
    .dot_y          (dot_y          ),
    .dot_contrast   (dot_contrast   ),
    .scan_done_flag (scan_done_flag ),
    .done_flag      (store_done_flag),
    .overflow_flag  (overflow_flag  ),
    .dot_count      (dot_count      ),
    .row_count      (row_count      ),
    .dot_rd_addr    (dot_rd_addr    ),
    .dot_rd_data    (dot_rd_data    ),
    .row_rd_addr    (row_rd_addr    ),
    .row_rd_data    (row_rd_data    )
);

band_grid_track
band_grid_track_inst
(
    .sys_clk        (sys_clk        ),
    .sys_rst_n      (sys_rst_n      ),
    .start_flag     (store_done_flag),
    .image_width    (image_width    ),
    .stored_rows    (row_count      ),
    .overflow_flag  (overflow_flag  ),
    .row_rd_addr    (row_rd_addr    ),
    .row_rd_data    (row_rd_data    ),
    .dot_rd_addr    (dot_rd_addr    ),
    .dot_rd_data    (dot_rd_data    ),
    .result_wr_en   (result_wr_en   ),
    .result_wr_addr (result_wr_addr ),
    .result_wr_data (result_wr_data ),
    .result_count   (result_count   ),
    .result_rows    (result_rows    ),
    .pitch_q8       (pitch_q8       ),
    .result_status  (result_status  ),
    .done_flag      (done_flag      )
);

endmodule
