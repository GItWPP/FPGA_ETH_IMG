"""Create independent HOG session controller and top-level wiring wrappers."""
import re
from generate_algorithm_modules import write, instance, ROOT, RTL

HOG_PORTS='''    output  wire            hog_frame_wr_en,
    output  wire    [16:0]  hog_frame_wr_addr,
    output  wire    [7:0]   hog_frame_wr_data,
    output  wire            hog_start_valid,
    input   wire            hog_start_ready,
    input   wire            hog_done_flag,
    output  wire    [8:0]   hog_score_rd_addr,
    input   wire    [31:0]  hog_score_rd_data,
    input   wire    [31:0]  hog_model_id'''


def controller():
    write('hog_uart_ctrl','HOG灰度上传、计算启动、得分分片读取和最近成功应答重发', '''    input   wire            sys_clk,
    input   wire            sys_rst_n,
    input   wire            cache_clear,
    input   wire            session_clear,
    output  wire            success_flag,
    output  wire            success_start_flag,
    output  wire            receive_en,
    input   wire            packet_valid,
    output  wire            packet_ready,
    input   wire    [7:0]   req_cmd,
    input   wire    [15:0]  req_id,
    input   wire    [15:0]  req_seq,
    input   wire    [15:0]  req_length,
    input   wire    [15:0]  req_crc,
    output  wire    [9:0]   rx_rd_addr,
    input   wire    [7:0]   rx_rd_data,
    output  wire            result_wr_en,
    output  wire    [9:0]   result_wr_addr,
    output  wire    [7:0]   result_wr_data,
    output  wire            resp_valid,
    input   wire            resp_ready,
    output  reg     [7:0]   resp_cmd,
    output  reg     [15:0]  resp_id,
    output  reg     [15:0]  resp_seq,
    output  reg     [15:0]  resp_length,
    input   wire    [9:0]   resp_addr,
    input   wire    [7:0]   result_rd_data,
    output  reg     [7:0]   resp_data,
    input   wire            resp_done,
''' + HOG_PORTS, '''//parameter define
localparam IDLE=5'd0, DISPATCH=5'd1, UP_WAIT=5'd2, UP_GET=5'd3, UP_WRITE=5'd4;
localparam ARG_WAIT=5'd5, ARG_GET=5'd6, ARG_CHECK=5'd7, CORE_REQ=5'd8, CORE_WAIT=5'd9;
localparam SCORE_WAIT=5'd10, SCORE_GET=5'd11, SCORE_WRITE=5'd12;
localparam COMMIT=5'd13, RESP_REQ=5'd14, RESP_WAIT=5'd15;
localparam EMPTY=3'd0, INFO=3'd1, COUNT=3'd2, SCORES=3'd3, ERROR=3'd4;
//wire  define
wire same_key;
wire duplicate_ok;
wire session_ok;
wire sequence_ok;
wire data_ok;
wire run_ok;
wire read_ok;
wire range_ok;
wire [127:0] info_bytes;
//reg   define
reg [4:0] state;
reg [4:0] next_state;
reg [7:0] cmd_reg;
reg [15:0] id_reg;
reg [15:0] seq_reg;
reg [15:0] len_reg;
reg [15:0] crc_reg;
reg active;
reg result_valid;
reg [15:0] session_id;
reg [15:0] next_seq;
reg [16:0] received_bytes;
reg [9:0] byte_index;
reg [7:0] upload_data;
reg [1:0] arg_index;
reg [15:0] read_offset;
reg [15:0] read_count;
reg [8:0] score_index;
reg [1:0] score_byte;
reg [31:0] score_data;
reg [2:0] resp_kind;
reg [7:0] error_code;
reg cache_valid;
reg [7:0] cache_cmd;
reg [15:0] cache_id;
reg [15:0] cache_seq;
reg [15:0] cache_len;
reg [15:0] cache_crc;
reg [7:0] cache_resp_cmd;
reg [15:0] cache_resp_length;
reg [2:0] cache_kind;''', '''assign receive_en = (state == IDLE);
assign packet_ready = (state == IDLE);
assign success_flag = (state == COMMIT);
assign success_start_flag = success_flag && (cmd_reg == 8'h10);
assign resp_valid = (state == RESP_REQ);
assign same_key = cache_valid && cmd_reg == cache_cmd && id_reg == cache_id && seq_reg == cache_seq;
assign duplicate_ok = same_key && len_reg == cache_len && crc_reg == cache_crc;
assign session_ok = active && id_reg == session_id;
assign sequence_ok = session_ok && seq_reg == next_seq;
assign data_ok = sequence_ok && !result_valid && len_reg != 16'd0 && len_reg <= 16'd1024
              && {1'b0, received_bytes} + {2'd0, len_reg} <= 18'd76800;
assign run_ok = sequence_ok && !result_valid && len_reg == 16'd0 && received_bytes == 17'd76800;
assign read_ok = sequence_ok && result_valid && len_reg == 16'd4;
assign range_ok = read_count >= 16'd1 && read_count <= 16'd256
               && {1'b0, read_offset} + {1'b0, read_count} <= 17'd495;
assign rx_rd_addr = (state == ARG_WAIT || state == ARG_GET) ? {8'd0, arg_index} : byte_index;
assign hog_frame_wr_en = (state == UP_WRITE);
assign hog_frame_wr_addr = received_bytes + {7'd0, byte_index};
assign hog_frame_wr_data = upload_data;
assign hog_start_valid = (state == CORE_REQ);
assign hog_score_rd_addr = read_offset[8:0] + score_index;
assign result_wr_en = (state == SCORE_WRITE);
assign result_wr_addr = {score_index[7:0], score_byte};
assign result_wr_data = score_data[score_byte * 8 +: 8];
assign info_bytes = {hog_model_id, 8'd1, 8'd8, 8'd128, 8'd64, 16'd240, 16'd320, 32'h31474f48};

always@(*) begin
    next_state = state;
    case(state)
        IDLE: if(packet_valid) next_state = DISPATCH;
        DISPATCH: begin
            next_state = RESP_REQ;
            if(!same_key)
                case(cmd_reg)
                    8'h1f: if(len_reg == 16'd0) next_state = COMMIT;
                    8'h10: if(len_reg == 16'd0 && seq_reg == 16'd0) next_state = COMMIT;
                    8'h11: if(data_ok) next_state = UP_WAIT;
                    8'h12: if(run_ok) next_state = CORE_REQ;
                    8'h13: if(read_ok) next_state = ARG_WAIT;
                    default: next_state = RESP_REQ;
                endcase
        end
        UP_WAIT: next_state = UP_GET;
        UP_GET: next_state = UP_WRITE;
        UP_WRITE: next_state = ({6'd0, byte_index} + 16'd1 == len_reg) ? COMMIT : UP_WAIT;
        ARG_WAIT: next_state = ARG_GET;
        ARG_GET: next_state = (arg_index == 2'd3) ? ARG_CHECK : ARG_WAIT;
        ARG_CHECK: next_state = range_ok ? SCORE_WAIT : RESP_REQ;
        CORE_REQ: if(hog_start_ready) next_state = CORE_WAIT;
        CORE_WAIT: if(hog_done_flag) next_state = COMMIT;
        SCORE_WAIT: next_state = SCORE_GET;
        SCORE_GET: next_state = SCORE_WRITE;
        SCORE_WRITE: if(score_byte == 2'd3)
                         next_state = ({7'd0, score_index} + 16'd1 == read_count) ? COMMIT : SCORE_WAIT;
        COMMIT: next_state = RESP_REQ;
        RESP_REQ: if(resp_ready) next_state = RESP_WAIT;
        RESP_WAIT: if(resp_done) next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

//状态与BRAM地址/使能链统一同步复位；请求和会话寄存器分开维护
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        state <= IDLE;
    else
        state <= next_state;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cmd_reg <= 8'd0;
        id_reg <= 16'd0;
        seq_reg <= 16'd0;
        len_reg <= 16'd0;
        crc_reg <= 16'd0;
        resp_id <= 16'd0;
        resp_seq <= 16'd0;
    end else if(state == IDLE && packet_valid) begin
        cmd_reg <= req_cmd;
        id_reg <= req_id;
        seq_reg <= req_seq;
        len_reg <= req_length;
        crc_reg <= req_crc;
        resp_id <= req_id;
        resp_seq <= req_seq;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        active <= 1'b0;
        result_valid <= 1'b0;
        session_id <= 16'd0;
        next_seq <= 16'd0;
        received_bytes <= 17'd0;
    end else if(session_clear) begin
        active <= 1'b0;
        result_valid <= 1'b0;
    end else if(state == COMMIT && cmd_reg == 8'h10) begin
        active <= 1'b1;
        result_valid <= 1'b0;
        session_id <= id_reg;
        next_seq <= 16'd1;
        received_bytes <= 17'd0;
    end else if(state == COMMIT && cmd_reg == 8'h11) begin
        received_bytes <= received_bytes + {1'b0, len_reg};
        next_seq <= next_seq + 1'b1;
    end else if(state == COMMIT && cmd_reg == 8'h12) begin
        result_valid <= 1'b1;
        next_seq <= next_seq + 1'b1;
    end else if(state == COMMIT && cmd_reg == 8'h13)
        next_seq <= next_seq + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        byte_index <= 10'd0;
    else if(state == DISPATCH)
        byte_index <= 10'd0;
    else if(state == UP_WRITE)
        byte_index <= byte_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        upload_data <= 8'd0;
    else if(state == UP_GET)
        upload_data <= rx_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        arg_index <= 2'd0;
    else if(state == DISPATCH)
        arg_index <= 2'd0;
    else if(state == ARG_GET)
        arg_index <= arg_index + 1'b1;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        read_offset <= 16'd0;
        read_count <= 16'd0;
    end else if(state == ARG_GET)
        case(arg_index)
            2'd0: read_offset[7:0] <= rx_rd_data;
            2'd1: read_offset[15:8] <= rx_rd_data;
            2'd2: read_count[7:0] <= rx_rd_data;
            2'd3: read_count[15:8] <= rx_rd_data;
            default: read_count <= 16'd0;
        endcase

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        score_index <= 9'd0;
        score_byte <= 2'd0;
    end else if(state == DISPATCH) begin
        score_index <= 9'd0;
        score_byte <= 2'd0;
    end else if(state == SCORE_WRITE) begin
        score_byte <= score_byte + 1'b1;
        if(score_byte == 2'd3) score_index <= score_index + 1'b1;
    end

//完整读出后才进入SCORE_WRITE，未初始化数据由状态有效性屏蔽；避免复位吸收进BRAM输出寄存器
always@(posedge sys_clk)
    if(state == SCORE_GET)
        score_data <= hog_score_rd_data;

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        resp_cmd <= 8'd0;
        resp_length <= 16'd0;
        resp_kind <= EMPTY;
    end else if(state == DISPATCH) begin
        resp_cmd <= 8'hff;
        resp_length <= 16'd1;
        resp_kind <= ERROR;
        if(duplicate_ok) begin
            resp_cmd <= cache_resp_cmd;
            resp_length <= cache_resp_length;
            resp_kind <= cache_kind;
        end else if(!same_key) begin
            if(cmd_reg == 8'h1f && len_reg == 16'd0) begin
                resp_cmd <= 8'h9f;
                resp_length <= 16'd16;
                resp_kind <= INFO;
            end else if(cmd_reg == 8'h10 && len_reg == 16'd0 && seq_reg == 16'd0) begin
                resp_cmd <= 8'h90;
                resp_length <= 16'd0;
                resp_kind <= EMPTY;
            end else if(cmd_reg == 8'h11 && data_ok) begin
                resp_cmd <= 8'h91;
                resp_length <= 16'd0;
                resp_kind <= EMPTY;
            end else if(cmd_reg == 8'h12 && run_ok) begin
                resp_cmd <= 8'h92;
                resp_length <= 16'd2;
                resp_kind <= COUNT;
            end
        end
    end else if(state == ARG_CHECK && range_ok) begin
        resp_cmd <= 8'h93;
        resp_length <= read_count << 2;
        resp_kind <= SCORES;
    end

always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        error_code <= 8'd0;
    else if(state == ARG_CHECK && !range_ok)
        error_code <= 8'd2;
    else if(state == DISPATCH) begin
        if(same_key)
            error_code <= 8'd6;
        else if(cmd_reg == 8'h10 || cmd_reg == 8'h1f)
            error_code <= 8'd2;
        else if(cmd_reg >= 8'h11 && cmd_reg <= 8'h13) begin
            if(!session_ok) error_code <= 8'd3;
            else if(!sequence_ok) error_code <= 8'd4;
            else error_code <= 8'd5;
        end else
            error_code <= 8'd1;
    end

//仅另一路成功提交使缓存失效，错误请求不破坏可重发的最近结果
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0) begin
        cache_valid <= 1'b0;
        cache_cmd <= 8'd0;
        cache_id <= 16'd0;
        cache_seq <= 16'd0;
        cache_len <= 16'd0;
        cache_crc <= 16'd0;
        cache_resp_cmd <= 8'd0;
        cache_resp_length <= 16'd0;
        cache_kind <= EMPTY;
    end else if(cache_clear)
        cache_valid <= 1'b0;
    else if(state == COMMIT) begin
        cache_valid <= 1'b1;
        cache_cmd <= cmd_reg;
        cache_id <= id_reg;
        cache_seq <= seq_reg;
        cache_len <= len_reg;
        cache_crc <= crc_reg;
        cache_resp_cmd <= resp_cmd;
        cache_resp_length <= resp_length;
        cache_kind <= resp_kind;
    end

always@(*) begin
    resp_data = 8'd0;
    case(resp_kind)
        INFO: resp_data = info_bytes[resp_addr[3:0] * 8 +: 8];
        COUNT: resp_data = (resp_addr == 10'd0) ? 8'hef : 8'h01;
        SCORES: resp_data = result_rd_data;
        ERROR: resp_data = error_code;
        default: resp_data = 8'd0;
    endcase
end''')


