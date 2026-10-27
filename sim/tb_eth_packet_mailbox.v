//--------------------------------------------------------------------------------------------------------
// 模块： tb_eth_packet_mailbox
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 验证异步整包邮箱、checksum、反压、忙时保护及复位
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_eth_packet_mailbox();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire            wr_start_ready;
wire            wr_byte_ready;
wire            wr_drop_flag;
wire            rd_packet_valid;
wire    [15:0]  rd_length;
wire    [95:0]  rd_peer;
wire    [31:0]  rd_sum;
wire            rd_byte_valid;
wire    [7:0]   rd_byte_data;
wire            rd_byte_last;

//reg   define
reg             wr_clk = 1'b0;
reg             rd_clk = 1'b0;
reg             rst_n = 1'b0;
reg             wr_start_valid = 1'b0;
reg     [15:0]  wr_length = 16'd0;
reg     [95:0]  wr_peer = 96'd0;
reg             wr_byte_valid = 1'b0;
reg     [7:0]   wr_byte_data = 8'd0;
reg             wr_finish_flag = 1'b0;
reg             wr_abort_en = 1'b0;
reg             rd_packet_ready = 1'b0;
reg             rd_byte_ready = 1'b0;
integer         drop_count = 0;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #4 wr_clk = ~wr_clk;
always #7 rd_clk = ~rd_clk;

always@(posedge wr_clk)
    if(rst_n && wr_drop_flag)
        drop_count <= drop_count + 1;

task send_packet;
    input integer length;
    input integer seed;
    input abort_en;
    integer index;
    begin
        wait(wr_start_ready);
        @(negedge wr_clk);
        wr_start_valid = 1'b1;
        wr_length = length;
        wr_peer = seed;
        @(negedge wr_clk);
        wr_start_valid = 1'b0;
        for(index = 0; index < length; index = index + 1) begin
            wr_byte_valid = 1'b1;
            wr_byte_data = (index + seed) & 255;
            if(!wr_byte_ready)
                $fatal(1, "Unexpected writer backpressure");
            @(negedge wr_clk);
        end
        wr_byte_valid = 1'b0;
        wr_abort_en = abort_en;
        wr_finish_flag = 1'b1;
        @(negedge wr_clk);
        wr_finish_flag = 1'b0;
        wr_abort_en = 1'b0;
    end
endtask

task receive_packet;
    input integer length;
    input integer seed;
    integer index;
    integer cycles;
    integer sum;
    integer high_value;
    integer low_value;
    begin
        wait(rd_packet_valid);
        if(rd_length !== length || rd_peer !== seed)
            $fatal(1, "Packet metadata mismatch");
        sum = 0;
        for(index = 0; index < length; index = index + 2) begin
            high_value = (index + seed) & 255;
            low_value = (index + 1 < length) ? ((index + 1 + seed) & 255) : 0;
            sum = sum + high_value * 256 + low_value;
        end
        if(rd_sum !== sum)
            $fatal(1, "Packet checksum sum mismatch got=%h expected=%h", rd_sum, sum);
        @(negedge rd_clk);
        rd_packet_ready = 1'b1;
        @(negedge rd_clk);
        rd_packet_ready = 1'b0;
        index = 0;
        cycles = 0;
        while(index < length) begin
            @(negedge rd_clk);
            rd_byte_ready = ((cycles % 4) != 0);
            @(posedge rd_clk);
            if(rd_byte_valid && rd_byte_ready) begin
                if(rd_byte_data !== ((index + seed) & 255))
                    $fatal(1, "Byte mismatch at %d: %h", index, rd_byte_data);
                if(rd_byte_last !== (index == length - 1))
                    $fatal(1, "Last mismatch at %d", index);
                index = index + 1;
            end
            cycles = cycles + 1;
        end
        @(negedge rd_clk);
        rd_byte_ready = 1'b0;
        wait(wr_start_ready);
    end
endtask

initial begin
    #100;
    rst_n = 1'b1;
    send_packet(14, 11, 1'b0);
    //邮箱未读完前，新请求不能改变已经提交的RAM及返回地址
    @(negedge wr_clk);
    wr_start_valid = 1'b1;
    wr_length = 16'd1038;
    wr_peer = 96'hdead_beef;
    @(negedge wr_clk);
    wr_start_valid = 1'b0;
    receive_packet(14, 11);
    send_packet(15, 39, 1'b0);
    receive_packet(15, 39);
    send_packet(1038, 227, 1'b0);
    receive_packet(1038, 227);
    send_packet(20, 78, 1'b1);
    repeat(20) @(negedge rd_clk);
    if(rd_packet_valid || rd_byte_valid)
        $fatal(1, "Aborted packet became visible");
    send_packet(17, 91, 1'b0);
    #20;
    rst_n = 1'b0;
    #100;
    rst_n = 1'b1;
    repeat(20) @(negedge rd_clk);
    if(rd_packet_valid || rd_byte_valid)
        $fatal(1, "Reset exposed stale packet");
    send_packet(16, 22, 1'b0);
    receive_packet(16, 22);
    if(drop_count < 2)
        $fatal(1, "Expected busy and abort rejection");
    $display("PASS tb_eth_packet_mailbox: asynchronous clocks, boundaries, checksum, stall, busy, abort and reset");
    $finish;
end

initial begin
    #1_000_000;
    $fatal(1, "Mailbox test timeout");
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_packet_mailbox dut
(
    .wr_clk             (wr_clk             ),
    .wr_rst_n           (rst_n              ),
    .wr_start_valid     (wr_start_valid     ),
    .wr_start_ready     (wr_start_ready     ),
    .wr_length          (wr_length          ),
    .wr_peer            (wr_peer            ),
    .wr_byte_valid      (wr_byte_valid      ),
    .wr_byte_ready      (wr_byte_ready      ),
    .wr_byte_data       (wr_byte_data       ),
    .wr_finish_flag     (wr_finish_flag     ),
    .wr_abort_en        (wr_abort_en        ),
    .wr_drop_flag       (wr_drop_flag       ),
    .rd_clk             (rd_clk             ),
    .rd_rst_n           (rst_n              ),
    .rd_packet_valid    (rd_packet_valid    ),
    .rd_packet_ready    (rd_packet_ready    ),
    .rd_length          (rd_length          ),
    .rd_peer            (rd_peer            ),
    .rd_sum             (rd_sum             ),
    .rd_byte_valid      (rd_byte_valid      ),
    .rd_byte_ready      (rd_byte_ready      ),
    .rd_byte_data       (rd_byte_data       ),
    .rd_byte_last       (rd_byte_last       )
);

endmodule
