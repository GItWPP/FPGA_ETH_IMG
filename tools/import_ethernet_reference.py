"""Import the selected ADC_ETH protocol layers once into a new image project."""
from pathlib import Path
import argparse
import re
from format_hdl_layout import format_source

HEADER = '''//--------------------------------------------------------------------------------------------------------
// 模块： {name}
// Type    : synthesizable
// Standard: Verilog 2001 (IEEE1364-2001)
// 功能： {purpose}
// 作者： WANG
// 时间： 26.10.22
//--------------------------------------------------------------------------------------------------------
'''
SIGNAL = '''//********************************************************************//
//****************** Parameter and Internal Signal *******************//
//********************************************************************//
'''
MAIN = SIGNAL.replace('****************** Parameter and Internal Signal *******************', '***************************** Main Code ****************************')
INST = SIGNAL.replace('****************** Parameter and Internal Signal *******************', '*************************** Instantiation **************************')


def styled(text, name, purpose):
    text = re.sub(r'^.*?(?=`timescale)', '', text, count=1, flags=re.S)
    text = HEADER.format(name=name, purpose=purpose) + text
    text = re.sub(r'always\s+@', 'always@', text)
    text = re.sub(r'module\s+'+name, 'module  '+name, text, count=1)
    end = text.index(');', text.index('module')) + 2
    text = text[:end] + '\n\n' + SIGNAL + text[end:]
    positions = [m.start() for m in re.finditer(r'^(?:assign |always@|eth_mac_rx\s)', text, re.M)]
    if positions:
        index = positions[0]
        text = text[:index] + MAIN + text[index:]
    else:
        text = text.replace('\nendmodule', '\n'+MAIN+'\nendmodule')
    # The reference MAC TX declares its decode wires after functions.
    declaration_pattern=r'^(?:\(\*[^\n]+\*\)\n)?(?:wire|reg)\s[^\n]+\n'
    declarations=re.findall(declaration_pattern,text,re.M)
    text=re.sub(declaration_pattern,'',text,flags=re.M)
    index=text.index('//********************************************************************//',text.index('Parameter and Internal Signal')+30)
    index=text.index('\n',index)+1
    text=text[:index]+'\n//wire/reg define\n'+''.join(declarations)+'\n'+text[index:]
    return format_source(text)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference_root',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    purposes={
        'mac/eth_mac':'MAC接收与发送子模块结构连接，复用ADC_ETH协议层',
        'mac/eth_mac_rx':'GMII前导码和以太网帧解析、尾部FCS剥离与CRC32校验',
        'mac/eth_mac_tx':'GMII以太网帧、最短帧补零、CRC32及帧间隔生成',
        'net/eth_udp_rx':'IPv4与UDP地址、长度和校验和检查，拒绝分片与选项',
        'net/eth_udp_tx':'IPv4与UDP报头、非零UDP校验和及负载握手生成',
        'net/eth_tx_arbiter':'ARP优先的整帧仲裁，帧内保持发送源不变',
        'net/eth_arp':'ARP解析、请求应答及单项地址解析缓存',
    }
    for relative,purpose in purposes.items():
        name=Path(relative).name
        target=root/'rtl/ethernet'/f'{name}.v'
        if target.exists():
            raise FileExistsError(target)
        source=(args.reference_root/'rtl'/f'{relative}.v').read_text(encoding='utf-8')
        target.write_text(styled(source,name,purpose),encoding='utf-8')
    source=(root/'rtl/uart_img_top.v').read_text(encoding='utf-8')
    source=source.replace('uart_img_top','img_stream_top')
    source=source.replace('50MHz纯PL串口图像处理顶层，默认1.5Mbps、RGB565分包往返',
                          '与物理传输无关的字节协议、命令分发和全部图像算法封装')
    source=source.replace('// 时间： 26.10.21','// 时间： 26.10.22')
    source=re.sub(r'^    parameter integer (?:CLK_HZ|UART_BPS).*\n','',source,flags=re.M)
    port_start=source.index('    input   wire')
    port_end=source.index('\n);',port_start)
    source=source[:port_start]+'''    input   wire            sys_clk         ,
    input   wire            sys_rst_n       ,
    input   wire    [7:0]   rx_data         ,
    input   wire            rx_valid        ,
    output  wire            rx_ready        ,
    output  wire    [7:0]   tx_data         ,
    output  wire            tx_valid        ,
    input   wire            tx_ready        ,
    output  wire            tx_start_flag   ,
    output  wire    [15:0]  tx_length       ,
    input   wire            tx_start_ready  ,
    output  wire            tx_done_flag'''+source[port_end:]
    source=re.sub(r'^wire\s+(?:\[7:0\]\s+)?(?:rx_byte|tx_byte|rx_flag|rx_error|tx_valid|tx_ready);\n','',source,flags=re.M)
    source=source.replace('wire                    resp_ready;','wire                    resp_ready;\nwire                    packet_tx_ready;')
    start=source.index('\nuart_rx\n')
    end=source.index('\nimg_packet_rx\n',start)
    source=source[:start]+source[end:]
    source=source.replace('assign rst_n = rst_sync[1];','''assign rst_n = rst_sync[1];
assign rx_ready = receive_en && !packet_valid;
assign resp_ready = packet_tx_ready && tx_start_ready;
assign tx_start_flag = resp_valid && resp_ready;
assign tx_length = resp_length + 16'd14;
assign tx_done_flag = resp_done;''')
    source=source.replace('(rx_byte             )','(rx_data             )')
    source=source.replace('(rx_flag             )','(rx_valid && rx_ready)')
    source=source.replace('(rx_error            )',"(1'b0                )")
    source=source.replace('.start_valid        (resp_valid          )','.start_valid        (resp_valid && tx_start_ready)')
    source=source.replace('.start_ready        (resp_ready          )','.start_ready        (packet_tx_ready     )')
    source=source.replace('(tx_byte             )','(tx_data             )')
    (root/'rtl/img_stream_top.v').write_text(format_source(source),encoding='utf-8')
    print('Imported seven Ethernet layers and created the physical-independent algorithm wrapper')


if __name__=='__main__':
    main()
