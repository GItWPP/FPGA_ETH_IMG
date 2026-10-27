//--------------------------------------------------------------------------------------------------------
// 模块： tb_img_async_command
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 非整数比时钟下验证原图旁路、边界拒绝、结果反压及执行中复位
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_img_async_command();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire packet_ready;
wire [9:0] rx_addr;
wire result_en;
wire [9:0] result_addr;
wire [7:0] result_data;
wire resp_valid;
wire [7:0] resp_cmd;
wire [15:0] resp_id;
wire [15:0] resp_seq;
wire [15:0] resp_length;
wire [7:0] resp_data;
//reg   define
reg sys_clk = 1'b0;
reg algo_clk = 1'b0;
reg rst_n = 1'b0;
reg packet_valid = 1'b0;
reg [7:0] req_cmd = 8'd0;
reg [15:0] req_id = 16'd0;
reg [15:0] req_seq = 16'd0;
reg [15:0] req_length = 16'd0;
reg [15:0] req_crc = 16'd0;
reg [7:0] rx_data;
reg [7:0] input_mem [0:1023];
reg [7:0] output_mem [0:1023];
reg resp_ready = 1'b0;
reg resp_done = 1'b0;
reg [9:0] resp_addr = 10'd0;
reg [63:0] ping_bytes = 64'h0400ff01474d4955;
integer index;
integer transactions = 0;
integer slow_copy_writes = 0;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #3 sys_clk = ~sys_clk;
initial begin
    #2;
    forever #11 algo_clk = ~algo_clk;
end

always@(posedge sys_clk) begin
    rx_data <= input_mem[rx_addr];
    if(result_en)
        output_mem[result_addr] <= result_data;
end

