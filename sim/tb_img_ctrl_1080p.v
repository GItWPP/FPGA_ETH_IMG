//--------------------------------------------------------------------------------------------------------
// 模块： tb_img_ctrl_1080p
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 直接在包接口验证1080p整帧累计、4050包序号、写数据和提前结束拒绝
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_img_ctrl_1080p();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam integer FRAME_BYTES = 1920 * 1080 * 2;
localparam integer DATA_BLOCKS = FRAME_BYTES / 1024;
localparam [15:0] TRANSFER_ID = 16'h1080;

//wire  define
wire                    packet_ready;
wire           [9:0]    rx_rd_addr;
wire                    result_wr_en;
wire           [9:0]    result_wr_addr;
wire           [7:0]    result_wr_data;
wire           [2:0]    pixel_mode;
wire           [15:0]   pixel_in_data;
wire           [143:0]  pixel_window_data;
wire                    pixel_in_valid;
wire                    pixel_in_ready;
wire           [15:0]   pixel_out_data;
wire                    pixel_out_valid;
wire                    pixel_out_ready;
wire                    resp_valid;
wire           [7:0]    resp_cmd;
wire           [15:0]   resp_id;
wire           [15:0]   resp_seq;
wire           [15:0]   resp_length;
wire           [7:0]    resp_data;

//reg   define
reg                     sys_clk;
reg                     sys_rst_n;
reg                     packet_valid;
reg            [7:0]    req_cmd;
reg            [15:0]   req_seq;
reg            [15:0]   req_length;
reg            [15:0]   req_crc;
reg            [7:0]    rx_rd_data;
reg                     resp_done;
integer         write_count;
integer         block_index;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
initial begin
    sys_clk = 1'b0;
    sys_rst_n = 1'b0;
    packet_valid = 1'b0;
    req_cmd = 8'd0;
    req_seq = 16'd0;
    req_length = 16'd0;
    req_crc = 16'd0;
    write_count = 0;
end

always #10 sys_clk = ~sys_clk;

