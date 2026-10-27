//--------------------------------------------------------------------------------------------------------
// 模块： tb_sobel_stream_protocol
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 流式Sobel独立标量参考、边界尺寸、重复冲突、槽回绕与反压
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_sobel_stream_protocol
#(
    parameter integer ALGO_HALF_PERIOD = 4
)
();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam integer SLOT_BYTES = 2048;
`include "../stream_vectors/count.vh"
//wire  define
wire rx_ready;
wire [7:0] tx_data;
wire tx_valid;
wire tx_start;
wire [15:0] tx_length;
wire [95:0] tx_peer;
wire tx_done;
//reg   define
reg sys_clk = 1'b0;
reg algo_clk = 1'b0;
reg rst_n = 1'b0;
reg rx_valid = 1'b0;
reg [7:0] rx_data = 8'd0;
reg [95:0] rx_peer = 96'd0;
reg tx_ready = 1'b1;
reg [7:0] request_data [0:REQUEST_COUNT*SLOT_BYTES-1];
reg [7:0] response_data [0:RESPONSE_COUNT*SLOT_BYTES-1];
integer request_length [0:REQUEST_COUNT-1];
integer response_length [0:RESPONSE_COUNT-1];
integer group_start [0:GROUP_COUNT-1];
integer group_end [0:GROUP_COUNT-1];
integer group_target [0:GROUP_COUNT-1];
integer response_index = 0;
integer byte_index = 0;
integer group_index;
integer request_index;
integer offset;
integer base;
integer monitor_base;
integer length;
integer expected_length;
integer stalled = 0;
reg [7:0] held_data;
reg held_valid = 1'b0;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
`include "../stream_vectors/cases.vh"
always #4 sys_clk = ~sys_clk;
always #ALGO_HALF_PERIOD algo_clk = ~algo_clk;

//独立接收端模型只在valid/ready时采样，反压时必须保持输出字节
always@(posedge sys_clk)
    if(rst_n) begin
        if(held_valid && (!tx_valid || tx_data !== held_data))
            $fatal(1, "Encoder output changed during backpressure");
        held_valid = tx_valid && !tx_ready;
        held_data = tx_data;
        monitor_base = response_index * SLOT_BYTES;
        if(tx_start) begin
            expected_length = {response_data[monitor_base+46],response_data[monitor_base+47]} - 8;
            if(tx_length != expected_length)
                $fatal(1, "Descriptor length mismatch");
            if(tx_peer !== {response_data[monitor_base+8],response_data[monitor_base+9],response_data[monitor_base+10],response_data[monitor_base+11],response_data[monitor_base+12],response_data[monitor_base+13],response_data[monitor_base+38],response_data[monitor_base+39],response_data[monitor_base+40],response_data[monitor_base+41],response_data[monitor_base+44],response_data[monitor_base+45]})
                $fatal(1, "Descriptor peer changed during pipeline");
        end
        if(tx_valid && tx_ready) begin
            if(tx_data !== response_data[monitor_base+50+byte_index])
                $fatal(1, "Pipeline data mismatch frame=%d byte=%d",response_index,byte_index);
            byte_index = byte_index + 1;
        end
        if(tx_done) begin
            if(byte_index != expected_length)
                $fatal(1, "Truncated pipeline response");
            response_index = response_index + 1;
            byte_index = 0;
        end
    end

initial begin
    wait(rst_n);
    wait(dut.req_id == 16'd200 && dut.req_cmd == 8'h41 && tx_valid);
    @(negedge sys_clk);
    tx_ready = 1'b0;
    #600_000;
    if(dut.window_transport.img_response_cache_inst.fifo_count != 4'd8)
        $fatal(1, "Descriptor FIFO did not fill");
    if(dut.pipeline_receive.rx_queue_inst.occupied != 2'b11)
        $fatal(1, "Both receive banks were not retained");
    @(negedge sys_clk);
    tx_ready = 1'b1;
    stalled = 1;
end

initial begin
    $readmemh("../stream_vectors/requests.mem",request_data);
    $readmemh("../stream_vectors/responses.mem",response_data);
    #200;
    rst_n = 1'b1;
    repeat(10) @(negedge sys_clk);
    for(group_index = 0; group_index < GROUP_COUNT; group_index = group_index + 1) begin
        for(request_index = group_start[group_index]; request_index < group_end[group_index]; request_index = request_index + 1) begin
            base = request_index * SLOT_BYTES;
            rx_peer = {request_data[base+14],request_data[base+15],request_data[base+16],request_data[base+17],request_data[base+18],request_data[base+19],request_data[base+34],request_data[base+35],request_data[base+36],request_data[base+37],request_data[base+42],request_data[base+43]};
            length = {request_data[base+46],request_data[base+47]} - 8;
            for(offset = 0; offset < length; offset = offset + 1) begin
                @(negedge sys_clk);
                rx_valid = 1'b1;
                rx_data = request_data[request_index*SLOT_BYTES+50+offset];
                @(posedge sys_clk);
                while(!rx_ready) @(posedge sys_clk);
            end
            @(negedge sys_clk);
            rx_valid = 1'b0;
            repeat(5) @(negedge sys_clk);
        end
        wait(response_index == group_target[group_index]);
        repeat(10) @(negedge sys_clk);
    end
    if(!stalled)
        $fatal(1, "Stall phase was not reached");
    $display("PASS tb_sobel_stream_protocol: %d responses, full FIFO, two occupied banks, stable bytes and endpoints during 600us TX backpressure",RESPONSE_COUNT);
    $finish;
end

initial begin
    #20_000_000;
    $fatal(1, "Pipeline timeout group=%d response=%d",group_index,response_index);
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_stream_top
#(
    .FAST_TRANSPORT (1),
    .ASYNC_ALGORITHMS (1)
)
dut
(
    .sys_clk        (sys_clk),
    .algo_clk       (algo_clk),
    .sys_rst_n      (rst_n),
    .rx_data        (rx_data),
    .rx_valid       (rx_valid),
    .rx_ready       (rx_ready),
    .rx_peer        (rx_peer),
    .tx_data        (tx_data),
    .tx_valid       (tx_valid),
    .tx_ready       (tx_ready),
    .tx_start_flag  (tx_start),
    .tx_length      (tx_length),
    .tx_start_ready (1'b1),
    .tx_done_flag   (tx_done),
    .tx_peer        (tx_peer)
);

endmodule
