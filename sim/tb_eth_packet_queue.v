//--------------------------------------------------------------------------------------------------------
// 模块： tb_eth_packet_queue
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 异步整包队列满槽、回绕、反压、失败回滚及全局复位自检
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_eth_packet_queue();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                   wr_ready;
wire                   wr_byte_ready;
wire                   wr_drop;
wire                   rd_valid;
wire           [15:0]  rd_length;
wire           [95:0]  rd_peer;
wire           [31:0]  rd_sum;
wire                   rd_byte_valid;
wire           [7:0]   rd_data;
wire                   rd_last;

//reg   define
reg                    wr_clk = 1'b0;
reg                    rd_clk = 1'b0;
reg                    rst_n = 1'b0;
reg                    wr_start = 1'b0;
reg            [15:0]  wr_length = 16'd0;
reg            [95:0]  wr_peer = 96'd0;
reg                    wr_valid = 1'b0;
reg            [7:0]   wr_data = 8'd0;
reg                    wr_finish = 1'b0;
reg                    wr_abort = 1'b0;
reg                    rd_ready = 1'b0;
reg                    rd_byte_ready = 1'b0;
integer index;
integer producer;
integer consumer;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #4 wr_clk = ~wr_clk;
always #7 rd_clk = ~rd_clk;

function [7:0] pattern;
    input integer identifier;
    input integer offset;
    begin
        pattern = (identifier * 13 + offset * 7) & 255;
    end
endfunction

task write_packet;
    input integer identifier;
    input integer length;
    input integer sent_length;
    input integer abort_packet;
    integer offset;
    begin
        @(negedge wr_clk);
        while(!wr_ready) @(negedge wr_clk);
        wr_length = length;
        wr_peer = identifier;
        wr_start = 1'b1;
        @(negedge wr_clk);
        wr_start = 1'b0;
        for(offset = 0; offset < sent_length; offset = offset + 1) begin
            wr_valid = 1'b1;
            wr_data = pattern(identifier, offset);
            if(!wr_byte_ready) $fatal(1, "Writer unexpectedly stalled");
            @(negedge wr_clk);
        end
        wr_valid = 1'b0;
        wr_abort = (abort_packet != 0);
        wr_finish = 1'b1;
        @(negedge wr_clk);
        wr_finish = 1'b0;
        wr_abort = 1'b0;
    end
endtask

task read_packet;
    input integer identifier;
    input integer length;
    integer offset;
    integer cycle;
    reg            [31:0]  expected_sum;
    begin
        @(negedge rd_clk);
        while(!rd_valid) @(negedge rd_clk);
        expected_sum = 32'd0;
        for(offset = 0; offset < length; offset = offset + 2)
            expected_sum = expected_sum + {pattern(identifier, offset),
                          ((offset+1 < length) ? pattern(identifier, offset+1) : 8'd0)};
        if(rd_length != length || rd_peer != identifier || rd_sum != expected_sum)
            $fatal(1, "Descriptor mismatch id=%d len=%d sum=%h expected=%h", identifier,rd_length,rd_sum,expected_sum);
        rd_ready = 1'b1;
        @(negedge rd_clk);
        rd_ready = 1'b0;
        offset = 0;
        cycle = 0;
        while(offset < length) begin
            rd_byte_ready = ((cycle % 7) != 2 && (cycle % 7) != 3);
            @(posedge rd_clk);
            if(rd_byte_valid && rd_byte_ready) begin
                if(rd_data !== pattern(identifier,offset) || rd_last !== (offset+1 == length))
                    $fatal(1, "Payload mismatch id=%d offset=%d got=%h",identifier,offset,rd_data);
                offset = offset + 1;
            end
            @(negedge rd_clk);
            cycle = cycle + 1;
        end
        rd_byte_ready = 1'b0;
    end
endtask

initial begin
    #200;
    rst_n = 1'b1;
    for(index = 0; index < 64; index = index + 1)
        write_packet(index,15,15,0);
    if(wr_ready) $fatal(1, "Queue did not fill at 64 packets");
    wr_start = 1'b1;
    @(negedge wr_clk);
    wr_start = 1'b0;
    if(!wr_drop) $fatal(1, "Overflow was not reported");
    for(index = 0; index < 64; index = index + 1)
        read_packet(index,15);
    write_packet(20,15,15,1);
    write_packet(21,15,14,0);
    repeat(20) @(negedge rd_clk);
    if(rd_valid) $fatal(1, "Aborted or truncated packet was published");
    write_packet(22,1038,1038,0);
    read_packet(22,1038);
    write_packet(23,1037,1037,0);
    read_packet(23,1037);
    fork
        begin
            for(producer = 0; producer < 160; producer = producer + 1)
                write_packet(100+producer,31,31,0);
        end
        begin
            for(consumer = 0; consumer < 160; consumer = consumer + 1)
                read_packet(100+consumer,31);
        end
    join
    write_packet(250,14,14,0);
    #3;
    rst_n = 1'b0;
    #100;
    rst_n = 1'b1;
    repeat(20) @(negedge rd_clk);
    if(rd_valid) $fatal(1, "Reset did not flush committed packets");
    write_packet(251,14,14,0);
    read_packet(251,14);
    $display("PASS tb_eth_packet_queue: 64 slots, full, rollback, odd checksum, max length, 160 concurrent packets, wrap and reset");
    $finish;
end

initial begin
    #20_000_000;
    $fatal(1, "Queue test timeout");
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
eth_packet_queue
#(
    .SLOT_BITS (6)
)
dut
(
    .wr_clk                 (wr_clk                                          ),
    .wr_rst_n               (rst_n                                           ),
    .wr_start_valid         (wr_start                                        ),
    .wr_start_ready         (wr_ready                                        ),
    .wr_length              (wr_length                                       ),
    .wr_peer                (wr_peer                                         ),
    .wr_byte_valid          (wr_valid                                        ),
    .wr_byte_ready          (wr_byte_ready                                   ),
    .wr_byte_data           (wr_data                                         ),
    .wr_finish_flag         (wr_finish                                       ),
    .wr_abort_en            (wr_abort                                        ),
    .wr_drop_flag           (wr_drop                                         ),
    .rd_clk                 (rd_clk                                          ),
    .rd_rst_n               (rst_n                                           ),
    .rd_packet_valid        (rd_valid                                        ),
    .rd_packet_ready        (rd_ready                                        ),
    .rd_length              (rd_length                                       ),
    .rd_peer                (rd_peer                                         ),
    .rd_sum                 (rd_sum                                          ),
    .rd_byte_valid          (rd_byte_valid                                   ),
    .rd_byte_ready          (rd_byte_ready                                   ),
    .rd_byte_data           (rd_data                                         ),
    .rd_byte_last           (rd_last                                         )
);

endmodule
