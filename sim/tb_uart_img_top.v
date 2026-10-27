//--------------------------------------------------------------------------------------------------------
// 模块： tb_uart_img_top
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 独立串口主机位级激励，逐字节对照Python协议与图像参考结果
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ps

module  tb_uart_img_top();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//parameter define
localparam real FPGA_BIT_NS = 1000.0 / 1.5;
localparam [7:0] OP_BYTE       = 8'd0;
localparam [7:0] OP_WAIT_REPLY = 8'd1;
localparam [7:0] OP_WAIT_CLK   = 8'd2;
localparam [7:0] OP_RESET      = 8'd3;
localparam [7:0] OP_BAD_STOP   = 8'd4;
localparam [7:0] OP_CASE       = 8'd5;
localparam [7:0] OP_BIT_PERIOD = 8'd6;
localparam [7:0] OP_FALSE_START = 8'd7;

//wire  define
wire                     uart_tx_o;

//reg   define
reg                      sys_clk;
reg                      sys_rst_n;
reg                      uart_rx_i;
reg            [7:0]     expected [0:65535];
reg            [31:0]    action;
reg            [7:0]     observed;
reg            [8191:0]  vector_dir;
integer         fd;
integer         scan;
integer         events;
integer         expected_count;
integer         count;
integer         event_index;
integer         bit_index;
integer         watchdog;
integer         path_found;
real            host_bit_ns;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
initial begin
    sys_clk = 1'b0;
    sys_rst_n = 1'b0;
    uart_rx_i = 1'b1;
    count = 0;
    host_bit_ns = 666.667;
end

always #10 sys_clk = ~sys_clk;

//send_byte:独立理想位周期，允许注入停止位错误
task send_byte;
    input [7:0] value;
    input bad_stop;
    integer b;
    begin
        uart_rx_i = 1'b0;
        #(host_bit_ns);
        for(b = 0; b < 8; b = b + 1) begin
            uart_rx_i = value[b];
            #(host_bit_ns);
        end
        uart_rx_i = !bad_stop;
        #(host_bit_ns);
        uart_rx_i = 1'b1;
        if(bad_stop)
            #(host_bit_ns * 2);
    end
endtask

//监视器在理想位中心采样，不复用DUT的计时器和接收模块
initial begin
    wait(sys_rst_n);
    forever begin
        @(negedge uart_tx_o);
        if(sys_rst_n) begin
            #(FPGA_BIT_NS * 1.5);
            for(bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                observed[bit_index] = uart_tx_o;
                #(FPGA_BIT_NS);
            end
            if(uart_tx_o !== 1'b1) begin
                $display("FAIL TX stop bit, byte %0d", count);
                $finish;
            end
            if(count >= expected_count || observed !== expected[count]) begin
                $display("FAIL reply byte %0d actual=%02x expected=%02x at %t", count, observed, expected[count], $time);
                $finish;
            end
            count = count + 1;
        end
    end
end

//向量包含事务边界与异常激励，主机遵守逐包停等约束
initial begin
    vector_dir = "../vectors";
    path_found = $value$plusargs("VECTOR_DIR=%s", vector_dir);
    fd = $fopen({vector_dir, "/stimulus.txt"}, "r");
    if(fd == 0) begin
        $display("FAIL missing vectors");
        $finish;
    end
    scan = $fscanf(fd, "%d %d\n", events, expected_count);
    $readmemh({vector_dir, "/expected.hex"}, expected, 0, expected_count - 1);
    #200;
    sys_rst_n = 1'b1;
    #500;
    for(event_index = 0; event_index < events; event_index = event_index + 1) begin
        scan = $fscanf(fd, "%h\n", action);
        if(scan != 1) begin
            $display("FAIL stimulus parse");
            $finish;
        end
        case(action[31:24])
            OP_BYTE: send_byte(action[7:0], 1'b0);
            OP_WAIT_REPLY: begin
                watchdog = 0;
                while(count < action[23:0] && watchdog < 2_000_000) begin
                    @(posedge sys_clk);
                    watchdog = watchdog + 1;
                end
                if(count != action[23:0]) begin
                    $display("FAIL reply timeout count=%0d target=%0d ctrl=%0d rx=%0d", count, action[23:0], uart_img_top_inst.img_ctrl_inst.image_ctrl_inst.state, uart_img_top_inst.img_packet_rx_inst.state);
                    $finish;
                end
            end
            OP_WAIT_CLK: repeat(action[23:0]) @(posedge sys_clk);
            OP_RESET: begin
                sys_rst_n = 1'b0;
                uart_rx_i = 1'b1;
                #200;
                sys_rst_n = 1'b1;
                #500;
            end
            OP_BAD_STOP: send_byte(action[7:0], 1'b1);
            OP_CASE: $display("CASE %0d at %t", action[23:0], $time);
            OP_BIT_PERIOD: host_bit_ns = action[23:0] / 1000.0;
            OP_FALSE_START: begin
                uart_rx_i = 1'b0;
                #(action[23:0]);
                uart_rx_i = 1'b1;
            end
            default: begin
                $display("FAIL unknown opcode");
                $finish;
            end
        endcase
    end
    $fclose(fd);
    if(count != expected_count)
        $display("FAIL byte count %0d/%0d", count, expected_count);
    else
        $display("PASS tb_uart_img_top: %0d bytes matched Python reference", count);
    $finish;
end

initial begin
    #500_000_000;
    $display("FAIL global watchdog");
    $finish;
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
uart_img_top
#(
    .RX_TIMEOUT_CLKS (50_000)
)
uart_img_top_inst
(
    .sys_clk    (sys_clk    ),
    .sys_rst_n  (sys_rst_n  ),
    .uart_rx_i  (uart_rx_i  ),

    .uart_tx_o  (uart_tx_o  )
);

endmodule
