//--------------------------------------------------------------------------------------------------------
// 模块： tb_band_uart_ctrl
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： Band尺寸、非整行分包、重发、读取边界及会话失效自检
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_band_uart_ctrl();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire               success_flag;
wire               success_start_flag;
wire               receive_en;
wire               packet_ready;
wire    [9:0]      rx_rd_addr;
wire               result_wr_en;
wire    [9:0]      result_wr_addr;
wire    [7:0]      result_wr_data;
wire               resp_valid;
wire    [7:0]      resp_cmd;
wire    [15:0]     resp_id;
wire    [15:0]     resp_seq;
wire    [15:0]     resp_length;
wire    [7:0]      resp_data;
wire               band_frame_wr_en;
wire    [17:0]     band_frame_wr_addr;
wire    [7:0]      band_frame_wr_data;
wire               band_start_valid;
wire    [11:0]     band_score_rd_addr;
wire    [9:0]      band_image_width;
wire    [9:0]      band_image_height;
//reg   define
reg                sys_clk;
reg                sys_rst_n;
reg                cache_clear;
reg                session_clear;
reg                packet_valid;
reg     [7:0]      req_cmd;
reg     [15:0]     req_id;
reg     [15:0]     req_seq;
reg     [15:0]     req_length;
reg     [15:0]     req_crc;
reg     [7:0]      rx_rd_data;
reg                resp_ready;
reg     [9:0]      resp_addr;
reg     [7:0]      result_rd_data;
reg                resp_done;
reg                band_start_ready;
reg                band_done_flag;
reg     [31:0]     band_score_rd_data;
reg     [15:0]     band_result_count;
reg     [7:0]      band_result_rows;
reg     [7:0]      band_result_status;
reg     [15:0]     band_pitch_q8;
reg     [15:0]     band_detected_dots;
reg [7:0] request_memory [0:1023];
reg [7:0] response_memory [0:1023];
reg [7:0] result_memory [0:1023];
integer frame_writes;
integer core_starts;
integer core_delay;
integer cases;
integer i;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #10 sys_clk = ~sys_clk;
always@(posedge sys_clk) begin
    rx_rd_data <= request_memory[rx_rd_addr];
    result_rd_data <= result_memory[resp_addr];
    band_score_rd_data <= 32'h80102000 + {20'd0, band_score_rd_addr};
    if(result_wr_en) result_memory[result_wr_addr] <= result_wr_data;
    if(sys_rst_n && band_frame_wr_en) begin
        if(band_frame_wr_addr !== ((frame_writes/33)*512+frame_writes%33) ||
           band_frame_wr_data !== ((frame_writes*17+3)&255))
            $fatal(1, "FAIL Band frame mapping at %0d", frame_writes);
        frame_writes = frame_writes+1;
    end
    band_done_flag <= (core_delay == 1);
    if(!sys_rst_n) begin
        core_delay <= 0;
        core_starts <= 0;
    end else if(band_start_valid && band_start_ready) begin
        core_delay <= 16;
        core_starts <= core_starts+1;
    end else if(core_delay > 0)
        core_delay <= core_delay-1;
end

