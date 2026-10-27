//--------------------------------------------------------------------------------------------------------
// 模块： img_async_command
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 高速命令搬运与50MHz算法跨时钟解耦，原图预复制在校验成功后发布
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_async_command
#(
    parameter integer MAX_WIDTH = 1920,
    parameter integer MAX_HEIGHT = 1080
)
(
    input   wire                    sys_clk                , //高速传输时钟
    input   wire                    sys_rst_n              , //全局复位在传输域同步释放
    input   wire                    algo_clk               , //算法时钟
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
//parameter define
localparam [3:0] FAST_IDLE = 4'd0;
localparam [3:0] FAST_PRIME = 4'd1;
localparam [3:0] FAST_LOAD = 4'd2;
localparam [3:0] FAST_REQUEST = 4'd3;
localparam [3:0] FAST_WAIT_REPLY = 4'd4;
localparam [3:0] FAST_RESULT_PRIME = 4'd5;
localparam [3:0] FAST_RESULT_COPY = 4'd6;
localparam [3:0] FAST_RESPONSE = 4'd7;
localparam [3:0] FAST_WAIT_DONE = 4'd8;
localparam [3:0] FAST_ACK = 4'd9;
localparam [2:0] ALGO_IDLE = 3'd0;
localparam [2:0] ALGO_LAUNCH = 3'd1;
localparam [2:0] ALGO_WAIT_REPLY = 3'd2;
localparam [2:0] ALGO_INLINE = 3'd3;
localparam [2:0] ALGO_RESPONSE = 3'd4;
localparam [2:0] ALGO_WAIT_ACK = 3'd5;

//wire  define
wire                    algo_rst_n;
wire                    request_write_ready;
wire                    request_read_valid;
wire           [71:0]   request_read_data;
wire                    response_write_ready;
wire                    response_read_valid;
wire           [184:0]  response_read_data;
wire                    acknowledge_write_ready;
wire                    acknowledge_read_valid;
wire                    fast_accept;
wire                    input_last;
wire                    output_last;
wire                    algo_accept;
wire                    algo_response_accept;
wire                    algo_packet_ready;
wire           [9:0]    algo_rx_addr;
wire           [7:0]    algo_rx_data;
wire                    algo_result_wr_en;
wire           [9:0]    algo_result_wr_addr;
wire           [7:0]    algo_result_wr_data;
wire                    algo_resp_valid;
wire           [7:0]    algo_resp_cmd;
wire           [15:0]   algo_resp_id;
wire           [15:0]   algo_resp_seq;
wire           [15:0]   algo_resp_length;
wire           [7:0]    algo_resp_data;
wire                    algo_copy_response;
wire                    algo_ram_response;
wire           [9:0]    result_rd_addr;
wire           [7:0]    result_rd_data;
wire                    reply_ram_response;

//reg   define
reg            [3:0]    fast_state;
reg            [3:0]    fast_next_state;
reg            [2:0]    algo_state;
reg            [2:0]    algo_next_state;
reg            [71:0]   request_hold;
reg            [71:0]   algo_request_hold;
reg            [9:0]    input_index;
reg            [9:0]    output_index;
reg            [3:0]    inline_index;
reg            [184:0]  reply_hold;
reg            [56:0]   algo_reply_header;
reg            [127:0]  algo_reply_inline;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign packet_ready = (fast_state == FAST_IDLE) && request_write_ready;
assign receive_en = packet_ready;
assign fast_accept = packet_valid && packet_ready;
assign input_last = ({6'd0,input_index} + 16'd1 == request_hold[31:16]);
assign output_last = ({6'd0,output_index} + 16'd1 == resp_length);
assign rx_rd_addr = (fast_state == FAST_LOAD && !input_last) ? input_index + 1'b1 : 10'd0;
assign result_wr_en = (fast_state == FAST_LOAD && request_hold[71:64] == 8'h03)
                      || (fast_state == FAST_RESULT_COPY);
assign result_wr_addr = (fast_state == FAST_RESULT_COPY) ? output_index : input_index;
assign result_wr_data = (fast_state == FAST_RESULT_COPY) ? result_rd_data : rx_rd_data;
assign resp_valid = (fast_state == FAST_RESPONSE);
assign {resp_cmd,resp_id,resp_seq,resp_length} = reply_hold[183:128];
assign reply_ram_response = (resp_cmd == 8'h83 || resp_cmd == 8'h93 || resp_cmd == 8'ha3);
assign resp_data = reply_ram_response ? result_rd_data : reply_hold[resp_addr[3:0]*8 +: 8];
assign result_rd_addr = (fast_state == FAST_RESULT_PRIME) ? 10'd0
                       : ((fast_state == FAST_RESULT_COPY) ? (output_last ? output_index : output_index + 1'b1) : resp_addr);
assign algo_accept = (algo_state == ALGO_LAUNCH) && algo_packet_ready;
assign algo_response_accept = (algo_state == ALGO_WAIT_REPLY) && algo_resp_valid;
assign algo_ram_response = (algo_resp_cmd == 8'h83 || algo_resp_cmd == 8'h93 || algo_resp_cmd == 8'ha3);

//传输状态只消费同域FIFO接口；算法延迟不会改变协议时钟
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        fast_state <= FAST_IDLE;
    else
        fast_state <= fast_next_state;

always@(*) begin
    fast_next_state = fast_state;
    case(fast_state)
        FAST_IDLE: if(fast_accept)
            fast_next_state = (req_length == 16'd0) ? FAST_REQUEST : FAST_PRIME;
        FAST_PRIME: fast_next_state = FAST_LOAD;
        FAST_LOAD: if(input_last) fast_next_state = FAST_REQUEST;
        FAST_REQUEST: if(request_write_ready) fast_next_state = FAST_WAIT_REPLY;
        FAST_WAIT_REPLY: if(response_read_valid)
            fast_next_state = (!response_read_data[184] && response_read_data[183:176] == 8'h83)
                              ? FAST_RESULT_PRIME : FAST_RESPONSE;
        FAST_RESULT_PRIME: fast_next_state = FAST_RESULT_COPY;
        FAST_RESULT_COPY: if(output_last) fast_next_state = FAST_RESPONSE;
        FAST_RESPONSE: if(resp_ready) fast_next_state = FAST_WAIT_DONE;
        FAST_WAIT_DONE: if(resp_done) fast_next_state = FAST_ACK;
        FAST_ACK: if(acknowledge_write_ready) fast_next_state = FAST_IDLE;
        default: fast_next_state = FAST_IDLE;
    endcase
end

//请求描述符及RAM内容从提交到完成确认始终保持
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        request_hold <= 72'd0;
    else if(fast_accept)
        request_hold <= {req_cmd,req_id,req_seq,req_length,req_crc};

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        input_index <= 10'd0;
    else if(fast_accept)
        input_index <= 10'd0;
    else if(fast_state == FAST_LOAD && !input_last)
        input_index <= input_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        output_index <= 10'd0;
    else if(fast_state == FAST_RESULT_PRIME)
        output_index <= 10'd0;
    else if(fast_state == FAST_RESULT_COPY && !output_last)
        output_index <= output_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        reply_hold <= 185'd0;
    else if(fast_state == FAST_WAIT_REPLY && response_read_valid)
        reply_hold <= response_read_data;

//算法命令完成后先提交结果，再等待高速域消费确认
always@(posedge algo_clk)
    if(algo_rst_n == 1'b0)
        algo_state <= ALGO_IDLE;
    else
        algo_state <= algo_next_state;

always@(*) begin
    algo_next_state = algo_state;
    case(algo_state)
        ALGO_IDLE: if(request_read_valid) algo_next_state = ALGO_LAUNCH;
        ALGO_LAUNCH: if(algo_accept) algo_next_state = ALGO_WAIT_REPLY;
        ALGO_WAIT_REPLY: if(algo_response_accept)
            algo_next_state = (algo_ram_response || algo_resp_length == 16'd0) ? ALGO_RESPONSE : ALGO_INLINE;
        ALGO_INLINE: if({12'd0,inline_index} + 16'd1 == algo_reply_header[15:0]) algo_next_state = ALGO_RESPONSE;
        ALGO_RESPONSE: if(response_write_ready) algo_next_state = ALGO_WAIT_ACK;
        ALGO_WAIT_ACK: if(acknowledge_read_valid) algo_next_state = ALGO_IDLE;
        default: algo_next_state = ALGO_IDLE;
    endcase
end

always@(posedge algo_clk)
    if(algo_rst_n == 1'b0)
        algo_request_hold <= 72'd0;
    else if(algo_state == ALGO_IDLE && request_read_valid)
        algo_request_hold <= request_read_data;

always@(posedge algo_clk)
    if(algo_rst_n == 1'b0)
        algo_reply_header <= 57'd0;
    else if(algo_response_accept)
        algo_reply_header <= {algo_copy_response,algo_resp_cmd,algo_resp_id,algo_resp_seq,algo_resp_length};

always@(posedge algo_clk)
    if(algo_rst_n == 1'b0)
        inline_index <= 4'd0;
    else if(algo_response_accept)
        inline_index <= 4'd0;
    else if(algo_state == ALGO_INLINE)
        inline_index <= inline_index + 1'b1;

always@(posedge algo_clk)
    if(algo_rst_n == 1'b0)
        algo_reply_inline <= 128'd0;
    else if(algo_response_accept)
        algo_reply_inline <= 128'd0;
    else if(algo_state == ALGO_INLINE)
        algo_reply_inline[inline_index*8 +: 8] <= algo_resp_data;

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_reset_sync algo_reset_inst
(
    .sys_clk                (algo_clk),
    .async_rst_n            (sys_rst_n),
    .rst_n                  (algo_rst_n)
);

img_async_fifo
#(
    .DATA_WIDTH             (72)
)
request_fifo_inst
(
    .wr_clk                 (sys_clk),
    .wr_rst_n               (sys_rst_n),
    .wr_data                (request_hold),
    .wr_valid               (fast_state == FAST_REQUEST),
    .wr_ready               (request_write_ready),
    .rd_clk                 (algo_clk),
    .rd_rst_n               (algo_rst_n),
    .rd_data                (request_read_data),
    .rd_valid               (request_read_valid),
    .rd_ready               (algo_state == ALGO_IDLE)
);

img_async_fifo
#(
    .DATA_WIDTH             (185)
)
response_fifo_inst
(
    .wr_clk                 (algo_clk),
    .wr_rst_n               (algo_rst_n),
    .wr_data                ({algo_reply_header,algo_reply_inline}),
    .wr_valid               (algo_state == ALGO_RESPONSE),
    .wr_ready               (response_write_ready),
    .rd_clk                 (sys_clk),
    .rd_rst_n               (sys_rst_n),
    .rd_data                (response_read_data),
    .rd_valid               (response_read_valid),
    .rd_ready               (fast_state == FAST_WAIT_REPLY)
);

img_async_fifo
#(
    .DATA_WIDTH             (1)
)
acknowledge_fifo_inst
(
    .wr_clk                 (sys_clk),
    .wr_rst_n               (sys_rst_n),
    .wr_data                (1'b1),
    .wr_valid               (fast_state == FAST_ACK),
    .wr_ready               (acknowledge_write_ready),
    .rd_clk                 (algo_clk),
    .rd_rst_n               (algo_rst_n),
    .rd_data                (),
    .rd_valid               (acknowledge_read_valid),
    .rd_ready               (algo_state == ALGO_WAIT_ACK)
);

img_dual_clock_buffer request_buffer_inst
(
    .wr_clk                 (sys_clk),
    .wr_en                  (fast_state == FAST_LOAD),
    .wr_addr                (input_index),
    .wr_data                (rx_rd_data),
    .rd_clk                 (algo_clk),
    .rd_addr                (algo_rx_addr),
    .rd_data                (algo_rx_data)
);

img_dual_clock_buffer result_buffer_inst
(
    .wr_clk                 (algo_clk),
    .wr_en                  (algo_result_wr_en),
    .wr_addr                (algo_result_wr_addr),
    .wr_data                (algo_result_wr_data),
    .rd_clk                 (sys_clk),
    .rd_addr                (result_rd_addr),
    .rd_data                (result_rd_data)
);

img_algorithm_top
#(
    .MAX_WIDTH              (MAX_WIDTH),
    .MAX_HEIGHT             (MAX_HEIGHT),
    .FAST_COPY              (1),
    .EXTERNAL_COPY          (1)
)
algorithm_inst
(
    .sys_clk                (algo_clk),
    .sys_rst_n              (algo_rst_n),
    .receive_en             (),
    .packet_valid           (algo_state == ALGO_LAUNCH),
    .packet_ready           (algo_packet_ready),
    .req_cmd                (algo_request_hold[71:64]),
    .req_id                 (algo_request_hold[63:48]),
    .req_seq                (algo_request_hold[47:32]),
    .req_length             (algo_request_hold[31:16]),
    .req_crc                (algo_request_hold[15:0]),
    .rx_rd_addr             (algo_rx_addr),
    .rx_rd_data             (algo_rx_data),
    .result_wr_en           (algo_result_wr_en),
    .result_wr_addr         (algo_result_wr_addr),
    .result_wr_data         (algo_result_wr_data),
    .resp_valid             (algo_resp_valid),
    .resp_ready             (algo_state == ALGO_WAIT_REPLY),
    .resp_cmd               (algo_resp_cmd),
    .resp_id                (algo_resp_id),
    .resp_seq               (algo_resp_seq),
    .resp_length            (algo_resp_length),
    .resp_addr              ({6'd0,inline_index}),
    .result_rd_data         (8'd0),
    .resp_data              (algo_resp_data),
    .resp_done              (algo_state == ALGO_WAIT_ACK && acknowledge_read_valid),
    .copy_response          (algo_copy_response)
);

endmodule
