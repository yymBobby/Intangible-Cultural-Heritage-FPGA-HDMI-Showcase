"""Portable selected regressions against the release RTL; no FPGA source edits."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,sys

ROOT=Path(__file__).resolve().parents[1]
SIM=Path(__file__).resolve().parent
H=ROOT/'01_FPGA_Project/src/user_source/hdl_source'
PROJ=ROOT/'01_FPGA_Project/src/td_project'
CTRL=[H/'control'/f for f in ['console_input_filter.v','rotary_console_input.v','menu_ui_state.v','menu_ui_state_v2.v','board_menu_input.v']]
RAM=[SIM/'sim_bram.v',PROJ/'al_ip/OSD_FONT_BITS.v',PROJ/'al_ip/OSD_FONT_ROM.v']
CASES={
 'browse_queue':('tb_browse_queue',[H/'SD/resource_v3_runtime.v'],SIM/'browse/tb_browse_queue.sv','Accelerated queue counters; eight slots including active command, full lock and FIFO ordering.'),
 'browse_rate':('tb_browse_rate',[H/'SD/resource_v3_runtime.v'],SIM/'browse/tb_browse_rate.sv','Production 40 MHz / 6,000,000-cycle (150 ms) admission boundary.'),
 'browse_transition':('tb_browse_transition',[H/'OSD/image_transition_commit.v'],SIM/'browse/tb_browse_transition.sv','Two clock domains with accelerated frame events; 32/16 updates and transaction handshakes.'),
 'browse_controls':('tb_browse_controls',CTRL,SIM/'browse/tb_browse_controls.sv','Release rotary-click theme control, joystick picture/pan and menu routing; accelerated input filters.'),
 'alarm_control':('tb_alarm_control',[H/'control/exhibit_alarm_control.v',H/'control/alarm_buzzer.v'],SIM/'alarm/tb_alarm_control.sv','Accelerated alarm/buzzer timing; leave, silence, return, and rearm.'),
 'alarm_controls':('tb_alarm_controls',CTRL+[H/'control/exhibit_alarm_control.v'],SIM/'alarm/tb_alarm_controls.sv','First press silences/consumes event; subsequent browsing and menu input resumes.'),
 'alarm_osd':('tb_alarm_osd',RAM+[H/'OSD/osd_menu_layer.v',H/'visualizer/video_brightness.v'],SIM/'alarm/tb_alarm_osd.sv','Actual released font wrapper/MIF with portable BRAM model; warning overlay and brightness.'),
 'contrast_math':('tb_contrast_math',[H/'visualizer/image_contrast.v'],SIM/'image/tb_contrast_math.sv','Channel arithmetic, rounding, saturation and synchronous metadata.'),
 'contrast_ui':('tb_contrast_ui',[H/'control/menu_ui_state_v2.v'],SIM/'image/tb_contrast_ui.sv','Four contrast levels, clamped endpoints and defaults.'),
 'cache_scheduler':('tb_image_cache_scheduler',[H/'SD/image_cache_scheduler.v'],SIM/'cache/tb_image_cache_scheduler.sv','Six-slot tag/hit/prefetch/slot protection logic with modeled loader responses.'),
 'cached_image_loader':('tb_cached_image_loader',[H/'OSD/image_text_loader.v',H/'OSD/osd_text_loader.v',H/'OSD/bmp_resource_loader.v'],SIM/'cache/tb_cached_image_loader.sv','Modeled resource/write responders; cache hit skips BMP write and retains text work.'),
 'fft_bands':('tb_fft_band_ram',[SIM/'sim_bram.v',H/'visualizer/audio_fft512.v'],SIM/'audio/tb_fft_band_ram.sv','RAM FFT against legacy fixed-point RTL reference; nine stimuli and 288 band comparisons.'),
}
def executable(name,folder):
    if folder:
        p=folder/(name+('.exe' if os.name=='nt' else ''))
        if p.is_file():return str(p)
    p=shutil.which(name)
    if not p:raise SystemExit(f'{name} not found. Install Icarus Verilog or pass --iverilog-bin PATH.')
    return p
def sources(name):
    top,rtl,bench,scope=CASES[name]
    return top,rtl+[bench],scope
def modelsim(name,out):
    top,files,scope=sources(name)
    out.mkdir(parents=True,exist_ok=True)
    lib=(out/'work').as_posix()
    q=lambda p:'{'+Path(p).as_posix()+'}'
    lines=['# '+scope,'onerror {quit -code 1}',f'cd {q(PROJ)}',f'if {{![file exists {q(lib)}]}} {{vlib {q(lib)}}}',f'vmap public_showcase_work {q(lib)}',
       'vlog -sv -work public_showcase_work +define+SIMULATION '+ ' '.join('+incdir+'+q(p) for p in [H/'OSD',H/'visualizer',SIM/'cache'])+' '+' '.join(q(f) for f in files),
       f'vsim -voptargs=+acc -wlf {q(out/(name+".wlf"))} public_showcase_work.{top}',
       'add wave -r /*','run -all','# Inspect waveform in the GUI; use quit -sim when finished.']
    script=out/'run_modelsim.do';script.write_text('\n'.join(lines)+'\n',encoding='utf8')
    return script
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case',action='append',choices=sorted(CASES),help='Repeat for multiple cases; omitted runs all.')
    p.add_argument('--list',action='store_true')
    p.add_argument('--iverilog-bin',type=Path)
    p.add_argument('--output-dir',type=Path,default=SIM/'output')
    p.add_argument('--emit-modelsim',action='store_true',help='Write .do scripts instead of invoking Icarus.')
    a=p.parse_args()
    if a.list:
        for name in CASES:print(name+': '+CASES[name][3])
        return
    names=a.case or list(CASES)
    if a.emit_modelsim:
        for name in names:print(modelsim(name,a.output_dir/name))
        return
    iverilog=executable('iverilog',a.iverilog_bin);vvp=executable('vvp',a.iverilog_bin)
    result={'status':'INCOMPLETE','scope':'Selected RTL logic regressions; portable BRAM model, not vendor timing/PHY simulation or board validation.','cases':{}}
    a.output_dir.mkdir(parents=True,exist_ok=True)
    fingerprints={f:hashlib.sha256(f.read_bytes()).hexdigest() for name in names for f in sources(name)[1]}
    try:
        for name in names:
            top,files,scope=sources(name);out=a.output_dir/name;out.mkdir(parents=True,exist_ok=True)
            before={f for f in PROJ.iterdir() if f.suffix.lower() in ['.vcd','.ppm','.csv']}
            exe=out/(name+'.vvp');args=[iverilog,'-g2012','-DSIMULATION','-I',str(H/'OSD'),'-I',str(H/'visualizer'),'-I',str(SIM/'cache'),'-s',top,'-o',str(exe),*map(str,files)]
            record={'status':'INCOMPLETE','scope':scope,'sources_sha256':{f.relative_to(ROOT).as_posix():fingerprints[f] for f in files}}
            result['cases'][name]=record
            try:
                for phase,cmd in [('compile',args),('run',[vvp,str(exe)])]:
                    with (out/(phase+'.log')).open('w',encoding='utf8') as log:
                        process=subprocess.run(cmd,cwd=PROJ,stdout=log,stderr=subprocess.STDOUT,timeout=300)
                    text=(out/(phase+'.log')).read_text('utf8',errors='replace')
                    if process.returncode or 'FATAL:' in text or 'ERROR:' in text:raise RuntimeError(name+' '+phase+' failed:\n'+text[-6000:])
                    if phase=='run':
                        passes=[line for line in text.splitlines() if 'PASS:' in line]
                        if not passes:raise RuntimeError(name+' did not report PASS')
                        record['messages']=passes;print(name+': '+' | '.join(passes),flush=True)
                record['status']='PASS'
            finally:
                for f in list(PROJ.iterdir()):
                    if f not in before and f.suffix.lower() in ['.vcd','.ppm','.csv']:shutil.move(str(f),out/f.name)
        for f,digest in fingerprints.items():
            if hashlib.sha256(f.read_bytes()).hexdigest()!=digest:raise RuntimeError('Input changed during simulation: '+str(f))
        result['status']='PASS'
    finally:(a.output_dir/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
if __name__=='__main__':main()
