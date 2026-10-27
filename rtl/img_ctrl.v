//--------------------------------------------------------------------------------------------------------
// 模块： img_ctrl
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 图像会话、滤波邻域分片检查、九像素读取及最近成功应答重发
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_ctrl
#(
    parameter integer MAX_WIDTH  = 1920,
    parameter integer MAX_HEIGHT = 1080,
    parameter integer FAST_COPY = 0,
    parameter integer EXTERNAL_COPY = 0
)
(
    input   wire                    sys_clk                ,
    input   wire                    sys_rst_n              ,
    input   wire                    cache_clear            ,
    input   wire                    session_clear          ,
    output  wire                    success_flag           ,
    output  wire                    success_start_flag     ,
    output  wire                    receive_en             ,
    input   wire                    packet_valid           ,
    output  wire                    packet_ready           ,
    input   wire           [7:0]    req_cmd                ,
    input   wire           [15:0]   req_id                 ,
    input   wire           [15:0]   req_seq                ,
    input   wire           [15:0]   req_length             ,
    input   wire           [15:0]   req_crc                ,

    output  reg            [9:0]    rx_rd_addr             ,
    input   wire           [7:0]    rx_rd_data             ,
    output  wire                    result_wr_en           ,
    output  wire           [9:0]    result_wr_addr         ,
    output  wire           [7:0]    result_wr_data         ,

    output  wire           [2:0]    pixel_mode             ,
    output  wire           [15:0]   pixel_in_data          ,
    output  wire           [143:0]  pixel_window_data      ,
    output  wire                    pixel_in_valid         ,
    input   wire                    pixel_in_ready         ,
    input   wire           [15:0]   pixel_out_data         ,
    input   wire                    pixel_out_valid        ,
    output  wire                    pixel_out_ready        ,

    output  wire                    resp_valid             ,
    input   wire                    resp_ready             ,
    output  reg            [7:0]    resp_cmd               ,
    output  reg            [15:0]   resp_id                ,
    output  reg            [15:0]   resp_seq               ,
    output  reg            [15:0]   resp_length            ,
    input   wire           [9:0]    resp_addr              ,
    input   wire           [7:0]    result_rd_data         ,
    output  reg            [7:0]    resp_data              ,
    input   wire                    resp_done              ,
    output  wire                    copy_response
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [4:0] IDLE          = 5'd0;
localparam [4:0] DISPATCH      = 5'd1;
localparam [4:0] ARG_WAIT      = 5'd2;
localparam [4:0] ARG_GET       = 5'd3;
localparam [4:0] ARG_CHECK     = 5'd4;
localparam [4:0] LO_WAIT       = 5'd5;
localparam [4:0] LO_GET        = 5'd6;
localparam [4:0] HI_WAIT       = 5'd7;
localparam [4:0] HI_GET        = 5'd8;
localparam [4:0] PIX_SEND      = 5'd9;
localparam [4:0] PIX_WAIT      = 5'd10;
localparam [4:0] WRITE_LO      = 5'd11;
localparam [4:0] WRITE_HI      = 5'd12;
localparam [4:0] COMMIT        = 5'd13;
localparam [4:0] RESP_REQ      = 5'd14;
localparam [4:0] RESP_WAIT     = 5'd15;
localparam [4:0] COUNT_LO_WAIT = 5'd16;
localparam [4:0] COUNT_LO_GET  = 5'd17;
localparam [4:0] COUNT_HI_WAIT = 5'd18;
localparam [4:0] COUNT_HI_GET  = 5'd19;
localparam [4:0] FILTER_CHECK  = 5'd20;
localparam [4:0] COPY_PRIME    = 5'd21;
localparam [4:0] COPY_RUN      = 5'd22;
localparam [4:0] COPY_EXTERNAL = 5'd23;
localparam [1:0] KIND_EMPTY  = 2'd0;
localparam [1:0] KIND_PIXELS = 2'd1;
localparam [1:0] KIND_PING   = 2'd2;
localparam [1:0] KIND_ERROR  = 2'd3;
localparam [7:0] CMD_PING  = 8'h01;
localparam [7:0] CMD_START = 8'h02;
localparam [7:0] CMD_DATA  = 8'h03;
localparam [7:0] CMD_END   = 8'h04;
localparam [7:0] CMD_ERROR = 8'hff;
localparam [7:0] ERR_COMMAND  = 8'd1;
localparam [7:0] ERR_ARGUMENT = 8'd2;
localparam [7:0] ERR_SESSION  = 8'd3;
localparam [7:0] ERR_SEQUENCE = 8'd4;
localparam [7:0] ERR_LENGTH   = 8'd5;
localparam [7:0] ERR_RETRY    = 8'd6;

//wire  define
wire           [31:0]   image_bytes;
wire                    same_key;
wire                    duplicate_ok;
wire                    start_request;
wire                    start_legal;
wire                    data_legal;
wire                    end_legal;
wire                    pixel_end;
wire                    filter_mode;
wire                    filter_legal;
wire           [31:0]   filter_input_length;
wire           [31:0]   filter_output_length;
wire           [9:0]    tile_stride;
wire                    copy_end;
wire                    data_complete;

//reg   define
reg            [4:0]    state;
reg            [4:0]    next_state;
reg            [1:0]    resp_kind;
reg            [7:0]    error_code;
reg            [7:0]    cmd_reg;
reg            [15:0]   id_reg;
reg            [15:0]   seq_reg;
reg            [15:0]   len_reg;
reg            [15:0]   crc_reg;
reg                     active;
reg            [15:0]   session_id;
reg            [15:0]   next_seq;
reg            [31:0]   total_bytes;
reg            [31:0]   received_bytes;
reg            [2:0]    mode_reg;
reg            [2:0]    arg_index;
reg            [15:0]   width_reg;
reg            [15:0]   height_reg;
reg            [7:0]    format_reg;
reg            [7:0]    requested_mode;
reg            [9:0]    pixel_index;
reg            [9:0]    copy_index;
reg            [7:0]    pixel_low;
reg            [15:0]   input_pixel;
reg            [15:0]   output_pixel;
reg            [15:0]   process_length;
reg            [15:0]   tile_count;
reg            [15:0]   session_width;
reg            [15:0]   column_index;
reg            [3:0]    window_index;
reg            [143:0]  window_data;
reg            [9:0]    filter_pixel_addr;
reg                     cache_valid;
reg            [7:0]    cache_cmd;
reg            [15:0]   cache_id;
reg            [15:0]   cache_seq;
reg            [15:0]   cache_len;
reg            [15:0]   cache_crc;
reg            [7:0]    cache_resp_cmd;
reg            [15:0]   cache_resp_len;
reg            [1:0]    cache_kind;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign image_bytes = ({16'd0, width_reg} * {16'd0, height_reg}) << 1;
assign same_key = cache_valid && cmd_reg == cache_cmd && id_reg == cache_id && seq_reg == cache_seq;
assign duplicate_ok = same_key && len_reg == cache_len && crc_reg == cache_crc;
assign start_request = (cmd_reg == CMD_START && len_reg == 16'd6 && seq_reg == 16'd0);
assign start_legal = (width_reg != 16'd0 && height_reg != 16'd0
                  && width_reg <= MAX_WIDTH && height_reg <= MAX_HEIGHT
                  && format_reg == 8'd1 && requested_mode <= 8'd7);
assign filter_mode = ((mode_reg >= 3'd3 && mode_reg <= 3'd5) || mode_reg == 3'd7);
assign data_legal = active && id_reg == session_id && seq_reg == next_seq
                 && len_reg != 16'd0 && !len_reg[0]
                 && (filter_mode ? (len_reg >= 16'd20)
                                 : (received_bytes + {16'd0, len_reg} <= total_bytes));
assign filter_input_length  = {16'd0, tile_count} * 32'd6 + 32'd14;
assign filter_output_length = {15'd0, tile_count, 1'b0};
assign filter_legal = tile_count >= 16'd1 && tile_count <= 16'd168
                   && {16'd0, len_reg} == filter_input_length
                   && {1'b0, column_index} + {1'b0, tile_count} <= {1'b0, session_width}
                   && received_bytes + filter_output_length <= total_bytes;
assign tile_stride = ({2'd0, tile_count[7:0]} + 10'd2) << 1;
assign end_legal = active && id_reg == session_id && seq_reg == next_seq
                && len_reg == 16'd0 && received_bytes == total_bytes;
assign pixel_end = ({6'd0, pixel_index} + 16'd2 == process_length);
assign copy_end = ({6'd0, copy_index} + 16'd1 == process_length);
assign data_complete = (state == WRITE_HI && pixel_end) || (state == COPY_RUN && copy_end)
                       || (state == COPY_EXTERNAL);
assign copy_response = EXTERNAL_COPY && mode_reg == 3'd0 && resp_cmd == 8'h83;

assign success_flag = (state == COMMIT);
assign success_start_flag = success_flag && (cmd_reg == CMD_START);
assign receive_en     = (state == IDLE);
assign packet_ready   = (state == IDLE);
assign pixel_mode     = mode_reg;
assign pixel_in_data  = input_pixel;
assign pixel_window_data = window_data;
assign pixel_in_valid = (state == PIX_SEND);
assign pixel_out_ready = (state == PIX_WAIT);
assign result_wr_en   = (state == WRITE_LO || state == WRITE_HI || state == COPY_RUN);
assign result_wr_addr = (state == COPY_RUN) ? copy_index
                      : ((state == WRITE_HI) ? pixel_index + 10'd1 : pixel_index);
assign result_wr_data = (state == COPY_RUN) ? rx_rd_data
                      : ((state == WRITE_HI) ? output_pixel[15:8] : output_pixel[7:0]);
assign resp_valid     = (state == RESP_REQ);

//同步复位用于全部BRAM地址/使能控制；状态转移与寄存器职责分开
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(packet_valid) next_state = DISPATCH;
        DISPATCH: begin
            next_state = RESP_REQ;
            if(!same_key)
                case(cmd_reg)
                    CMD_PING:  if(len_reg == 16'd0) next_state = COMMIT;
                    CMD_START: if(start_request) next_state = ARG_WAIT;
                    CMD_DATA:  if(data_legal) next_state = filter_mode ? COUNT_LO_WAIT
                              : ((EXTERNAL_COPY && mode_reg == 3'd0) ? COPY_EXTERNAL
                                 : ((FAST_COPY && mode_reg == 3'd0) ? COPY_PRIME : LO_WAIT));
                    CMD_END:   if(end_legal) next_state = COMMIT;
                    default: next_state = RESP_REQ;
                endcase
        end
        ARG_WAIT: next_state = ARG_GET;
        ARG_GET: next_state = (arg_index == 3'd5) ? ARG_CHECK : ARG_WAIT;
        ARG_CHECK: next_state = start_legal ? COMMIT : RESP_REQ;
        COUNT_LO_WAIT: next_state = COUNT_LO_GET;
        COUNT_LO_GET: next_state = COUNT_HI_WAIT;
        COUNT_HI_WAIT: next_state = COUNT_HI_GET;
        COUNT_HI_GET: next_state = FILTER_CHECK;
        FILTER_CHECK: next_state = filter_legal ? LO_WAIT : RESP_REQ;
        LO_WAIT: next_state = LO_GET;
        LO_GET:  next_state = HI_WAIT;
        HI_WAIT: next_state = HI_GET;
        HI_GET:  next_state = (filter_mode && window_index != 4'd8) ? LO_WAIT : PIX_SEND;
        PIX_SEND: if(pixel_in_ready) next_state = PIX_WAIT;
        PIX_WAIT: if(pixel_out_valid) next_state = WRITE_LO;
        WRITE_LO: next_state = WRITE_HI;
        WRITE_HI: next_state = pixel_end ? COMMIT : LO_WAIT;
        COPY_PRIME: next_state = COPY_RUN;
        COPY_RUN: if(copy_end) next_state = COMMIT;
        COPY_EXTERNAL: next_state = COMMIT;
        COMMIT: next_state = RESP_REQ;
        RESP_REQ: if(resp_ready) next_state = RESP_WAIT;
        RESP_WAIT: if(resp_done) next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//请求字段在完整包握手时锁存，应答编号始终回显本次请求
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cmd_reg  <= 8'd0;
        id_reg   <= 16'd0;
        seq_reg  <= 16'd0;
        len_reg  <= 16'd0;
        crc_reg  <= 16'd0;
        resp_id  <= 16'd0;
        resp_seq <= 16'd0;
    end else if(state == IDLE && packet_valid) begin
        cmd_reg  <= req_cmd;
        id_reg   <= req_id;
        seq_reg  <= req_seq;
        len_reg  <= req_length;
        crc_reg  <= req_crc;
        resp_id  <= req_id;
        resp_seq <= req_seq;
    end

//resp_kind/字段:错误为默认应答，合法命令和已缓存重试覆盖默认值
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        resp_cmd    <= 8'd0;
        resp_length <= 16'd0;
        resp_kind   <= KIND_EMPTY;
    end else if(state == DISPATCH) begin
        resp_cmd    <= CMD_ERROR;
        resp_length <= 16'd1;
        resp_kind   <= KIND_ERROR;
        if(duplicate_ok) begin
            resp_cmd    <= cache_resp_cmd;
            resp_length <= cache_resp_len;
            resp_kind   <= cache_kind;
        end else if(!same_key) begin
            if(cmd_reg == CMD_PING && len_reg == 16'd0) begin
                resp_cmd    <= 8'h81;
                resp_length <= 16'd8;
                resp_kind   <= KIND_PING;
            end else if(cmd_reg == CMD_END && end_legal) begin
                resp_cmd    <= 8'h84;
                resp_length <= 16'd0;
                resp_kind   <= KIND_EMPTY;
            end
        end
    end else if(state == ARG_CHECK && start_legal) begin
        resp_cmd    <= 8'h82;
        resp_length <= 16'd0;
        resp_kind   <= KIND_EMPTY;
    end else if(data_complete) begin
        resp_cmd    <= 8'h83;
        resp_length <= process_length;
        resp_kind   <= KIND_PIXELS;
    end

//error_code:拒绝请求只改变本次错误应答，不覆盖最近成功缓存
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        error_code <= 8'd0;
    else if(state == ARG_CHECK && !start_legal)
        error_code <= ERR_ARGUMENT;
    else if(state == FILTER_CHECK && !filter_legal)
        error_code <= ERR_LENGTH;
    else if(state == DISPATCH) begin
        if(same_key) begin
            if(!duplicate_ok)
                error_code <= ERR_RETRY;
        end else
            case(cmd_reg)
                CMD_PING: if(len_reg != 16'd0) error_code <= ERR_ARGUMENT;
                CMD_START: if(!start_request) error_code <= ERR_ARGUMENT;
                CMD_DATA, CMD_END: begin
                    if(!active || id_reg != session_id)
                        error_code <= ERR_SESSION;
                    else if(seq_reg != next_seq)
                        error_code <= ERR_SEQUENCE;
                    else if((cmd_reg == CMD_DATA && !data_legal) || (cmd_reg == CMD_END && !end_legal))
                        error_code <= ERR_LENGTH;
                end
                default: error_code <= ERR_COMMAND;
            endcase
    end

//START六个参数字节从同步RAM依次读取，WAIT用于对齐一个周期读延迟
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        arg_index <= 3'd0;
    else if(state == DISPATCH && !same_key && start_request)
        arg_index <= 3'd0;
    else if(state == ARG_GET && arg_index != 3'd5)
        arg_index <= arg_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        width_reg      <= 16'd0;
        height_reg     <= 16'd0;
        format_reg     <= 8'd0;
        requested_mode <= 8'd0;
    end else if(state == ARG_GET)
        case(arg_index)
            3'd0: width_reg[7:0]  <= rx_rd_data;
            3'd1: width_reg[15:8] <= rx_rd_data;
            3'd2: height_reg[7:0] <= rx_rd_data;
            3'd3: height_reg[15:8] <= rx_rd_data;
            3'd4: format_reg     <= rx_rd_data;
            3'd5: requested_mode <= rx_rd_data;
            default: requested_mode <= 8'hff;
        endcase

//会话长度和序号只在首次成功请求完成时更新，重试不进入这些分支
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        active         <= 1'b0;
        session_id     <= 16'd0;
        next_seq       <= 16'd0;
        total_bytes    <= 32'd0;
        received_bytes <= 32'd0;
        mode_reg       <= 3'd0;
        session_width  <= 16'd0;
    end else if(session_clear)
        active <= 1'b0;
    else if(state == ARG_CHECK && start_legal) begin
        active         <= 1'b1;
        session_id     <= id_reg;
        next_seq       <= 16'd1;
        total_bytes    <= image_bytes;
        received_bytes <= 32'd0;
        mode_reg       <= requested_mode[2:0];
        session_width  <= width_reg;
    end else if(data_complete) begin
        received_bytes <= received_bytes + {16'd0, process_length};
        next_seq       <= next_seq + 1'b1;
    end else if(state == DISPATCH && !same_key && cmd_reg == CMD_END && end_legal)
        active <= 1'b0;

//图像行位置只在滤波分片首次完成时推进，非法START参数不影响会话宽度
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        column_index <= 16'd0;
    else if(state == ARG_CHECK && start_legal)
        column_index <= 16'd0;
    else if(state == WRITE_HI && pixel_end && filter_mode)
        column_index <= (column_index + tile_count == session_width) ? 16'd0 : column_index + tile_count;

//滤波请求长度与返回长度不同；先完整校验N，再允许写结果RAM
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        process_length <= 16'd0;
    else if(state == DISPATCH && !same_key && cmd_reg == CMD_DATA && data_legal && !filter_mode)
        process_length <= len_reg;
    else if(state == FILTER_CHECK && filter_legal)
        process_length <= filter_output_length[15:0];

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        tile_count <= 16'd0;
    else if(state == COUNT_LO_GET)
        tile_count[7:0] <= rx_rd_data;
    else if(state == COUNT_HI_GET)
        tile_count[15:8] <= rx_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        window_index <= 4'd0;
    else if(state == DISPATCH || state == WRITE_HI)
        window_index <= 4'd0;
    else if(state == HI_GET && filter_mode && window_index != 4'd8)
        window_index <= window_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        window_data <= 144'd0;
    else if(state == HI_GET && filter_mode)
        window_data[window_index * 16 +: 16] <= {rx_rd_data, pixel_low};

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        pixel_index <= 10'd0;
    else if(state == DISPATCH && !same_key && cmd_reg == CMD_DATA && data_legal)
        pixel_index <= 10'd0;
    else if(state == WRITE_HI && !pixel_end)
        pixel_index <= pixel_index + 10'd2;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        pixel_low <= 8'd0;
    else if(state == LO_GET)
        pixel_low <= rx_rd_data;

//原图通道先读取字节0，随后每拍读下一字节并写入当前字节
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        copy_index <= 10'd0;
    else if(state == DISPATCH)
        copy_index <= 10'd0;
    else if(state == COPY_RUN && !copy_end)
        copy_index <= copy_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        input_pixel <= 16'd0;
    else if(state == HI_GET)
        input_pixel <= {rx_rd_data, pixel_low};

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        output_pixel <= 16'd0;
    else if(state == PIX_WAIT && pixel_out_valid)
        output_pixel <= pixel_out_data;

//缓存最近成功应答的字段，结果RAM内容保留到下一个合法DATA处理
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cache_valid    <= 1'b0;
        cache_cmd      <= 8'd0;
        cache_id       <= 16'd0;
        cache_seq      <= 16'd0;
        cache_len      <= 16'd0;
        cache_crc      <= 16'd0;
        cache_resp_cmd <= 8'd0;
        cache_resp_len <= 16'd0;
        cache_kind     <= KIND_EMPTY;
    end else if(cache_clear)
        cache_valid <= 1'b0;
    else if(state == COMMIT) begin
        cache_valid    <= 1'b1;
        cache_cmd      <= cmd_reg;
        cache_id       <= id_reg;
        cache_seq      <= seq_reg;
        cache_len      <= len_reg;
        cache_crc      <= crc_reg;
        cache_resp_cmd <= resp_cmd;
        cache_resp_len <= resp_length;
        cache_kind     <= resp_kind;
    end

//行片段布局：N低/高字节、上中下三行；pixel_index为当前输出像素的字节偏移
always@(*) begin
    filter_pixel_addr = 10'd2 + pixel_index;
    case(window_index)
        4'd0: filter_pixel_addr = 10'd2 + pixel_index;
        4'd1: filter_pixel_addr = 10'd4 + pixel_index;
        4'd2: filter_pixel_addr = 10'd6 + pixel_index;
        4'd3: filter_pixel_addr = 10'd2 + pixel_index + tile_stride;
        4'd4: filter_pixel_addr = 10'd4 + pixel_index + tile_stride;
        4'd5: filter_pixel_addr = 10'd6 + pixel_index + tile_stride;
        4'd6: filter_pixel_addr = 10'd2 + pixel_index + (tile_stride << 1);
        4'd7: filter_pixel_addr = 10'd4 + pixel_index + (tile_stride << 1);
        4'd8: filter_pixel_addr = 10'd6 + pixel_index + (tile_stride << 1);
        default: filter_pixel_addr = 10'd2 + pixel_index;
    endcase
end

//rx_rd_addr:WAIT/GET使用同一地址，对齐同步BRAM的一拍读延迟
always@(*) begin
    rx_rd_addr = filter_mode ? filter_pixel_addr : pixel_index;
    if(state == ARG_WAIT || state == ARG_GET || state == ARG_CHECK)
        rx_rd_addr = {7'd0, arg_index};
    else if(state == COUNT_LO_WAIT || state == COUNT_LO_GET)
        rx_rd_addr = 10'd0;
    else if(state == COUNT_HI_WAIT || state == COUNT_HI_GET)
        rx_rd_addr = 10'd1;
    else if(state == HI_WAIT || state == HI_GET)
        rx_rd_addr = (filter_mode ? filter_pixel_addr : pixel_index) + 10'd1;
    else if(state == COPY_PRIME)
        rx_rd_addr = 10'd0;
    else if(state == COPY_RUN)
        rx_rd_addr = copy_end ? copy_index : copy_index + 1'b1;
end

always@(*) begin
    resp_data = 8'd0;
    case(resp_kind)
        KIND_PIXELS: resp_data = result_rd_data;
        KIND_ERROR:  resp_data = error_code;
        KIND_PING: case(resp_addr)
            10'd0: resp_data = 8'h55;
            10'd1: resp_data = 8'h49;
            10'd2: resp_data = 8'h4d;
            10'd3: resp_data = 8'h47;
            10'd4: resp_data = 8'd1;
            10'd5: resp_data = 8'hff;
            10'd6: resp_data = 8'h00;
            10'd7: resp_data = 8'h04;
            default: resp_data = 8'd0;
        endcase
        default: resp_data = 8'd0;
    endcase
end

endmodule
