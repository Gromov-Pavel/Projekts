"""Create SDR H264/30fps viewing copies; retain original AAC packets and source files."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess

BASE = Path(__file__).resolve().parents[1]
CORPUS = BASE / 'qa/video-corpus-20261018'
DEST = BASE / 'prepared-videos'


def run(args):
    return subprocess.check_output(args, stderr=subprocess.PIPE, text=True)


def probe(path):
    return json.loads(run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)]))


def audio_hash(path):
    return run(['ffmpeg','-v','error','-i',str(path),'-map','0:a:0','-c','copy','-f','hash','-hash','sha256','-']).strip()


def prepare(row):
    source = Path(row['path'])
    dest = DEST / (source.stem + '-PACE.mp4')
    partial = dest.with_suffix('.partial.mp4')
    before = probe(source)
    video = next(s for s in before['streams'] if s['codec_type'] == 'video')
    audio = next(s for s in before['streams'] if s['codec_type'] == 'audio')
    if audio['codec_name'] != 'aac':
        raise ValueError('Original audio must be AAC for packet-preserving copies')
    rotation = next((s.get('rotation',0) for s in video.get('side_data_list',[]) if 'rotation' in s),0)
    width,height = video['width'],video['height']
    if int(rotation) % 180: width,height=height,width
    max_width,max_height = (720,1280) if height > width else (1280,720)
    scale = min(1,max_width/width,max_height/height)
    out_width,out_height = max(2,int(width*scale)//2*2),max(2,int(height*scale)//2*2)
    if video.get('color_transfer') in ('arib-std-b67','smpte2084'):
        filters = f'zscale=w={out_width}:h={out_height}:t=linear:npl=100,format=gbrpf32le,tonemap=tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p,fps=30'
    else:
        filters = f'scale={out_width}:{out_height},format=yuv420p,fps=30'
    try:
        run(['ffmpeg','-v','error','-y','-threads','2','-i',str(source),'-map','0:v:0','-map','0:a:0','-vf',filters,'-filter_threads','2','-c:v','libx264','-threads','2','-preset','veryfast','-crf','22','-c:a','copy','-movflags','+faststart',str(partial)])
        after = probe(partial)
        result = next(s for s in after['streams'] if s['codec_type']=='video')
        result_audio = next(s for s in after['streams'] if s['codec_type']=='audio')
        assert result['codec_name']=='h264' and result['width']<=max_width and result['height']<=max_height
        assert result['pix_fmt']=='yuv420p' and result_audio['codec_name']=='aac'
        num,den = map(int,result['avg_frame_rate'].split('/'))
        assert num/den <= 30.05
        assert abs(float(before['format']['duration'])-float(after['format']['duration'])) < .25
        old_relative = float(audio.get('start_time',0))-float(video.get('start_time',0))
        new_relative = float(result_audio.get('start_time',0))-float(result.get('start_time',0))
        assert abs(old_relative-new_relative)<.04
        original_audio_hash = audio_hash(source)
        assert original_audio_hash == audio_hash(partial), 'AAC packets changed'
        assert hashlib.file_digest(source.open('rb'),'sha256').hexdigest()==row['sha256'], 'Source modified'
        partial.replace(dest)
        print(f'Prepared {source.name}',flush=True)
        return {'source':str(source),'sourceSHA256':row['sha256'],'copy':str(dest),'width':result['width'],'height':result['height'],'fps':num/den,'audioPackets':original_audio_hash,'audioVideoOffsetDifference':new_relative-old_relative,'duration':after['format']['duration'],'bytes':dest.stat().st_size}
    finally:
        if partial.exists(): partial.unlink()


def main():
    DEST.mkdir(exist_ok=True)
    rows=json.loads((CORPUS/'inventory.json').read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(prepare,rows))
    (DEST/'manifest.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    print(f'Validated {len(results)} viewing copies; AAC packets unchanged.',flush=True)


if __name__=='__main__': main()
