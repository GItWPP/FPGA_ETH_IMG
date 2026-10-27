//--------------------------------------------------------------------------------------------------------
// 模块： band_command_top
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： Band串口命令与独立解码算法封装，共享外部包缓存及应答接口
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  band_command_top
#(
    parameter integer USE_ULTRARAM = 0
)
(
    input   wire               sys_clk,
    input   wire               sys_rst_n,
    input   wire               cache_clear,
    input   wire               session_clear,
    output  wire               success_flag,
    output  wire               success_start_flag,
    output  wire               receive_en,
    input   wire               packet_valid,
    output  wire               packet_ready,
    input   wire    [7:0]      req_cmd,
    input   wire    [15:0]     req_id,
    input   wire    [15:0]     req_seq,
    input   wire    [15:0]     req_length,
    input   wire    [15:0]     req_crc,
    output  wire    [9:0]      rx_rd_addr,
    input   wire    [7:0]      rx_rd_data,
    output  wire               result_wr_en,
    output  wire    [9:0]      result_wr_addr,
    output  wire    [7:0]      result_wr_data,
    output  wire               resp_valid,
    input   wire               resp_ready,
    output  wire    [7:0]      resp_cmd,
    output  wire    [15:0]     resp_id,
    output  wire    [15:0]     resp_seq,
    output  wire    [15:0]     resp_length,
    input   wire    [9:0]      resp_addr,
    input   wire    [7:0]      result_rd_data,
    output  wire    [7:0]      resp_data,
    input   wire               resp_done
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire               band_frame_wr_en;
wire    [17:0]     band_frame_wr_addr;
wire    [7:0]      band_frame_wr_data;
wire               band_start_valid;
wire               band_start_ready;
wire               band_done_flag;
wire    [11:0]     band_score_rd_addr;
wire    [31:0]     band_score_rd_data;
wire    [15:0]     band_result_count;
wire    [7:0]      band_result_rows;
wire    [7:0]      band_result_status;
wire    [15:0]     band_pitch_q8;
wire    [15:0]     band_detected_dots;
wire    [9:0]      band_image_width;
wire    [9:0]      band_image_height;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
band_uart_ctrl
band_uart_ctrl_inst
(
    .sys_clk                  (sys_clk                 ),
    .sys_rst_n                (sys_rst_n               ),
    .cache_clear              (cache_clear             ),
    .session_clear            (session_clear           ),
    .success_flag             (success_flag            ),
    .success_start_flag       (success_start_flag      ),
    .receive_en               (receive_en              ),
    .packet_valid             (packet_valid            ),
    .packet_ready             (packet_ready            ),
    .req_cmd                  (req_cmd                 ),
    .req_id                   (req_id                  ),
    .req_seq                  (req_seq                 ),
    .req_length               (req_length              ),
    .req_crc                  (req_crc                 ),
    .rx_rd_addr               (rx_rd_addr              ),
    .rx_rd_data               (rx_rd_data              ),
    .result_wr_en             (result_wr_en            ),
    .result_wr_addr           (result_wr_addr          ),
    .result_wr_data           (result_wr_data          ),
    .resp_valid               (resp_valid              ),
    .resp_ready               (resp_ready              ),
    .resp_cmd                 (resp_cmd                ),
    .resp_id                  (resp_id                 ),
    .resp_seq                 (resp_seq                ),
    .resp_length              (resp_length             ),
    .resp_addr                (resp_addr               ),
    .result_rd_data           (result_rd_data          ),
    .resp_data                (resp_data               ),
    .resp_done                (resp_done               ),
    .band_frame_wr_en         (band_frame_wr_en        ),
    .band_frame_wr_addr       (band_frame_wr_addr      ),
    .band_frame_wr_data       (band_frame_wr_data      ),
    .band_start_valid         (band_start_valid        ),
    .band_start_ready         (band_start_ready        ),
    .band_done_flag           (band_done_flag          ),
    .band_score_rd_addr       (band_score_rd_addr      ),
    .band_score_rd_data       (band_score_rd_data      ),
    .band_result_count        (band_result_count       ),
    .band_result_rows         (band_result_rows        ),
    .band_result_status       (band_result_status      ),
    .band_pitch_q8            (band_pitch_q8           ),
    .band_detected_dots       (band_detected_dots      ),
    .band_image_width         (band_image_width        ),
    .band_image_height        (band_image_height       )
);

band_decode_top
#(
    .USE_ULTRARAM   (USE_ULTRARAM)
)
band_decode_top_inst
(
    .sys_clk                  (sys_clk                 ),
    .sys_rst_n                (sys_rst_n               ),
    .frame_wr_en              (band_frame_wr_en        ),
    .frame_wr_addr            (band_frame_wr_addr      ),
    .frame_wr_data            (band_frame_wr_data      ),
    .image_width              (band_image_width        ),
    .image_height             (band_image_height       ),
    .start_valid              (band_start_valid        ),
    .start_ready              (band_start_ready        ),
    .done_flag                (band_done_flag          ),
    .result_count             (band_result_count       ),
    .result_rows              (band_result_rows        ),
    .result_status            (band_result_status      ),
    .pitch_q8                 (band_pitch_q8           ),
    .detected_dots            (band_detected_dots      ),
    .result_rd_addr           (band_score_rd_addr      ),
    .result_rd_data           (band_score_rd_data      )
);

endmodule
