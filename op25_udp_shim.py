#!/usr/bin/env python3

"""
op25_udp_shim.py

Shim between OP25 and ffmpeg that turns OP25's bursty UDP audio output
into a continuous PCM stream over TCP.

This allows downstream consumers (ffmpeg, MediaMTX, players) to see a stable,
always-on audio stream even though the underlying P25 traffic is intermittent.

- Listens on a UDP port for decoded 8 kHz mono PCM audio packets from OP25.
- Buffers incoming packets and tracks wall-clock time to determine how many
  samples should be output each loop.
- When there isn't enough real audio in the buffer (e.g. no one is talking),
  it pads with zeros (silence) so the output stream stays continuous.
- Exposes this steady 16-bit PCM stream on a TCP port, which ffmpeg reads and
  encodes (AAC) before sending to MediaMTX.

Jitter buffer:
- OP25 can be slightly "late" at the start of a call. To avoid chopping off
  the first syllable, we can keep a small amount of real audio buffered before
  we start draining it to ffmpeg.
- The size of this buffer is controlled by OP25_MIN_BUFFER_MS (milliseconds).
- Setting OP25_MIN_BUFFER_MS=0 disables the jitter buffer and does not introduce
  any intentional extra latency.

"""

import os
import socket
import time
import select
import sys

SAMPLE_RATE = 8000        # OP25 UDP audio: 8 kHz decoded audio
BYTES_PER_SAMPLE = 2      # 16-bit PCM (2 bytes per sample)
MAX_UDP_PACKET = 65535    # max UDP packet size
UDP_PORT = int(os.environ.get("OP25_UDP_PORT", "23456"))
TCP_PORT = int(os.environ.get("PCM_TCP_PORT", "19000"))

# Jitter buffer configuration:
# - OP25_MIN_BUFFER_MS: how much real audio (in ms) we want buffered before we
#   start draining it to ffmpeg. This helps avoid chopping off the start of a
#   call when OP25 is slightly late with audio.
# - If OP25_MIN_BUFFER_MS <= 0, the jitter buffer is disabled and the shim
#   behaves like the original version (no intentional extra latency).
_MIN_BUFFER_MS_ENV = int(os.environ.get("OP25_MIN_BUFFER_MS", "250"))
if _MIN_BUFFER_MS_ENV < 0:
    _MIN_BUFFER_MS_ENV = 0

MIN_BUFFER_MS = _MIN_BUFFER_MS_ENV
USE_JITTER_BUFFER = MIN_BUFFER_MS > 0
if USE_JITTER_BUFFER:
    MIN_BUFFER_BYTES = int(
        SAMPLE_RATE * (MIN_BUFFER_MS / 1000.0) * BYTES_PER_SAMPLE
    )
else:
    MIN_BUFFER_BYTES = 0  # unused when jitter buffer is disabled


def log(msg: str) -> None:
    print(f"[op25_udp_shim.py] {msg}", file=sys.stderr, flush=True)


