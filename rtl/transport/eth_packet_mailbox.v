//--------------------------------------------------------------------------------------------------------
// 模块： eth_packet_mailbox
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 双时钟整包BRAM邮箱，校验提交、反压读取及双向确认保护数据
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  eth_packet_mailbox
#(
    parameter integer MAX_BYTES = 1038,
    parameter integer ADDR_WIDTH = 11
)
(
    input   wire                   wr_clk                 ,
    input   wire                   wr_rst_n               ,
    input   wire                   wr_start_valid         ,
    output  wire                   wr_start_ready         ,
    input   wire           [15:0]  wr_length              ,
    input   wire           [95:0]  wr_peer                , //MAC、IP、UDP端口
    input   wire                   wr_byte_valid          ,
    output  wire                   wr_byte_ready          ,
    input   wire           [7:0]   wr_byte_data           ,
    input   wire                   wr_finish_flag         ,
    input   wire                   wr_abort_en            ,
    output  reg                    wr_drop_flag           ,

    input   wire                   rd_clk                 ,
    input   wire                   rd_rst_n               ,
    output  wire                   rd_packet_valid        ,
    input   wire                   rd_packet_ready        ,
    output  reg            [15:0]  rd_length              ,
    output  reg            [95:0]  rd_peer                ,
    output  reg            [31:0]  rd_sum                 ,
    output  reg                    rd_byte_valid          ,
    input   wire                   rd_byte_ready          ,
    output  wire           [7:0]   rd_byte_data           ,
    output  reg                    rd_byte_last
);

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam [1:0] WR_IDLE = 2'd0;
localparam [1:0] WR_DATA = 2'd1;
localparam [1:0] WR_HOLD = 2'd2;
localparam [1:0] RD_IDLE = 2'd0;
localparam [1:0] RD_WAIT = 2'd1;
localparam [1:0] RD_DATA = 2'd2;

//wire  define
wire                   wr_start_accept;
wire                   wr_byte_accept;
wire                   wr_store_en;
wire                   wr_commit_en;
wire                   rd_start_accept;
wire                   rd_byte_accept;
wire                   rd_load_en;
wire                   rd_pending_en;

//reg   define
reg            [1:0]   wr_state;
reg            [1:0]   wr_next_state;
reg            [1:0]   rd_state;
reg            [1:0]   rd_next_state;
reg            [15:0]  wr_count;
reg            [15:0]  length_hold;
reg            [95:0]  peer_hold;
reg            [31:0]  sum_hold;
reg            [31:0]  checksum_sum;
reg            [7:0]   high_byte;
reg                    wr_error_en;
reg                    request_toggle;
reg                    acknowledge_toggle;
reg            [15:0]  rd_count;
reg                    rd_fetch_en;
(* ASYNC_REG = "TRUE" *) reg [2:0] request_sync;
(* ASYNC_REG = "TRUE" *) reg [2:0] acknowledge_sync;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
assign wr_start_ready = (wr_state == WR_IDLE);
assign wr_start_accept = wr_start_valid && wr_start_ready;
assign wr_byte_ready = (wr_state == WR_DATA);
assign wr_byte_accept = wr_byte_valid && wr_byte_ready;
assign wr_store_en = wr_byte_accept && (wr_count < length_hold)
                   && (wr_count < MAX_BYTES);
assign wr_commit_en = (wr_state == WR_DATA) && wr_finish_flag
                    && !wr_abort_en && !wr_error_en
                    && (wr_count == length_hold);
assign rd_pending_en = (request_sync[2] != acknowledge_toggle);
assign rd_packet_valid = (rd_state == RD_WAIT);
assign rd_start_accept = rd_packet_valid && rd_packet_ready;
assign rd_byte_accept = rd_byte_valid && rd_byte_ready;
assign rd_load_en = (rd_state == RD_DATA) && rd_fetch_en
                  && (!rd_byte_valid || rd_byte_ready);

//提交和确认只同步单比特；多位数据在整个未确认窗口内保持稳定
always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0)
        acknowledge_sync <= 3'd0;
    else
        acknowledge_sync <= {acknowledge_sync[1:0], acknowledge_toggle};

always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0)
        request_sync <= 3'd0;
    else
        request_sync <= {request_sync[1:0], request_toggle};

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0)
        wr_state <= WR_IDLE;
    else
        wr_state <= wr_next_state;

