# 软件工具与复现

从源码仓库开始时，先下载正式发布页的 `media_assets.zip` 并解压到仓库根目录。完整发布ZIP已含素材。固定字库重建不依赖媒体；裁切与镜像构建需要补齐媒体目录。

以下命令从包根目录执行。Python建议3.10或以上；裁切和通用字体栅格化需要 `python -m pip install -r 03_Software/requirements.txt`。固定字形重建和镜像打包只使用Python标准库。

## 1. 字符与字库

固定发布版重建：

```powershell
python 03_Software/tools/font_compact/build_assets.py
```

该脚本按`03_Software/inputs/font176/glyph_selection.json`从冻结的旧字形位图选取175字和1个警告图案，重建`03_Software/tools/font_rom/release_alarm_192`。输入清单来自GitHub发布的`mapping_migration.json`，菜单模板来自发布版菜单表。输出的ROM、字形编号、菜单表和报警表应与GitHub发布字库一致。

通用字体栅格化入口为`03_Software/tools/font_rom/generate_font_rom.py`，可读取UTF-8字表及TTF／OTF／TTC，生成32×32或16×16点阵、ROM初始化文件、编号表和预览图。查看参数：

```powershell
python 03_Software/tools/font_rom/generate_font_rom.py --help
```

该通用入口用于后续扩展；更换字体或字表会产生新的字库内容，不能直接假定与最终BIT兼容。复现现版时，使用上面的固定发布版重建命令即可。

## 2. 保比例图片裁切

```powershell
python 03_Software/tools/image_processing/batch_crop.py
```

默认读取`04_Media/crop_recipe.json`及`Image_Sources`中16张原图，调用原GitHub转换函数：先按EXIF校正方向，再使用记录的4:3裁切框，最后等比例LANCZOS缩放为640×480、24位无压缩BMP。输出在`03_Software/output/cropped_images`；每张与GitHub发布BMP做SHA256对拍。

单张转换保留原命令：

```powershell
python 03_Software/tools/image_processing/convert_images_to_bmp.py input.jpg output.bmp --fit crop
```

`--crop-box LEFT TOP RIGHT BOTTOM`可指定符合4:3的取景范围。转换器源码末尾保留了早期“复制BMP到TF根目录”的提示；当前系统使用ICHSHOW3原始扇区镜像，应执行下面的镜像打包，而不是直接复制图片到TF文件系统。

## 3. 完整镜像生成与校验

```powershell
python 03_Software/rebuild_image.py
```

输入为`04_Media/Pack_Input/themes.json`、其`assets`目录中的16份BMP和4份WAV，以及Font176编号表。调用原GitHub `multi_image.py build`，从素材和配置直接生成完整镜像，不依赖输入旧IMG。默认输出在`03_Software/output/image_build`，包括IMG、manifest和验证JSON，并与官方镜像SHA256对拍。

原始命令行入口仍可直接使用：

```powershell
python 03_Software/tools/c_phase2/multi_image.py build 04_Media/Pack_Input/themes.json output.img --glyph-map 03_Software/tools/font_rom/release_alarm_192/glyph_map.json --report output.manifest.json
python 03_Software/tools/c_phase2/multi_image.py verify output.img --glyph-map 03_Software/tools/font_rom/release_alarm_192/glyph_map.json
```

打包和裁切的输出目录须为新目录，防止覆盖发布原件。再次验证可用`--output-dir`指定新目录。软件重建结果不会自动替换`01_FPGA_Project`的ROM或`02_Bitstream`的最终BIT。
