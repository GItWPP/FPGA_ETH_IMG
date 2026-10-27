//--------------------------------------------------------------------------------------------------------
// 模块： tb_img_byte_uram
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 验证UltraRAM字节写使能、全地址边界、相邻字节保留及一拍读取
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_img_byte_uram();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire [7:0] rd_data;
//reg   define
reg sys_clk = 1'b0;
reg wr_en = 1'b0;
reg [17:0] wr_addr = 18'd0;
reg [17:0] rd_addr = 18'd0;
reg [7:0] wr_data = 8'd0;
reg [7:0] expected [0:262143];
integer index;
integer address;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #10 sys_clk = ~sys_clk;

initial begin
    //写满所有字节，每个lane和最高地址都必须可独立保存
    for(index = 0; index < 262144; index = index + 1) begin
        @(negedge sys_clk);
        wr_en = 1'b1;
        wr_addr = index;
        wr_data = (index * 37 + index / 8 + 19) & 255;
        expected[index] = wr_data;
    end
    @(negedge sys_clk);
    wr_en = 1'b0;
    for(index = 0; index < 262144; index = index + 1) begin
        @(negedge sys_clk);
        rd_addr = index;
        @(posedge sys_clk);
        #1;
        if(rd_data !== expected[index])
            $fatal(1, "URAM lane mismatch addr=%d got=%h expected=%h",index,rd_data,expected[index]);
    end
    //重新覆盖伪随机地址，检查共享64位字内其余字节未变化
    for(index = 0; index < 1024; index = index + 1) begin
        address = (index * 7919) % 262144;
        @(negedge sys_clk);
        wr_en = 1'b1;
        wr_addr = address;
        wr_data = index ^ 8'hca;
        expected[address] = wr_data;
        @(negedge sys_clk);
        wr_en = 1'b0;
    end
    for(index = 0; index < 8192; index = index + 1) begin
        address = ((index / 8 * 7919) % 262144 / 8) * 8 + index % 8;
        @(negedge sys_clk);
        rd_addr = address;
        @(posedge sys_clk);
        #1;
        if(rd_data !== expected[address])
            $fatal(1, "URAM overwrite mismatch addr=%d",address);
    end
    $display("PASS tb_img_byte_uram: 262144 bytes, all lanes, sparse rewrites and retained neighbors");
    $finish;
end

initial begin
    #30_000_000;
    $fatal(1, "URAM timeout");
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_byte_uram dut
(
    .sys_clk (sys_clk),
    .wr_en   (wr_en),
    .wr_addr (wr_addr),
    .wr_data (wr_data),
    .rd_addr (rd_addr),
    .rd_data (rd_data)
);

endmodule
