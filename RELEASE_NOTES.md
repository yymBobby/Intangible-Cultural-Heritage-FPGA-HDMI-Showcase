正式版本整理自团队开发仓库 `the-second-stage` 提交 `4b0f5f677f5e04a115c8462dd7f8670ccc821645`，保留旋钮点按切换主题的实际控制方式。

## 下载

- `Intangible_Cultural_Heritage_FPGA_HDMI_Showcase_v1.0.0.zip`：完整工程、软件、素材、BIT、IMG、文档和验证记录，首次使用推荐。
- `media_assets.zip`：将素材解压到源码仓库根目录，用于裁切和从零打包。
- `showcase_font176.img`：匹配Font176的原始TF镜像。
- `MediaAV_ReedAlarm_Font176_20261026.bit`：配套FPGA配置文件。
- `showcase_font176.manifest.json`：镜像资源编号、地址与有效长度清单。
- `SHA256SUMS.txt`：以上发布附件的SHA256。

GitHub自动生成的Source code ZIP是源码快照，不包含媒体附件；需要完整可用包时下载上面带项目全称的ZIP。

## 运行

用TD打开 `01_FPGA_Project/src/td_project/Media_AV_Visualizer_Ultimate.al`。使用成套BIT与IMG，接线和控制方式见README及 `00_Documentation`。

生产RTL、IP、ROM、约束、BIT和IMG保持正式来源内容。字库12份输出、16张裁切BMP和完整IMG已重建对拍；精选RTL回归结果与原BIT的资源/STA报告分别存放，完整记录见 `05_Verification`。本次整理不重新运行完整布局布线。

完整镜像SHA256：`ffad4af1597d69f2003d155b96150c66982ae6298492d255a3be9dca66ece929`。

配套BIT SHA256：`a9342657b061af4a1010a02f079b9ff10d42aff9f91fd280084f354adccb4ae6`。
