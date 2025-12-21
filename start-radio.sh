#!/usr/bin/env bash
# op25-radio-stream entrypoint
#
# This script is the PID 1 inside the container
#   - Reads configuration from environment variables (with sane defaults)
#   - Starts the op25_udp_shim.py process (UDP → continuous PCM over TCP)
#   - Runs OP25 rx.py in a restart loop (decoded audio → UDP)
#   - Runs ONE encoder (PCM → AAC in MPEG-TS over UDP multicast) in a restart loop
#   - Runs TWO independent publishers fed from that multicast:
#       * publisher A: multicast → MediaMTX (RTSP)
#       * publisher B: multicast → Icecast (HTTP AAC)
#
# Why this structure:
#   - Avoids "tee" weirdness where one output affects the other
#   - Avoids RTP+SDP complexity by using MPEG-TS over UDP multicast
#   - Gives clean fanout:
#       * MediaMTX handles RTSP/HLS
#       * Icecast handles AAC HTTP clients
#
# The container stays "alive" as long as encoder_loop is running.
# All processes log to stdout/stderr, so `docker logs` shows a combined view.

set -euo pipefail

# ------------------------------------------------------------------------------
# 1) Read environment variables (with defaults)
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

FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-warning}"           # ffmpeg log level

# MediaMTX publish target (RTSP ingest) - MediaMTX will fan out RTSP and HLS to clients
# Backward compatible:
#   - If MEDIAMTX_RTSP_URL is set, use it as-is.
#   - Otherwise compose it from host/port/path.
MEDIAMTX_HOST="${MEDIAMTX_HOST:-127.0.0.1}"
MEDIAMTX_RTSP_PORT="${MEDIAMTX_RTSP_PORT:-8554}"
MEDIAMTX_PATH="${MEDIAMTX_PATH:-/op25}"
if [[ "${MEDIAMTX_PATH}" != /* ]]; then
  MEDIAMTX_PATH="/${MEDIAMTX_PATH}"
fi
MEDIAMTX_RTSP_URL="${MEDIAMTX_RTSP_URL:-rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_RTSP_PORT}${MEDIAMTX_PATH}}"

# Icecast publish target (fanout HTTP AAC for embedded)
# NOTE: ffmpeg uses the "icecast://" protocol for SOURCE publishing.
ICECAST_HOST="${ICECAST_HOST:-127.0.0.1}"
ICECAST_PORT="${ICECAST_PORT:-8091}"
ICECAST_MOUNT="${ICECAST_MOUNT:-/op25.aac}"
ICECAST_SOURCE_PASSWORD="${ICECAST_SOURCE_PASSWORD:-hackme}"

# Encoder settings
AAC_BITRATE="${AAC_BITRATE:-64k}"                       # AAC bitrate (e.g. 64k)
AAC_SR="${AAC_SR:-44100}"                               # Output sample rate (Hz)

# Multicast transport between encoder and publishers
# Using MPEG-TS avoids SDP files and makes ffmpeg ingest dead simple.
MCAST_ADDR="${MCAST_ADDR:-239.10.10.10}"
MCAST_PORT="${MCAST_PORT:-5004}"
MCAST_TTL="${MCAST_TTL:-1}"
MCAST_OUT_URL="udp://${MCAST_ADDR}:${MCAST_PORT}?ttl=${MCAST_TTL}&pkt_size=1316"
MCAST_IN_URL="udp://${MCAST_ADDR}:${MCAST_PORT}?fifo_size=640&overrun_nonfatal=1&buffer_size=65536"

# Derived / display variables
HTTP_PORT=8888  # MediaMTX HTTP port (HLS lives here if enabled)

# Public host override (used only for printed client endpoints)
PUBLIC_HOST="${PUBLIC_HOST:-}"
if [[ -n "${PUBLIC_HOST}" ]]; then
  HOST_ADDR="${PUBLIC_HOST}"
else
  HOST_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  HOST_ADDR="${HOST_ADDR:-127.0.0.1}"
fi

ICECAST_URL="http://${HOST_ADDR}:${ICECAST_PORT}${ICECAST_MOUNT}"

# Simple logger to prefix all entrypoint messages
log() {
  echo "[start-radio.sh] $*"
}

log_stream_endpoints() {
  local path_no_trailing="${MEDIAMTX_PATH%/}"

  log "============================================================"
  log "OP25 STREAM ONLINE"
  log ""
  log "MediaMTX path:      ${path_no_trailing}"
  log "Source frequency:   ${OP25_FREQ}"
  log ""
  log "Available endpoints:"
  log ""
  log "  RTSP (VLC, ffplay):"
  log "    rtsp://${HOST_ADDR}:${MEDIAMTX_RTSP_PORT}${path_no_trailing}"
  log ""
  log "  HLS (browser):"
  log "    http://${HOST_ADDR}:${HTTP_PORT}${path_no_trailing}/index.m3u8"
  log ""
  log "  HTTP AAC (embedded devices):"
  log "    ${ICECAST_URL}"
  log ""
  log "============================================================"
}

# ------------------------------------------------------------------------------
# 2) Start the UDP → continuous-audio shim (op25_udp_shim.py)
#
#    - Listens on OP25_UDP_PORT for decoded audio packets from OP25
#    - Tracks wall-clock time and fills gaps with zeros (silence)
#    - Exposes a continuous 16-bit PCM stream on PCM_TCP_PORT (TCP)
# ------------------------------------------------------------------------------

log "Starting op25_udp_shim.py shim..."
OP25_UDP_PORT="${OP25_UDP_PORT}" PCM_TCP_PORT="${PCM_TCP_PORT}" OP25_MIN_BUFFER_MS="${OP25_MIN_BUFFER_MS}" \
  /usr/local/bin/op25_udp_shim.py &
PCM_SHIM_PID=$!
log "op25_udp_shim.py running as PID ${PCM_SHIM_PID}"

# Cleanup function called when this script exits (container stop).
cleanup() {
  log "Shutting down..."
  # Kill the full process group so background loops (OP25/publishers/ffmpeg) stop cleanly.
  kill 0 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT SIGTERM SIGINT

# ------------------------------------------------------------------------------
# 3) OP25 loop (background)
#
#    - Runs OP25 rx.py with the configured args
#    - Sends decoded audio over UDP to OP25_UDP_PORT
#    - Exposes the OP25 web UI on OP25_UI_PORT
#    - Restarts on exit
# ------------------------------------------------------------------------------

op25_loop() {
  while true; do
    log "Starting OP25 rx.py..."
    cd /op25/op25/gr-op25_repeater/apps

    set +e
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
    rc=$?
    set -e

    log "OP25 exited (code ${rc}), restarting in 3 seconds..."
    sleep 3
  done
}

# ------------------------------------------------------------------------------
# 4) Encoder loop (foreground)
#
#    - Pulls continuous PCM from the shim (TCP)
#    - Applies minimal processing (keep latency low)
#    - Encodes to AAC
#    - Muxes AAC into MPEG-TS and sends it to UDP multicast (MCAST_URL)
#
#    MediaMTX and Icecast publishers both subscribe to the multicast.
# ------------------------------------------------------------------------------

encoder_loop() {
  local announced=0

  while true; do
    log "Starting encoder → MPEG-TS multicast (${MCAST_OUT_URL})..."

    # NOTE: Avoid heavy lookahead filters (like large-window dynaudnorm) if you care about latency.
    # Keep it simple: resample, limiter, and optional gain.
    ffmpeg -hide_banner -loglevel "${FFMPEG_LOGLEVEL}" \
      -fflags nobuffer -flags low_delay \
      -use_wallclock_as_timestamps 1 \
      -thread_queue_size 32768 \
      -f s16le -ac 1 -ar 8000 \
      -i "tcp://127.0.0.1:${PCM_TCP_PORT}" \
      -filter_complex "\
        [0:a]
          aresample=${AAC_SR}:async=1:min_hard_comp=0.100:first_pts=0,
          alimiter=limit=0.9:level=disabled
        [aout]" \
      -map "[aout]" \
      -c:a aac -profile:a aac_low -b:a "${AAC_BITRATE}" -ac 1 -ar "${AAC_SR}" \
      -muxpreload 0 -muxdelay 0 -flush_packets 1 \
      -f mpegts "${MCAST_OUT_URL}" &

    ENCODER_PID=$!

    # Give it a moment to start flowing
    sleep 2

    if [[ "${announced}" -eq 0 ]]; then
      log_stream_endpoints
      announced=1
    fi

    set +e
    wait "${ENCODER_PID}"
    rc=$?
    set -e

    log "Encoder exited (code ${rc}), restarting in 3 seconds..."
    announced=0
    sleep 3
  done
}

# ------------------------------------------------------------------------------
# 5) Publisher: multicast → MediaMTX (background)
#
#    - Subscribes to the MPEG-TS multicast
#    - Re-encodes AAC (keeps output consistent for RTSP consumers)
#    - Publishes to MediaMTX via RTSP
# ------------------------------------------------------------------------------

mediamtx_publisher_loop() {
  while true; do
    log "Publishing MPEG-TS multicast → MediaMTX (RTSP) ..."

    set +e
    ffmpeg -hide_banner -loglevel "${FFMPEG_LOGLEVEL}" \
      -fflags nobuffer -flags low_delay \
      -probesize 32 -analyzeduration 0 \
      -i "${MCAST_IN_URL}" \
      -vn \
      -c:a aac \
      -profile:a aac_low \
      -b:a "${AAC_BITRATE}" \
      -ac 1 \
      -ar "${AAC_SR}" \
      -fflags +genpts \
      -avoid_negative_ts make_zero \
      -rtsp_transport tcp -rtsp_flags prefer_tcp \
      -muxpreload 0 -muxdelay 0 -flush_packets 1 \
      -f rtsp "${MEDIAMTX_RTSP_URL}"
    rc=$?
    set -e

    log "MediaMTX publisher exited (code ${rc}), restarting in 3 seconds..."
    sleep 3
  done
}

# ------------------------------------------------------------------------------
# 6) Publisher: multicast → Icecast (background)
#
#    - Subscribes to the MPEG-TS multicast
#    - Copies AAC (no re-encode)
#    - Publishes ADTS AAC to Icecast so many clients can connect (ESP32, etc.)
# ------------------------------------------------------------------------------

icecast_publisher_loop() {
  local ICECAST_PUSH_URL="icecast://source:${ICECAST_SOURCE_PASSWORD}@${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}"

  while true; do
    log "Publishing MPEG-TS multicast → Icecast (${ICECAST_URL}) ..."

    set +e
    ffmpeg -hide_banner -loglevel "${FFMPEG_LOGLEVEL}" \
      -fflags nobuffer -flags low_delay \
      -probesize 32 -analyzeduration 0 \
      -i "${MCAST_IN_URL}" \
      -vn \
      -c:a copy \
      -f adts \
      -flush_packets 1 \
      -content_type audio/aac \
      -legacy_icecast 1 \
      "${ICECAST_PUSH_URL}"
    rc=$?
    set -e

    log "Icecast publisher exited (code ${rc}), restarting in 3 seconds..."
    sleep 3
  done
}

# ------------------------------------------------------------------------------
# 7) Kick everything off
# ------------------------------------------------------------------------------

log "=== op25-radio-stream: starting ==="
log "  Freq:          ${OP25_FREQ}"
log "  OP25 UDP port: ${OP25_UDP_PORT}"
log "  PCM TCP port:  ${PCM_TCP_PORT}"
log "  MPEGTS mcast:  ${MCAST_OUT_URL}"
log "  RTSP target:   ${MEDIAMTX_RTSP_URL}"
log "  Icecast URL:   ${ICECAST_URL}"

op25_loop &                 # OP25 in background
mediamtx_publisher_loop &   # publisher A in background
icecast_publisher_loop &    # publisher B in background
encoder_loop                # encoder in foreground (container lifetime)
