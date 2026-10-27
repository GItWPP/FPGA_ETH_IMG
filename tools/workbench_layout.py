"""Compact instrument-style controls, paired viewports and green metric displays."""
import socket
import tkinter as tk
from tkinter import ttk

from image_viewer import COLORS, ImageViewer


def local_addresses():
    try:
        return sorted({item[4][0] for item in socket.getaddrinfo(socket.gethostname(),None,socket.AF_INET)
                       if not item[4][0].startswith('127.')})
    except OSError:
        return []


def configure_styles(root):
    style = ttk.Style(root)
    style.theme_use('clam')
    style.configure('.',font=('Microsoft YaHei UI',9),foreground=COLORS['text'])
    for name,color in [('App',COLORS['background']),('Card',COLORS['surface']),('Sidebar',COLORS['background'])]:
        style.configure(f'{name}.TFrame',background=color)
    style.configure('Controls.TLabelframe',background=COLORS['background'],borderwidth=0,relief='flat')
    style.configure('Controls.TLabelframe.Label',background=COLORS['background'],font=('Microsoft YaHei UI',10,'bold'))
    style.configure('Title.TLabel',background=COLORS['background'],font=('Microsoft YaHei UI',16,'bold'))
    for name in ('Subtitle','Status','CardMuted','Card','Side'):
        style.configure(f'{name}.TLabel',background=COLORS['background'],font=('Microsoft YaHei UI',9))
    style.configure('Subtitle.TLabel',foreground=COLORS['muted'])
    style.configure('CardMuted.TLabel',foreground=COLORS['muted'])
    style.configure('TButton',padding=(8,4),background='#FFFFFF',bordercolor='#C4C4C4',relief='flat')
    style.map('TButton',background=[('active','#E5EDF4'),('disabled','#F5F5F5')],foreground=[('disabled','#999999')])
    style.configure('Primary.TButton',background=COLORS['blue'],foreground='white',padding=(10,6))
    style.map('Primary.TButton',background=[('disabled','#B2C8D8'),('active','#145886')],foreground=[('!disabled','white')])
    style.configure('View.TButton',padding=(6,2),font=('Segoe UI',9))
    style.configure('TEntry',padding=3,bordercolor='#C5C5C5')
    style.configure('TCombobox',padding=3,fieldbackground='white',bordercolor='#C5C5C5')
    style.map('TCombobox',fieldbackground=[('readonly','white'),('disabled','#EAEAEA')])
    style.configure('Accent.Horizontal.TProgressbar',background='#16865A',troughcolor='#D0D0D0',borderwidth=0)


def section(parent,title):
    frame = ttk.LabelFrame(parent,text=title,style='Controls.TLabelframe',padding=(0,5,0,0))
    frame.pack(fill='x',pady=(0,12))
    frame.columnconfigure(1,weight=1)
    return frame


def field(parent,label,row,variable):
    ttk.Label(parent,text=label,style='Side.TLabel').grid(row=row,column=0,sticky='w',pady=3,padx=(0,8))
    entry = ttk.Entry(parent,textvariable=variable,width=17)
    entry.grid(row=row,column=1,sticky='ew',pady=3)
    return entry


