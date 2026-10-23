"""Offline frame extraction; requires existing numpy and ffmpeg, never plays/uploads audio."""
import json, subprocess, tempfile, wave
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'qa/video-corpus-20261018'

def split(name):
    if name == 'IMG_5604.MOV':
        return 'diagnostic-development'
    return 'holdout' if name.startswith(('IMG_559', 'IMG_560', '20240707_')) else 'development'

def extract(path, index, rate, channels, origin):
    raw = subprocess.run(['ffmpeg','-v','error','-i',path,'-map',f'0:{index}',
        '-f','f32le','-acodec','pcm_f32le','-'], check=True,capture_output=True).stdout
    pcm = np.frombuffer(raw,dtype='<f4').reshape(-1,channels)
    size = round(rate * .02)
    windows = pcm[:len(pcm)//size*size].reshape(-1,size,channels)
    energy = (windows.astype(np.float64)**2).sum(axis=1)
    chosen = energy.argmax(axis=1)
    samples = windows[np.arange(len(windows))[:,None],np.arange(size)[None,:],chosen[:,None]]
    total = energy[np.arange(len(windows)),chosen]
    spectrum = np.abs(np.fft.rfft(samples,axis=1))**2
    hz = np.arange(1250,min(5000,rate/2-250)+1,50)
    bins = np.rint(hz * size / rate).astype(int)
    powers = spectrum[:,bins]
    peak = powers.argmax(axis=1)
    tone = np.minimum(1,2*powers[np.arange(len(powers)),peak]/np.maximum(size*total,1e-30))
    return [[round(origin+i*size/rate,6),round(float(np.sqrt(total[i]/size)),7),
        round(float(tone[i]),6),int(hz[peak[i]]) if total[i] else 0] for i in range(len(windows))]

def groups(frames, threshold=.15):
    output=[]; active=[]
    for frame in frames+[[1e9,0,0,0]]:
        if frame[2]>=threshold and frame[1]>=.001 and (not active or abs(frame[3]-active[-1][3])<=100):
            active.append(frame);continue
        if len(active)>=4:
            output.append(dict(time=active[0][0],duration=round(active[-1][0]-active[0][0]+.02,3),
                rms=round(float(np.median([x[1] for x in active])),5),tone=round(float(np.mean([x[2] for x in active])),3),
                frequency=int(np.median([x[3] for x in active]))))
        active=[frame] if frame[2]>=threshold and frame[1]>=.001 else []
    return output

def self_check():
    # Opposite-phase stereo must retain the tone, not cancel on downmix.
    with tempfile.TemporaryDirectory() as directory:
        path=Path(directory)/'tone.wav'
        x=np.rint(16000*np.sin(2*np.pi*2300*np.arange(3200)/16000)).astype('<i2')
        with wave.open(str(path),'wb') as out:
            out.setnchannels(2);out.setsampwidth(2);out.setframerate(16000)
            out.writeframes(np.column_stack([x,-x]).tobytes())
        frames=extract(str(path),0,16000,2,0)
        assert len(frames)==10 and frames[0][3]==2300
        assert frames[0][1]>.3 and frames[0][2]>.99

def main():
    self_check()
    output=BASE/'audiofeatures';output.mkdir(exist_ok=True)
    summary=[]
    inventory=json.loads((BASE/'inventory.json').read_text())
    (BASE/'split.json').write_text(json.dumps({x['name']:split(x['name']) for x in inventory},indent=2))
    for item in inventory:
        probe=json.loads(subprocess.run(['ffprobe','-v','error','-select_streams','a','-show_entries',
            'stream=index,sample_rate,channels,start_time','-of','json',item['path']],check=True,capture_output=True).stdout)
        for stream in probe['streams']:
            try:
                frames=extract(item['path'],stream['index'],int(stream['sample_rate']),stream['channels'],float(stream.get('start_time',0)))
            except subprocess.CalledProcessError:
                summary.append(dict(name=item['name'],stream=stream['index'],split=split(item['name']),error='No decoder for auxiliary audio track; primary AAC analyzed separately'))
                continue
            name=f"{item['name']}.stream{stream['index']}.json"
            (output/name).write_text(json.dumps(dict(name=item['name'],stream=stream['index'],split=split(item['name']),
                channels=stream['channels'],sampleRate=int(stream['sample_rate']),frontend='max-energy-channel-per20ms-rectangular-FFT-equivalent-Goertzel',
                frameFields=['time','rms','tone','frequencyHz'],frames=frames),separators=(',',':')))
            summary.append(dict(name=item['name'],stream=stream['index'],split=split(item['name']),frames=len(frames),
                candidates=groups(frames),legacyCandidates=groups(frames,.45)))
    (BASE/'spectral-candidates.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps([x for x in summary if x['split']=='development'],indent=2))

if __name__=='__main__':main()
