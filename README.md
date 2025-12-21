# op25-radio-stream

OP25-based P25 radio decoder for RTL-SDR that runs in Docker and streams audio as an
**always-on AAC feed** via **Icecast**, while also publishing to **MediaMTX** for
**RTSP + HLS** playback.

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
- **Always-on audio source**
  - OP25 only emits decoded audio when someone is transmitting.
  - A small shim (`op25_udp_shim.py`) turns OP25’s bursty UDP audio into a continuous PCM stream by
    filling silent gaps with zeros, so downstream tools always see a steady audio feed.
- **Fanout streaming to two “outputs”**
  - A single encoder produces **AAC-in-MPEGTS over UDP multicast**.
  - Two independent publishers subscribe to that multicast:
    - **Publisher A → MediaMTX (RTSP ingest)** → RTSP + HLS for clients
    - **Publisher B → Icecast (HTTP AAC)** → ideal for embedded clients
- **Network endpoints**
  - **Icecast HTTP AAC (ADTS)**: `http://host:8091/op25.aac`
  - **MediaMTX RTSP**: `rtsp://host:8554/op25`
  - **MediaMTX HLS**:  `http://host:8888/op25/index.m3u8`
  - **OP25 status UI**: `http://host:8080/`
- **Optional test audio injection**
  - You can inject raw PCM (s16le, 8 kHz mono) over UDP and the shim will temporarily override OP25 audio.
- **Configurable via environment variables** (frequency, gain, ports, bitrate, etc.)
- Runs as **three containers** (via `docker-compose.yml`)
  - `op25-radio-stream` – RF → OP25 → UDP → shim → encoder → multicast → publishers
  - `mediamtx` – RTSP/HLS server
  - `icecast` – HTTP fanout for AAC clients

---

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
(UDP → continuous PCM over TCP with silence fill)
   │  (16-bit PCM s16le over TCP)
   ▼
 ffmpeg (encoder)
(PCM → AAC → MPEG-TS over UDP multicast)
   │
   ├──────────────► ffmpeg publisher A ──► MediaMTX ──► RTSP + HLS
   │
   └──────────────► ffmpeg publisher B ──► Icecast  ──► HTTP AAC clients