//旁路证明：原图合法事务不得在算法时钟域再次写像素
always@(posedge algo_clk)
    if(rst_n && dut.algo_result_wr_en && req_id == 16'd1)
        slow_copy_writes = slow_copy_writes + 1;

task launch;
    input [7:0] cmd;
    input [15:0] id;
    input [15:0] seq;
    input [15:0] length;
    input [15:0] crc;
    begin
        wait(packet_ready);
        @(negedge sys_clk);
        req_cmd = cmd;
        req_id = id;
        req_seq = seq;
        req_length = length;
        req_crc = crc;
        packet_valid = 1'b1;
        @(posedge sys_clk);
        while(!packet_ready) @(posedge sys_clk);
        @(negedge sys_clk);
        packet_valid = 1'b0;
    end
endtask

task expect_reply;
    input [7:0] cmd;
    input [15:0] length;
    begin
        wait(resp_valid);
        @(negedge sys_clk);
        if(resp_cmd !== cmd || resp_length !== length || resp_id !== req_id || resp_seq !== req_seq)
            $fatal(1,"CDC reply mismatch command=%h expected=%h length=%d",resp_cmd,cmd,resp_length);
        //对端暂不接受描述符，字段和RAM必须保持
        repeat(37) begin
            @(negedge sys_clk);
            if(!resp_valid || resp_cmd !== cmd || resp_length !== length)
                $fatal(1,"CDC descriptor changed during response backpressure");
        end
    end
endtask

task finish_reply;
    begin
        @(negedge sys_clk);
        resp_ready = 1'b1;
        @(negedge sys_clk);
        resp_ready = 1'b0;
        repeat(17) @(negedge sys_clk);
        resp_done = 1'b1;
        @(negedge sys_clk);
        resp_done = 1'b0;
        wait(packet_ready);
        transactions = transactions + 1;
    end
endtask

task expect_error;
    input [7:0] error;
    begin
        expect_reply(8'hff,16'd1);
        resp_addr = 10'd0;
        #1;
        if(resp_data !== error)
            $fatal(1,"CDC error mismatch got=%h expected=%h",resp_data,error);
        finish_reply;
    end
endtask

task reset_all;
    begin
        #5;
        rst_n = 1'b0;
        packet_valid = 1'b0;
        resp_ready = 1'b0;
        resp_done = 1'b0;
        #143;
        rst_n = 1'b1;
        wait(packet_ready);
    end
endtask

task fill_start;
    input [15:0] width;
    input [7:0] mode;
    begin
        input_mem[0] = width[7:0];
        input_mem[1] = width[15:8];
        input_mem[2] = 8'd1;
        input_mem[3] = 8'd0;
        input_mem[4] = 8'd1;
        input_mem[5] = mode;
    end
endtask

initial begin
    reset_all;
    launch(8'h01,16'd0,16'd0,16'd0,16'd1);
    expect_reply(8'h81,16'd8);
    for(index = 0; index < 8; index = index + 1) begin
        resp_addr = index;
        #1;
        if(resp_data !== ping_bytes[index*8 +: 8]) $fatal(1,"Inline ping mismatch");
    end
    finish_reply;

    fill_start(16'd513,8'd0);
    launch(8'h02,16'd1,16'd0,16'd6,16'd2);
    expect_reply(8'h82,16'd0);
    finish_reply;
    launch(8'h03,16'd1,16'd1,16'd1,16'd3);
    expect_error(8'd5);
    launch(8'h03,16'd1,16'd1,16'd1023,16'd4);
    expect_error(8'd5);

    for(index = 0; index < 1024; index = index + 1) input_mem[index] = (index*29+7) & 255;
    launch(8'h03,16'd1,16'd1,16'd1024,16'd5);
    expect_reply(8'h83,16'd1024);
    for(index = 0; index < 1024; index = index + 1)
        if(output_mem[index] !== input_mem[index]) $fatal(1,"Fast copy byte mismatch %d",index);
    finish_reply;
    launch(8'h03,16'd1,16'd1,16'd1024,16'd6);
    expect_error(8'd6);
    launch(8'h03,16'd1,16'd1,16'd1024,16'd5);
    expect_reply(8'h83,16'd1024);
    finish_reply;
    launch(8'h03,16'd1,16'd2,16'd2,16'd7);
    expect_reply(8'h83,16'd2);
    finish_reply;
    launch(8'h04,16'd1,16'd3,16'd0,16'd8);
    expect_reply(8'h84,16'd0);
    finish_reply;
    if(slow_copy_writes != 0) $fatal(1,"Copy still wrote pixels in slow domain");

    fill_start(16'd8,8'd2);
    launch(8'h02,16'd2,16'd0,16'd6,16'd9);
    expect_reply(8'h82,16'd0);
    finish_reply;
    for(index = 0; index < 16; index = index + 1) input_mem[index] = (index*11+3) & 255;
    launch(8'h03,16'd2,16'd1,16'd16,16'd10);
    expect_reply(8'h83,16'd16);
    for(index = 0; index < 16; index = index + 1)
        if(output_mem[index] !== (input_mem[index] ^ 8'hff)) $fatal(1,"Slow algorithm result mismatch");
    finish_reply;

    //请求搬运途中复位，旧描述符不能在恢复后产生应答
    launch(8'h03,16'd2,16'd2,16'd1024,16'd11);
    wait(dut.input_index == 10'd8);
    reset_all;
    launch(8'h03,16'd2,16'd1,16'd2,16'd12);
    expect_error(8'd3);

    //算法正在处理时复位，再建立全新会话
    fill_start(16'd512,8'd2);
    launch(8'h02,16'd3,16'd0,16'd6,16'd13);
    expect_reply(8'h82,16'd0);
    finish_reply;
    launch(8'h03,16'd3,16'd1,16'd1024,16'd14);
    wait(dut.algo_result_wr_en);
    reset_all;
    launch(8'h01,16'd4,16'd0,16'd0,16'd15);
    expect_reply(8'h81,16'd8);
    //描述符反压中复位，不能泄露之前的控制应答
    reset_all;
    launch(8'h01,16'd5,16'd0,16'd0,16'd16);
    expect_reply(8'h81,16'd8);
    finish_reply;
    repeat(300) @(negedge sys_clk);
    if(resp_valid) $fatal(1,"Stale CDC response after reset");
    $display("PASS tb_img_async_command: %d replies, 166.7/45.45MHz clocks, copy bypass, odd lengths, retries, backpressure and three active reset phases",transactions);
    $finish;
end

initial begin
    #2_000_000;
    $fatal(1,"CDC command timeout fast=%d algo=%d",dut.fast_state,dut.algo_state);
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_async_command dut
(
    .sys_clk                (sys_clk),
    .sys_rst_n              (rst_n),
    .algo_clk               (algo_clk),
    .receive_en             (),
    .packet_valid           (packet_valid),
    .packet_ready           (packet_ready),
    .req_cmd                (req_cmd),
    .req_id                 (req_id),
    .req_seq                (req_seq),
    .req_length             (req_length),
    .req_crc                (req_crc),
    .rx_rd_addr             (rx_addr),
    .rx_rd_data             (rx_data),
    .result_wr_en           (result_en),
    .result_wr_addr         (result_addr),
    .result_wr_data         (result_data),
    .resp_valid             (resp_valid),
    .resp_ready             (resp_ready),
    .resp_cmd               (resp_cmd),
    .resp_id                (resp_id),
    .resp_seq               (resp_seq),
    .resp_length            (resp_length),
    .resp_addr              (resp_addr),
    .resp_data              (resp_data),
    .resp_done              (resp_done)
);

endmodule