def main() -> None:
    # 1) Create a non-blocking UDP socket to receive audio from OP25.
    #    OP25 sends 8 kHz mono decoded PCM audio packets here.
    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_sock.bind(("0.0.0.0", UDP_PORT))
    udp_sock.setblocking(False)
    log(f"Listening for OP25 UDP audio on 0.0.0.0:{UDP_PORT}")

    if USE_JITTER_BUFFER:
        log(
            f"Jitter buffer enabled: MIN_BUFFER_MS={MIN_BUFFER_MS} "
            f"(~{MIN_BUFFER_BYTES} bytes)"
        )
    else:
        log("Jitter buffer disabled (OP25_MIN_BUFFER_MS <= 0)")

    # 2) Create a TCP server socket.
    #    ffmpeg will connect to this and read a continuous PCM stream.
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind(("0.0.0.0", TCP_PORT))
    server_sock.listen(1)
    log(f"Waiting for ffmpeg on tcp://0.0.0.0:{TCP_PORT}")

    # OUTER LOOP:
    # Accept/re-accept ffmpeg connections. If ffmpeg disconnects, we go back
    # to this loop and wait for the next connection.
    while True:
        conn, addr = server_sock.accept()
        log(f"ffmpeg connected from {addr}")

        # audio_buf holds raw decoded audio bytes we’ve received from OP25
        # but not yet sent to ffmpeg.
        audio_buf = bytearray()

        # last_time tracks when we last “accounted for” samples being sent.
        # We use real wall-clock time to decide how many samples should have
        # been produced at 8 kHz.
        last_time = time.time()

        try:
            # PER-CONNECTION STREAMING LOOP:
            # This loop runs as long as ffmpeg is connected.
            while True:
                now = time.time()
                elapsed = now - last_time

                # If the system clock jumps backwards slightly, guard against
                # negative elapsed time.
                if elapsed < 0:
                    last_time = now
                    elapsed = 0

                # Compute how many samples we *should* output since the last loop
                # based on the elapsed real time and SAMPLE_RATE.
                samples_needed = int(elapsed * SAMPLE_RATE)

                if samples_needed > 0:
                    # Convert samples to bytes.
                    bytes_needed = samples_needed * BYTES_PER_SAMPLE

                    # Move last_time forward by exactly the amount of time
                    # those samples represent, so errors don’t accumulate.
                    last_time += samples_needed / SAMPLE_RATE

                    # TOP-UP LOOP:
                    # Pull in all currently available UDP packets (non-blocking)
                    # to top up our audio buffer before we pull bytes out.
                    while True:
                        # select with timeout 0 means: “is there anything to read?”
                        rlist, _, _ = select.select([udp_sock], [], [], 0)
                        if not rlist:
                            # No more UDP packets ready right now.
                            break
                        try:
                            data, _ = udp_sock.recvfrom(MAX_UDP_PACKET)
                            if data:
                                audio_buf.extend(data)
                        except BlockingIOError:
                            # Non-blocking socket had nothing after all.
                            break

                    # Now decide how to build the chunk for this iteration.
                    if len(audio_buf) >= bytes_needed:
                        if USE_JITTER_BUFFER and len(audio_buf) < MIN_BUFFER_BYTES:
                            # We have some real audio, but not enough to satisfy
                            # our jitter buffer. Keep buffering and send silence
                            # for now so we don't "outrun" OP25 at call start.
                            chunk = b"\x00" * bytes_needed
                        else:
                            # Buffer is either primed with enough audio (when
                            # jitter buffer is enabled), or jitter buffer is
                            # disabled and we just drain normally.
                            chunk = audio_buf[:bytes_needed]
                            del audio_buf[:bytes_needed]
                    else:
                        # Not enough audio yet (e.g., idle or long gap).
                        # We send what we have and pad the rest with zeros (silence)
                        # to keep ffmpeg seeing a smooth, continuous stream.
                        missing = bytes_needed - len(audio_buf)
                        chunk = bytes(audio_buf) + b"\x00" * missing
                        audio_buf.clear()

                    # Send the chunk to ffmpeg over TCP.
                    try:
                        conn.sendall(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        # ffmpeg disconnected (stopped, crashed, etc.)
                        # Break out of the streaming loop and go back to accept().
                        log("ffmpeg disconnected (broken pipe)")
                        break

                # SECOND UDP DRAIN LOOP:
                # After sending, quickly drain any additional UDP packets that
                # may have arrived. This keeps the buffer as “caught up” as
                # possible for the next iteration.
                try:
                    while True:
                        rlist, _, _ = select.select([udp_sock], [], [], 0)
                        if not rlist:
                            break
                        data, _ = udp_sock.recvfrom(MAX_UDP_PACKET)
                        if data:
                            audio_buf.extend(data)
                except BlockingIOError:
                    # Nothing to read; ignore.
                    pass

                # Small sleep to avoid spinning 100% CPU while still reacting
                # quickly (every ~10 ms).
                time.sleep(0.01)

        finally:
            # Clean up this connection.
            try:
                conn.close()
            except Exception:
                pass
            log("Waiting for next ffmpeg connection...")


if __name__ == "__main__":
    main()