```

---

## Files

Quick overview of the main files in this repo:

- **`Dockerfile`**
  Builds the `op25-radio-stream` image:
  - Base image: `iqtlabs/gnuradio:3.10.9`
  - Builds `gr-osmosdr` with only the **RTL-SDR** backend enabled
  - Clones and builds `boatbod/op25` (branch `gr310`)
  - Installs `op25_udp_shim.py`, `start-radio.sh`, and `ffmpeg`

- **`start-radio.sh`**
  Container entrypoint script:
  - Starts `op25_udp_shim.py` (UDP → continuous PCM over TCP)
  - Runs OP25 `rx.py` in a restart loop (decoded audio → UDP)
  - Runs one **encoder** that publishes **AAC-in-MPEGTS to UDP multicast**
  - Runs two independent **publishers** fed from that multicast:
    - multicast → **MediaMTX** (RTSP ingest)
    - multicast → **Icecast** (HTTP AAC / ADTS)

- **`op25_udp_shim.py`**
  Shim between OP25 and ffmpeg:
  - Listens for bursty 8 kHz mono audio from OP25 over UDP
  - Fills gaps with zeros to keep output continuous
  - Exposes continuous 16-bit PCM (s16le) over TCP for ffmpeg
  - Optional **injection** input for test audio (raw s16le over UDP)

- **`docker-compose.yml`**
  Example stack definition that runs:
  - `op25-radio-stream` (this image, with RTL-SDR passed through)
  - `mediamtx` (MediaMTX server)
  - `icecast` (Icecast server)

  All services use `network_mode: host` so:
  - The RTL-SDR is reachable at `/dev/bus/usb` without extra plumbing
  - MediaMTX ports (8554/8888) are exposed directly on the host
  - Icecast’s listen port (8091 by default here) is exposed directly on the host
  - ffmpeg can publish to MediaMTX and Icecast via `127.0.0.1` with no NAT layer

---

## Environment variables

These environment variables tune the radio, audio pipeline, and publishing behavior.

### Radio + OP25

| Variable             | Default       | Description |
|----------------------|---------------|-------------|
| `OP25_FREQ`          | `463.725e6`   | Tune frequency in Hz (e.g. `463.725e6` Hz = 463.725 MHz) |
| `OP25_ARGS`          | `rtl`         | OP25 `--args` for source (e.g. `rtl`, `rtl=0`) |
| `OP25_LNA`           | `49`          | LNA gain value passed via `-N "LNA:<value>"` |
| `OP25_SAMP_RATE`     | `960000`      | SDR sample rate in Hz |
| `OP25_OFFSET`        | `17000`       | Frequency offset passed via `-o` (Hz) |
| `OP25_UI_PORT`       | `8080`        | HTTP port for OP25 status UI |

### OP25 audio plumbing + shim

| Variable              | Default   | Description |
|-----------------------|-----------|-------------|
| `OP25_UDP_PORT`       | `23456`   | UDP port where OP25 sends 8 kHz mono raw audio samples |
| `PCM_TCP_PORT`        | `19000`   | TCP port where the shim exposes continuous PCM to ffmpeg |
| `OP25_MIN_BUFFER_MS`  | `250`     | Jitter buffer size in ms (0 = disable) |
| `INJECT_UDP_PORT`     | `23457`   | Optional UDP port for injected test audio (s16le, 8 kHz mono) |
| `INJECT_HOLD_MS`      | `750`     | Hold window to keep prioritizing injection after last injected packet |
| `MAX_BUFFER_SECONDS`  | `30`      | Safety cap for internal buffers |

### Encoder (PCM → AAC → MPEG-TS multicast)

| Variable          | Default   | Description |
|------------------|-----------|-------------|
| `AAC_BITRATE`     | `64k`    | AAC bitrate |
| `AAC_SR`          | `44100`  | Output sample rate (Hz) |
| `FFMPEG_LOGLEVEL` | `warning` | ffmpeg log level (`info`, `debug`, etc.) |

### Multicast bus (encoder → publishers)

| Variable      | Default        | Description |
|---------------|----------------|-------------|
| `MCAST_ADDR`  | `239.10.10.10` | UDP multicast address |
| `MCAST_PORT`  | `5004`         | UDP multicast port |
| `MCAST_TTL`   | `1`            | Multicast TTL |

### Publisher targets

MediaMTX (RTSP ingest target used by the MediaMTX publisher process inside `op25-radio-stream`):

| Variable             | Default     | Description |
|----------------------|-------------|-------------|
| `MEDIAMTX_HOST`      | `127.0.0.1` | MediaMTX host |
| `MEDIAMTX_RTSP_PORT` | `8554`      | MediaMTX RTSP port |
| `MEDIAMTX_PATH`      | `/op25`     | Stream path (leading `/` optional) |
| `MEDIAMTX_RTSP_URL`  | *(derived)* | If set, overrides host/port/path composition |

Icecast (SOURCE publish target used by the Icecast publisher process inside `op25-radio-stream`):

| Variable                  | Default     | Description |
|---------------------------|-------------|-------------|
| `ICECAST_HOST`            | `127.0.0.1` | Icecast host |
| `ICECAST_PORT`            | `8091`      | Icecast listen port (matches `docker-compose.yml`) |
| `ICECAST_MOUNT`           | `/op25.aac` | Mountpoint path |
| `ICECAST_SOURCE_PASSWORD` | `hackme`    | SOURCE password for publishing |

### Display-only

| Variable      | Default | Description |
|---------------|---------|-------------|
| `PUBLIC_HOST` | *(empty)* | If set, overrides what host/IP is printed in the startup endpoints |

---

## MediaMTX ports

This project configures MediaMTX (via env vars in `docker-compose.yml`) to use:

- RTSP: **8554** → `rtsp://host:8554/op25`
- HLS:  **8888** → `http://host:8888/op25/index.m3u8`

If you need to change ports or enable/disable protocols (RTMP, WebRTC, etc.), provide
a custom MediaMTX config (`mediamtx.yml`) and mount it, or adjust the MediaMTX env vars
in `docker-compose.yml`.

---

## Icecast port + image

This repo’s `docker-compose.yml` uses:

- **Icecast image**: `majorcadevs/icecast:latest`
- **Listen port**: `8091` (set via `IC_LISTEN_PORT`)

The HTTP AAC stream is served at:

- `http://host:8091/op25.aac`

---

## Testing: injected audio

If you want to test the Icecast / MediaMTX streams without waiting for real OP25 traffic,
inject test audio into the shim.

The shim expects **raw PCM**:
- mono (`-ac 1`)
- 8 kHz (`-ar 8000`)
- signed 16-bit little-endian (`-f s16le`)

Example (run on the host; replace `test.wav`):

```bash
ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i ./test.wav \
  -ac 1 -ar 8000 -f s16le "udp://127.0.0.1:23457?pkt_size=320"
```

Notes:
- `pkt_size=320` is ~20 ms at 8 kHz mono s16le (0.020 * 8000 * 2 = 320 bytes).
- While injection packets are arriving (and for `INJECT_HOLD_MS` afterward), injected audio
  overrides OP25 audio automatically.

---

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

---

## Licensing

This project builds and packages the [`boatbod/op25`](https://github.com/boatbod/op25) P25 decoder.
The OP25 source files state that OP25 is licensed under the **GNU General Public License (GPL), version 3 or later**.

All original code and scripts in this repository are also provided under the **GNU General Public License v3.0 or later**.
See [`LICENSE`](LICENSE) for the full text.

If you redistribute Docker images built from this project, you are responsible for complying with the GPL, including providing or linking to the corresponding source code for OP25 and this project.
