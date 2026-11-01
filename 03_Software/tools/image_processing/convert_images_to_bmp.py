import os
import sys
import argparse
from math import gcd
from PIL import Image, ImageOps

def crop_box_for_size(size, target_width=640, target_height=480):
    """Largest integer crop with exactly the target aspect ratio, centered."""
    if target_width <= 0 or target_height <= 0:
        raise ValueError('目标尺寸必须大于0')
    divisor = gcd(target_width, target_height)
    ratio_width, ratio_height = target_width // divisor, target_height // divisor
    units = min(size[0] // ratio_width, size[1] // ratio_height)
    if units < 1:
        raise ValueError('原图太小，无法按目标比例裁切')
    width, height = units * ratio_width, units * ratio_height
    left, top = (size[0] - width) // 2, (size[1] - height) // 2
    return left, top, left + width, top + height

def prepare_image(img, target_width=640, target_height=480, fit='crop', crop_box=None):
    """Crop changes aspect ratio; subsequent resize uses equal X/Y scales."""
    img_rgb = ImageOps.exif_transpose(img).convert('RGB')
    if fit == 'crop':
        box = crop_box or crop_box_for_size(img_rgb.size, target_width, target_height)
        left, top, right, bottom = box
        if not (0 <= left < right <= img_rgb.width and 0 <= top < bottom <= img_rgb.height):
            raise ValueError('裁切区域超出原图范围')
        if (right-left) * target_height != (bottom-top) * target_width:
            raise ValueError('裁切区域必须与目标尺寸比例完全一致')
        img_rgb = img_rgb.crop(box)
    elif fit != 'stretch' or crop_box is not None:
        raise ValueError('fit应为crop或stretch；stretch不支持crop_box')
    return img_rgb.resize((target_width, target_height), Image.Resampling.LANCZOS)

def convert_single_file(input_path, output_path, target_width=640, target_height=480,
                        fit='crop', crop_box=None):
    """
    将单张图片转换为指定分辨率的无压缩 24-bit BMP 格式。
    """
    if not os.path.exists(input_path):
        print(f"[错误] 找不到输入文件: {input_path}")
        return False

    try:
        with Image.open(input_path) as img:
            # 默认先裁切到目标比例，再等比例缩放，避免人物横向/纵向变形。
            img_resized = prepare_image(img, target_width, target_height, fit, crop_box)
            
            # 确保输出后缀为 .bmp
            if not output_path.lower().endswith('.bmp'):
                output_path += '.bmp'

            # 保存为无压缩的 BMP 文件
            img_resized.save(output_path, 'BMP')
            
            print(f"[成功] 转换完成: {input_path} -> {output_path}")
            return True
    except Exception as e:
        print(f"[失败] 转换 {input_path} 时发生错误: {e}")
        return False

def convert_to_bmp(input_dir, output_dir, target_width=640, target_height=480, fit='crop'):
    """
    批量将图片转换为指定分辨率的无压缩 24-bit BMP 格式。
    """
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    supported_formats = ('.png', '.jpg', '.jpeg', '.bmp', '.webp', '.gif')
    files = [f for f in os.listdir(input_dir) if f.lower().endswith(supported_formats)]

    if not files:
        print(f"在目录 '{input_dir}' 中没有找到支持的图片文件。")
        return

    print(f"找到 {len(files)} 个图片文件，开始转换...")
    success_count = 0

    for filename in files:
        input_path = os.path.join(input_dir, filename)
        # 生成输出文件名，确保后缀为 .bmp
        base_name = os.path.splitext(filename)[0]
        output_filename = f"{base_name}_640x480.bmp"
        output_path = os.path.join(output_dir, output_filename)

        try:
            with Image.open(input_path) as img:
                img_resized = prepare_image(img, target_width, target_height, fit)
                
                # 保存为无压缩的 BMP 文件
                img_resized.save(output_path, 'BMP')
                
                print(f"[成功] {filename} -> {output_filename}")
                success_count += 1
        except Exception as e:
            print(f"[失败] 转换 {filename} 时发生错误: {e}")

    print(f"\n转换完成！共成功转换 {success_count} 个文件。")
    print(f"请将 '{output_dir}' 目录下的所有 BMP 文件复制到 TF(SD) 卡的根目录中。")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="FPGA TF卡 BMP 图片转换工具 (640x480, 24位无压缩)")
    parser.add_argument('input', nargs='?', help='输入的图片文件路径 (例如: 1.jpg)')
    parser.add_argument('output', nargs='?', help='输出的BMP文件路径 (例如: 1.bmp)')
    parser.add_argument('--fit', choices=('crop', 'stretch'), default='crop',
                        help='默认crop：裁切后等比例缩放；stretch仅用于复现旧处理')
    parser.add_argument('--crop-box', nargs=4, type=int, metavar=('LEFT', 'TOP', 'RIGHT', 'BOTTOM'),
                        help='指定裁切区域，必须为4:3且位于原图内，仅适用于单文件')
    
    args = parser.parse_args()

    # 如果提供了输入和输出参数，则进行单文件转换
    if args.input and args.output:
        if not convert_single_file(args.input, args.output, fit=args.fit, crop_box=args.crop_box):
            sys.exit(1)
    else:
        # 否则回退到默认的批量转换模式
        current_dir = os.path.dirname(os.path.abspath(__name__))
        default_input = os.path.join(current_dir, "input_images")
        default_output = os.path.join(current_dir, "output_bmp")

        print("=== FPGA TF卡 BMP 图片转换工具 ===")
        print("要求：640x480, 24位无压缩 BMP")
        print("-" * 40)
        print("提示: 你也可以通过命令行参数指定单张图片进行转换，格式如下:")
        print("python convert_images_to_bmp.py <输入文件> <输出文件>")
        print("-" * 40)

        # 检查默认输入目录是否存在，不存在则创建
        if not os.path.exists(default_input):
            os.makedirs(default_input)
            print(f"已创建默认输入目录: {default_input}")
            print(f"请将你需要转换的图片放入该目录中，然后重新运行本脚本。")
            sys.exit(0)

        # 运行批量转换
        if args.crop_box is not None:
            parser.error('--crop-box需要同时提供单文件输入和输出路径')
        convert_to_bmp(default_input, default_output, fit=args.fit)
