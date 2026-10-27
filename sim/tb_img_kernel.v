//--------------------------------------------------------------------------------------------------------
// 模块： tb_img_kernel
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 四种3x3算法逐窗口比对独立参考，检查输入锁存、反压及计算中复位
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_img_kernel();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire                     in_ready;
wire                     out_valid;
wire           [15:0]    out_data;

//reg   define
reg                      sys_clk;
reg                      sys_rst_n;
reg                      in_valid;
reg                      out_ready;
reg            [2:0]     mode;
reg            [15:0]    in_data;
reg            [143:0]   window_data;
reg            [15:0]    wanted;
reg            [8191:0]  vector_dir;
integer          fd;
integer          scan;
integer          vector_count;
integer          vector_index;
integer          watchdog;
integer          hold_index;
integer          path_found;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
initial begin
    sys_clk     = 1'b0;
    sys_rst_n   = 1'b0;
    in_valid    = 1'b0;
    out_ready   = 1'b0;
    mode        = 3'd0;
    in_data     = 16'd0;
    window_data = 144'd0;
end

always #10 sys_clk = ~sys_clk;

initial begin
    vector_dir = "../vectors";
    path_found = $value$plusargs("VECTOR_DIR=%s", vector_dir);
    fd = $fopen({vector_dir, "/kernels.txt"}, "r");
    if(fd == 0) begin
        $display("FAIL missing kernel vectors");
        $finish;
    end
    scan = $fscanf(fd, "%d\n", vector_count);
    #100;
    @(negedge sys_clk);
    sys_rst_n = 1'b1;
    for(vector_index = 0; vector_index < vector_count; vector_index = vector_index + 1) begin
        @(negedge sys_clk);
        scan = $fscanf(fd, "%d %h %h\n", mode, wanted, window_data);
        if(scan != 3 || !in_ready) begin
            $display("FAIL vector input %0d", vector_index);
            $finish;
        end
        in_valid = 1'b1;
        @(posedge sys_clk);
        @(negedge sys_clk);
        in_valid = 1'b0;
        window_data = ~window_data;
        mode = 3'd0;
        watchdog = 0;
        while(!out_valid && watchdog < 200) begin
            @(posedge sys_clk);
            #1;
            watchdog = watchdog + 1;
        end
        if(!out_valid || out_data !== wanted) begin
            $display("FAIL kernel %0d actual=%04x expected=%04x latency=%0d", vector_index, out_data, wanted, watchdog);
            $finish;
        end
        //结果被阻塞四拍；改变输入也不能改变已经完成的输出
        for(hold_index = 0; hold_index < 4; hold_index = hold_index + 1) begin
            @(posedge sys_clk);
            #1;
            if(!out_valid || in_ready || out_data !== wanted) begin
                $display("FAIL kernel backpressure");
                $finish;
            end
        end
        @(negedge sys_clk);
        out_ready = 1'b1;
        @(posedge sys_clk);
        @(negedge sys_clk);
        out_ready = 1'b0;
    end
    $fclose(fd);

    //中值计算中复位，不能产生旧窗口的幽灵输出
    mode = 3'd4;
    in_valid = 1'b1;
    @(posedge sys_clk);
    @(negedge sys_clk);
    in_valid = 1'b0;
    repeat(20) @(negedge sys_clk);
    sys_rst_n = 1'b0;
    #1;
    if(out_valid) begin
        $display("FAIL reset did not clear valid");
        $finish;
    end
    repeat(3) @(negedge sys_clk);
    sys_rst_n = 1'b1;
    repeat(160) @(negedge sys_clk);
    if(out_valid || !in_ready) begin
        $display("FAIL stale result after reset");
        $finish;
    end
    mode = 3'd2;
    in_data = 16'h1234;
    in_valid = 1'b1;
    @(posedge sys_clk);
    #1;
    if(!out_valid || out_data !== 16'hedcb) begin
        $display("FAIL normal mode after reset");
        $finish;
    end
    $display("PASS tb_img_kernel: %0d windows, input latch, backpressure and reset", vector_count);
    $finish;
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_pixel_proc img_pixel_proc_inst
(
    .sys_clk     (sys_clk     ),
    .sys_rst_n   (sys_rst_n   ),
    .mode        (mode        ),
    .in_data     (in_data     ),
    .window_data (window_data ),
    .in_valid    (in_valid    ),
    .in_ready    (in_ready    ),

    .out_data    (out_data    ),
    .out_valid   (out_valid   ),
    .out_ready   (out_ready   )
);

endmodule
