# Timer and video integration spike — 2026-10-18

## Decision


## Evidence and confidence

- **Manufacturer, protocol compatibility:** Special Pie says its protocol changed and temporarily broke M1A2+ synchronization, restored with PractiScore2 2.3.15+319. Therefore identify firmware per timer and qualify versions separately. [Manufacturer notice, 2026-08-13](https://special314.com/gongsizixun/274.html).
- **Manufacturer, interoperability:** Bluetooth data transfer to CQS Performance is confirmed on Android and iOS. This confirms an integration exists, not a public SDK or wire contract. [Manufacturer notice, 2026-09-18](https://special314.com/gongsizixun/277.html).
- **Manufacturer, firmware:** September update notice links a firmware package and lists compatibility improvements. No firmware was downloaded, changed or flashed. [Manufacturer notice, 2026-09-04](https://special314.com/gongsizixun/276.html).
- **Manufacturer manuals:** English M1A2+ manual and PractiScore2 connection guide are listed. Their CDN PDFs could not be fetched by the web tool; the listing alone establishes no UUID/frame format. [Official downloads, page 2](https://www.specialpiestore.com/download-p2.html).
- **Certification exhibit:** Applicant-supplied RF exposure report describes Bluetooth 4.2 BLE on M1A2 hardware/software V2.0. This is primary test evidence mirrored by FCCID.io, not proof of every older/newer unit. [RF report](https://fccid.io/m/4af153bbfa9d8ad4d856c999c77dce96dd7912b4f32242b46ee25ca0dfaffe2f.pdf), [filing index](https://fccid.io/2BDR4-M1A2).

### Candidate profile from an implementer's own source (not vendor specification)

The independent ESP32 bridge project documents `FFF0` service and `FFF1` notifications, expanded with Bluetooth base UUID `0000xxxx-0000-1000-8000-00805F9B34FB`. Frames use `F8 F9` prefix and `F9 F8` suffix; start/stop types `34`/`18` have six bytes. Its ten-byte `36` shot frame places seconds at byte 4, centiseconds at byte 5 and shot index at byte 6. Byte 7 is unresolved. It claims M1A2 uses name discovery (`SP M1A2 Timer …`), whereas Plus advertises the service. Its documentation says zero-based shot numbering; current model headers say one-based. This conflict must be resolved by capture. No client parser was copied or implemented.

[Protocol document](https://github.com/jkesseler/sg-timer-led-display/blob/de8e30c63daeadc0d116c14b4bc56b89c8d0d8a7/docs/timer-protocols/special-pie-ble.md), [M1A2 header](https://github.com/jkesseler/sg-timer-led-display/blob/de8e30c63daeadc0d116c14b4bc56b89c8d0d8a7/ESP32-S3-firmware/include/SpecialPieM1A2F.h), [Plus header](https://github.com/jkesseler/sg-timer-led-display/blob/de8e30c63daeadc0d116c14b4bc56b89c8d0d8a7/ESP32-S3-firmware/include/SpecialPieM1A2Plus.h).

### CED7000 RF (secondary)

The official-distributor GEN-2 manual describes an optional RF transmitter sending shot data to a CED BigBoard, linked by a four-digit ID. This does not establish direct Android Bluetooth support. Exact user's generation, regional RF variant, receiver and usable output remain unknown. A receiver/bridge or manual import is required until an actual supported interface is documented. Do not treat AUX or a charging port as a shot-data API. [Official-distributor manual](https://www.doublealpha.biz/us/downloads/CED7000%20GEN-2%20User%20Manual.pdf) (indexed text inspected; direct PDF fetch failed).

## Video audio analysis

`analyze_beeps.py` uses installed ffmpeg/ffprobe and Python standard library; no model, installation, network upload or audible playback. It scans mono 16 kHz audio using 20 ms windows and 1.5–5 kHz Goertzel tone concentration. A 3 kHz synthetic onset and silence self-check pass. Results are in `beep-candidates.json`.

| Supplied clip | Duration | Candidate onset | Tonal evidence |
|---|---:|---:|---|
| IMG_2224.MOV | 11.100 s | 0.460 s | 2.3 kHz; 0.52 s stable segment; concentration 0.974 |
| IMG_2252.MOV | 20.867 s | 1.260 s | 2.3 kHz; 0.50 s stable segment; concentration 0.956 |
| 2026-10-18 13.51.20.mp4 | 12.800 s | 2.240 s | 2.3 kHz; interrupted segments through 2.720 s; concentration 0.677–0.915 |

These are **unverified tonal candidates**, not labelled ground truth, probability scores or confirmed run matches. Coarse onset resolution is 20 ms; AAC encoding, echoes, noise, tone frequency outside the search band and clipped audio add uncertainty. All three tracks report start time zero. The third clip has multiple nearby segments; it needs visual/user confirmation rather than silently treating each as a separate start.

The videos are unrelated to the supplied CSV; no association was inferred. User chooses video and run manually. A confirmed beep onset provides `videoTime = beepOnset + timerShotElapsed`; timer shot times remain authoritative. Expose manual onset adjustment and retain whether sync was automatic, confirmed or manual. Do not use acoustic gunshot detection to replace timer timings or Bluetooth packet arrival time as the shot timestamp.

## Exact next actions and release blockers

1. Record each timer's precise model, firmware, advertised name, advertisement bytes and discovered GATT services/properties. Vendor SDK/protocol would be preferable if available; obtaining it must not block read-only captures.
2. Subscribe to observed notification characteristics without speculative control writes. Save timestamped raw hex with timer identity through start, delayed start, first shot, multiple shots, stop, reset and reconnect; photograph timer display for correlation. Resolve index base, time encoding/range, unknown byte, notifications versus framed streams and any firmware differences.
3. Build a versioned parser only from captures/specification, with known vectors and malformed/truncated/duplicate data tests. Preserve raw frames and show unsupported firmware explicitly. Verify no silent losses after reconnect or app backgrounding; do not claim history recovery without evidence.
4. Test one then five physical timers on both devices, interleaving runs and reconnects. Keep run ownership per timer; measure packet loss, connection stability and battery/background behavior. A phone supporting five peripherals does not imply one timer accepts several clients.
5. Label beep onsets on a diverse clip set (quiet/noisy, live/dry fire, other beeps, multiple shooters, missing beep). Validate precision and false positives; verify saved/manual sync survives reopening and imported media access. Three candidate detections alone do not qualify a production auto-sync algorithm.

Skipped firmware modifications, speculative command writes, RF reverse engineering and ML dependencies. Hardware connections, on-device audio extraction and labelled beep accuracy remain unverified.
