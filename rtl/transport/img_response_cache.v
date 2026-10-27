//--------------------------------------------------------------------------------------------------------
// 模块： img_response_cache
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 64槽有效缓存加独立暂存槽，校验成功原子换槽，计算与发送并行
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  img_response_cache
(
    input   wire                   sys_clk                ,
    input   wire                   sys_rst_n              ,
    input   wire                   packet_valid           ,
    output  wire                   packet_ready           ,
    output  wire                   receive_en             ,
    output  wire                   packet_release_flag    ,
    input   wire           [7:0]   req_cmd                ,
    input   wire           [15:0]  req_id                 ,
    input   wire           [15:0]  req_seq                ,
    input   wire           [15:0]  req_length             ,
    input   wire           [15:0]  req_crc                ,
    input   wire           [95:0]  req_peer               ,
    output  wire                   cmd_packet_valid       ,
    input   wire                   cmd_packet_ready       ,

    input   wire                   result_wr_en           ,
    input   wire           [9:0]   result_wr_addr         ,
    input   wire           [7:0]   result_wr_data         ,
    input   wire                   cmd_resp_valid         ,
    output  wire                   cmd_resp_ready         ,
    input   wire           [7:0]   cmd_resp_cmd           ,
    input   wire           [15:0]  cmd_resp_id            ,
    input   wire           [15:0]  cmd_resp_seq           ,
    input   wire           [15:0]  cmd_resp_length        ,
    input   wire           [7:0]   cmd_resp_data          ,
    output  wire                   cmd_resp_done          ,
    output  wire                   resp_valid             ,
    input   wire                   resp_ready             ,
    output  wire           [7:0]   resp_cmd               ,
    output  wire           [15:0]  resp_id                ,
    output  wire           [15:0]  resp_seq               ,
    output  wire           [15:0]  resp_length            ,
    input   wire           [9:0]   resp_addr              ,
    output  wire           [7:0]   resp_data              ,
    output  wire           [95:0]  resp_peer              ,
    input   wire                   resp_done
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [2:0] IDLE = 3'd0;
localparam [2:0] CHECK = 3'd1;
localparam [2:0] FORWARD = 3'd2;
localparam [2:0] WAIT_REPLY = 3'd3;
localparam [2:0] LOCAL_REQ = 3'd4;
localparam [2:0] FINISH = 3'd5;
localparam [2:0] BLOCK_WAIT = 3'd6;
localparam [1:0] CACHE_DATA = 2'd0;
localparam [1:0] INLINE_DATA = 2'd1;
localparam [1:0] COMMAND_DATA = 2'd2;
localparam [63:0] INFO_BYTES = 64'h04_00_40_01_4e_49_57_45;
//wire  define
wire [5:0] req_slot;
wire [183:0] tag_read;
wire data_request;
wire same_key;
wire duplicate_ok;
wire info_request;
wire fifo_full;
wire command_push;
wire local_push;
wire push_flag;
wire pop_flag;
wire data_success;
wire cache_write_en;
wire tag_commit_en;
wire tag_clear_en;
wire [7:0] cache_read_data;
wire [7:0] spare_read_data;
wire [1:0] head_kind;
wire [6:0] head_slot;
wire [63:0] head_inline;
wire [7:0] local_cmd;
wire [15:0] local_length;
wire [63:0] local_inline;
wire [224:0] push_descriptor;
//reg   define
reg [2:0] state;
reg [2:0] next_state;
reg [63:0] tag_valid;
reg [63:0] slot_busy;
(* ram_style = "distributed" *) reg [183:0] tags [0:63];
(* ram_style = "distributed" *) reg [224:0] descriptors [0:7];
reg [6:0] slot_map [0:63];
reg [6:0] free_slot;
reg [2:0] wr_pointer;
reg [2:0] rd_pointer;
reg [3:0] fifo_count;
genvar slot;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign req_slot = req_seq[5:0];
assign data_request = (req_cmd == 8'h03 || req_cmd == 8'h41);
assign tag_read = tags[req_slot];
assign packet_ready = (state == IDLE) && !(data_request && slot_busy[req_slot]);
assign receive_en = (state == IDLE);
assign cmd_packet_valid = (state == FORWARD);
assign same_key = data_request && tag_valid[req_slot] && tag_read[183:176] == req_cmd
                  && tag_read[175:160] == req_id && tag_read[159:144] == req_seq
                  && tag_read[95:0] == req_peer;
assign duplicate_ok = same_key && tag_read[143:128] == req_length
                      && tag_read[127:112] == req_crc;
assign info_request = (req_cmd == 8'h05);
assign fifo_full = (fifo_count == 4'd8);
assign command_push = (state == WAIT_REPLY) && cmd_resp_valid && !fifo_full;
assign local_push = (state == LOCAL_REQ) && !fifo_full;
assign push_flag = command_push || local_push;
assign pop_flag = resp_done && fifo_count != 4'd0;
assign data_success = (cmd_resp_cmd == 8'h83 || cmd_resp_cmd == 8'hc1);
assign cmd_resp_ready = (state == WAIT_REPLY) && !fifo_full;
assign cmd_resp_done = (state == FINISH) || ((state == BLOCK_WAIT) && pop_flag && head_kind == COMMAND_DATA);
assign packet_release_flag = (state == FINISH) || local_push
                             || ((state == BLOCK_WAIT) && pop_flag && head_kind == COMMAND_DATA);
assign resp_valid = (fifo_count != 4'd0);
assign {head_kind,head_slot,resp_cmd,resp_id,resp_seq,resp_length,resp_peer,head_inline}
       = descriptors[rd_pointer];
assign local_cmd = info_request ? ((req_length == 16'd0) ? 8'h85 : 8'hff)
                               : (duplicate_ok ? (req_cmd | 8'h80) : 8'hff);
assign local_length = info_request ? ((req_length == 16'd0) ? 16'd8 : 16'd1)
                                  : (duplicate_ok ? tag_read[111:96] : 16'd1);
assign local_inline = info_request ? ((req_length == 16'd0) ? INFO_BYTES : 64'd2) : 64'd6;
assign push_descriptor = command_push
    ? {data_success ? CACHE_DATA : COMMAND_DATA,free_slot,cmd_resp_cmd,cmd_resp_id,cmd_resp_seq,cmd_resp_length,req_peer,64'd0}
    : {duplicate_ok && !info_request ? CACHE_DATA : INLINE_DATA,slot_map[req_slot],local_cmd,req_id,req_seq,local_length,req_peer,local_inline};
assign resp_data = (head_kind == CACHE_DATA) ? (head_slot[6] ? spare_read_data : cache_read_data)
                 : ((head_kind == INLINE_DATA) ? head_inline[resp_addr[2:0]*8 +: 8] : cmd_resp_data);
assign cache_write_en = (state == WAIT_REPLY) && data_request && result_wr_en;
assign tag_commit_en = command_push && data_success;
assign tag_clear_en = command_push && !data_success && cmd_resp_cmd != 8'hff;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(packet_valid && packet_ready) next_state = CHECK;
        CHECK: next_state = (info_request || same_key) ? LOCAL_REQ : FORWARD;
        FORWARD: if(cmd_packet_ready) next_state = WAIT_REPLY;
        WAIT_REPLY: if(command_push) next_state = data_success ? FINISH : BLOCK_WAIT;
        LOCAL_REQ: if(local_push) next_state = IDLE;
        FINISH: next_state = IDLE;
        BLOCK_WAIT: if(cmd_resp_done) next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//FIFO头在编码完成前保持；描述符同时保存结果槽与返回端点
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        wr_pointer <= 3'd0;
    else if(push_flag)
        wr_pointer <= wr_pointer + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        rd_pointer <= 3'd0;
    else if(pop_flag)
        rd_pointer <= rd_pointer + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        fifo_count <= 4'd0;
    else if(push_flag != pop_flag)
        case({push_flag,pop_flag})
            2'b10: fifo_count <= fifo_count + 1'b1;
            2'b01: fifo_count <= fifo_count - 1'b1;
            default: fifo_count <= 4'd0;
        endcase

always@(posedge sys_clk)
    if(push_flag)
        descriptors[wr_pointer] <= push_descriptor;

always@(posedge sys_clk)
    if(tag_commit_en)
        tags[req_slot] <= {req_cmd,req_id,req_seq,req_length,req_crc,cmd_resp_length,req_peer};

//65个物理槽中仅一个可写，提交时与目标逻辑槽互换；错误请求不改变映射
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        free_slot <= 7'd64;
    else if(tag_commit_en)
        free_slot <= slot_map[req_slot];

//busy直到缓存读取结束才释放，保护发送反压及低六位槽号回绕
generate
    for(slot = 0; slot < 64; slot = slot + 1) begin : cache_tag
        always@(posedge sys_clk)
            if(sys_rst_n == 1'b0)
                slot_map[slot] <= slot;
            else if(tag_commit_en && req_slot == slot)
                slot_map[slot] <= free_slot;

        always@(posedge sys_clk)
            if(sys_rst_n == 1'b0)
                tag_valid[slot] <= 1'b0;
            else if(tag_clear_en)
                tag_valid[slot] <= 1'b0;
            else if(tag_commit_en && req_slot == slot)
                tag_valid[slot] <= 1'b1;

        always@(posedge sys_clk)
            if(sys_rst_n == 1'b0)
                slot_busy[slot] <= 1'b0;
            else if(push_flag && push_descriptor[224:223] == CACHE_DATA && req_slot == slot)
                slot_busy[slot] <= 1'b1;
            else if(pop_flag && head_kind == CACHE_DATA && resp_seq[5:0] == slot)
                slot_busy[slot] <= 1'b0;
    end
endgenerate

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_block_buffer
#(
    .ADDR_WIDTH             (16)
)
cache_ram_inst
(
    .sys_clk                (sys_clk),
    .wr_en                  (cache_write_en && !free_slot[6]),
    .wr_addr                ({free_slot[5:0],result_wr_addr}),
    .wr_data                (result_wr_data),
    .rd_addr                ({head_slot[5:0],resp_addr}),
    .rd_data                (cache_read_data)
);

img_block_buffer spare_ram_inst
(
    .sys_clk                (sys_clk),
    .wr_en                  (cache_write_en && free_slot[6]),
    .wr_addr                (result_wr_addr),
    .wr_data                (result_wr_data),
    .rd_addr                (resp_addr),
    .rd_data                (spare_read_data)
);

endmodule
