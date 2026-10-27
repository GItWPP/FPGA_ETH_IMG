//--------------------------------------------------------------------------------------------------------
// 模块： tb_band_decode_top
// Type    : simulation
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： 原始图片、已知码流合成图、亮度变化及空白帧Band解码自检
// 作者： WANG
// 时间： 26.10.21
//--------------------------------------------------------------------------------------------------------
`timescale  1ns/1ns

module  tb_band_decode_top();

//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
//wire  define
wire            start_ready;
wire            done_flag;
wire    [15:0]  result_count;
wire    [7:0]   result_rows;
wire    [15:0]  pitch_q8;
wire    [7:0]   result_status;
wire    [15:0]  detected_dots;
wire    [31:0]  result_rd_data;
//reg   define
reg             sys_clk;
reg             sys_rst_n;
reg             frame_wr_en;
reg     [17:0]  frame_wr_addr;
reg     [7:0]   frame_wr_data;
reg     [9:0]   image_width;
reg     [9:0]   image_height;
reg             start_valid;
reg     [11:0]  result_rd_addr;
reg     [7:0]   pixels [0:262143];
reg     [31:0]  expected [0:4095];
integer         errors;
integer         cases;
integer         cycles;

//********************************************************************//
//***************************** Main Code ****************************//
//********************************************************************//
always #10 sys_clk = ~sys_clk;

task run_case;
    input [4095:0] image_file;
    input [4095:0] cells_file;
    input integer width_value;
    input integer height_value;
    input integer count_value;
    input integer rows_value;
    input integer pitch_value;
    input integer dots_value;
    input integer status_value;
    integer x;
    integer y;
    integer index;
    begin
        $readmemh(image_file, pixels, 0, width_value*height_value-1);
        if(count_value != 0)
            $readmemh(cells_file, expected, 0, count_value-1);
        image_width = width_value;
        image_height = height_value;
        for(y=0; y<height_value; y=y+1)
            for(x=0; x<width_value; x=x+1) begin
                @(negedge sys_clk);
                frame_wr_en = 1'b1;
                frame_wr_addr = y*512+x;
                frame_wr_data = pixels[y*width_value+x];
            end
        @(negedge sys_clk);
        frame_wr_en = 1'b0;
        start_valid = 1'b1;
        @(negedge sys_clk);
        start_valid = 1'b0;
        cycles = 0;
        while(done_flag == 1'b0 && cycles < 20_000_000) begin
            @(negedge sys_clk);
            cycles = cycles+1;
        end
        if(done_flag !== 1'b1 || result_status !== status_value || result_count !== count_value ||
           result_rows !== rows_value || pitch_q8 !== pitch_value || detected_dots !== dots_value) begin
            $display("FAIL header status=%0d count=%0d rows=%0d pitch=%0d dots=%0d cycles=%0d", result_status, result_count, result_rows, pitch_q8, detected_dots, cycles);
            errors = errors+1;
        end
        for(index=0; index<count_value; index=index+1) begin
            @(negedge sys_clk);
            result_rd_addr = index;
            @(negedge sys_clk);
            if(result_rd_data !== expected[index]) begin
                if(errors < 12) $display("FAIL cell %0d actual=%h expected=%h", index, result_rd_data, expected[index]);
                errors = errors+1;
            end
        end
        cases = cases+1;
        $display("CASE %0d cells=%0d clocks=%0d errors=%0d", cases, count_value, cycles, errors);
        repeat(3) @(negedge sys_clk);
    end
endtask

initial begin
    sys_clk = 1'b0;
    sys_rst_n = 1'b0;
    frame_wr_en = 1'b0;
    frame_wr_addr = 18'd0;
    frame_wr_data = 8'd0;
    image_width = 10'd512;
    image_height = 10'd512;
    start_valid = 1'b0;
    result_rd_addr = 12'd0;
    errors = 0;
    cases = 0;
    repeat(5) @(negedge sys_clk);
    sys_rst_n = 1'b1;
    repeat(3) @(negedge sys_clk);
    `include "band_cases.vh"
    if(errors == 0)
        $display("PASS tb_band_decode_top: %0d frames", cases);
    else
        $fatal(1, "FAIL tb_band_decode_top: %0d errors", errors);
    $finish;
end

//********************************************************************//
//*************************** Instantiation **************************//
//********************************************************************//
band_decode_top
band_decode_top_inst
(
    .sys_clk        (sys_clk        ),
    .sys_rst_n      (sys_rst_n      ),
    .frame_wr_en    (frame_wr_en    ),
    .frame_wr_addr  (frame_wr_addr  ),
    .frame_wr_data  (frame_wr_data  ),
    .image_width    (image_width    ),
    .image_height   (image_height   ),
    .start_valid    (start_valid    ),
    .start_ready    (start_ready    ),
    .done_flag      (done_flag      ),
    .result_count   (result_count   ),
    .result_rows    (result_rows    ),
    .pitch_q8       (pitch_q8       ),
    .result_status  (result_status  ),
    .detected_dots  (detected_dots  ),
    .result_rd_addr (result_rd_addr ),
    .result_rd_data (result_rd_data )
);

endmodule
