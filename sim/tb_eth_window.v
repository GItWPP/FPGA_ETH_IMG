//--------------------------------------------------------------------------------------------------------
// 模块： tb_eth_window
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： GMII八包突发、旧序号重传、乱序恢复、端点隔离及滤波回放自检
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_eth_window
#(
    parameter integer ALGO_HALF_PERIOD = 4
)
();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam integer SLOT_BYTES = 2048;
`include "../window_vectors/count.vh"

//wire  define
wire                   gmii_tx_en;
wire                   gmii_tx_er;
wire           [7:0]   gmii_txd;

//reg   define
reg                    rx_clk = 1'b0;
reg                    tx_clk = 1'b0;
reg                    app_clk = 1'b0;
reg                    algo_clk = 1'b0;
reg                    rst_n = 1'b0;
reg                    rx_dv = 1'b0;
reg            [7:0]   rx_data = 8'd0;
reg            [7:0]   request_data [0:REQUEST_COUNT*SLOT_BYTES-1];
reg            [7:0]   response_data [0:RESPONSE_COUNT*SLOT_BYTES-1];
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
integer parse_overlap = 0;
integer compute_overlap = 0;
reg                    capture_active = 1'b0;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
`include "../window_vectors/cases.vh"
always #4 rx_clk = ~rx_clk;
always #4 app_clk = ~app_clk;
always #ALGO_HALF_PERIOD algo_clk = ~algo_clk;
initial begin
    #2;
    forever #4 tx_clk = ~tx_clk;
end

//接收监视器持续工作，发送下一请求时同样校验并发回包
always@(negedge tx_clk)
    if(gmii_tx_en) begin
        if(response_index >= RESPONSE_COUNT || byte_index >= response_length[response_index])
            $fatal(1, "Unexpected window output frame=%d byte=%d",response_index,byte_index);
        if(gmii_tx_er || gmii_txd !== response_data[response_index*SLOT_BYTES+byte_index])
            $fatal(1, "Window wire mismatch frame=%d byte=%d got=%h expected=%h",response_index,byte_index,gmii_txd,response_data[response_index*SLOT_BYTES+byte_index]);
        byte_index = byte_index + 1;
        capture_active = 1'b1;
    end else if(capture_active) begin
        if(byte_index != response_length[response_index])
            $fatal(1, "Window frame was truncated");
        response_index = response_index + 1;
        byte_index = 0;
        capture_active = 1'b0;
    end

//至少观察到解析与计算、计算与发送两个方向的真实重叠
always@(posedge app_clk)
    if(rst_n) begin
        if(dut.img_stream_top_inst.pipeline_receive.rx_queue_inst.commit_flag && !dut.img_stream_top_inst.cmd_receive_en)
            parse_overlap = parse_overlap + 1;
        if(dut.img_stream_top_inst.result_wr_en && dut.app_tx_valid)
            compute_overlap = compute_overlap + 1;
    end

initial begin
    $readmemh("../window_vectors/requests.mem",request_data);
    $readmemh("../window_vectors/responses.mem",response_data);
    #200;
    rst_n = 1'b1;
    repeat(30) @(negedge rx_clk);
    for(group_index = 0; group_index < GROUP_COUNT; group_index = group_index + 1) begin
        for(request_index = group_start[group_index]; request_index < group_end[group_index]; request_index = request_index + 1) begin
            for(offset = 0; offset < request_length[request_index]; offset = offset + 1) begin
                @(negedge rx_clk);
                rx_dv = 1'b1;
                rx_data = request_data[request_index*SLOT_BYTES+offset];
            end
            @(negedge rx_clk);
            rx_dv = 1'b0;
            repeat(12) @(negedge rx_clk);
        end
        wait(response_index == group_target[group_index]);
        repeat(30) @(negedge tx_clk);
    end
    if(parse_overlap == 0 || compute_overlap == 0)
        $fatal(1, "Missing pipeline overlap parse=%d compute=%d",parse_overlap,compute_overlap);
    $display("Pipeline overlap parse=%d compute=%d",parse_overlap,compute_overlap);
    $display("PASS tb_eth_window: %d GMII replies, 64-packet bursts and wrap, oldest-slot retry, conflict, reorder, peer isolation, session clear, gray and filter",RESPONSE_COUNT);
    $finish;
end

initial begin
    #20_000_000;
    $fatal(1, "Window timeout group=%d replies=%d",group_index,response_index);
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_image_core
#(
    .ASYNC_ALGORITHMS (1)
)
dut
(
    .sys_rst_n              (rst_n                                           ),
    .gmii_rx_clk            (rx_clk                                          ),
    .gmii_rx_dv             (rx_dv                                           ),
    .gmii_rx_er             (1'b0                                            ),
    .gmii_rxd               (rx_data                                         ),
    .gmii_tx_clk            (tx_clk                                          ),
    .gmii_tx_en             (gmii_tx_en                                      ),
    .gmii_tx_er             (gmii_tx_er                                      ),
    .gmii_txd               (gmii_txd                                        ),
    .algo_clk          (algo_clk),
    .app_clk                (app_clk                                         ),
    .rx_packet_done         (                                                ),
    .rx_packet_error        (                                                ),
    .rx_drop_flag           (                                                ),
    .tx_packet_done         (                                                ),
    .tx_busy                (                                                )
);

endmodule
