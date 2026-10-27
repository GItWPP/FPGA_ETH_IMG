//--------------------------------------------------------------------------------------------------------
// 模块： hog_uart_ctrl
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： HOG灰度上传、计算启动、得分分片读取和最近成功应答重发
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  hog_uart_ctrl
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
    output  wire                    hog_frame_wr_en        ,
    output  wire           [16:0]   hog_frame_wr_addr      ,
    output  wire           [7:0]    hog_frame_wr_data      ,
    output  wire                    hog_start_valid        ,
    input   wire                    hog_start_ready        ,
    input   wire                    hog_done_flag          ,
    output  wire           [8:0]    hog_score_rd_addr      ,
    input   wire           [31:0]   hog_score_rd_data      ,
    input   wire           [31:0]   hog_model_id
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
reg            [16:0]   received_bytes;
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
assign success_start_flag = success_flag && (cmd_reg == 8'h10);
assign resp_valid = (state == RESP_REQ);
assign same_key = cache_valid && cmd_reg == cache_cmd && id_reg == cache_id && seq_reg == cache_seq;
assign duplicate_ok = same_key && len_reg == cache_len && crc_reg == cache_crc;
assign session_ok = active && id_reg == session_id;
assign sequence_ok = session_ok && seq_reg == next_seq;
assign data_ok = sequence_ok && !result_valid && len_reg != 16'd0 && len_reg <= 16'd1024
              && {1'b0, received_bytes} + {2'd0, len_reg} <= 18'd76800;
assign run_ok = sequence_ok && !result_valid && len_reg == 16'd0 && received_bytes == 17'd76800;
assign read_ok = sequence_ok && result_valid && len_reg == 16'd4;
assign range_ok = read_count >= 16'd1 && read_count <= 16'd256
               && {1'b0, read_offset} + {1'b0, read_count} <= 17'd495;
assign rx_rd_addr = (state == ARG_WAIT || state == ARG_GET) ? {8'd0, arg_index} : byte_index;
assign hog_frame_wr_en = (state == UP_WRITE);
assign hog_frame_wr_addr = received_bytes + {7'd0, byte_index};
assign hog_frame_wr_data = upload_data;
assign hog_start_valid = (state == CORE_REQ);
assign hog_score_rd_addr = read_offset[8:0] + score_index;
assign result_wr_en = (state == SCORE_WRITE);
assign result_wr_addr = {score_index[7:0], score_byte};
assign result_wr_data = score_data[score_byte * 8 +: 8];
assign info_bytes = {hog_model_id, 8'd1, 8'd8, 8'd128, 8'd64, 16'd240, 16'd320, 32'h31474f48};

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(packet_valid) next_state = DISPATCH;
        DISPATCH: begin
            next_state = RESP_REQ;
            if(!same_key)
                case(cmd_reg)
                    8'h1f: if(len_reg == 16'd0) next_state = COMMIT;
                    8'h10: if(len_reg == 16'd0 && seq_reg == 16'd0) next_state = COMMIT;
                    8'h11: if(data_ok) next_state = UP_WAIT;
                    8'h12: if(run_ok) next_state = CORE_REQ;
                    8'h13: if(read_ok) next_state = ARG_WAIT;
                    default: next_state = RESP_REQ;
                endcase
        end
        UP_WAIT: next_state = UP_GET;
        UP_GET: next_state = UP_WRITE;
        UP_WRITE: next_state = ({6'd0, byte_index} + 16'd1 == len_reg) ? COMMIT : UP_WAIT;
        ARG_WAIT: next_state = ARG_GET;
        ARG_GET: next_state = (arg_index == 2'd3) ? ARG_CHECK : ARG_WAIT;
        ARG_CHECK: next_state = range_ok ? SCORE_WAIT : RESP_REQ;
        CORE_REQ: if(hog_start_ready) next_state = CORE_WAIT;
        CORE_WAIT: if(hog_done_flag) next_state = COMMIT;
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
        received_bytes <= 17'd0;
    end else if(session_clear) begin
        active <= 1'b0;
        result_valid <= 1'b0;
    end else if(state == COMMIT && cmd_reg == 8'h10) begin
        active <= 1'b1;
        result_valid <= 1'b0;
        session_id <= id_reg;
        next_seq <= 16'd1;
        received_bytes <= 17'd0;
    end else if(state == COMMIT && cmd_reg == 8'h11) begin
        received_bytes <= received_bytes + {1'b0, len_reg};
        next_seq <= next_seq + 1'b1;
    end else if(state == COMMIT && cmd_reg == 8'h12) begin
        result_valid <= 1'b1;
        next_seq <= next_seq + 1'b1;
    end else if(state == COMMIT && cmd_reg == 8'h13)
        next_seq <= next_seq + 1'b1;

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
        score_data <= hog_score_rd_data;

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
            if(cmd_reg == 8'h1f && len_reg == 16'd0) begin
                resp_cmd <= 8'h9f;
                resp_length <= 16'd16;
                resp_kind <= INFO;
            end else if(cmd_reg == 8'h10 && len_reg == 16'd0 && seq_reg == 16'd0) begin
                resp_cmd <= 8'h90;
                resp_length <= 16'd0;
                resp_kind <= EMPTY;
            end else if(cmd_reg == 8'h11 && data_ok) begin
                resp_cmd <= 8'h91;
                resp_length <= 16'd0;
                resp_kind <= EMPTY;
            end else if(cmd_reg == 8'h12 && run_ok) begin
                resp_cmd <= 8'h92;
                resp_length <= 16'd2;
                resp_kind <= COUNT;
            end
        end
    end else if(state == ARG_CHECK && range_ok) begin
        resp_cmd <= 8'h93;
        resp_length <= read_count << 2;
        resp_kind <= SCORES;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        error_code <= 8'd0;
    else if(state == ARG_CHECK && !range_ok)
        error_code <= 8'd2;
    else if(state == DISPATCH) begin
        if(same_key)
            error_code <= 8'd6;
        else if(cmd_reg == 8'h10 || cmd_reg == 8'h1f)
            error_code <= 8'd2;
        else if(cmd_reg >= 8'h11 && cmd_reg <= 8'h13) begin
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
        COUNT: resp_data = (resp_addr == 10'd0) ? 8'hef : 8'h01;
        SCORES: resp_data = result_rd_data;
        ERROR: resp_data = error_code;
        default: resp_data = 8'd0;
    endcase
end

endmodule