def build_workbench(app, mode_labels):
    root = app.root
    root.title('FPGA 图像 / 视频工作台 · ZU4EV UDP')
    root.geometry(f'{max(1100,min(1440,root.winfo_screenwidth()-60))}x{max(720,min(850,root.winfo_screenheight()-100))}')
    root.minsize(1100,720)
    root.configure(background=COLORS['background'])
    configure_styles(root)
    outer = ttk.Frame(root,style='App.TFrame',padding=(12,10))
    outer.pack(fill='both',expand=True)
    outer.rowconfigure(0,weight=1)
    outer.columnconfigure(1,weight=1)

    app.settings_panel = ttk.Frame(outer,style='Sidebar.TFrame',width=306)
    app.settings_panel.grid(row=0,column=0,sticky='nsew',padx=(0,14))
    app.settings_panel.pack_propagate(False)
    app.control_canvas = tk.Canvas(app.settings_panel,background=COLORS['background'],highlightthickness=0,width=286)
    scrollbar = ttk.Scrollbar(app.settings_panel,orient='vertical',command=app.control_canvas.yview)
    scrollbar.pack(side='right',fill='y')
    app.control_canvas.pack(side='left',fill='both',expand=True)
    app.control_canvas.configure(yscrollcommand=scrollbar.set)
    panel = ttk.Frame(app.control_canvas,style='Sidebar.TFrame',padding=(2,0,5,0))
    window = app.control_canvas.create_window(0,0,window=panel,anchor='nw')
    panel.bind('<Configure>',lambda event: app.control_canvas.configure(scrollregion=app.control_canvas.bbox('all')))
    app.control_canvas.bind('<Configure>',lambda event: app.control_canvas.itemconfigure(window,width=event.width))

    network = section(panel,'网络 Network')
    ttk.Label(network,text='本机 IP',style='Side.TLabel').grid(row=0,column=0,sticky='w',padx=(0,8),pady=3)
    app.bind_ip_combo = ttk.Combobox(network,textvariable=app.bind_ip,state='readonly',width=17,
                                   values=('自动选择',*local_addresses()))
    app.bind_ip_combo.grid(row=0,column=1,sticky='ew',pady=3)
    app.host_entry = field(network,'FPGA IP',1,app.host)
    app.udp_port_entry = field(network,'UDP 端口',2,app.udp_port)
    app.refresh_button = ttk.Button(network,text='检测连接',command=app.test_connection)
    app.refresh_button.grid(row=3,column=0,columnspan=2,sticky='ew',pady=(5,4))
    ttk.Label(network,textvariable=app.connection_text,style='Subtitle.TLabel',wraplength=266).grid(row=4,column=0,columnspan=2,sticky='w')

    inputs = section(panel,'输入与算法 Processing')
    inputs.columnconfigure(0,weight=1)
    app.open_button = ttk.Button(inputs,text='打开图片',command=app.open_image)
    app.open_button.grid(row=0,column=0,sticky='ew',padx=(0,4))
    app.open_video_button = ttk.Button(inputs,text='打开视频',command=app.open_video)
    app.open_video_button.grid(row=0,column=1,sticky='ew')
    ttk.Label(inputs,textvariable=app.path_text,style='CardMuted.TLabel',wraplength=266).grid(row=1,column=0,columnspan=2,sticky='w',pady=(6,6))
    app.mode_combo = ttk.Combobox(inputs,textvariable=app.mode,values=tuple(mode_labels),state='readonly',width=24)
    app.mode_combo.grid(row=2,column=0,columnspan=2,sticky='ew',pady=(0,6))
    app.mode_combo.bind('<<ComboboxSelected>>',lambda event: app.update_source_preview())
    app.send_button = ttk.Button(inputs,text='发送并处理',style='Primary.TButton',command=app.send,state='disabled')
    app.send_button.grid(row=3,column=0,columnspan=2,sticky='ew',pady=(0,6))
    app.save_button = ttk.Button(inputs,text='保存结果',command=app.save,state='disabled')
    app.save_button.grid(row=4,column=0,columnspan=2,sticky='ew')
    app.binary_button = ttk.Button(inputs,text='查看0/1',command=app.show_binary,state='disabled')
    app.binary_button.grid(row=4,column=1,sticky='ew',padx=(4,0))
    app.binary_button.grid_remove()

    dimensions = section(panel,'尺寸与参数 Parameters')
    app.size_preset = ttk.Combobox(dimensions,state='readonly',width=24,
                                 values=('自动识别原图','手动输入','128×128','320×240','640×480','1280×720','1920×1080'))
    app.size_preset.set('自动识别原图')
    app.size_preset.grid(row=0,column=0,columnspan=2,sticky='ew',pady=(0,5))
    app.size_preset.bind('<<ComboboxSelected>>',app.select_preset)
    sizes = ttk.Frame(dimensions,style='Sidebar.TFrame')
    sizes.grid(row=1,column=0,columnspan=2,sticky='ew')
    app.width_entry = ttk.Entry(sizes,textvariable=app.width,width=6,state='readonly')
    app.width_entry.pack(side='left')
    ttk.Label(sizes,text=' × ',style='Side.TLabel').pack(side='left')
    app.height_entry = ttk.Entry(sizes,textvariable=app.height,width=6,state='readonly')
    app.height_entry.pack(side='left')
    app.original_button = ttk.Button(sizes,text='原图尺寸',command=app.use_original_size)
    app.original_button.pack(side='right')
    for entry in (app.width_entry,app.height_entry):
        entry.bind('<Return>',lambda event: app.update_source_preview())
        entry.bind('<FocusOut>',lambda event: app.update_source_preview() if not app.busy else None)
    app.size_hint = ttk.Label(dimensions,text='最大 1920 × 1080 · RGB565',style='CardMuted.TLabel',wraplength=266)
    app.size_hint.grid(row=2,column=0,columnspan=2,sticky='w',pady=5)
    app.hog_label = ttk.Label(dimensions,text='HOG 阈值',style='Side.TLabel')
    app.hog_label.grid(row=3,column=0,sticky='w')
    app.hog_threshold_entry = ttk.Entry(dimensions,textvariable=app.hog_threshold,width=12)
    app.hog_threshold_entry.grid(row=3,column=1,sticky='ew')
    app.hog_note = ttk.Label(dimensions,text='单尺度全身行人 · 得分非概率',style='CardMuted.TLabel',wraplength=266)
    app.hog_note.grid(row=4,column=0,columnspan=2,sticky='w',pady=(4,0))
    app.band_note = ttk.Label(dimensions,text='Band：近水平点阵，底部两行同步点',style='CardMuted.TLabel',wraplength=266)
    app.band_note.grid(row=3,column=0,columnspan=2,rowspan=2,sticky='w')
    app.band_note.grid_remove()

    app.video_bar = section(panel,'视频播放 Video')
    app.video_size_combo = ttk.Combobox(app.video_bar,textvariable=app.video_size,state='readonly',width=24,
                                      values=('320×240','640×360','640×480','1280×720','1920×1080','原视频尺寸'))
    app.video_size_combo.grid(row=0,column=0,columnspan=2,sticky='ew',pady=(0,5))
    app.video_size_combo.bind('<<ComboboxSelected>>',lambda event: app.update_video_preview())
    app.video_policy_combo = ttk.Combobox(app.video_bar,textvariable=app.video_policy,state='readonly',width=24,
                                        values=('实时播放（跳帧）','逐帧处理（不跳帧）'))
    app.video_policy_combo.grid(row=1,column=0,columnspan=2,sticky='ew',pady=(0,5))
    app.video_bar.columnconfigure(0,weight=1)
    app.video_pause_button = ttk.Button(app.video_bar,text='暂停',command=app.pause_video,state='disabled')
    app.video_pause_button.grid(row=2,column=0,sticky='ew',padx=(0,4))
    app.video_stop_button = ttk.Button(app.video_bar,text='停止',command=app.stop_video,state='disabled')
    app.video_stop_button.grid(row=2,column=1,sticky='ew')
    ttk.Label(app.video_bar,textvariable=app.video_time,style='CardMuted.TLabel').grid(row=3,column=0,columnspan=2,sticky='w',pady=(5,0))
    app.video_bar.pack_forget()

    app.display_controls = section(panel,'视图 Display')
    app.display_controls.columnconfigure(0,weight=1)
    ttk.Button(app.display_controls,text='适应窗口',command=lambda: (app.left_image.fit_image(),app.right_image.fit_image())).grid(row=0,column=0,sticky='ew',padx=(0,4))
    ttk.Button(app.display_controls,text='1:1',command=lambda: (app.left_image.actual_size(),app.right_image.actual_size())).grid(row=0,column=1,sticky='ew')
    ttk.Label(app.display_controls,text='滚轮缩放 · 拖动平移 · 双击复位',style='CardMuted.TLabel',wraplength=266).grid(row=1,column=0,columnspan=2,sticky='w',pady=(5,0))

    main = ttk.Frame(outer,style='App.TFrame')
    main.grid(row=0,column=1,sticky='nsew')
    main.columnconfigure(0,weight=1)
    main.rowconfigure(1,weight=1)
    header = ttk.Frame(main,style='App.TFrame')
    header.grid(row=0,column=0,columnspan=2,sticky='ew',pady=(0,10))
    ttk.Label(header,text='FPGA 图像 / 视频工作台',style='Title.TLabel').pack(side='left')
    app.settings_button = ttk.Button(header,text='隐藏控制',command=app.toggle_settings)
    app.settings_button.pack(side='right')
    views = ttk.Frame(main,style='App.TFrame')
    views.grid(row=1,column=0,columnspan=2,sticky='nsew')
    views.columnconfigure((0,1),weight=1,uniform='view')
    views.rowconfigure(0,weight=1)
    app.left_image = ImageViewer(views,'原始画面','打开图片或视频后查看原始画面',app.open_image)
    app.right_image = ImageViewer(views,'FPGA 处理结果','处理完成后显示对应结果')
    app.left_image.grid(row=0,column=0,sticky='nsew',padx=(0,4))
    app.right_image.grid(row=0,column=1,sticky='nsew',padx=(4,0))

    metrics = ttk.LabelFrame(main,text='运行状态 Metrics',style='Controls.TLabelframe',padding=(0,5,0,0))
    metrics.grid(row=2,column=0,columnspan=2,sticky='ew',pady=(8,4))
    metrics.columnconfigure((0,1,2),weight=1,uniform='metric')
    app.metric_values = {}
    for index,(key,title) in enumerate((('fps','处理帧率  FPS'),('mbps','有效吞吐  Mbps'),('latency','处理耗时  ms'),
                                        ('source_fps','源视频  FPS'),('skipped','跳过帧数'),('retries','重试次数'))):
        card = tk.Frame(metrics,background='#111111',highlightbackground='#454545',highlightthickness=1)
        card.grid(row=index//3,column=index%3,sticky='ew',padx=3,pady=3)
        value = tk.StringVar(value='—')
        app.metric_values[key] = value
        tk.Label(card,text=title,background='#111111',foreground='#00E66A',font=('Microsoft YaHei UI',9)).pack(pady=(4,0))
        tk.Label(card,textvariable=value,background='#111111',foreground='#00FF66',font=('Consolas',16,'bold')).pack(pady=(0,4))
    progress = ttk.Frame(main,style='App.TFrame',height=4)
    progress.grid(row=3,column=0,columnspan=2,sticky='ew',pady=(5,6))
    app.progress = ttk.Progressbar(progress,maximum=100,style='Accent.Horizontal.TProgressbar')
    app.progress.place(relwidth=1,relheight=1)
    app.status_label = ttk.Label(main,textvariable=app.status,style='Status.TLabel',wraplength=700)
    app.status_label.grid(row=4,column=0,sticky='ew')
    ttk.Label(main,textvariable=app.percent_text,style='Subtitle.TLabel').grid(row=4,column=1,sticky='e',padx=(10,0))

    def scroll_controls(event):
        app.control_canvas.yview_scroll(-int(event.delta/120),'units')
        return 'break'
    def bind_scroll(widget):
        widget.bind('<MouseWheel>',scroll_controls)
        for child in widget.winfo_children():
            bind_scroll(child)
    bind_scroll(panel)
