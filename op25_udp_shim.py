#!/usr/bin/env python3

"""
op25_udp_shim.py

Shim between OP25 and ffmpeg that turns OP25's bursty UDP audio output
into a continuous PCM stream over TCP.

This allows downstream consumers (ffmpeg, MediaMTX, Icecast, etc) to see a
stable, always-on audio stream even though the underlying P25 traffic is
intermittent.

- Listens on a UDP port for decoded 8 kHz mono PCM audio packets from OP25.
- Buffers incoming packets and tracks wall-clock time to determine how many
  samples should be output each loop.
- When there isn't enough real audio in the buffer (e.g. no one is talking),
  it pads with zeros (silence) so the output stream stays continuous.
- Exposes this steady 16-bit PCM stream on a TCP port, which ffmpeg reads and
  encodes (AAC) before sending to MediaMTX.

Jitter buffer
---------------
- OP25 can be slightly "late" at the start of a call. To avoid chopping off
  the first syllable, we can keep a small amount of real audio buffered before
  we start draining it to ffmpeg.
- The size of this buffer is controlled by OP25_MIN_BUFFER_MS (milliseconds).
- Setting OP25_MIN_BUFFER_MS=0 disables the jitter buffer and does not introduce
  any intentional extra latency.

Injection / test override (optional)
------------------------------------
For testing, this shim can accept an injected PCM stream and temporarily
prioritize it over OP25 audio.

When enabled, the shim listens on INJECT_UDP_PORT (default: 23457) for raw
16-bit PCM, mono, 8 kHz (s16le) sent over UDP. Whenever injected audio packets
arrive, the shim outputs injected audio instead of OP25. When injection stops,
it automatically falls back to OP25 after a short hold window (INJECT_HOLD_MS).

Usage Example (run on the host machine + replace test.wav with your audio file):

  ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i ./test.wav \
    -ac 1 -ar 8000 -f s16le "udp://127.0.0.1:23457?pkt_size=320"

pkt_size=320 corresponds to ~20 ms of audio at 8 kHz mono s16le:
    0.020 * 8000 samples/sec * 2 bytes/sample = 320 bytes

Keeping packets small makes the override feel “snappy” and helps avoid building
extra latency during tests.

Configurable environment variables
----------------------------------
The shim supports the following environment variables. Each has a sensible
default so you can run without configuration.

- OP25_UDP_PORT (default: 23456)
    UDP port the script listens on for decoded OP25 8 kHz mono PCM audio.

- PCM_TCP_PORT (default: 19000)
    TCP port the script binds for a single ffmpeg (or other consumer) connection
    which will receive a continuous 16-bit PCM stream.

- INJECT_UDP_PORT (default: 23457)
    Optional UDP port to receive injected test audio (raw s16le, 8 kHz, mono).
    When injected audio is active it takes priority over incoming OP25 audio.

- INJECT_HOLD_MS (default: 750)
    Milliseconds to keep prioritizing injected audio after the last injected
    packet was received. Prevents rapid flipping to OP25 audio on brief gaps.

- MAX_BUFFER_SECONDS (default: 30)
    Safety cap (seconds) used to compute the maximum jitter buffer size and avoid
    unbounded memory growth if producers stop draining.

- OP25_MIN_BUFFER_MS (default: 250)
    When >0 enables a small jitter buffer (in milliseconds) to avoid clipping the
    start of transmissions. Set to 0 to disable the intentional jitter buffer.
"""

import os
import socket
import time
import sys
import signal

SAMPLE_RATE = 8000        # OP25 UDP audio: 8 kHz decoded audio
BYTES_PER_SAMPLE = 2      # 16-bit PCM (2 bytes per sample)
MAX_UDP_PACKET = 65535    # max UDP packet size
UDP_PORT = int(os.environ.get("OP25_UDP_PORT", "23456"))
TCP_PORT = int(os.environ.get("PCM_TCP_PORT", "19000"))