def wrappers():
    old=(RTL/'img_ctrl.v').read_text(encoding='utf-8')
    if not re.search(r'\binput\s+wire\s+cache_clear\b', old):
        old=old.replace('    output  wire             receive_en', '''    input   wire             cache_clear       ,
    input   wire             session_clear     ,
    output  wire             success_flag      ,
    output  wire             success_start_flag,
    output  wire             receive_en''',1)
        old=old.replace('assign receive_en', '''assign success_flag = (state == COMMIT);
assign success_start_flag = success_flag && (cmd_reg == CMD_START);
assign receive_en''',1)
        old=old.replace('    end else if(state == ARG_CHECK && start_legal) begin\n        active', '''    end else if(session_clear)
        active <= 1'b0;
    else if(state == ARG_CHECK && start_legal) begin
        active''',1)
        old=old.replace('    end else if(state == COMMIT) begin\n        cache_valid', '''    end else if(cache_clear)
        cache_valid <= 1'b0;
    else if(state == COMMIT) begin
        cache_valid''',1)
        (RTL/'img_ctrl.v').write_text(old,encoding='utf-8')
    porttext=old.split('\n(\n',1)[1].split('\n);',1)[0]
    porttext='\n'.join(line for line in porttext.splitlines() if not any(k in line for k in ('cache_clear','session_clear','success_flag','success_start_flag')))
    porttext=re.sub(r'output  reg', 'output  wire',porttext)
    ports=re.findall(r'(input|output)\s+(?:wire|reg)\s*(\[[^]]+\])?\s*(\w+)',porttext)
    sharedout=('receive_en','packet_ready','rx_rd_addr','result_wr_en','result_wr_addr','result_wr_data','resp_valid','resp_cmd','resp_id','resp_seq','resp_length','resp_data')
    decl=['//wire  define','wire route_hog;','wire image_success;','wire image_start_success;','wire hog_success;','wire hog_start_success;']
    for direction,width,name in ports:
        if name in sharedout:
            for prefix in ('image','hog'): decl.append(f'wire {width or ""} {prefix}_{name};')
    decl+=['//reg   define','reg owner_hog;']
    body='''assign route_hog = (req_cmd[7:4] == 4'h1);
assign receive_en = image_receive_en && hog_receive_en;
assign packet_ready = image_packet_ready && hog_packet_ready;

//共享RAM和应答端口在接受整包时锁存所有者，整个事务期间保持
always@(posedge sys_clk)
    if(sys_rst_n == 1'b0)
        owner_hog <= 1'b0;
    else if(packet_valid && packet_ready)
        owner_hog <= route_hog;
'''
    for name in sharedout:
        if name not in ('receive_en','packet_ready'):
            body+=f'assign {name} = owner_hog ? hog_{name} : image_{name};\n'
    mappings=[]
    for direction,width,name in ports:
        value=name
        if name in sharedout: value='image_'+name
        if name=='packet_valid': value='packet_valid && packet_ready && !route_hog'
        if name in ('resp_ready','resp_done'): value=name+' && !owner_hog'
        mappings.append((name,value))
    mappings += [('cache_clear','hog_success'),('session_clear','hog_start_success'),('success_flag','image_success'),('success_start_flag','image_start_success')]
    image_inst=instance('img_ctrl','image_ctrl_inst',mappings)
    image_inst=image_inst.replace('img_ctrl\n','img_ctrl\n#(\n    .MAX_WIDTH (MAX_WIDTH),\n    .MAX_HEIGHT (MAX_HEIGHT)\n)\n',1)
    mappings=[]
    for direction,width,name in ports:
        if name.startswith('pixel_'): continue
        value=name
        if name in sharedout: value='hog_'+name
        if name=='packet_valid': value='packet_valid && packet_ready && route_hog'
        if name in ('resp_ready','resp_done'): value=name+' && owner_hog'
        mappings.append((name,value))
    mappings += [('cache_clear','image_success'),('session_clear','image_start_success'),('success_flag','hog_success'),('success_start_flag','hog_start_success')]
    mappings +=[(name,name) for name in re.findall(r'\b(hog_\w+)\s*[,\n]?',HOG_PORTS)]
    write('img_command_top','普通图像与独立HOG命令分发，共享缓存仲裁及跨会话失效',porttext.rstrip()+',\n'+HOG_PORTS,'\n'.join(decl),body,image_inst+'\n'+instance('hog_uart_ctrl','hog_uart_ctrl_inst',mappings))
    path=RTL/'img_command_top.v'
    path.write_text(path.read_text(encoding='utf-8').replace('module  img_command_top\n(','''module  img_command_top
#(
    parameter integer MAX_WIDTH = 1920,
    parameter integer MAX_HEIGHT = 1080
)
('''),encoding='utf-8')
    pixel=(RTL/'img_pixel_proc.v').read_text(encoding='utf-8')
    pp=pixel.split('\n(\n',1)[1].split('\n);',1)[0]
    pp=re.sub('output  reg','output  wire',pp)
    pm=[(p,p) for p in re.findall(r'(?:input|output)\s+(?:wire|reg)\s*(?:\[[^]]+\])?\s*(\w+)',pp)]
    coreports=HOG_PORTS.replace('output','TEMP').replace('input','output').replace('TEMP','input')
    hm=[('sys_clk','sys_clk'),('sys_rst_n','sys_rst_n')]+[(name[4:],name) for name in re.findall(r'\b(hog_\w+)\s*[,\n]?',HOG_PORTS)]
    write('img_process_top','图像处理系统顶层，独立图像算法选择器及HOG检测算法互连',pp.rstrip()+',\n'+coreports,'//wire  define','//各算法在子模块内完成，顶层保持纯互连结构',instance('img_pixel_proc','img_pixel_proc_inst',pm)+'\n'+instance('hog_detect_top','hog_detect_top_inst',hm))
    top=RTL/'uart_img_top.v'
    txt=top.read_text(encoding='utf-8')
    if 'img_process_top\n' not in txt:
        names=re.findall(r'\b(hog_\w+)\s*[,\n]?',HOG_PORTS)
        declarations='\n'.join(re.sub(r'\s*(input|output)\s+wire', 'wire', line).strip().rstrip(',')+';' for line in HOG_PORTS.splitlines())
        txt=txt.replace('//reg   define',declarations+'\n\n//reg   define',1)
        txt=txt.replace('img_pixel_proc\nimg_pixel_proc_inst','img_process_top\nimg_process_top_inst',1)
        txt=txt.replace('img_ctrl\n#(','img_command_top\n#(',1)
        extra=',\n'+',\n'.join(f'    .{n:<22}({n})' for n in names)
        txt=txt.replace('    .out_ready          (pixel_out_ready     )\n);','    .out_ready          (pixel_out_ready     )'+extra+'\n);',1)
        txt=txt.replace('    .resp_done          (resp_done           )\n);','    .resp_done          (resp_done           )'+extra+'\n);',1)
        top.write_text(txt,encoding='utf-8')
    bench=ROOT/'sim/tb_img_ctrl_1080p.v'
    txt=bench.read_text(encoding='utf-8')
    if '.cache_clear' not in txt:
        txt=txt.replace('    .receive_en', '''    .cache_clear        (1'b0),
    .session_clear      (1'b0),
    .success_flag       (),
    .success_start_flag (),
    .receive_en''',1)
        bench.write_text(txt,encoding='utf-8')
    bench=ROOT/'sim/tb_uart_img_top.v'
    txt=bench.read_text(encoding='utf-8').replace('img_ctrl_inst.state','img_ctrl_inst.image_ctrl_inst.state')
    bench.write_text(txt,encoding='utf-8')


if __name__=='__main__':
    controller()
    wrappers()
    print('Generated HOG controller and modular interconnect')
