//--------------------------------------------------------------------------------------------------------
// 模块： band_uart_ctrl
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： Band原始灰度上传、尺寸校验、解码启动及结果分片读取
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  band_uart_ctrl
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
    output  wire           [9:0]    rx_rd_addr             ,
    input   wire           [7:0]    rx_rd_data             ,
    output  wire                    result_wr_en           ,
    output  wire           [9:0]    result_wr_addr         ,
    output  wire           [7:0]    result_wr_data         ,
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
    output  wire                    band_frame_wr_en        ,
    output  wire           [17:0]   band_frame_wr_addr      ,
    output  wire           [7:0]    band_frame_wr_data      ,
    output  wire                    band_start_valid        ,
    input   wire                    band_start_ready        ,
    input   wire                    band_done_flag          ,
    output  wire           [11:0]   band_score_rd_addr      ,
    input   wire           [31:0]   band_score_rd_data      ,
    input   wire           [15:0]   band_result_count      ,
    input   wire           [7:0]    band_result_rows       ,
    input   wire           [7:0]    band_result_status     ,
    input   wire           [15:0]   band_pitch_q8          ,
    input   wire           [15:0]   band_detected_dots     ,
    output  wire           [9:0]    band_image_width       ,
    output  wire           [9:0]    band_image_height
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [4:0] IDLE             = 5'd0;
localparam [4:0] DISPATCH         = 5'd1;
localparam [4:0] UP_WAIT          = 5'd2;
localparam [4:0] UP_GET           = 5'd3;
localparam [4:0] UP_WRITE         = 5'd4;
localparam [4:0] ARG_WAIT         = 5'd5;
localparam [4:0] ARG_GET          = 5'd6;
localparam [4:0] ARG_CHECK        = 5'd7;
localparam [4:0] CORE_REQ         = 5'd8;
localparam [4:0] CORE_WAIT        = 5'd9;
localparam [4:0] SCORE_WAIT       = 5'd10;
localparam [4:0] SCORE_GET        = 5'd11;
localparam [4:0] SCORE_WRITE      = 5'd12;
localparam [4:0] COMMIT           = 5'd13;
localparam [4:0] RESP_REQ         = 5'd14;
localparam [4:0] RESP_WAIT        = 5'd15;
localparam [2:0] EMPTY            = 3'd0;
localparam [2:0] INFO             = 3'd1;
localparam [2:0] COUNT            = 3'd2;
localparam [2:0] SCORES           = 3'd3;
localparam [2:0] ERROR            = 3'd4;
//wire  define
wire                    same_key;
wire                    duplicate_ok;
wire                    session_ok;
wire                    sequence_ok;
wire                    data_ok;
wire                    run_ok;
wire                    read_ok;
wire                    range_ok;
wire           [127:0]  info_bytes;
wire           [127:0]  count_bytes;
wire                    start_range_ok;
//reg   define
reg            [4:0]    state;
reg            [4:0]    next_state;
reg            [7:0]    cmd_reg;
reg            [15:0]   id_reg;
reg            [15:0]   seq_reg;
reg            [15:0]   len_reg;
reg            [15:0]   crc_reg;
reg                     active;
reg                     result_valid;
reg            [15:0]   session_id;
reg            [15:0]   next_seq;
reg            [18:0]   received_bytes;
reg            [18:0]   expected_bytes;
reg            [9:0]    width_reg;
reg            [9:0]    height_reg;
reg            [8:0]    upload_x;
reg            [8:0]    upload_y;
reg            [9:0]    byte_index;
reg            [7:0]    upload_data;
reg            [1:0]    arg_index;
reg            [15:0]   read_offset;
reg            [15:0]   read_count;
reg            [8:0]    score_index;
reg            [1:0]    score_byte;
reg            [31:0]   score_data;
reg            [2:0]    resp_kind;
reg            [7:0]    error_code;
reg                     cache_valid;
reg            [7:0]    cache_cmd;
reg            [15:0]   cache_id;
reg            [15:0]   cache_seq;
reg            [15:0]   cache_len;
reg            [15:0]   cache_crc;
reg            [7:0]    cache_resp_cmd;
reg            [15:0]   cache_resp_length;
reg            [2:0]    cache_kind;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign receive_en = (state == IDLE);
assign packet_ready = (state == IDLE);
assign success_flag = (state == COMMIT);
assign success_start_flag = success_flag && (cmd_reg == 8'h20);
assign resp_valid = (state == RESP_REQ);
assign same_key = cache_valid && cmd_reg == cache_cmd && id_reg == cache_id && seq_reg == cache_seq;
assign duplicate_ok = same_key && len_reg == cache_len && crc_reg == cache_crc;
assign session_ok = active && id_reg == session_id;
assign sequence_ok = session_ok && seq_reg == next_seq;
assign data_ok = sequence_ok && !result_valid && len_reg != 16'd0 && len_reg <= 16'd1024
              && {1'b0, received_bytes} + {4'd0, len_reg} <= {1'b0, expected_bytes};
assign run_ok = sequence_ok && !result_valid && len_reg == 16'd0 && received_bytes == expected_bytes;
assign read_ok = sequence_ok && result_valid && len_reg == 16'd4;
assign range_ok = read_count >= 16'd1 && read_count <= 16'd256
               && {1'b0, read_offset} + {1'b0, read_count} <= {1'b0, band_result_count} && band_result_status == 8'd0;
assign rx_rd_addr = (state == ARG_WAIT || state == ARG_GET) ? {8'd0, arg_index} : byte_index;
assign band_frame_wr_en = (state == UP_WRITE);
assign band_frame_wr_addr = {upload_y, upload_x};
assign band_image_width = width_reg;
assign band_image_height = height_reg;
assign start_range_ok = read_offset >= 16'd16 && read_offset <= 16'd512 && read_count >= 16'd16 && read_count <= 16'd512;
assign band_frame_wr_data = upload_data;
assign band_start_valid = (state == CORE_REQ);
assign band_score_rd_addr = read_offset[11:0] + {3'd0, score_index};
assign result_wr_en = (state == SCORE_WRITE);
assign result_wr_addr = {score_index[7:0], score_byte};
assign result_wr_data = score_data[score_byte * 8 +: 8];
assign info_bytes = {32'd0, 16'd4096, 8'd2, 8'd1, 16'd512, 16'd512, 32'h31444e42};
assign count_bytes = {band_detected_dots, 6'd0, height_reg, 6'd0, width_reg, band_pitch_q8, band_result_status, band_result_rows, band_result_count, 32'h31444e42};

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(packet_valid) next_state = DISPATCH;
        DISPATCH: begin
            next_state = RESP_REQ;
            if(!same_key)
                case(cmd_reg)
                    8'h2f: if(len_reg == 16'd0) next_state = COMMIT;
                    8'h20: if(len_reg == 16'd4 && seq_reg == 16'd0) next_state = ARG_WAIT;
                    8'h21: if(data_ok) next_state = UP_WAIT;
                    8'h22: if(run_ok) next_state = CORE_REQ;
                    8'h23: if(read_ok) next_state = ARG_WAIT;
                    default: next_state = RESP_REQ;
                endcase
        end
        UP_WAIT: next_state = UP_GET;
        UP_GET: next_state = UP_WRITE;
        UP_WRITE: next_state = ({6'd0, byte_index} + 16'd1 == len_reg) ? COMMIT : UP_WAIT;
        ARG_WAIT: next_state = ARG_GET;
        ARG_GET: next_state = (arg_index == 2'd3) ? ARG_CHECK : ARG_WAIT;
        ARG_CHECK: next_state = (cmd_reg == 8'h20) ? (start_range_ok ? COMMIT : RESP_REQ) : (range_ok ? SCORE_WAIT : RESP_REQ);
        CORE_REQ: if(band_start_ready) next_state = CORE_WAIT;
        CORE_WAIT: if(band_done_flag) next_state = COMMIT;
        SCORE_WAIT: next_state = SCORE_GET;
        SCORE_GET: next_state = SCORE_WRITE;
        SCORE_WRITE: if(score_byte == 2'd3)
                         next_state = ({7'd0, score_index} + 16'd1 == read_count) ? COMMIT : SCORE_WAIT;
        COMMIT: next_state = RESP_REQ;
        RESP_REQ: if(resp_ready) next_state = RESP_WAIT;
        RESP_WAIT: if(resp_done) next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//状态与BRAM地址/使能链统一同步复位；请求和会话寄存器分开维护
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cmd_reg <= 8'd0;
        id_reg <= 16'd0;
        seq_reg <= 16'd0;
        len_reg <= 16'd0;
        crc_reg <= 16'd0;
        resp_id <= 16'd0;
        resp_seq <= 16'd0;
    end else if(state == IDLE && packet_valid) begin
        cmd_reg <= req_cmd;
        id_reg <= req_id;
        seq_reg <= req_seq;
        len_reg <= req_length;
        crc_reg <= req_crc;
        resp_id <= req_id;
        resp_seq <= req_seq;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        active <= 1'b0;
        result_valid <= 1'b0;
        session_id <= 16'd0;
        next_seq <= 16'd0;
        received_bytes <= 19'd0;
    end else if(session_clear) begin
        active <= 1'b0;
        result_valid <= 1'b0;
    end else if(state == COMMIT && cmd_reg == 8'h20) begin
        active <= 1'b1;
        result_valid <= 1'b0;
        session_id <= id_reg;
        next_seq <= 16'd1;
        received_bytes <= 19'd0;
    end else if(state == COMMIT && cmd_reg == 8'h21) begin
        received_bytes <= received_bytes + {3'd0, len_reg};
        next_seq <= next_seq + 1'b1;
    end else if(state == COMMIT && cmd_reg == 8'h22) begin
        result_valid <= 1'b1;
        next_seq <= next_seq + 1'b1;
    end else if(state == COMMIT && cmd_reg == 8'h23)
        next_seq <= next_seq + 1'b1;

//上传按固定512像素行跨度映射帧RAM，外部数据保持原始紧凑布局
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        expected_bytes <= 19'd0;
        width_reg <= 10'd512;
        height_reg <= 10'd512;
        upload_x <= 9'd0;
        upload_y <= 9'd0;
    end else if(state == COMMIT && cmd_reg == 8'h20) begin
        expected_bytes <= read_offset * read_count;
        width_reg <= read_offset[9:0];
        height_reg <= read_count[9:0];
        upload_x <= 9'd0;
        upload_y <= 9'd0;
    end else if(state == UP_WRITE) begin
        if({1'b0, upload_x} + 10'd1 == width_reg) begin
            upload_x <= 9'd0;
            upload_y <= upload_y + 1'b1;
        end else
            upload_x <= upload_x + 1'b1;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        byte_index <= 10'd0;
    else if(state == DISPATCH)
        byte_index <= 10'd0;
    else if(state == UP_WRITE)
        byte_index <= byte_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        upload_data <= 8'd0;
    else if(state == UP_GET)
        upload_data <= rx_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        arg_index <= 2'd0;
    else if(state == DISPATCH)
        arg_index <= 2'd0;
    else if(state == ARG_GET)
        arg_index <= arg_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        read_offset <= 16'd0;
        read_count <= 16'd0;
    end else if(state == ARG_GET)
        case(arg_index)
            2'd0: read_offset[7:0] <= rx_rd_data;
            2'd1: read_offset[15:8] <= rx_rd_data;
            2'd2: read_count[7:0] <= rx_rd_data;
            2'd3: read_count[15:8] <= rx_rd_data;
            default: read_count <= 16'd0;
        endcase

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        score_index <= 9'd0;
        score_byte <= 2'd0;
    end else if(state == DISPATCH) begin
        score_index <= 9'd0;
        score_byte <= 2'd0;
    end else if(state == SCORE_WRITE) begin
        score_byte <= score_byte + 1'b1;
        if(score_byte == 2'd3) score_index <= score_index + 1'b1;
    end

//完整读出后才进入SCORE_WRITE，未初始化数据由状态有效性屏蔽；避免复位吸收进BRAM输出寄存器
always@(posedge sys_clk)
    if(state == SCORE_GET)
        score_data <= band_score_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        resp_cmd <= 8'd0;
        resp_length <= 16'd0;
        resp_kind <= EMPTY;
    end else if(state == DISPATCH) begin
        resp_cmd <= 8'hff;
        resp_length <= 16'd1;
        resp_kind <= ERROR;
        if(duplicate_ok) begin
            resp_cmd <= cache_resp_cmd;
            resp_length <= cache_resp_length;
            resp_kind <= cache_kind;
        end else if(!same_key) begin
            if(cmd_reg == 8'h2f && len_reg == 16'd0) begin
                resp_cmd <= 8'haf;
                resp_length <= 16'd16;
                resp_kind <= INFO;
            end else if(cmd_reg == 8'h20 && len_reg == 16'd4 && seq_reg == 16'd0) begin
                resp_cmd <= 8'ha0;
                resp_length <= 16'd0;
                resp_kind <= EMPTY;
            end else if(cmd_reg == 8'h21 && data_ok) begin
                resp_cmd <= 8'ha1;
                resp_length <= 16'd0;
                resp_kind <= EMPTY;
            end else if(cmd_reg == 8'h22 && run_ok) begin
                resp_cmd <= 8'ha2;
                resp_length <= 16'd16;
                resp_kind <= COUNT;
            end
        end
    end else if(state == ARG_CHECK && cmd_reg == 8'h20 && !start_range_ok) begin
        resp_cmd <= 8'hff;
        resp_length <= 16'd1;
        resp_kind <= ERROR;
    end else if(state == ARG_CHECK && cmd_reg == 8'h23 && range_ok) begin
        resp_cmd <= 8'ha3;
        resp_length <= read_count << 2;
        resp_kind <= SCORES;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        error_code <= 8'd0;
    else if(state == ARG_CHECK && ((cmd_reg == 8'h20 && !start_range_ok) || (cmd_reg == 8'h23 && !range_ok)))
        error_code <= 8'd2;
    else if(state == DISPATCH) begin
        if(same_key)
            error_code <= 8'd6;
        else if(cmd_reg == 8'h20 || cmd_reg == 8'h2f)
            error_code <= 8'd2;
        else if(cmd_reg >= 8'h21 && cmd_reg <= 8'h23) begin
            if(!session_ok) error_code <= 8'd3;
            else if(!sequence_ok) error_code <= 8'd4;
            else error_code <= 8'd5;
        end else
            error_code <= 8'd1;
    end

//仅另一路成功提交使缓存失效，错误请求不破坏可重发的最近结果
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cache_valid <= 1'b0;
        cache_cmd <= 8'd0;
        cache_id <= 16'd0;
        cache_seq <= 16'd0;
        cache_len <= 16'd0;
        cache_crc <= 16'd0;
        cache_resp_cmd <= 8'd0;
        cache_resp_length <= 16'd0;
        cache_kind <= EMPTY;
    end else if(cache_clear)
        cache_valid <= 1'b0;
    else if(state == COMMIT) begin
        cache_valid <= 1'b1;
        cache_cmd <= cmd_reg;
        cache_id <= id_reg;
        cache_seq <= seq_reg;
        cache_len <= len_reg;
        cache_crc <= crc_reg;
        cache_resp_cmd <= resp_cmd;
        cache_resp_length <= resp_length;
        cache_kind <= resp_kind;
    end

always@(*) begin
    resp_data = 8'd0;
    case(resp_kind)
        INFO: resp_data = info_bytes[resp_addr[3:0] * 8 +: 8];
        COUNT: resp_data = count_bytes[resp_addr[3:0] * 8 +: 8];
        SCORES: resp_data = result_rd_data;
        ERROR: resp_data = error_code;
        default: resp_data = 8'd0;
    endcase
end

endmodule
