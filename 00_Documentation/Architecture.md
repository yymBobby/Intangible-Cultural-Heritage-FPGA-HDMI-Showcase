# 系统架构

电脑端负责素材裁切、字符编号和镜像打包；FPGA独立完成运行期读卡、图像处理、音频播放与交互，不依赖电脑实时控制。

1. TF目录在启动时校验并发布资源描述符，图像/字幕与音频通过共享SPI资源服务读取。
2. 六槽调度器在8 MiB SDRAM中保存当前主题四图和邻主题首图，标签命中时跳过重复BMP加载；正在显示或参与转场的槽位受保护。
3. 两条图像读通路分别取景和缩放，按方向合成滑动，或进行两图交叉淡化；对比度、滤镜、OSD及最终全屏亮度按实际顶层通路连接。
4. WAV解析后的PCM分为播放与可视化支路；FFT512结果用于频谱及声场外环，左右样本生成电平和声场点图。
5. 旋钮、摇杆和开关生成控制事件，经菜单与浏览状态解释后形成参数快照和切图请求。
6. 干簧管在控制域完成稳定时间判定与消音门控，像素域显示固定警示，板载蜂鸣器独立鸣响。

## 主要代码入口

相对于 `01_FPGA_Project/src/user_source/hdl_source`：

| 功能 | 入口 |
|---|---|
| 板级主连接 | `top_tf_hdmi_audio.v` |
| 目录/资源服务/运行调度 | `SD/resource_v3_catalog.v`、`resource_v3_service.v`、`resource_v3_runtime.v` |
| 六槽调度 | `SD/image_cache_scheduler.v` |
| 图文加载 | `OSD/image_text_loader.v` |
| 双图动画与提交 | `OSD/image_transition_commit.v`、`video_frame_commit.v` |
| 取景与缩放 | `visualizer/image_viewport_scaler.v`、`image_line_scaler.v` |
| 音频分析 | `visualizer/audio_fft512.v`（含RAM结果接口实现） |
| 实体交互 | `control/board_menu_input.v`、`menu_ui_state_v2.v` |
| 报警 | `control/exhibit_alarm_control.v`、`alarm_buzzer.v` |

时钟域按40 MHz控制、50 MHz存储、75 MHz像素组织；跨域使用同步事件、保持数据握手或FIFO。具体边界见顶层及各模块端口，通用仿真模型不加入综合工程。
