//--------------------------------------------------------------------------------------------------------
// 模块： tb_eth_image_core
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 注入真实GMII帧，逐字节验证网络校验、重试及全部图像算法
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_eth_image_core
#(
    parameter integer ALGO_HALF_PERIOD = 4
)
();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam integer SLOT_BYTES = 2048;
`include "../eth_vectors/count.vh"

//wire  define
wire            gmii_tx_en;
wire            gmii_tx_er;
wire    [7:0]   gmii_txd;

//reg   define
reg             rx_clk = 1'b0;
reg             tx_clk = 1'b0;
reg             app_clk = 1'b0;
reg             algo_clk = 1'b0;
reg             rst_n = 1'b0;
reg             gmii_rx_dv = 1'b0;
reg             gmii_rx_er = 1'b0;
reg     [7:0]   gmii_rxd = 8'd0;
reg     [7:0]   request_data [0:CASE_COUNT*SLOT_BYTES-1];
reg     [7:0]   response_data [0:CASE_COUNT*SLOT_BYTES-1];
reg     [7:0]   captured_data [0:SLOT_BYTES-1];
reg             inject_error [0:CASE_COUNT-1];
integer         request_length [0:CASE_COUNT-1];
integer         response_length [0:CASE_COUNT-1];
integer         captured_length = 0;
integer         completed_length = 0;
integer         frame_count = 0;
integer         capture_active = 0;
integer         case_index;
integer         byte_index;
integer         before_count;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
`include "../eth_vectors/cases.vh"
always #4 rx_clk = ~rx_clk;
always #4 app_clk = ~app_clk;
always #ALGO_HALF_PERIOD algo_clk = ~algo_clk;
initial begin
    #2;
    forever #4 tx_clk = ~tx_clk;
end

//发送域在下降沿观察，避开GMII输出寄存器的非阻塞更新
always@(negedge tx_clk)
    if(gmii_tx_en) begin
        if(capture_active == 0) begin
            captured_length = 0;
            capture_active = 1;
        end
        if(gmii_tx_er || captured_length >= SLOT_BYTES)
            $fatal(1, "GMII transmission error case=%d", case_index);
        captured_data[captured_length] = gmii_txd;
        captured_length = captured_length + 1;
    end else if(capture_active != 0) begin
        completed_length = captured_length;
        frame_count = frame_count + 1;
        capture_active = 0;
    end

task send_frame;
    input integer selected_case;
    integer index;
    begin
        for(index = 0; index < request_length[selected_case]; index = index + 1) begin
            @(negedge rx_clk);
            gmii_rx_dv = 1'b1;
            gmii_rx_er = inject_error[selected_case] && (index == 40);
            gmii_rxd = request_data[selected_case*SLOT_BYTES+index];
        end
        @(negedge rx_clk);
        gmii_rx_dv = 1'b0;
        gmii_rx_er = 1'b0;
        gmii_rxd = 8'd0;
    end
endtask

initial begin
    $readmemh("../eth_vectors/requests.mem", request_data);
    $readmemh("../eth_vectors/responses.mem", response_data);
    #200;
    rst_n = 1'b1;
    repeat(30) @(negedge rx_clk);
    for(case_index = 0; case_index < CASE_COUNT; case_index = case_index + 1) begin
        before_count = frame_count;
        send_frame(case_index);
        if(response_length[case_index] == 0) begin
            repeat(2500) @(negedge tx_clk);
            if(frame_count != before_count)
                $fatal(1, "Rejected frame produced a reply case=%d", case_index);
        end else begin
            fork : response_wait
                begin
                    wait(frame_count != before_count);
                    disable response_wait;
                end
                begin
                    if(case_index < 100)
                        #2_000_000;
                    else
                        #200_000_000;
                    $display("RX start=%b done=%b error=%b drop=%b count=%d len=%d bad=%b",dut.udp_rx_start,dut.rx_packet_done,dut.rx_packet_error,dut.rx_drop_flag,dut.eth_image_rx_inst.byte_count,dut.eth_image_rx_inst.length_reg,dut.eth_image_rx_inst.packet_bad);
                    $display("Mailbox RX wr=%d rd=%d req=%b ack=%b, TX wr=%d rd=%d count=%d len=%d",dut.eth_image_rx_inst.rx_mailbox_inst.wr_active,dut.eth_image_rx_inst.rx_mailbox_inst.rd_state,dut.eth_image_rx_inst.rx_mailbox_inst.wr_gray,dut.eth_image_rx_inst.rx_mailbox_inst.rd_gray,dut.tx_mailbox_inst.wr_active,dut.tx_mailbox_inst.rd_state,dut.tx_mailbox_inst.wr_count,dut.tx_mailbox_inst.length_hold);
                    $display("App parser=%d valid=%b ctrl=%d TXstate=%d respvalid=%b ready=%b",dut.img_stream_top_inst.pipeline_receive.rx_queue_inst.parser_inst.state,dut.img_stream_top_inst.packet_valid,dut.img_stream_top_inst.async_algorithm.command_bridge_inst.legacy_command_inst.algorithm_inst.img_ctrl_inst.image_ctrl_inst.state,dut.img_stream_top_inst.fast_tx.img_packet_tx_inst.state,dut.img_stream_top_inst.resp_valid,dut.img_stream_top_inst.resp_ready);
                    $fatal(1, "Response timeout case=%d", case_index);
                end
            join
            if(completed_length != response_length[case_index])
                $fatal(1, "Length mismatch case=%d got=%d expected=%d",case_index,completed_length,response_length[case_index]);
            for(byte_index = 0; byte_index < completed_length; byte_index = byte_index + 1)
                if(captured_data[byte_index] !== response_data[case_index*SLOT_BYTES+byte_index])
                    $fatal(1, "Wire mismatch case=%d offset=%d got=%h expected=%h",case_index,byte_index,captured_data[byte_index],response_data[case_index*SLOT_BYTES+byte_index]);
            repeat(20) @(negedge tx_clk);
            if(frame_count != before_count + 1)
                $fatal(1, "Unexpected duplicate response case=%d",case_index);
        end
        if((case_index % 25) == 0)
            $display("Ethernet transaction %d/%d passed",case_index,CASE_COUNT);
    end
    $display("PASS tb_eth_image_core: %d GMII transactions, ARP, all checksums, packet rejection, retry, eight modes, HOG and Band",CASE_COUNT);
    $finish;
end

initial begin
    #2_000_000_000;
    $fatal(1, "Ethernet core global timeout");
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
    .sys_rst_n          (rst_n             ),
    .gmii_rx_clk        (rx_clk            ),
    .gmii_rx_dv         (gmii_rx_dv        ),
    .gmii_rx_er         (gmii_rx_er        ),
    .gmii_rxd           (gmii_rxd          ),
    .gmii_tx_clk        (tx_clk            ),
    .gmii_tx_en         (gmii_tx_en        ),
    .gmii_tx_er         (gmii_tx_er        ),
    .gmii_txd           (gmii_txd          ),
    .algo_clk          (algo_clk),
    .app_clk            (app_clk           ),
    .rx_packet_done     (                  ),
    .rx_packet_error    (                  ),
    .rx_drop_flag       (                  ),
    .tx_packet_done     (                  ),
    .tx_busy            (                  )
);

endmodule
