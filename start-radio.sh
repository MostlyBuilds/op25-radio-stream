#!/usr/bin/env bash
# op25-radio-stream entrypoint
#
# This script is the PID 1 inside the container
#   - Reads configuration from environment variables (with sane defaults)
#   - Starts the op25_udp_shim.py process (UDP → continuous PCM over TCP)
#   - Runs OP25 rx.py in a restart loop (decoded audio → UDP)
#   - Runs ffmpeg in a restart loop in the foreground (TCP PCM → AAC over RTSP to MediaMTX)
#
# The container stays "alive" as long as ffmpeg_loop is running.
# All three processes (shim, OP25, ffmpeg) log to stdout/stderr, so
# `docker logs` will show a combined view of everything.
#
# NOTE: This script is intentionally simple. Process supervision is done via
# small restart loops here, not via systemd.

set -euo pipefail

# Simple logger to prefix all entrypoint messages
log() {
  echo "[start-radio.sh] $*"
}

# ------------------------------------------------------------------------------
# 1) Read environment variables (with defaults)
#    These match what's documented in the README and Dockerfile.
# ------------------------------------------------------------------------------

OP25_FREQ="${OP25_FREQ:-463.725e6}"                     # Tune frequency in Hz (e.g. 463.725e6 Hz = 463.725 MHz)
OP25_ARGS="${OP25_ARGS:-rtl}"                           # OP25 --args (e.g. 'rtl', 'rtl=0')
OP25_LNA="${OP25_LNA:-49}"                              # LNA gain (passed via -N "LNA:<value>")
OP25_SAMP_RATE="${OP25_SAMP_RATE:-960000}"              # SDR sample rate in Hz
OP25_OFFSET="${OP25_OFFSET:-17000}"                     # Frequency offset in Hz (OP25 -o)
OP25_UDP_PORT="${OP25_UDP_PORT:-23456}"                 # UDP port where OP25 sends decoded audio
PCM_TCP_PORT="${PCM_TCP_PORT:-19000}"                   # TCP port where the shim exposes continuous PCM
OP25_MIN_BUFFER_MS="${OP25_MIN_BUFFER_MS:-250}"         # Min jitter buffer size in ms (0 = disable jitter buffer)
OP25_UI_PORT="${OP25_UI_PORT:-8080}"                    # HTTP port for OP25 status UI
MEDIAMTX_RTSP_URL="${MEDIAMTX_RTSP_URL:-rtsp://127.0.0.1:8554/op25}"  # RTSP URL on MediaMTX
FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-warning}"           # ffmpeg log level

log "=== op25-radio-stream: starting ==="
log "  Freq:          ${OP25_FREQ}"
log "  OP25 UDP port: ${OP25_UDP_PORT}"
log "  PCM TCP port:  ${PCM_TCP_PORT}"
log "  RTSP target:   ${MEDIAMTX_RTSP_URL}"

# ------------------------------------------------------------------------------
# 2) Start the UDP → continuous-audio shim (op25_udp_shim.py)
#
#    - Listens on OP25_UDP_PORT for decoded audio packets from OP25
#    - Tracks wall-clock time and fills gaps with zeros (silence)
#    - Exposes a continuous 16-bit PCM stream on PCM_TCP_PORT (TCP)
#
#    This runs as a background process; we track its PID so we can kill it
#    cleanly when the container exits.
# ------------------------------------------------------------------------------

log "Starting op25_udp_shim.py shim..."
OP25_UDP_PORT="${OP25_UDP_PORT}" PCM_TCP_PORT="${PCM_TCP_PORT}" \
  /usr/local/bin/op25_udp_shim.py &
PCM_SHIM_PID=$!
log "op25_udp_shim.py running as PID ${PCM_SHIM_PID}"

