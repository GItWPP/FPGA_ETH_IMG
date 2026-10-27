//--------------------------------------------------------------------------------------------------------
// 模块： img_fast_command
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 流式Sobel通道与原跨时钟算法桥的命令仲裁
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_fast_command
#(
    parameter integer MAX_WIDTH = 1920,
    parameter integer MAX_HEIGHT = 1080
)
(
    input   wire                    sys_clk                , //高速传输时钟
    input   wire                    sys_rst_n              , //全局复位在传输域同步释放
    input   wire                    algo_clk               , //算法时钟
    input   wire           [95:0]   req_peer,
    output  wire                    receive_en             ,
    input   wire                    packet_valid           ,
    output  wire                    packet_ready           ,
    input   wire           [7:0]    req_cmd                ,
    input   wire           [15:0]   req_id                 ,
    input   wire           [15:0]   req_seq                ,
    input   wire           [15:0]   req_length             ,
    input   wire           [15:0]   req_crc                ,
    output  wire           [9:0]    rx_rd_addr             ,
    input   wire           [7:0]    rx_rd_data             ,
    output  wire                    result_wr_en           ,
    output  wire           [9:0]    result_wr_addr         ,
    output  wire           [7:0]    result_wr_data         ,

    output  wire                    resp_valid             ,
    input   wire                    resp_ready             ,
    output  wire           [7:0]    resp_cmd               ,
    output  wire           [15:0]   resp_id                ,
    output  wire           [15:0]   resp_seq               ,
    output  wire           [15:0]   resp_length            ,
    input   wire           [9:0]    resp_addr              ,
    output  wire           [7:0]    resp_data              ,
    input   wire                    resp_done
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire stream_request;
wire          legacy_receive_en;
wire          legacy_packet_ready;
wire [9:0]    legacy_rx_rd_addr;
wire          legacy_result_wr_en;
wire [9:0]    legacy_result_wr_addr;
wire [7:0]    legacy_result_wr_data;
wire          legacy_resp_valid;
wire [7:0]    legacy_resp_cmd;
wire [15:0]   legacy_resp_id;
wire [15:0]   legacy_resp_seq;
wire [15:0]   legacy_resp_length;
wire [7:0]    legacy_resp_data;
wire          stream_receive_en;
wire          stream_packet_ready;
wire [9:0]    stream_rx_rd_addr;
wire          stream_result_wr_en;
wire [9:0]    stream_result_wr_addr;
wire [7:0]    stream_result_wr_data;
wire          stream_resp_valid;
wire [7:0]    stream_resp_cmd;
wire [15:0]   stream_resp_id;
wire [15:0]   stream_resp_seq;
wire [15:0]   stream_resp_length;
wire [7:0]    stream_resp_data;
//reg   define
reg route_stream;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign stream_request = (req_cmd == 8'h40 || req_cmd == 8'h41 || req_cmd == 8'h42);
always@(posedge sys_clk)
    if(!sys_rst_n)
        route_stream <= 1'b0;
    else if(packet_valid && packet_ready)
        route_stream <= stream_request;

assign receive_en = stream_request ? stream_receive_en : legacy_receive_en;
assign packet_ready = stream_request ? stream_packet_ready : legacy_packet_ready;
assign rx_rd_addr = route_stream ? stream_rx_rd_addr : legacy_rx_rd_addr;
assign result_wr_en = route_stream ? stream_result_wr_en : legacy_result_wr_en;
assign result_wr_addr = route_stream ? stream_result_wr_addr : legacy_result_wr_addr;
assign result_wr_data = route_stream ? stream_result_wr_data : legacy_result_wr_data;
assign resp_valid = route_stream ? stream_resp_valid : legacy_resp_valid;
assign resp_cmd = route_stream ? stream_resp_cmd : legacy_resp_cmd;
assign resp_id = route_stream ? stream_resp_id : legacy_resp_id;
assign resp_seq = route_stream ? stream_resp_seq : legacy_resp_seq;
assign resp_length = route_stream ? stream_resp_length : legacy_resp_length;
assign resp_data = route_stream ? stream_resp_data : legacy_resp_data;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_async_command
#(
    .MAX_WIDTH              (MAX_WIDTH),
    .MAX_HEIGHT             (MAX_HEIGHT)
)
legacy_command_inst
(
    .sys_clk                 (sys_clk),
    .sys_rst_n               (sys_rst_n),
    .algo_clk                (algo_clk),
    .receive_en              (legacy_receive_en),
    .packet_valid            (packet_valid && !stream_request),
    .packet_ready            (legacy_packet_ready),
    .req_cmd                 (req_cmd),
    .req_id                  (req_id),
    .req_seq                 (req_seq),
    .req_length              (req_length),
    .req_crc                 (req_crc),
    .rx_rd_addr              (legacy_rx_rd_addr),
    .rx_rd_data              (rx_rd_data),
    .result_wr_en            (legacy_result_wr_en),
    .result_wr_addr          (legacy_result_wr_addr),
    .result_wr_data          (legacy_result_wr_data),
    .resp_valid              (legacy_resp_valid),
    .resp_ready              (resp_ready && !route_stream),
    .resp_cmd                (legacy_resp_cmd),
    .resp_id                 (legacy_resp_id),
    .resp_seq                (legacy_resp_seq),
    .resp_length             (legacy_resp_length),
    .resp_addr               (resp_addr),
    .resp_data               (legacy_resp_data),
    .resp_done               (resp_done && !route_stream)
);

img_sobel_stream_ctrl
#(
    .MAX_WIDTH              (MAX_WIDTH),
    .MAX_HEIGHT             (MAX_HEIGHT)
)
stream_command_inst
(
    .sys_clk                 (sys_clk),
    .sys_rst_n               (sys_rst_n),
    .req_peer                (req_peer),
    .receive_en              (stream_receive_en),
    .packet_valid            (packet_valid && stream_request),
    .packet_ready            (stream_packet_ready),
    .req_cmd                 (req_cmd),
    .req_id                  (req_id),
    .req_seq                 (req_seq),
    .req_length              (req_length),
    .req_crc                 (req_crc),
    .rx_rd_addr              (stream_rx_rd_addr),
    .rx_rd_data              (rx_rd_data),
    .result_wr_en            (stream_result_wr_en),
    .result_wr_addr          (stream_result_wr_addr),
    .result_wr_data          (stream_result_wr_data),
    .resp_valid              (stream_resp_valid),
    .resp_ready              (resp_ready && route_stream),
    .resp_cmd                (stream_resp_cmd),
    .resp_id                 (stream_resp_id),
    .resp_seq                (stream_resp_seq),
    .resp_length             (stream_resp_length),
    .resp_addr               (resp_addr),
    .resp_data               (stream_resp_data),
    .resp_done               (resp_done && route_stream),
    .abort_flag              (packet_valid && packet_ready && !stream_request && req_cmd != 8'h01)
);

endmodule