always@(*) begin
    wr_next_state = wr_state;
    case(wr_state)
        WR_IDLE: if(wr_start_accept && wr_length != 16'd0 && wr_length <= MAX_BYTES)
            wr_next_state = WR_DATA;
        WR_DATA: if(wr_finish_flag)
            wr_next_state = wr_commit_en ? WR_HOLD : WR_IDLE;
        WR_HOLD: if(acknowledge_sync[2] == request_toggle)
            wr_next_state = WR_IDLE;
        default: wr_next_state = WR_IDLE;
    endcase
end

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
    else if(wr_byte_accept && !wr_store_en)
        wr_error_en <= 1'b1;

//反码和按网络字节序累计，奇数字节在包尾补零
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

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0) begin
        request_toggle <= 1'b0;
        sum_hold <= 32'd0;
    end else if(wr_commit_en) begin
        request_toggle <= ~request_toggle;
        sum_hold <= checksum_sum + (length_hold[0] ? {16'd0, high_byte, 8'd0} : 32'd0);
    end

always@(posedge wr_clk or negedge wr_rst_n)
    if(wr_rst_n == 1'b0)
        wr_drop_flag <= 1'b0;
    else
        wr_drop_flag <= (wr_start_valid && !wr_start_ready)
                     || (wr_start_accept && (wr_length == 16'd0 || wr_length > MAX_BYTES))
                     || (wr_state == WR_DATA && wr_finish_flag && !wr_commit_en);

always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0)
        rd_state <= RD_IDLE;
    else
        rd_state <= rd_next_state;

always@(*) begin
    rd_next_state = rd_state;
    case(rd_state)
        RD_IDLE: if(rd_pending_en) rd_next_state = RD_WAIT;
        RD_WAIT: if(rd_start_accept) rd_next_state = RD_DATA;
        RD_DATA: if(rd_byte_accept && rd_byte_last) rd_next_state = RD_IDLE;
        default: rd_next_state = RD_IDLE;
    endcase
end

always@(posedge rd_clk or negedge rd_rst_n)
    if(rd_rst_n == 1'b0) begin
        rd_length <= 16'd0;
        rd_peer <= 96'd0;
        rd_sum <= 32'd0;
    end else if(rd_state == RD_IDLE && rd_pending_en) begin
        rd_length <= length_hold;
        rd_peer <= peer_hold;
        rd_sum <= sum_hold;
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

//RAM延迟一拍与valid/last对齐；反压时关闭读使能以保持数据
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
    if(rd_rst_n == 1'b0)
        acknowledge_toggle <= 1'b0;
    else if(rd_byte_accept && rd_byte_last)
        acknowledge_toggle <= request_sync[2];

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
xpm_memory_sdpram
#(
    .ADDR_WIDTH_A       (ADDR_WIDTH           ),
    .ADDR_WIDTH_B       (ADDR_WIDTH           ),
    .BYTE_WRITE_WIDTH_A (8                    ),
    .CLOCKING_MODE      ("independent_clock"  ),
    .MEMORY_PRIMITIVE   ("block"              ),
    .MEMORY_SIZE        (8 * (2 ** ADDR_WIDTH)),
    .READ_DATA_WIDTH_B  (8                    ),
    .READ_LATENCY_B     (1                    ),
    .WRITE_DATA_WIDTH_A (8                    ),
    .WRITE_MODE_B       ("no_change"          ),
    .USE_MEM_INIT       (0                    )
)
packet_ram_inst
(
    .clka               (wr_clk                      ),
    .ena                (wr_store_en                 ),
    .wea                (wr_store_en                 ),
    .addra              (wr_count[ADDR_WIDTH-1:0]    ),
    .dina               (wr_byte_data                ),
    .clkb               (rd_clk                      ),
    .enb                (rd_load_en                  ),
    .addrb              (rd_count[ADDR_WIDTH-1:0]    ),
    .doutb              (rd_byte_data                ),
    .rstb               (1'b0                        ),
    .regceb             (1'b1                        ),
    .sleep              (1'b0                        ),
    .injectsbiterra     (1'b0                        ),
    .injectdbiterra     (1'b0                        ),
    .sbiterrb           (                            ),
    .dbiterrb           (                            )
);

endmodule
