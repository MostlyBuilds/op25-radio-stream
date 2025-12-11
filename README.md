# op25-radio-stream
OP25-based P25 radio decoder for RTL-SDR that runs in Docker and streams audio as an always-on RTSP/HLS feed through [MediaMTX](https://github.com/bluenviron/mediamtx)

This is useful for decoding **unencrypted** P25 radio traffic and streaming the
decoded audio across your network, where it can be listened to by other
devices or used as input to other audio processing pipelines.

This setup is designed to monitor a **single frequency** and does not currently
support multiple simultaneous frequencies or trunked radio systems.

Make sure you only monitor and stream signals you are legally allowed to receive in your jurisdiction.

---

## Features

- **P25 voice decode** using the [boatbod OP25 fork](https://github.com/boatbod/op25) + GNU Radio
- **RTL-SDR support** (R820T/R820T2 / RTL2832U dongles)
- **Always-on stream**
  - OP25 only sends raw audio samples when a transmission is received. A small shim (`op25_udp_shim.py`) takes this bursty audio and "smooths" it into a continuous stream by filling silent gaps with zeros, so ffmpeg and MediaMTX always see a steady audio feed.
- **Network streaming**
  - RTSP: `rtsp://host:8554/op25`
  - HLS:  `http://host:8888/op25/index.m3u8`
- **Configurable via environment variables** (frequency, sample rate, offset port, etc.)
- Runs as **two containers**
  - `op25-radio-stream` – RF → OP25 → UDP → shim → ffmpeg → RTSP
  - `mediamtx` – RTSP/HLS/WebRTC server (stock image)

## Architecture

High-level data flow:

```text
RTL-SDR
   │
   ▼
 OP25 (rx.py, GNU Radio)
   │  (8 kHz mono raw audio over UDP)
   ▼
op25_udp_shim.py
(UDP → continuous audio stream with silence fill)
   │  (16-bit PCM over TCP)
   ▼
 ffmpeg
(PCM → AAC over RTSP)
   │
   ▼
 MediaMTX
(RTSP / HLS / WebRTC)
```

## Files

Quick overview of the main files in this repo:

- **`Dockerfile`**
  Builds the `op25-radio-stream` image:
  - Base image: `iqtlabs/gnuradio:3.10.9`
  - Builds `gr-osmosdr` with only the **RTL-SDR** backend enabled
  - Clones and builds `boatbod/op25` (gr310)
  - Installs `op25_udp_shim.py`, `start-radio.sh`, and `ffmpeg`

- **`start-radio.sh`**
  Container entrypoint script
  - Starts `op25_udp_shim.py` (the UDP → continuous-audio shim)
  - Runs OP25 `rx.py` in a loop, sending raw decoded audio out over UDP
  - Runs ffmpeg in a loop, reading continuous audio from the shim and publishing AAC to the MediaMTX RTSP URL

- **`op25_udp_shim.py`**
  The “shim” between OP25 and ffmpeg:
  - Listens for bursty 8 kHz mono raw audio packets from OP25 over UDP
  - Fills gaps between packets with zeros (silence)
  - Exposes a continuous 16-bit PCM audio stream over TCP for ffmpeg

- **`docker-compose.yml`** Example stack definition that runs:
  - `op25-radio-stream` (this image, with RTL-SDR passed through)
  - `mediamtx` (stock MediaMTX image)
  Wired together using `network_mode: host` so RTSP/HLS ports and the RTL-SDR are available on the host.
  - Why `network_mode: host`?
    - `op25-radio-stream` needs direct access to the RTL-SDR via `/dev/bus/usb`
    - `mediamtx` exposes RTSP/HLS/WebRTC ports
    - Using host networking here keeps things simple and reliable
      - The RTL-SDR shows up on the host as usual (no extra container networking tricks).
      - RTSP (`rtsp://host:8554/op25`) and HLS (`http://host:8888/op25/index.m3u8`) are available directly on the host IP without additional port mappings.
      - There’s no extra NAT layer between ffmpeg and MediaMTX, which helps avoid weird edge cases with streaming protocols.

## Environment variables

These environment variables tune the radio and streaming behavior. Change the `OP25_FREQ` to your desired frequency
by setting this value in an environment variable.

| Variable            | Default                      | Description                                                |
|---------------------|------------------------------|------------------------------------------------------------|
| `OP25_FREQ`         | `463.725e6`                  | Tune frequency in Hz (e.g. `463.725e6` Hz = 463.725 MHz)   |
| `OP25_ARGS`         | `"rtl"`                      | OP25 `--args` for source (e.g. `rtl`, `rtl=0`)             |
| `OP25_LNA`          | `"49"`                       | LNA gain value passed via `-N "LNA:<value>"`               |
| `OP25_SAMP_RATE`    | `"960000"`                   | SDR sample rate in Hz                                      |
| `OP25_OFFSET`       | `"17000"`                    | Frequency offset passed via `-o` (Hz)                      |
| `OP25_UDP_PORT`     | `"23456"`                    | UDP port where OP25 sends 8 kHz mono raw audio samples     |
| `PCM_TCP_PORT`      | `"19000"`                    | TCP port where the shim exposes a continuous audio stream  |
| `OP25_MIN_BUFFER_MS`| `"250"`                      | Min jitter buffer size in ms (0 = disable jitter buffer)   |
| `OP25_UI_PORT`      | `"8080"`                     | HTTP port for OP25 status UI                               |
| `MEDIAMTX_RTSP_URL` | `rtsp://127.0.0.1:8554/op25` | RTSP URL ffmpeg publishes to                               |
| `FFMPEG_LOGLEVEL`   | `"warning"`                  | ffmpeg log level (`info`, `debug`, etc.)                   |

## MediaMTX ports

This project uses the **default MediaMTX ports**:

- RTSP: 8554 (`rtsp://host:8554/op25`)
- HLS:  8888 (`http://host:8888/op25/index.m3u8`)

Our `docker-compose.yml` does not override these ports; the stock
[`bluenviron/mediamtx`](https://github.com/bluenviron/mediamtx) image uses its built-in configuration.

If you need to change ports or enable/disable protocols (RTMP, WebRTC, etc.), you’ll need to provide
a custom MediaMTX config file (`mediamtx.yml`) and mount it into the container. See the MediaMTX
documentation for details on configuration and available options.

## Upstream components / pinned commits

This image is built by pinning the SDR stack to specific commits that have been tested together.

Current pinned versions:

- **Base GNU Radio image**: `iqtlabs/gnuradio:3.10.9`
- **gr-osmosdr**: commit `a8d5bccb1aff93740dc4079dabc8524e2912bb9a`
  from [gitea.osmocom.org/sdr/gr-osmosdr](https://gitea.osmocom.org/sdr/gr-osmosdr)
- **boatbod OP25**: commit `c56ed40204e20e1723029982d42ee14089a51239`
  from [github.com/boatbod/op25](https://github.com/boatbod/op25) (branch `gr310`)

These commits are wired into the `Dockerfile` via:

- `GR_OSMOSDR_PINNED_COMMIT`
- `OP25_PINNED_COMMIT`

If you want to update to newer upstream code, change these values in the
`Dockerfile`, rebuild the image, and test with your hardware and frequency
before relying on it.

## Licensing

This project builds and packages the [`boatbod/op25`](https://github.com/boatbod/op25) P25 decoder.
The OP25 source files state that OP25 is licensed under the **GNU General Public License (GPL), version 3 or later**.

All original code and scripts in this repository are also provided under the **GNU General Public License v3.0 or later**.
See [`LICENSE`](LICENSE) for the full text.

If you redistribute Docker images built from this project, you are responsible for complying with the GPL, including providing or linking to the corresponding source code for OP25 and this project.