task transact;
    input [7:0] cmd;
    input [15:0] id;
    input [15:0] seq;
    input [15:0] length;
    input [15:0] crc;
    input [7:0] expected_cmd;
    input [15:0] expected_length;
    input [7:0] expected_error;
    integer watchdog;
    integer byte_number;
    begin
        @(negedge sys_clk);
        while(!packet_ready) @(negedge sys_clk);
        req_cmd = cmd;
        req_id = id;
        req_seq = seq;
        req_length = length;
        req_crc = crc;
        packet_valid = 1'b1;
        @(negedge sys_clk);
        packet_valid = 1'b0;
        watchdog = 0;
        while(!resp_valid && watchdog < 10000) begin
            @(negedge sys_clk);
            watchdog = watchdog + 1;
        end
        if(!resp_valid || resp_cmd !== expected_cmd || resp_length !== expected_length || resp_id !== id || resp_seq !== seq) begin
            $display("FAIL Band case=%d cmd=%h seq=%d response=%h len=%d expected=%h len=%d",cases,cmd,seq,resp_cmd,resp_length,expected_cmd,expected_length);
            $fatal(1, "Band transaction failed");
        end
        resp_ready = 1'b1;
        @(negedge sys_clk);
        resp_ready = 1'b0;
        for(byte_number=0; byte_number<expected_length; byte_number=byte_number+1) begin
            resp_addr = byte_number;
            repeat(2) @(negedge sys_clk);
            response_memory[byte_number] = resp_data;
        end
        if(expected_cmd == 8'hff && response_memory[0] !== expected_error) begin
            $display("FAIL Band error case=%d actual=%d expected=%d",cases,response_memory[0],expected_error);
            $fatal(1, "Band transaction failed");
        end
        resp_done = 1'b1;
        @(negedge sys_clk);
        resp_done = 1'b0;
        cases = cases + 1;
    end
endtask

initial begin
    sys_clk = 'd0;
    sys_rst_n = 'd0;
    cache_clear = 'd0;
    session_clear = 'd0;
    packet_valid = 'd0;
    req_cmd = 'd0;
    req_id = 'd0;
    req_seq = 'd0;
    req_length = 'd0;
    req_crc = 'd0;
    rx_rd_data = 'd0;
    resp_ready = 'd0;
    resp_addr = 'd0;
    result_rd_data = 'd0;
    resp_done = 'd0;
    band_start_ready = 1'b1;
    band_done_flag = 'd0;
    band_score_rd_data = 'd0;
    band_result_count = 16'd4096;
    band_result_rows = 8'd64;
    band_result_status = 8'd0;
    band_pitch_q8 = 16'd4096;
    band_detected_dots = 16'd1000;
    frame_writes = 0;
    cases = 0;
    repeat(5) @(negedge sys_clk);
    sys_rst_n = 1'b1;
    transact(8'h2f,0,0,0,1,8'haf,16,0);
    if({response_memory[3],response_memory[2],response_memory[1],response_memory[0]} !== 32'h31444e42)
        $fatal(1, "FAIL Band INFO");
    request_memory[0] = 8'd15;
    request_memory[1] = 8'd0;
    request_memory[2] = 8'd32;
    request_memory[3] = 8'd0;
    transact(8'h20,100,0,4,2,8'hff,1,2);
    request_memory[0] = 8'd33;
    transact(8'h20,100,0,4,3,8'ha0,0,0);
    transact(8'h20,100,0,4,3,8'ha0,0,0);
    if(band_image_width !== 10'd33 || band_image_height !== 10'd32)
        $fatal(1, "FAIL Band dimensions");
    transact(8'h22,100,1,0,4,8'hff,1,5);
    transact(8'h21,101,1,1,5,8'hff,1,3);
    transact(8'h21,100,2,1,6,8'hff,1,4);
    for(i=0; i<1024; i=i+1) request_memory[i] = (i*17+3)&255;
    transact(8'h21,100,1,1024,7,8'ha1,0,0);
    transact(8'h21,100,1,1024,7,8'ha1,0,0);
    transact(8'h21,100,1,1024,8,8'hff,1,6);
    transact(8'h21,100,1,1024,7,8'ha1,0,0);
    for(i=0; i<32; i=i+1) request_memory[i] = ((1024+i)*17+3)&255;
    transact(8'h21,100,2,32,9,8'ha1,0,0);
    transact(8'h21,100,3,1,10,8'hff,1,5);
    transact(8'h22,100,3,0,11,8'ha2,16,0);
    transact(8'h22,100,3,0,11,8'ha2,16,0);
    if(frame_writes != 1056 || core_starts != 1 || {response_memory[5],response_memory[4]} !== 16'd4096)
        $fatal(1, "FAIL duplicate START/DATA/RUN");
    request_memory[0] = 8'hff;
    request_memory[1] = 8'h0f;
    request_memory[2] = 8'd2;
    request_memory[3] = 8'd0;
    transact(8'h23,100,4,4,12,8'hff,1,2);
    request_memory[2] = 8'd1;
    transact(8'h23,100,4,4,13,8'ha3,4,0);
    if({response_memory[3],response_memory[2],response_memory[1],response_memory[0]} !== 32'h80102fff)
        $fatal(1, "FAIL last result read");
    transact(8'h23,100,4,4,13,8'ha3,4,0);
    request_memory[0] = 8'd0;
    request_memory[1] = 8'd0;
    request_memory[2] = 8'd0;
    request_memory[3] = 8'd1;
    transact(8'h23,100,5,4,14,8'ha3,1024,0);
    for(i=0; i<256; i=i+1)
        if({response_memory[i*4+3],response_memory[i*4+2],response_memory[i*4+1],response_memory[i*4]} !== 32'h80102000+i)
            $fatal(1, "FAIL 1024-byte results");
    @(negedge sys_clk);
    cache_clear = 1'b1;
    session_clear = 1'b1;
    @(negedge sys_clk);
    cache_clear = 1'b0;
    session_clear = 1'b0;
    transact(8'h23,100,6,4,15,8'hff,1,3);
    $display("PASS tb_band_uart_ctrl: %0d transactions", cases);
    $finish;
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
band_uart_ctrl
band_uart_ctrl_inst
(
    .sys_clk                  (sys_clk                 ),
    .sys_rst_n                (sys_rst_n               ),
    .cache_clear              (cache_clear             ),
    .session_clear            (session_clear           ),
    .success_flag             (success_flag            ),
    .success_start_flag       (success_start_flag      ),
    .receive_en               (receive_en              ),
    .packet_valid             (packet_valid            ),
    .packet_ready             (packet_ready            ),
    .req_cmd                  (req_cmd                 ),
    .req_id                   (req_id                  ),
    .req_seq                  (req_seq                 ),
    .req_length               (req_length              ),
    .req_crc                  (req_crc                 ),
    .rx_rd_addr               (rx_rd_addr              ),
    .rx_rd_data               (rx_rd_data              ),
    .result_wr_en             (result_wr_en            ),
    .result_wr_addr           (result_wr_addr          ),
    .result_wr_data           (result_wr_data          ),
    .resp_valid               (resp_valid              ),
    .resp_ready               (resp_ready              ),
    .resp_cmd                 (resp_cmd                ),
    .resp_id                  (resp_id                 ),
    .resp_seq                 (resp_seq                ),
    .resp_length              (resp_length             ),
    .resp_addr                (resp_addr               ),
    .result_rd_data           (result_rd_data          ),
    .resp_data                (resp_data               ),
    .resp_done                (resp_done               ),
    .band_frame_wr_en         (band_frame_wr_en        ),
    .band_frame_wr_addr       (band_frame_wr_addr      ),
    .band_frame_wr_data       (band_frame_wr_data      ),
    .band_start_valid         (band_start_valid        ),
    .band_start_ready         (band_start_ready        ),
    .band_done_flag           (band_done_flag          ),
    .band_score_rd_addr       (band_score_rd_addr      ),
    .band_score_rd_data       (band_score_rd_data      ),
    .band_result_count        (band_result_count       ),
    .band_result_rows         (band_result_rows        ),
    .band_result_status       (band_result_status      ),
    .band_pitch_q8            (band_pitch_q8           ),
    .band_detected_dots       (band_detected_dots      ),
    .band_image_width         (band_image_width        ),
    .band_image_height        (band_image_height       )
);

endmodule