//模拟同步接收RAM，START为1920x1080、RGB565、原图模式
always@(posedge sys_clk)
    if(req_cmd == 8'h02)
        case(rx_rd_addr)
            10'd0: rx_rd_data <= 8'h80;
            10'd1: rx_rd_data <= 8'h07;
            10'd2: rx_rd_data <= 8'h38;
            10'd3: rx_rd_data <= 8'h04;
            10'd4: rx_rd_data <= 8'd1;
            10'd5: rx_rd_data <= 8'd0;
            default: rx_rd_data <= 8'd0;
        endcase
    else
        rx_rd_data <= rx_rd_addr[7:0] ^ 8'ha6;

//模拟应答下游的完成握手，省略串口逐位等待以便覆盖完整4MB帧
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        resp_done <= 1'b0;
    else
        resp_done <= resp_valid;

//所有像素均检查实际写使能、地址和字节值；重复包不应再次写入
always@(posedge sys_clk)
    if(sys_rst_n && result_wr_en) begin
        if(result_wr_addr !== (write_count % 1024)
           || result_wr_data !== (result_wr_addr[7:0] ^ 8'ha6)) begin
            $display("FAIL 1080p pixel write count=%0d addr=%0d data=%02x", write_count, result_wr_addr, result_wr_data);
            $finish;
        end
        write_count = write_count + 1;
    end

task request;
    input [7:0] command;
    input [15:0] sequence;
    input [15:0] payload_len;
    input [7:0] wanted_cmd;
    input [15:0] wanted_len;
    input [7:0] wanted_error;
    integer watchdog;
    begin
        @(negedge sys_clk);
        while(!packet_ready)
            @(negedge sys_clk);
        req_cmd = command;
        req_seq = sequence;
        req_length = payload_len;
        req_crc = sequence ^ {8'h5a, command};
        packet_valid = 1'b1;
        @(negedge sys_clk);
        packet_valid = 1'b0;
        watchdog = 0;
        while(!resp_valid && watchdog < 20000) begin
            @(negedge sys_clk);
            watchdog = watchdog + 1;
        end
        if(!resp_valid || resp_cmd !== wanted_cmd || resp_length !== wanted_len
           || resp_id !== TRANSFER_ID || resp_seq !== sequence) begin
            $display("FAIL 1080p response seq=%0d cmd=%02x len=%0d", sequence, resp_cmd, resp_length);
            $finish;
        end
        if(wanted_cmd == 8'hff && resp_data !== wanted_error) begin
            $display("FAIL 1080p error code actual=%0d wanted=%0d", resp_data, wanted_error);
            $finish;
        end
        while(!packet_ready)
            @(negedge sys_clk);
    end
endtask

initial begin
    #200;
    @(negedge sys_clk);
    sys_rst_n = 1'b1;
    request(8'h02, 16'd0, 16'd6, 8'h82, 16'd0, 8'd0);
    for(block_index = 1; block_index <= DATA_BLOCKS; block_index = block_index + 1) begin
        request(8'h03, block_index[15:0], 16'd1024, 8'h83, 16'd1024, 8'd0);
        if(block_index == 64) begin
            request(8'h04, 16'd65, 16'd0, 8'hff, 16'd1, 8'd5);
            request(8'h03, 16'd64, 16'd1024, 8'h83, 16'd1024, 8'd0);
        end
    end
    request(8'h04, 16'd4051, 16'd0, 8'h84, 16'd0, 8'd0);
    request(8'h04, 16'd4051, 16'd0, 8'h84, 16'd0, 8'd0);
    request(8'h03, 16'd4052, 16'd2, 8'hff, 16'd1, 8'd3);
    if(write_count != FRAME_BYTES) begin
        $display("FAIL 1080p byte count %0d/%0d", write_count, FRAME_BYTES);
        $finish;
    end
    $display("PASS tb_img_ctrl_1080p: 4147200 bytes, 4050 DATA blocks, length/sequence/retry/END checked");
    $finish;
end

initial begin
    #1_000_000_000;
    $display("FAIL 1080p watchdog");
    $finish;
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_ctrl img_ctrl_inst
(
    .sys_clk            (sys_clk            ),
    .sys_rst_n          (sys_rst_n          ),
    .cache_clear        (1'b0),
    .session_clear      (1'b0),
    .success_flag       (),
    .success_start_flag (),
    .receive_en         (),
    .packet_valid       (packet_valid       ),
    .packet_ready       (packet_ready       ),
    .req_cmd            (req_cmd            ),
    .req_id             (TRANSFER_ID        ),
    .req_seq            (req_seq            ),
    .req_length         (req_length         ),
    .req_crc            (req_crc            ),
    .rx_rd_addr         (rx_rd_addr         ),
    .rx_rd_data         (rx_rd_data         ),
    .result_wr_en       (result_wr_en       ),
    .result_wr_addr     (result_wr_addr     ),
    .result_wr_data     (result_wr_data     ),
    .pixel_mode         (pixel_mode         ),
    .pixel_in_data      (pixel_in_data      ),
    .pixel_window_data  (pixel_window_data  ),
    .pixel_in_valid     (pixel_in_valid     ),
    .pixel_in_ready     (pixel_in_ready     ),
    .pixel_out_data     (pixel_out_data     ),
    .pixel_out_valid    (pixel_out_valid    ),
    .pixel_out_ready    (pixel_out_ready    ),
    .resp_valid         (resp_valid         ),
    .resp_ready         (1'b1               ),
    .resp_cmd           (resp_cmd           ),
    .resp_id            (resp_id            ),
    .resp_seq           (resp_seq           ),
    .resp_length        (resp_length        ),
    .resp_addr          (10'd0              ),
    .result_rd_data     (8'd0               ),
    .resp_data          (resp_data          ),
    .resp_done          (resp_done          )
);

img_pixel_proc img_pixel_proc_inst
(
    .sys_clk            (sys_clk            ),
    .sys_rst_n          (sys_rst_n          ),
    .mode               (pixel_mode         ),
    .in_data            (pixel_in_data      ),
    .window_data        (pixel_window_data  ),
    .in_valid           (pixel_in_valid     ),
    .in_ready           (pixel_in_ready     ),
    .out_data           (pixel_out_data     ),
    .out_valid          (pixel_out_valid    ),
    .out_ready          (pixel_out_ready    )
);

endmodule
