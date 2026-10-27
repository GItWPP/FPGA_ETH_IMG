//--------------------------------------------------------------------------------------------------------
// 模块： img_sobel_stream_ctrl
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 视频Sobel会话、顺序和长度验证，流式数据与缓存应答控制
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module img_sobel_stream_ctrl
#(
    parameter integer MAX_WIDTH = 1920,
    parameter integer MAX_HEIGHT = 1080
)
(
    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire            abort_flag,
    output  wire            receive_en,
    input   wire            packet_valid,
    output  wire            packet_ready,
    input   wire [7:0]      req_cmd,
    input   wire [15:0]     req_id,
    input   wire [15:0]     req_seq,
    input   wire [15:0]     req_length,
    input   wire [15:0]     req_crc,
    input   wire [95:0]     req_peer,
    output  wire [9:0]      rx_rd_addr,
    input   wire [7:0]      rx_rd_data,
    output  wire            result_wr_en,
    output  wire [9:0]      result_wr_addr,
    output  wire [7:0]      result_wr_data,
    output  wire            resp_valid,
    input   wire            resp_ready,
    output  reg  [7:0]      resp_cmd,
    output  wire [15:0]     resp_id,
    output  wire [15:0]     resp_seq,
    output  reg  [15:0]     resp_length,
    input   wire [9:0]      resp_addr,
    output  wire [7:0]      resp_data,
    input   wire            resp_done
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [3:0] IDLE = 4'd0;
localparam [3:0] CHECK = 4'd1;
localparam [3:0] HEADER_PRIME = 4'd2;
localparam [3:0] HEADER_LOAD = 4'd3;
localparam [3:0] START_CHECK = 4'd4;
localparam [3:0] DATA_PRIME = 4'd5;
localparam [3:0] DATA_LOAD = 4'd6;
localparam [3:0] DRAIN = 4'd7;
localparam [3:0] REPLY = 4'd8;
localparam [3:0] WAIT_DONE = 4'd9;
//wire  define
wire start_ok;
wire same_start;
wire start_conflict;
wire session_ok;
wire data_ok;
wire end_ok;
wire frame_start;
wire kernel_valid;
wire [7:0] kernel_data;
wire [23:0] padded_bytes;
wire [23:0] expected_pixels;
wire [7:0] error_code;
//reg   define
reg [3:0] state;
reg [3:0] next_state;
reg active;
reg ended;
reg [15:0] session_id;
reg [95:0] session_peer;
reg [15:0] start_crc;
reg [15:0] next_seq;
reg [15:0] frame_width;
reg [15:0] frame_height;
reg [23:0] bytes_left;
reg [23:0] pixels_done;
reg [47:0] start_header;
reg [9:0] byte_index;
reg [9:0] output_count;
reg [3:0] drain_count;
reg [7:0] low_byte;
reg [63:0] reply_inline;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign receive_en = (state == IDLE);
assign packet_ready = (state == IDLE);
assign resp_valid = (state == REPLY);
assign resp_id = req_id;
assign resp_seq = req_seq;
assign resp_data = reply_inline[resp_addr[2:0]*8 +: 8];
assign rx_rd_addr = (state == HEADER_LOAD || state == DATA_LOAD) ? byte_index + 1'b1 : 10'd0;
assign session_ok = (active || ended) && req_id == session_id && req_peer == session_peer;
assign same_start = session_ok && req_cmd == 8'h40 && req_seq == 16'd0 && req_crc == start_crc;
assign start_conflict = session_ok && req_cmd == 8'h40 && !same_start;
assign start_ok = start_header[15:0] != 16'd0 && start_header[15:0] <= MAX_WIDTH
                  && start_header[31:16] != 16'd0 && start_header[31:16] <= MAX_HEIGHT
                  && start_header[47:32] == 16'h0501 && req_seq == 16'd0;
assign data_ok = req_cmd == 8'h41 && session_ok && active && req_seq == next_seq
                 && req_length != 16'd0 && req_length <= 16'd1024 && !req_length[0]
                 && {8'd0,req_length} <= bytes_left;
assign end_ok = req_cmd == 8'h42 && session_ok && req_seq == next_seq && req_length == 16'd0
                && bytes_left == 24'd0 && pixels_done == expected_pixels;
assign error_code = (req_cmd == 8'h40) ? 8'd2 : (!session_ok ? 8'd3 : ((req_seq != next_seq) ? 8'd4 : 8'd5));
assign padded_bytes = (24'd1 + start_header[15:0]) * (24'd1 + start_header[31:16]) * 24'd2;
assign expected_pixels = {8'd0,frame_width} * {8'd0,frame_height};
assign frame_start = (state == START_CHECK) && start_ok && !same_start && !start_conflict;
assign result_wr_en = kernel_valid && (state == DATA_LOAD || state == DRAIN);
assign result_wr_addr = output_count;
assign result_wr_data = kernel_data;

always@(posedge sys_clk)
    if(!sys_rst_n)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(packet_valid) next_state = CHECK;
        CHECK: begin
            if(req_cmd == 8'h40 && req_length == 16'd6)
                next_state = HEADER_PRIME;
            else if(data_ok)
                next_state = DATA_PRIME;
            else
                next_state = REPLY;
        end
        HEADER_PRIME: next_state = HEADER_LOAD;
        HEADER_LOAD: if(byte_index == 10'd5) next_state = START_CHECK;
        START_CHECK: next_state = REPLY;
        DATA_PRIME: next_state = DATA_LOAD;
        DATA_LOAD: if({6'd0,byte_index} + 16'd1 == req_length) next_state = DRAIN;
        DRAIN: if(drain_count == 4'd8) next_state = REPLY;
        REPLY: if(resp_ready) next_state = WAIT_DONE;
        WAIT_DONE: if(resp_done) next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//会话推进只能发生在完整校验后的合法请求；重复START不会清空已处理的数据
always@(posedge sys_clk)
    if(!sys_rst_n) begin
        active <= 1'b0;
        ended <= 1'b0;
        session_id <= 16'd0;
        session_peer <= 96'd0;
        start_crc <= 16'd0;
    end else if(abort_flag) begin
        active <= 1'b0;
        ended <= 1'b0;
    end else if(frame_start) begin
        active <= 1'b1;
        ended <= 1'b0;
        session_id <= req_id;
        session_peer <= req_peer;
        start_crc <= req_crc;
    end else if(state == CHECK && end_ok) begin
        active <= 1'b0;
        ended <= 1'b1;
    end

always@(posedge sys_clk)
    if(!sys_rst_n) begin
        frame_width <= 16'd0;
        frame_height <= 16'd0;
    end else if(frame_start) begin
        frame_width <= start_header[15:0];
        frame_height <= start_header[31:16];
    end

//frame_start当拍内核取尺寸旧值，首个数据包才开始使用新尺寸
always@(posedge sys_clk)
    if(!sys_rst_n)
        next_seq <= 16'd1;
    else if(frame_start)
        next_seq <= 16'd1;
    else if(state == DRAIN && drain_count == 4'd8)
        next_seq <= next_seq + 1'b1;

always@(posedge sys_clk)
    if(!sys_rst_n)
        bytes_left <= 24'd0;
    else if(frame_start)
        bytes_left <= padded_bytes;
    else if(state == DATA_LOAD && next_state == DRAIN)
        bytes_left <= bytes_left - {8'd0,req_length};

always@(posedge sys_clk)
    if(!sys_rst_n || frame_start)
        pixels_done <= 24'd0;
    else if(result_wr_en)
        pixels_done <= pixels_done + 1'b1;

always@(posedge sys_clk)
    if(!sys_rst_n || state == CHECK)
        byte_index <= 10'd0;
    else if(state == HEADER_LOAD || state == DATA_LOAD)
        byte_index <= byte_index + 1'b1;

always@(posedge sys_clk)
    if(state == HEADER_LOAD)
        start_header[byte_index*8 +: 8] <= rx_rd_data;

always@(posedge sys_clk)
    if(state == DATA_LOAD && !byte_index[0])
        low_byte <= rx_rd_data;

always@(posedge sys_clk)
    if(!sys_rst_n || state == CHECK)
        output_count <= 10'd0;
    else if(result_wr_en)
        output_count <= output_count + 1'b1;

always@(posedge sys_clk)
    if(!sys_rst_n || state != DRAIN)
        drain_count <= 4'd0;
    else
        drain_count <= drain_count + 1'b1;

always@(posedge sys_clk)
    if(!sys_rst_n) begin
        resp_cmd <= 8'hff;
        resp_length <= 16'd1;
        reply_inline <= 64'd0;
    end else if(state == CHECK) begin
        resp_cmd <= end_ok ? 8'hc2 : 8'hff;
        resp_length <= end_ok ? 16'd4 : 16'd1;
        reply_inline <= end_ok ? {40'd0,pixels_done} : {56'd0,error_code};
    end else if(state == START_CHECK) begin
        resp_cmd <= (start_ok && !start_conflict) ? 8'hc0 : 8'hff;
        resp_length <= (start_ok && !start_conflict) ? 16'd8 : 16'd1;
        reply_inline <= start_conflict ? 64'd6
                        : (start_ok ? {start_header[31:0],32'h314c4253} : 64'd2);
    end else if(state == DRAIN && drain_count == 4'd8) begin
        resp_cmd <= 8'hc1;
        resp_length <= {6'd0,output_count};
    end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_sobel_stream_top sobel_stream_inst
(
    .sys_clk                (sys_clk),
    .sys_rst_n              (sys_rst_n),
    .frame_start            (frame_start),
    .frame_width            (frame_width),
    .frame_height           (frame_height),
    .pixel_valid            (state == DATA_LOAD && byte_index[0]),
    .pixel_data             ({rx_rd_data,low_byte}),
    .gray_valid             (kernel_valid),
    .gray_data              (kernel_data)
);

endmodule
