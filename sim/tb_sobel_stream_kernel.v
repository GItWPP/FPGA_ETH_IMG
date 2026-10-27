//--------------------------------------------------------------------------------------------------------
// 模块： tb_sobel_stream_kernel
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 独立坐标参考检查流式Sobel连续输入、空拍、行边界及处理中复位
// 作者： WANG
// 时间： 26.10.23
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module tb_sobel_stream_kernel();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire gray_valid;
wire [7:0] gray_data;
//reg   define
reg sys_clk = 1'b0;
reg rst_n = 1'b0;
reg frame_start = 1'b0;
reg [15:0] width = 16'd1;
reg [15:0] height = 16'd1;
reg pixel_valid = 1'b0;
reg [15:0] pixel_data = 16'd0;
reg check_en = 1'b0;
integer output_count = 0;
integer cases_done = 0;
integer x;
integer y;
integer k;
integer expected;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #4 sys_clk = ~sys_clk;

function [15:0] source_pixel;
    input integer px;
    input integer py;
    begin
        source_pixel = ((px*67 + py*139) ^ (px*13 + py*29)) & 65535;
    end
endfunction

function integer gray_at;
    input integer px;
    input integer py;
    integer xx;
    integer yy;
    integer p;
    integer r;
    integer g;
    integer b;
    begin
        xx = (px < 0) ? 0 : ((px >= width) ? width-1 : px);
        yy = (py < 0) ? 0 : ((py >= height) ? height-1 : py);
        p = source_pixel(xx,yy);
        r = p >> 11;
        g = (p >> 5) & 63;
        b = p & 31;
        gray_at = (77*((r << 3) | (r >> 2)) + 150*((g << 2) | (g >> 4)) + 29*((b << 3) | (b >> 2))) >> 8;
    end
endfunction

function integer edge_at;
    input integer px;
    input integer py;
    integer gx;
    integer gy;
    integer mag;
    begin
        gx = gray_at(px+1,py-1) + 2*gray_at(px+1,py) + gray_at(px+1,py+1)
             - gray_at(px-1,py-1) - 2*gray_at(px-1,py) - gray_at(px-1,py+1);
        gy = gray_at(px-1,py+1) + 2*gray_at(px,py+1) + gray_at(px+1,py+1)
             - gray_at(px-1,py-1) - 2*gray_at(px,py-1) - gray_at(px+1,py-1);
        mag = ((gx < 0) ? -gx : gx) + ((gy < 0) ? -gy : gy);
        edge_at = (mag > 255) ? 255 : mag;
    end
endfunction

always@(posedge sys_clk)
    if(rst_n && check_en && gray_valid) begin
        if(output_count >= width*height)
            $fatal(1,"Unexpected extra pixel");
        expected = edge_at(output_count % width,output_count / width);
        if(gray_data !== expected[7:0])
            $fatal(1,"Kernel mismatch width=%d height=%d offset=%d got=%d expected=%d",width,height,output_count,gray_data,expected);
        output_count = output_count + 1;
    end

task run_frame;
    input integer frame_w;
    input integer frame_h;
    input integer bubbles;
    integer px;
    integer py;
    begin
        @(negedge sys_clk);
        width = frame_w;
        height = frame_h;
        frame_start = 1'b1;
        pixel_valid = 1'b0;
        output_count = 0;
        check_en = 1'b1;
        @(negedge sys_clk);
        frame_start = 1'b0;
        for(py = 0; py <= frame_h; py = py + 1) begin
            for(px = 0; px <= frame_w; px = px + 1) begin
                pixel_valid = 1'b1;
                pixel_data = source_pixel((px == frame_w) ? px-1 : px,(py == frame_h) ? py-1 : py);
                @(negedge sys_clk);
                if(bubbles && (px % 7 == 3)) begin
                    pixel_valid = 1'b0;
                    repeat(3) @(negedge sys_clk);
                end
            end
        end
        pixel_valid = 1'b0;
        repeat(10) @(negedge sys_clk);
        if(output_count != frame_w*frame_h)
            $fatal(1,"Missing output pixels");
        check_en = 1'b0;
        cases_done = cases_done + 1;
    end
endtask

initial begin
    #200;
    rst_n = 1'b1;
    run_frame(1,1,0);
    run_frame(1,17,1);
    run_frame(17,1,1);
    run_frame(31,19,0);
    run_frame(1920,3,1);
    run_frame(1280,9,0);
    @(negedge sys_clk);
    frame_start = 1'b1;
    @(negedge sys_clk);
    frame_start = 1'b0;
    pixel_valid = 1'b1;
    repeat(20) @(negedge sys_clk);
    rst_n = 1'b0;
    pixel_valid = 1'b0;
    repeat(5) @(negedge sys_clk);
    rst_n = 1'b1;
    repeat(8) @(negedge sys_clk);
    if(gray_valid)
        $fatal(1,"Stale valid after reset");
    run_frame(7,13,1);
    $display("PASS tb_sobel_stream_kernel: %d frames, II=1, bubbles, width changes, reset in flight",cases_done);
    $finish;
end

initial begin
    #2_000_000;
    $fatal(1,"Kernel timeout");
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
img_sobel_stream_top dut
(
    .sys_clk                (sys_clk),
    .sys_rst_n              (rst_n),
    .frame_start            (frame_start),
    .frame_width            (width),
    .frame_height           (height),
    .pixel_valid            (pixel_valid),
    .pixel_data             (pixel_data),
    .gray_valid             (gray_valid),
    .gray_data              (gray_data)
);

endmodule
