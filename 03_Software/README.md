# 配套软件源码

| 入口 | 用途 |
|---|---|
| `tools/font_rom/generate_font_rom.py` | UTF-8字表与字体文件生成点阵、ROM、编号表 |
| `tools/font_compact/build_assets.py` | 从冻结位图重建发布版175字＋警告图案 |
| `tools/image_processing/convert_images_to_bmp.py` | GitHub原版保比例裁切与BMP转换 |
| `tools/image_processing/batch_crop.py` | 依据16图裁切配置批量调用原转换函数及对拍 |
| `tools/c_phase2/multi_image.py` | 当前ICHSHOW3四主题四图镜像构建、校验与资源提取 |
| `tools/media_pack/build_media_image.py` | 原打包公共解析及格式校验实现；由multi_image导入 |
| `rebuild_image.py` | 现版素材一键生成完整镜像并与官方镜像对拍 |
| `inputs/font176` | 发布字形选择清单及菜单模板 |

操作命令见`../00_Documentation/Software_Workflow.md`。`tools/font_rom/release_alarm_192`供软件重现使用；FPGA综合实际使用`../01_FPGA_Project/tools/font_rom/release_alarm_192`，二者发布初始内容相同，软件运行不会自动改写FPGA工程。