# Optional injection UDP port (raw PCM s16le, 8kHz mono).
INJECT_UDP_PORT = int(os.environ.get("INJECT_UDP_PORT", "23457"))

# If we have seen injected audio within this window, keep prioritizing it.
# This prevents brief gaps / packet jitter from immediately falling back to OP25 mid-test.
INJECT_HOLD_MS = int(os.environ.get("INJECT_HOLD_MS", "750"))
INJECT_HOLD_S = max(0.0, INJECT_HOLD_MS / 1000.0)

# Safety cap to prevent unbounded buffering if something gets stuck.
MAX_BUFFER_SECONDS = float(os.environ.get("MAX_BUFFER_SECONDS", "30"))
MAX_BUFFER_BYTES = int(SAMPLE_RATE * MAX_BUFFER_SECONDS * BYTES_PER_SAMPLE)

# Socket tuning / observability
UDP_RCVBUF_BYTES = int(os.environ.get("UDP_RCVBUF_BYTES", "1048576"))
STATS_INTERVAL_S = max(0.0, float(os.environ.get("SHIM_STATS_INTERVAL_S", "30")))

# Jitter buffer configuration:
_MIN_BUFFER_MS_ENV = int(os.environ.get("OP25_MIN_BUFFER_MS", "250"))
if _MIN_BUFFER_MS_ENV < 0:
    _MIN_BUFFER_MS_ENV = 0

MIN_BUFFER_MS = _MIN_BUFFER_MS_ENV
MIN_BUFFER_BYTES = int(
    SAMPLE_RATE * (MIN_BUFFER_MS / 1000.0) * BYTES_PER_SAMPLE
) if MIN_BUFFER_MS > 0 else 0

# Output frame configuration (cap per-iteration output for stability).
FRAME_MS = 20
FRAME_SAMPLES = int(SAMPLE_RATE * (FRAME_MS / 1000.0))
FRAME_BYTES = FRAME_SAMPLES * BYTES_PER_SAMPLE

def _log(msg: str) -> None:
    print(f"[op25_udp_shim.py] {msg}", file=sys.stderr, flush=True)


def _drain_udp(sock: socket.socket, buf: bytearray) -> int:
    """Drain all available UDP packets from a non-blocking socket into buf."""
    added = 0
    while True:
        try:
            data, _ = sock.recvfrom(MAX_UDP_PACKET)
            if not data:
                break
            buf.extend(data)
            added += len(data)
        except BlockingIOError:
            break
    return added


def _cap_buffer(buf: bytearray, max_bytes: int) -> int:
    """Keep only the newest max_bytes to avoid runaway memory growth."""
    dropped = max(0, len(buf) - max_bytes)
    if dropped > 0:
        # Drop oldest data
        del buf[:dropped]
    return dropped


def _enforce_sample_alignment(buf: bytearray) -> None:
    """Ensure s16le alignment (2 bytes per sample) to avoid sample-boundary drift."""
    if len(buf) & 1:
        del buf[-1]


def _buffer_ms(buf: bytearray) -> float:
    return (len(buf) / BYTES_PER_SAMPLE) * 1000.0 / SAMPLE_RATE


def _configure_udp_socket(sock: socket.socket, port: int, label: str) -> None:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, UDP_RCVBUF_BYTES)
    sock.bind(("0.0.0.0", port))
    sock.setblocking(False)
    actual = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    _log(f"Listening for {label} on 0.0.0.0:{port} (rcvbuf={actual} bytes)")


