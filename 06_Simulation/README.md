# 精选RTL回归

这组用例从原团队仓库的正式提交筛选，针对本仓库实际RTL运行。安装 Icarus Verilog 后，在仓库根目录运行：

```text
python 06_Simulation/run_tests.py --list
python 06_Simulation/run_tests.py
python 06_Simulation/run_tests.py --case browse_rate
```

程序默认从PATH寻找 `iverilog` 和 `vvp`；Windows可使用 `--iverilog-bin C:/iverilog/bin`。输出日志、VCD、可执行仿真文件及JSON在 `06_Simulation/output`，不会加入Git。执行期间不要让多个仿真进程同时使用同一工程工作目录。

| 用例 | 观察重点 |
|---|---|
| browse_queue | 八条队列、指针回绕、满后锁定与排空恢复 |
| browse_rate | 40 MHz生产参数下150 ms边界，拒绝输入不延长计时 |
| browse_transition | 正反向32/16次更新、取景描述锁定、两域提交握手 |
| browse_controls | 旋钮点按切主题、摇杆切图/平移、菜单隔离 |
| alarm_control / alarm_controls | 稳定时间、两种消音输入、保警与恢复操作 |
| alarm_osd | 真实Font176、半透明背景、警示字形与低亮度保护 |
| contrast_math / contrast_ui | 通道算术、舍入饱和、档位边界与默认恢复 |
| cache_scheduler / cached_image_loader | 六槽保护、缓存命中跳过BMP、字幕仍独立读取 |
| fft_bands | 九组激励、288频带结果和逐周期定点参考对拍 |

## ModelSim

无需PowerShell脚本。先生成所选用例的 `.do` 文件：

```text
python 06_Simulation/run_tests.py --case alarm_control --emit-modelsim
```

在ModelSim的Transcript中执行生成脚本的完整路径：

```tcl
do {D:/your_path/Intangible_Cultural_Heritage_FPGA_HDMI_Showcase/06_Simulation/output/alarm_control/run_modelsim.do}
```

脚本自动建立工作库、编译、添加信号和运行；需要时自行调整信号组合和时间窗口。本轮实际执行的是Icarus回归，生成的ModelSim脚本未代替一次ModelSim工具运行记录。

## 版本适配与验证范围

原 `tb_cached_image_loader.sv` 的激励仍使用旧字库ID `0x7F318820` 和184字符；本仓库只把激励中的ID、字节序字段及字符总数更新为正式Font176值 `0xCBE17BCF` / 175。载荷、CRC错误用例和断言保持原逻辑，生产RTL没有修改。来源及适配哈希见 `05_Verification/simulation_sources.json`。

`sim_bram.v` 是公开的行为模型，只服务于逻辑检查，不是厂商时序模型。部分用例加速消抖或帧事件，只有 `browse_rate` 使用完整150 ms周期数。FFT参考为旧版定点RTL，不是实板音频延迟测量。原BIT的布局布线/STA证据独立保存在 `05_Verification/Github_Signoff`。
