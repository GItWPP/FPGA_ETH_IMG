//--------------------------------------------------------------------------------------------------------
// 模块： eth_packet_queue
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 八槽双时钟整包队列，Gray指针提交、校验失败回滚及连续字节读取
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  eth_packet_queue
#(
    parameter integer SLOT_BITS = 3,
    parameter integer MAX_BYTES = 1038,
    parameter integer ADDR_WIDTH = 11
)
(
    input   wire                            wr_clk                 ,
    input   wire                            wr_rst_n               ,
    input   wire                            wr_start_valid         ,
    output  wire                            wr_start_ready         ,
    input   wire           [15:0]           wr_length              ,
    input   wire           [95:0]           wr_peer                ,
    input   wire                            wr_byte_valid          ,
    output  wire                            wr_byte_ready          ,
    input   wire           [7:0]            wr_byte_data           ,
    input   wire                            wr_finish_flag         ,
    input   wire                            wr_abort_en            ,
    output  reg                             wr_drop_flag           ,

    input   wire                            rd_clk                 ,
    input   wire                            rd_rst_n               ,
    output  wire                            rd_packet_valid        ,
    input   wire                            rd_packet_ready        ,
    output  reg            [15:0]           rd_length              ,
    output  reg            [95:0]           rd_peer                ,
    output  reg            [31:0]           rd_sum                 ,
    output  reg                             rd_byte_valid          ,
    input   wire                            rd_byte_ready          ,
    output  wire           [7:0]            rd_byte_data           ,
    output  reg                             rd_byte_last
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam integer PTR_WIDTH = SLOT_BITS + 1;
localparam integer RAM_ADDR_WIDTH = SLOT_BITS + ADDR_WIDTH;
localparam [2:0] RD_IDLE = 3'd0;
localparam [2:0] RD_META = 3'd1;
localparam [2:0] RD_WAIT = 3'd2;
localparam [2:0] RD_DATA = 3'd3;

//wire  define
wire                            wr_full;
wire                            rd_empty;
wire                            wr_start_accept;
wire                            wr_store_en;
wire                            wr_commit_en;
wire                            rd_start_accept;
wire                            rd_byte_accept;
wire                            rd_release_en;
wire                            rd_load_en;
wire                            meta_read_en;
wire           [143:0]          meta_write_data;
wire           [143:0]          meta_read_data;
wire           [PTR_WIDTH-1:0]  wr_bin_next;
wire           [PTR_WIDTH-1:0]  rd_bin_next;

//reg   define
reg                             wr_active;
reg                             wr_error_en;
reg            [15:0]           wr_count;
reg            [15:0]           length_hold;
reg            [95:0]           peer_hold;
reg            [31:0]           checksum_sum;
reg            [7:0]            high_byte;
reg            [PTR_WIDTH-1:0]  wr_bin;
reg            [PTR_WIDTH-1:0]  wr_gray;
reg            [PTR_WIDTH-1:0]  rd_bin;
reg            [PTR_WIDTH-1:0]  rd_gray;
(* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_sync1;
(* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_sync2;
(* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_sync3;
(* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_sync1;
(* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_sync2;
(* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_sync3;
reg            [2:0]            rd_state;
reg            [2:0]            rd_next_state;
reg            [15:0]           rd_count;
reg                             rd_fetch_en;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign wr_full = (wr_gray == {~rd_gray_sync3[PTR_WIDTH-1:PTR_WIDTH-2],
                              rd_gray_sync3[PTR_WIDTH-3:0]});
assign rd_empty = (rd_gray == wr_gray_sync3);
assign wr_start_ready = !wr_active && !wr_full;
assign wr_start_accept = wr_start_valid && wr_start_ready;
assign wr_byte_ready = wr_active;
assign wr_store_en = wr_byte_valid && wr_byte_ready && wr_count < length_hold
                   && wr_count < MAX_BYTES;
assign wr_commit_en = wr_active && wr_finish_flag && !wr_abort_en
                    && !wr_error_en && wr_count == length_hold;
assign wr_bin_next = wr_bin + {{SLOT_BITS{1'b0}}, 1'b1};
assign rd_bin_next = rd_bin + {{SLOT_BITS{1'b0}}, 1'b1};
assign meta_write_data = {length_hold, peer_hold,
                         checksum_sum + (length_hold[0] ? {16'd0, high_byte, 8'd0} : 32'd0)};
assign meta_read_en = (rd_state == RD_IDLE) && !rd_empty;
assign rd_packet_valid = (rd_state == RD_WAIT);
assign rd_start_accept = rd_packet_valid && rd_packet_ready;
assign rd_byte_accept = rd_byte_valid && rd_byte_ready;
assign rd_release_en = rd_byte_accept && rd_byte_last;
assign rd_load_en = (rd_state == RD_DATA) && rd_fetch_en
                  && (!rd_byte_valid || rd_byte_ready);

//Gray总线仅在整包提交/释放时改变一位，三级同步后再判断空满
always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0) begin
        rd_gray_sync1 <= {PTR_WIDTH{1'b0}};
        rd_gray_sync2 <= {PTR_WIDTH{1'b0}};
        rd_gray_sync3 <= {PTR_WIDTH{1'b0}};
    end else begin
        rd_gray_sync1 <= rd_gray;
        rd_gray_sync2 <= rd_gray_sync1;
        rd_gray_sync3 <= rd_gray_sync2;
    end

always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0) begin
        wr_gray_sync1 <= {PTR_WIDTH{1'b0}};
        wr_gray_sync2 <= {PTR_WIDTH{1'b0}};
        wr_gray_sync3 <= {PTR_WIDTH{1'b0}};
    end else begin
        wr_gray_sync1 <= wr_gray;
        wr_gray_sync2 <= wr_gray_sync1;
        wr_gray_sync3 <= wr_gray_sync2;
    end

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0)
        wr_active <= 1'b0;
    else if(wr_start_accept)
        wr_active <= (wr_length != 16'd0 && wr_length <= MAX_BYTES);
    else if(wr_finish_flag)
        wr_active <= 1'b0;

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0) begin
        length_hold <= 16'd0;
        peer_hold <= 96'd0;
    end else if(wr_start_accept) begin
        length_hold <= wr_length;
        peer_hold <= wr_peer;
    end

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0)
        wr_count <= 16'd0;
    else if(wr_start_accept)
        wr_count <= 16'd0;
    else if(wr_store_en)
        wr_count <= wr_count + 1'b1;

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0)
        wr_error_en <= 1'b0;
    else if(wr_start_accept)
        wr_error_en <= 1'b0;
    else if(wr_active && wr_byte_valid && !wr_store_en)
        wr_error_en <= 1'b1;

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0) begin
        checksum_sum <= 32'd0;
        high_byte <= 8'd0;
    end else if(wr_start_accept) begin
        checksum_sum <= 32'd0;
        high_byte <= 8'd0;
    end else if(wr_store_en) begin
        if(wr_count[0])
            checksum_sum <= checksum_sum + {16'd0, high_byte, wr_byte_data};
        else
            high_byte <= wr_byte_data;
    end

//失败包不推进指针，下一包安全覆盖未发布的槽
always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0) begin
        wr_bin <= {PTR_WIDTH{1'b0}};
        wr_gray <= {PTR_WIDTH{1'b0}};
    end else if(wr_commit_en) begin
        wr_bin <= wr_bin_next;
        wr_gray <= (wr_bin_next >> 1) ^ wr_bin_next;
    end

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0)
        wr_drop_flag <= 1'b0;
    else
        wr_drop_flag <= (wr_start_valid && !wr_start_ready)
                     || (wr_start_accept && (wr_length == 16'd0 || wr_length > MAX_BYTES))
                     || (wr_active && wr_finish_flag && !wr_commit_en);

always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0)
        rd_state <= RD_IDLE;
    else
        rd_state <= rd_next_state;

always@(*) begin
    rd_next_state = rd_state;
    case(rd_state)
        RD_IDLE: if(!rd_empty) rd_next_state = RD_META;
        RD_META: rd_next_state = RD_WAIT;
        RD_WAIT: if(rd_start_accept) rd_next_state = RD_DATA;
        RD_DATA: if(rd_release_en) rd_next_state = RD_IDLE;
        default: rd_next_state = RD_IDLE;
    endcase
end

always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0) begin
        rd_length <= 16'd0;
        rd_peer <= 96'd0;
        rd_sum <= 32'd0;
    end else if(rd_state == RD_META) begin
        rd_length <= meta_read_data[143:128];
        rd_peer <= meta_read_data[127:32];
        rd_sum <= meta_read_data[31:0];
    end

always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0) begin
        rd_count <= 16'd0;
        rd_fetch_en <= 1'b0;
    end else if(rd_start_accept) begin
        rd_count <= 16'd0;
        rd_fetch_en <= 1'b1;
    end else if(rd_load_en) begin
        if(rd_count + 16'd1 == rd_length)
            rd_fetch_en <= 1'b0;
        else
            rd_count <= rd_count + 1'b1;
    end

//同步RAM一拍输出直接作为保持寄存器，反压期间禁止下一次读
always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0) begin
        rd_byte_valid <= 1'b0;
        rd_byte_last <= 1'b0;
    end else if(rd_load_en) begin
        rd_byte_valid <= 1'b1;
        rd_byte_last <= (rd_count + 16'd1 == rd_length);
    end else if(rd_byte_accept) begin
        rd_byte_valid <= 1'b0;
        rd_byte_last <= 1'b0;
    end

always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0) begin
        rd_bin <= {PTR_WIDTH{1'b0}};
        rd_gray <= {PTR_WIDTH{1'b0}};
    end else if(rd_release_en) begin
        rd_bin <= rd_bin_next;
        rd_gray <= (rd_bin_next >> 1) ^ rd_bin_next;
    end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
xpm_memory_sdpram
#(
    .ADDR_WIDTH_A           (RAM_ADDR_WIDTH                                  ),
    .ADDR_WIDTH_B           (RAM_ADDR_WIDTH                                  ),
    .BYTE_WRITE_WIDTH_A     (8                                               ),
    .CLOCKING_MODE          ("independent_clock"                             ),
    .MEMORY_PRIMITIVE       ("block"                                         ),
    .MEMORY_SIZE            (8 * (2 ** RAM_ADDR_WIDTH)                       ),
    .READ_DATA_WIDTH_B      (8                                               ),
    .READ_LATENCY_B         (1                                               ),
    .WRITE_DATA_WIDTH_A     (8                                               ),
    .WRITE_MODE_B           ("no_change"                                     ),
    .USE_MEM_INIT           (0                                               )
)
packet_ram_inst
(
    .clka                   (wr_clk                                          ),
    .ena                    (wr_store_en                                     ),
    .wea                    (wr_store_en                                     ),
    .addra                  ({wr_bin[SLOT_BITS-1:0], wr_count[ADDR_WIDTH-1:0]}),
    .dina                   (wr_byte_data                                    ),
    .clkb                   (rd_clk                                          ),
    .enb                    (rd_load_en                                      ),
    .addrb                  ({rd_bin[SLOT_BITS-1:0], rd_count[ADDR_WIDTH-1:0]}),
    .doutb                  (rd_byte_data                                    ),
    .rstb                   (1'b0                                            ),
    .regceb                 (1'b1                                            ),
    .sleep                  (1'b0                                            ),
    .injectsbiterra         (1'b0                                            ),
    .injectdbiterra         (1'b0                                            ),
    .sbiterrb               (                                                ),
    .dbiterrb               (                                                )
);

xpm_memory_sdpram
#(
    .ADDR_WIDTH_A           (SLOT_BITS                                       ),
    .ADDR_WIDTH_B           (SLOT_BITS                                       ),
    .BYTE_WRITE_WIDTH_A     (144                                             ),
    .CLOCKING_MODE          ("independent_clock"                             ),
    .MEMORY_PRIMITIVE       ("block"                                         ),
    .MEMORY_SIZE            (144 * (2 ** SLOT_BITS)                          ),
    .WRITE_MODE_B           ("read_first"                                    ),
    .READ_DATA_WIDTH_B      (144                                             ),
    .READ_LATENCY_B         (1                                               ),
    .WRITE_DATA_WIDTH_A     (144                                             ),
    .USE_MEM_INIT           (0                                               )
)
descriptor_ram_inst
(
    .clka                   (wr_clk                                          ),
    .ena                    (wr_commit_en                                    ),
    .wea                    (wr_commit_en                                    ),
    .addra                  (wr_bin[SLOT_BITS-1:0]                           ),
    .dina                   (meta_write_data                                 ),
    .clkb                   (rd_clk                                          ),
    .enb                    (meta_read_en                                    ),
    .addrb                  (rd_bin[SLOT_BITS-1:0]                           ),
    .doutb                  (meta_read_data                                  ),
    .rstb                   (1'b0                                            ),
    .regceb                 (1'b1                                            ),
    .sleep                  (1'b0                                            ),
    .injectsbiterra         (1'b0                                            ),
    .injectdbiterra         (1'b0                                            ),
    .sbiterrb               (                                                ),
    .dbiterrb               (                                                )
);

endmodule