def main() -> None:
    running = True

    # Docker (and most process supervisors) stop containers by sending SIGTERM.
    # Handle SIGTERM/SIGINT so we can exit our accept/send loops cleanly and close sockets,
    # instead of being killed mid-write and leaving noisy stack traces in logs.
    def _handle_signal(signum, frame) -> None:
        nonlocal running
        running = False
        _log(f"Received signal {signum}; shutting down...")

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    # 1a) Create a non-blocking UDP socket to receive audio from OP25.
    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    _configure_udp_socket(udp_sock, UDP_PORT, "OP25 UDP audio")

    # 1b) Create a non-blocking UDP socket to receive optional injected test audio.
    inject_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    _configure_udp_socket(inject_sock, INJECT_UDP_PORT, "INJECT UDP audio")
    _log(f"Injection hold window: {INJECT_HOLD_MS}ms")

    if MIN_BUFFER_MS > 0:
        _log(
            f"Jitter buffer enabled: MIN_BUFFER_MS={MIN_BUFFER_MS} "
            f"(~{MIN_BUFFER_BYTES} bytes)"
        )
    else:
        _log("Jitter buffer disabled (OP25_MIN_BUFFER_MS <= 0)")

    # 2) Create a TCP server socket.
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind(("0.0.0.0", TCP_PORT))
    server_sock.listen(1)
    server_sock.settimeout(1.0)  # allow periodic checks for shutdown signals
    _log(f"Waiting for ffmpeg on tcp://0.0.0.0:{TCP_PORT}")

    try:
        while running:
            try:
                conn, addr = server_sock.accept()
            except socket.timeout:
                continue

            _log(f"ffmpeg connected from {addr}")
            try:
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except Exception:
                pass

            audio_buf = bytearray()     # OP25 audio
            inject_buf = bytearray()    # Injected audio (priority)
            last_inject_time = 0.0

            # Jitter-buffer priming:
            # Only apply the "wait until MIN_BUFFER_BYTES" rule at the start of a call, then
            # continue draining normally even if the buffer dips below MIN_BUFFER_BYTES mid-call.
            op25_primed = MIN_BUFFER_BYTES == 0
            last_op25_rx_time = 0.0
            OP25_IDLE_RESET_S = 0.40  # treat OP25 as "idle/new call" after this much silence
            ACTIVE_AUDIO_WINDOW_S = 0.20  # if OP25 recently sent audio, underflows are suspicious

            stats_started = time.monotonic()
            op25_rx_bytes = 0
            inject_rx_bytes = 0
            op25_zero_fill_bytes = 0
            inject_zero_fill_bytes = 0
            active_underrun_frames = 0
            dropped_buffer_bytes = 0
            dropped_buffer_events = 0

            # Use monotonic time for stable pacing (immune to wall-clock jumps).
            frame_interval = FRAME_SAMPLES / SAMPLE_RATE
            next_send_time = time.monotonic()

            try:
                while running:
                    now = time.monotonic()

                    # Drain as quickly as possible (non-blocking).
                    added_inject = _drain_udp(inject_sock, inject_buf)
                    if added_inject > 0:
                        last_inject_time = now
                        inject_rx_bytes += added_inject
                    _enforce_sample_alignment(inject_buf)
                    dropped = _cap_buffer(inject_buf, MAX_BUFFER_BYTES)
                    if dropped > 0:
                        dropped_buffer_bytes += dropped
                        dropped_buffer_events += 1

                    added_op25 = _drain_udp(udp_sock, audio_buf)
                    if added_op25 > 0:
                        op25_rx_bytes += added_op25
                        # If OP25 was idle for a while, this looks like a new call: re-arm priming.
                        if last_op25_rx_time == 0.0 or (now - last_op25_rx_time) > OP25_IDLE_RESET_S:
                            op25_primed = MIN_BUFFER_BYTES == 0
                        last_op25_rx_time = now
                    else:
                        # No new OP25 data; if we've been idle long enough, re-arm for the next call.
                        if last_op25_rx_time != 0.0 and (now - last_op25_rx_time) > OP25_IDLE_RESET_S:
                            op25_primed = MIN_BUFFER_BYTES == 0

                    _enforce_sample_alignment(audio_buf)
                    dropped = _cap_buffer(audio_buf, MAX_BUFFER_BYTES)
                    if dropped > 0:
                        dropped_buffer_bytes += dropped
                        dropped_buffer_events += 1

                    # Send at most a bounded number of frames per loop to avoid giant catch-up bursts.
                    frames_sent = 0
                    max_frames_per_loop = 10
                    while running and now >= next_send_time and frames_sent < max_frames_per_loop:
                        bytes_needed = FRAME_BYTES

                        inject_active = (len(inject_buf) > 0) or ((now - last_inject_time) <= INJECT_HOLD_S)

                        if inject_active:
                            # PRIORITY: injected audio overrides OP25 while active.
                            if len(inject_buf) >= bytes_needed:
                                chunk = inject_buf[:bytes_needed]
                                del inject_buf[:bytes_needed]
                            else:
                                missing = bytes_needed - len(inject_buf)
                                chunk = bytes(inject_buf) + b"\x00" * missing
                                inject_buf.clear()
                                inject_zero_fill_bytes += missing
                        else:
                            # Normal OP25 behavior (with optional jitter buffer).
                            if len(audio_buf) >= bytes_needed:
                                if (MIN_BUFFER_BYTES > 0) and (not op25_primed) and (len(audio_buf) < MIN_BUFFER_BYTES):
                                    chunk = b"\x00" * bytes_needed
                                    op25_zero_fill_bytes += bytes_needed
                                else:
                                    chunk = audio_buf[:bytes_needed]
                                    del audio_buf[:bytes_needed]
                                    if (MIN_BUFFER_BYTES > 0) and (not op25_primed):
                                        op25_primed = True
                            else:
                                missing = bytes_needed - len(audio_buf)
                                had_any = len(audio_buf) > 0
                                chunk = bytes(audio_buf) + b"\x00" * missing
                                audio_buf.clear()
                                op25_zero_fill_bytes += missing
                                if last_op25_rx_time != 0.0 and (now - last_op25_rx_time) <= ACTIVE_AUDIO_WINDOW_S:
                                    active_underrun_frames += 1
                                if (MIN_BUFFER_BYTES > 0) and (not op25_primed) and had_any:
                                    op25_primed = True

                        try:
                            conn.sendall(chunk)
                        except (BrokenPipeError, ConnectionResetError):
                            _log("ffmpeg disconnected (broken pipe)")
                            raise

                        frames_sent += 1
                        next_send_time += frame_interval
                        now = time.monotonic()

                    # Sleep until the next frame is due (or a short minimum) to reduce CPU usage.
                    now = time.monotonic()
                    sleep_s = next_send_time - now
                    if sleep_s > 0:
                        time.sleep(min(sleep_s, 0.01))
                    else:
                        # If we're behind, avoid busy-looping: yield briefly.
                        time.sleep(0.001)

                    if STATS_INTERVAL_S > 0 and (now - stats_started) >= STATS_INTERVAL_S:
                        _log(
                            "stats: "
                            f"op25_rx={op25_rx_bytes}B "
                            f"inject_rx={inject_rx_bytes}B "
                            f"op25_zero_fill={op25_zero_fill_bytes}B "
                            f"inject_zero_fill={inject_zero_fill_bytes}B "
                            f"active_underruns={active_underrun_frames} "
                            f"buffer_drop_events={dropped_buffer_events} "
                            f"buffer_drop_bytes={dropped_buffer_bytes} "
                            f"op25_buf_ms={_buffer_ms(audio_buf):.1f} "
                            f"inject_buf_ms={_buffer_ms(inject_buf):.1f}"
                        )
                        stats_started = now
                        op25_rx_bytes = 0
                        inject_rx_bytes = 0
                        op25_zero_fill_bytes = 0
                        inject_zero_fill_bytes = 0
                        active_underrun_frames = 0
                        dropped_buffer_bytes = 0
                        dropped_buffer_events = 0

            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                try:
                    conn.close()
                except Exception:
                    pass
                if running:
                    _log("Waiting for next ffmpeg connection...")

    finally:
        try:
            server_sock.close()
        except Exception:
            pass
        try:
            udp_sock.close()
        except Exception:
            pass
        try:
            inject_sock.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
