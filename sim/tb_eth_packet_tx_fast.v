//--------------------------------------------------------------------------------------------------------
// 模块： tb_eth_packet_tx_fast
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 快速组包器独立软件码流比对、最大长度连续输出及长短反压自检
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_eth_packet_tx_fast();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                   start_ready;
wire           [9:0]   payload_addr;
wire           [7:0]   byte_data;
wire                   byte_valid;
wire                   done_flag;

//reg   define
reg                    sys_clk = 1'b0;
reg                    sys_rst_n = 1'b0;
reg                    start_valid = 1'b0;
reg            [15:0]  length = 16'd0;
reg            [15:0]  seq = 16'd0;
reg            [7:0]   payload_data = 8'd0;
reg                    byte_ready = 1'b0;
reg            [7:0]   expected [0:7*2048-1];
reg                    running = 1'b0;
reg                    held_valid = 1'b0;
reg            [7:0]   held_data = 8'd0;
integer lengths [0:6];
integer case_index = 0;
integer byte_count = 0;
integer cycle;
integer stall_left;
reg                    stall_started;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #10 sys_clk = ~sys_clk;

//独立同步读源，故意在每个时钟刷新数据以暴露地址/valid错位
always@(posedge sys_clk)
    payload_data <= (payload_addr * 7 + case_index * 13) & 255;

always@(posedge sys_clk) begin
    if(held_valid && (!byte_valid || byte_data !== held_data))
        $fatal(1, "Output changed under backpressure case=%d byte=%d",case_index,byte_count);
    held_valid = running && byte_valid && !byte_ready;
    held_data = byte_data;
    if(running && case_index == 4 && byte_count > 0 && byte_count < length+14 && !byte_valid)
        $fatal(1, "Maximum payload contains a bubble");
    if(running && byte_valid && byte_ready) begin
        if(byte_count >= length+14 || byte_data !== expected[case_index*2048+byte_count])
            $fatal(1, "Fast packet mismatch case=%d byte=%d got=%h expected=%h",case_index,byte_count,byte_data,expected[case_index*2048+byte_count]);
        byte_count = byte_count + 1;
    end
end

initial begin
    $readmemh("../window_vectors/fast.mem",expected);
    lengths[0] = 0;
    lengths[1] = 1;
    lengths[2] = 2;
    lengths[3] = 17;
    lengths[4] = 1024;
    lengths[5] = 1023;
    lengths[6] = 2;
    #200;
    sys_rst_n = 1'b1;
    for(case_index = 0; case_index < 7; case_index = case_index + 1) begin
        @(negedge sys_clk);
        wait(start_ready);
        length = lengths[case_index];
        seq = case_index;
        byte_count = 0;
        cycle = 0;
        stall_left = 0;
        stall_started = 1'b0;
        running = 1'b1;
        start_valid = 1'b1;
        @(negedge sys_clk);
        start_valid = 1'b0;
        while(!done_flag) begin
            if(case_index == 5 && byte_count >= 15 && !stall_started) begin
                stall_left = 100;
                stall_started = 1'b1;
            end
            byte_ready = (case_index == 4) || ((cycle % 5) < 3 && stall_left == 0);
            if(stall_left > 0) stall_left = stall_left - 1;
            cycle = cycle + 1;
            @(negedge sys_clk);
        end
        if(byte_count != length+14) $fatal(1, "Incorrect encoded length");
        running = 1'b0;
        byte_ready = 1'b0;
    end
    $display("PASS tb_eth_packet_tx_fast: zero/one/two/odd/1024 bytes, no-bubble maximum packet and 100-cycle backpressure");
    $finish;
end

initial begin
    #2_000_000;
    $fatal(1, "Fast encoder timeout");
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_packet_tx_fast dut
(
    .sys_clk                (sys_clk                                         ),
    .sys_rst_n              (sys_rst_n                                       ),
    .start_valid            (start_valid                                     ),
    .start_ready            (start_ready                                     ),
    .cmd                    (8'h83                                           ),
    .transfer_id            (16'h1234                                        ),
    .seq                    (seq                                             ),
    .length                 (length                                          ),
    .payload_addr           (payload_addr                                    ),
    .payload_data           (payload_data                                    ),
    .byte_data              (byte_data                                       ),
    .byte_valid             (byte_valid                                      ),
    .byte_ready             (byte_ready                                      ),
    .done_flag              (done_flag                                       )
);

endmodule
