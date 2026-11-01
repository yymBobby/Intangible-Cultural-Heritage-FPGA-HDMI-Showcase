# 快速使用

## 下载与打开

完整文件位于 [v1.0.1](https://github.com/yymBobby/Intangible-Cultural-Heritage-FPGA-HDMI-Showcase/releases/tag/v1.0.1)。建议首次使用下载全称ZIP，解压到英文目录。用安路 Tang Dynasty 6.2.1 Engineer 打开：

`01_FPGA_Project/src/td_project/Media_AV_Visualizer_Ultimate.al`

这是唯一主工程，保留目录关系即可直接打开，不需要启动脚本。工程源文件、IP、初始化ROM及约束均在 `01_FPGA_Project` 中。重新综合和布线由TD工程界面执行；运行环境和原始签核版本见README。

## 配套上板文件

- BIT：`02_Bitstream/MediaAV_ReedAlarm_Font176_20261026.bit`。
- TF镜像：`04_Media/Ready_To_Flash/showcase_font176.img`，也可独立从发布页下载。
- 新字库ID：`0xCBE17BCF`；175个普通字符，加1个警告图案，物理192槽。

镜像需按原始扇区写卡，不能直接复制到卡内。BIT与IMG必须成套使用。

## 仓库源码与完整发布包

Git仓库保存源码及配置，约50 MiB的IMG和原始媒体不进入提交历史。从源码开始时，将 `media_assets.zip` 解压到仓库根目录；只运行RTL仿真无需下载素材。完整发布ZIP已含全部素材与镜像。

`python 05_Verification/check_package.py` 检查核心文件；补齐素材和IMG后加 `--with-media` 检查完整媒体配套。

## 操作与软件

接线、菜单和报警按压规则见 [Controls_And_Wiring](Controls_And_Wiring.md)。字模生成、裁切与镜像打包见 [Software_Workflow](Software_Workflow.md)。仿真见 [06_Simulation](../06_Simulation/README.md)。
