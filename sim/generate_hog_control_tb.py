"""Generate controller fault/retry coverage without simulating UART bit times."""
from pathlib import Path
import re
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from generate_algorithm_modules import write,instance,RTL
from hog_reference import gradient_bin


def tb(name,description,decl,body,instances):
    write(name,description,'',decl,body,instances)
    source=(RTL/f'{name}.v').read_text(encoding='utf-8').replace('Type    : synthesizable','Type    : simulation')
    (ROOT/f'sim/{name}.v').write_text(source,encoding='utf-8')
    (RTL/f'{name}.v').unlink()


def main():
    text=(RTL/'img_command_top.v').read_text(encoding='utf-8').split('\n(\n',1)[1].split('\n);',1)[0]
    ports=re.findall(r'(input|output)\s+wire\s*(\[[^]]+\])?\s*(\w+)',text)
    driven={'pixel_in_ready','pixel_out_data','pixel_out_valid','rx_rd_data','result_rd_data','hog_score_rd_data'}
    decl=['//wire  define']
    regs=[]
    for direction,width,name in ports:
        if direction=='output' or name in driven:
            decl.append(f'wire {width or ""} {name};')
        else: regs.append(f'reg {width or ""} {name};')
    decl+=['//reg   define']+regs+['''reg [7:0] request_memory [0:1023];
reg [7:0] response_memory [0:1023];
reg [7:0] frame [0:76799];
reg [7:0] rx_data_reg;
reg [31:0] score_data_reg;
reg [7:0] result_memory [0:1023];
reg [7:0] result_data_reg;
integer i;
integer chunk;
integer frame_writes;
integer core_starts;
integer core_delay;
integer cases;''']
    inst=instance('img_command_top','img_command_top_inst',[(n,n) for _,_,n in ports])
    inst+='\n'+instance('img_pixel_proc','img_pixel_proc_inst',[('sys_clk','sys_clk'),('sys_rst_n','sys_rst_n'),('mode','pixel_mode'),('in_data','pixel_in_data'),('window_data','pixel_window_data'),('in_valid','pixel_in_valid'),('in_ready','pixel_in_ready'),('out_data','pixel_out_data'),('out_valid','pixel_out_valid'),('out_ready','pixel_out_ready')])
    tb('tb_hog_uart_ctrl','检查HOG会话、整帧上传、读取边界、错误/重发及跨算法共享缓存仲裁','\n'.join(decl),'''assign rx_rd_data = rx_data_reg;
assign result_rd_data = result_data_reg;
assign hog_score_rd_data = score_data_reg;
always #10 sys_clk = ~sys_clk;

always@(posedge sys_clk) begin
    rx_data_reg <= request_memory[rx_rd_addr];
    score_data_reg <= 32'h80102000 + {23'd0, hog_score_rd_addr};
    result_data_reg <= result_memory[resp_addr];
    if(result_wr_en) result_memory[result_wr_addr] <= result_wr_data;
    if(sys_rst_n && hog_frame_wr_en) begin
        if(hog_frame_wr_addr !== frame_writes || hog_frame_wr_data !== frame[frame_writes]) begin
            $display("FAIL HOG upload addr=%d count=%d data=%h",hog_frame_wr_addr,frame_writes,hog_frame_wr_data);
            $finish;
        end
        frame_writes = frame_writes + 1;
    end
end

//检测引擎替身仅验证命令握手，数值算法由完整HOG testbench独立验证
always@(posedge sys_clk) begin
    if(!sys_rst_n) begin
        core_delay <= 0;
        hog_done_flag <= 1'b0;
        core_starts <= 0;
    end else begin
        hog_done_flag <= (core_delay == 1);
        if(hog_start_valid && hog_start_ready) begin
            core_delay <= 16;
            core_starts <= core_starts + 1;
        end else if(core_delay > 0)
            core_delay <= core_delay - 1;
    end
end

task transact;
    input [7:0] cmd;
    input [15:0] id;
    input [15:0] seq;
    input [15:0] length;
    input [15:0] crc;
    input [7:0] expected_cmd;
    input [15:0] expected_length;
    input [7:0] expected_error;
    integer watchdog;
    integer byte_number;
    begin
        @(negedge sys_clk);
        while(!packet_ready) @(negedge sys_clk);
        req_cmd = cmd;
        req_id = id;
        req_seq = seq;
        req_length = length;
        req_crc = crc;
        packet_valid = 1'b1;
        @(negedge sys_clk);
        packet_valid = 1'b0;
        watchdog = 0;
        while(!resp_valid && watchdog < 10000) begin
            @(negedge sys_clk);
            watchdog = watchdog + 1;
        end
        if(!resp_valid || resp_cmd !== expected_cmd || resp_length !== expected_length || resp_id !== id || resp_seq !== seq) begin
            $display("FAIL HOG case=%d cmd=%h seq=%d response=%h len=%d expected=%h len=%d",cases,cmd,seq,resp_cmd,resp_length,expected_cmd,expected_length);
            $finish;
        end
        resp_ready = 1'b1;
        @(negedge sys_clk);
        resp_ready = 1'b0;
        for(byte_number=0; byte_number<expected_length; byte_number=byte_number+1) begin
            resp_addr = byte_number;
            repeat(2) @(negedge sys_clk);
            response_memory[byte_number] = resp_data;
        end
        if(expected_cmd == 8'hff && response_memory[0] !== expected_error) begin
            $display("FAIL HOG error case=%d actual=%d expected=%d",cases,response_memory[0],expected_error);
            $finish;
        end
        resp_done = 1'b1;
        @(negedge sys_clk);
        resp_done = 1'b0;
        cases = cases + 1;
    end
endtask

initial begin
    sys_clk = 1'b0;
    sys_rst_n = 1'b0;
    packet_valid = 1'b0;
    req_cmd = 8'd0;
    req_id = 16'd0;
    req_seq = 16'd0;
    req_length = 16'd0;
    req_crc = 16'd0;
    resp_ready = 1'b0;
    resp_addr = 10'd0;
    resp_done = 1'b0;
    hog_start_ready = 1'b1;
    hog_model_id = 32'hd2a8b58b;
    frame_writes = 0;
    cases = 0;
    $readmemh("../hog_frame.mem",frame);
    repeat(6) @(negedge sys_clk);
    sys_rst_n = 1'b1;
    transact(8'h1f,16'd0,16'd0,16'd0,16'd10,8'h9f,16'd16,8'd0);
    if({response_memory[3],response_memory[2],response_memory[1],response_memory[0]} !== 32'h31474f48) begin
        $display("FAIL HOG INFO magic");
        $finish;
    end
    request_memory[0] = 8'd1;
    request_memory[1] = 8'd0;
    request_memory[2] = 8'd1;
    request_memory[3] = 8'd0;
    request_memory[4] = 8'd1;
    request_memory[5] = 8'd0;
    transact(8'h02,16'd90,16'd0,16'd6,16'd20,8'h82,16'd0,8'd0);
    request_memory[0] = 8'h12;
    request_memory[1] = 8'hab;
    transact(8'h03,16'd90,16'd1,16'd2,16'd21,8'h83,16'd2,8'd0);
    transact(8'h1e,16'd4,16'd0,16'd0,16'd22,8'hff,16'd1,8'd1);
    transact(8'h03,16'd90,16'd1,16'd2,16'd21,8'h83,16'd2,8'd0);
    if(response_memory[0] !== 8'h12 || response_memory[1] !== 8'hab) begin
        $display("FAIL cross-command error destroyed old cache");
        $finish;
    end
    transact(8'h10,16'd100,16'd1,16'd0,16'd23,8'hff,16'd1,8'd2);
    transact(8'h10,16'd100,16'd0,16'd0,16'd24,8'h90,16'd0,8'd0);
    transact(8'h10,16'd100,16'd0,16'd0,16'd24,8'h90,16'd0,8'd0);
    transact(8'h03,16'd90,16'd2,16'd2,16'd25,8'hff,16'd1,8'd3);
    transact(8'h12,16'd100,16'd1,16'd0,16'd26,8'hff,16'd1,8'd5);
    transact(8'h11,16'd101,16'd1,16'd1,16'd27,8'hff,16'd1,8'd3);
    transact(8'h11,16'd100,16'd2,16'd1,16'd28,8'hff,16'd1,8'd4);
    transact(8'h11,16'd100,16'd1,16'd0,16'd29,8'hff,16'd1,8'd5);
    for(chunk=0; chunk<75; chunk=chunk+1) begin
        for(i=0; i<1024; i=i+1) request_memory[i] = frame[chunk*1024+i];
        transact(8'h11,16'd100,chunk+1,16'd1024,chunk+100,8'h91,16'd0,8'd0);
        if(chunk == 0) begin
            transact(8'h11,16'd100,16'd1,16'd1024,16'd100,8'h91,16'd0,8'd0);
            transact(8'h11,16'd100,16'd1,16'd1024,16'd101,8'hff,16'd1,8'd6);
            transact(8'h11,16'd100,16'd1,16'd1024,16'd100,8'h91,16'd0,8'd0);
        end
    end
    transact(8'h11,16'd100,16'd76,16'd1,16'd200,8'hff,16'd1,8'd5);
    transact(8'h12,16'd100,16'd76,16'd0,16'd201,8'h92,16'd2,8'd0);
    transact(8'h12,16'd100,16'd76,16'd0,16'd201,8'h92,16'd2,8'd0);
    if(frame_writes != 76800 || core_starts != 1 || {response_memory[1],response_memory[0]} !== 16'd495) begin
        $display("FAIL duplicate uploads or RUN count");
        $finish;
    end
    request_memory[0] = 8'd0;
    request_memory[1] = 8'd0;
    request_memory[2] = 8'd0;
    request_memory[3] = 8'd0;
    transact(8'h13,16'd100,16'd77,16'd4,16'd202,8'hff,16'd1,8'd2);
    request_memory[3] = 8'd1;
    transact(8'h13,16'd100,16'd77,16'd4,16'd203,8'h93,16'd1024,8'd0);
    for(i=0; i<256; i=i+1)
        if({response_memory[i*4+3],response_memory[i*4+2],response_memory[i*4+1],response_memory[i*4]} !== 32'h80102000+i) begin
            $display("FAIL score bytes first chunk index=%d",i);
            $finish;
        end
    //旧算法非法请求不得破坏HOG最近得分应答
    transact(8'h02,16'd91,16'd0,16'd0,16'd204,8'hff,16'd1,8'd2);
    transact(8'h13,16'd100,16'd77,16'd4,16'd203,8'h93,16'd1024,8'd0);
    if(response_memory[0] !== 8'h00 || response_memory[1023] !== 8'h80) begin
        $display("FAIL HOG cached score bytes");
        $finish;
    end
    request_memory[0] = 8'd0;
    request_memory[1] = 8'd1;
    request_memory[2] = 8'd240;
    request_memory[3] = 8'd0;
    transact(8'h13,16'd100,16'd78,16'd4,16'd205,8'hff,16'd1,8'd2);
    request_memory[2] = 8'd239;
    transact(8'h13,16'd100,16'd78,16'd4,16'd206,8'h93,16'd956,8'd0);
    for(i=0; i<239; i=i+1)
        if({response_memory[i*4+3],response_memory[i*4+2],response_memory[i*4+1],response_memory[i*4]} !== 32'h80102100+i) begin
            $display("FAIL score bytes final chunk index=%d",i);
            $finish;
        end
    request_memory[0] = 8'd1;
    request_memory[1] = 8'd0;
    request_memory[2] = 8'd1;
    request_memory[3] = 8'd0;
    request_memory[4] = 8'd1;
    request_memory[5] = 8'd0;
    transact(8'h02,16'd91,16'd0,16'd6,16'd207,8'h82,16'd0,8'd0);
    transact(8'h13,16'd100,16'd79,16'd4,16'd208,8'hff,16'd1,8'd3);
    $display("PASS tb_hog_uart_ctrl: %d transactions, errors/retry/cross-cache/frame/scores",cases);
    $finish;
end''',inst)
    golden=[]
    for gx in range(-255,256):
        for gy in range(-255,256):
            direction,magnitude=gradient_bin(gx,gy)
            golden.append((direction<<10)|magnitude)
    (ROOT/'sim/hog_gradient_golden.mem').write_text(''.join(f'{g:04x}\n' for g in golden))
    tb('tb_hog_math','穷举所有梯度差分组合及除法边界、随机输入和反压', '''//wire  define
wire [9:0] magnitude;
wire [3:0] direction;
wire in_ready;
wire [25:0] quotient;
wire out_valid;
//reg   define
reg sys_clk;
reg sys_rst_n;
reg [7:0] pixel_left;
reg [7:0] pixel_right;
reg [7:0] pixel_up;
reg [7:0] pixel_down;
reg [25:0] numerator;
reg [16:0] denominator;
reg in_valid;
reg out_ready;
reg [13:0] gradient_golden [0:261120];
reg [25:0] expected_quotient;
integer gx;
integer gy;
integer index;
integer count;
integer delay;
integer seed;''', '''always #10 sys_clk = ~sys_clk;

initial begin
    sys_clk = 1'b0;
    sys_rst_n = 1'b0;
    pixel_left = 8'd0;
    pixel_right = 8'd0;
    pixel_up = 8'd0;
    pixel_down = 8'd0;
    numerator = 26'd0;
    denominator = 17'd1;
    in_valid = 1'b0;
    out_ready = 1'b0;
    seed = 20261021;
    index = 0;
    $readmemh("../hog_gradient_golden.mem",gradient_golden);
    for(gx=-255; gx<=255; gx=gx+1)
        for(gy=-255; gy<=255; gy=gy+1) begin
            pixel_left = (gx < 0) ? -gx : 0;
            pixel_right = (gx < 0) ? 0 : gx;
            pixel_up = (gy < 0) ? -gy : 0;
            pixel_down = (gy < 0) ? 0 : gy;
            #1;
            if({direction,magnitude} !== gradient_golden[index]) begin
                $display("FAIL gradient gx=%d gy=%d",gx,gy);
                $finish;
            end
            index = index + 1;
        end
    repeat(6) @(negedge sys_clk);
    sys_rst_n = 1'b1;
    for(count=0; count<512; count=count+1) begin
        @(negedge sys_clk);
        numerator = $random(seed);
        denominator = $random(seed);
        if(count == 0) denominator = 17'd0;
        if(count == 1) denominator = 17'd1;
        if(count == 2) begin
            numerator = 26'h3ffffff;
            denominator = 17'h1ffff;
        end
        expected_quotient = numerator / ((denominator == 0) ? 17'd1 : denominator);
        in_valid = 1'b1;
        if(!in_ready) begin
            $display("FAIL divider input not ready");
            $finish;
        end
        @(negedge sys_clk);
        in_valid = 1'b0;
        delay = 0;
        while(!out_valid && delay < 30) begin
            @(negedge sys_clk);
            delay = delay + 1;
        end
        if(!out_valid || quotient !== expected_quotient) begin
            $display("FAIL divider count=%d actual=%d expected=%d",count,quotient,expected_quotient);
            $finish;
        end
        repeat(3) begin
            @(negedge sys_clk);
            if(!out_valid || quotient !== expected_quotient || in_ready) begin
                $display("FAIL divider backpressure hold");
                $finish;
            end
        end
        out_ready = 1'b1;
        @(negedge sys_clk);
        out_ready = 1'b0;
    end
    $display("PASS tb_hog_math: 261121 gradients, 512 divisions and output stalls");
    $finish;
end''',instance('hog_gradient','hog_gradient_inst',[(p,p) for p in ('pixel_left','pixel_right','pixel_up','pixel_down','magnitude','direction')])+'\n'+instance('hog_unsigned_div','hog_unsigned_div_inst',[(p,p) for p in ('sys_clk','sys_rst_n','numerator','denominator','in_valid','in_ready','quotient','out_valid','out_ready')]))
    print('Generated HOG controller and math verification')


if __name__=='__main__': main()