# Cleanup function called when this script exits (container stop).
# It currently only stops the shim; OP25 and ffmpeg will receive SIGTERM
# naturally when the container is stopped.
cleanup() {
  log "Shutting down op25_udp_shim.py (PID ${PCM_SHIM_PID})..."
  kill "${PCM_SHIM_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 3) OP25 loop (background)
#
#    This function:
#      - Runs OP25 rx.py with the configured args
#      - Sends decoded audio over UDP to OP25_UDP_PORT
#      - Exposes the OP25 web UI on OP25_UI_PORT
#      - If rx.py exits for any reason, it waits 3 seconds and restarts it
#
#    This loop runs in the background so that ffmpeg_loop can run in the
#    foreground and control the container lifecycle.
# ------------------------------------------------------------------------------

op25_loop() {
  while true; do
    log "Starting OP25 rx.py..."
    cd /op25/op25/gr-op25_repeater/apps

    /usr/bin/python3 ./rx.py \
      --args "${OP25_ARGS}" \
      -N "LNA:${OP25_LNA}" \
      -S "${OP25_SAMP_RATE}" \
      -f "${OP25_FREQ}" \
      -o "${OP25_OFFSET}" \
      -q 1 \
      -r 8000 \
      -V \
      -D fsk4 \
      -w -W 127.0.0.1 -u "${OP25_UDP_PORT}" \
      -l "http:0.0.0.0:${OP25_UI_PORT}" \
      -v 8

    # If we get here, rx.py exited (cleanly or due to an error).
    # We simply log and restart it after a short delay.
    log "OP25 exited, restarting in 3 seconds..."
    sleep 3
  done
}

# ------------------------------------------------------------------------------
# 4) ffmpeg loop (foreground)
#
#    - Connects to the shim over TCP (PCM_TCP_PORT) and reads continuous PCM
#    - Normalizes and limits audio, then encodes as AAC
#    - Publishes the stream via RTSP to MEDIAMTX_RTSP_URL
#    - If ffmpeg exits (error/stop), it logs and restarts after 2 seconds
#
#    This loop is run in the foreground at the end of this script, so the
#    container's lifetime is tied to ffmpeg. As long as this loop runs,
#    the container is considered "up".
# ------------------------------------------------------------------------------

ffmpeg_loop() {
  while true; do
    log "Starting ffmpeg → ${MEDIAMTX_RTSP_URL}..."
    ffmpeg -hide_banner -loglevel "${FFMPEG_LOGLEVEL}" \
      -fflags nobuffer -flags low_delay \
      -use_wallclock_as_timestamps 1 \
      -thread_queue_size 32768 \
      -f s16le -ac 1 -ar 8000 -i "tcp://127.0.0.1:${PCM_TCP_PORT}" \
      -filter_complex "\
        [0:a]
          aformat=sample_fmts=s16:channel_layouts=mono,
          aresample=48000:async=1:min_hard_comp=0.100:first_pts=0,
          dynaudnorm=f=301:g=31,
          alimiter=limit=0.9:level=disabled,
          volume=7dB
        [aout]" \
      -map "[aout]" \
      -c:a aac -b:a 64k -ac 1 -ar 48000 \
      -rtsp_transport tcp -rtsp_flags prefer_tcp \
      -muxpreload 0 -muxdelay 0 -flush_packets 1 \
      -f rtsp "${MEDIAMTX_RTSP_URL}"

    # If we get here, ffmpeg exited. We log and restart it after a short delay.
    # This keeps the pipeline resilient if MediaMTX or the network hiccups.
    log "ffmpeg exited, restarting in 3 seconds..."
    sleep 3
  done
}

# ------------------------------------------------------------------------------
# 5) Kick everything off
#
#    - Start OP25 in the background (restart loop)
#    - Run ffmpeg_loop in the foreground (controls container lifecycle)
# ------------------------------------------------------------------------------

op25_loop &    # Run OP25 supervise loop in the background
ffmpeg_loop    # Run ffmpeg supervise loop in the foreground (blocks)
