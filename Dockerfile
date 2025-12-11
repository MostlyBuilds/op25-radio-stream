# Base image with GNU Radio 3.10.9 + Python, maintained by IQTLabs.
# This already includes GNU Radio, so we deliberately do NOT install
# any gnuradio* packages from apt.
FROM iqtlabs/gnuradio:3.10.9

ENV DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# Pin upstream sources to known-good commits
# These SHAs are the exact revisions that have been tested and verified.
# If you update them, also update any notes in the README.
# ------------------------------------------------------------------------------

ARG GR_OSMOSDR_PINNED_COMMIT=a8d5bccb1aff93740dc4079dabc8524e2912bb9a
ARG OP25_PINNED_COMMIT=c56ed40204e20e1723029982d42ee14089a51239

# ------------------------------------------------------------------------------
# System dependencies
# - Toolchain: git, build-essential, cmake, pkg-config
# - Libraries needed by GNU Radio / gr-osmosdr / OP25
# - rtl-sdr support (librtlsdr-dev)
# - ffmpeg for encoding and RTSP output
# ------------------------------------------------------------------------------

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential cmake pkg-config \
    libusb-1.0-0-dev libfftw3-dev libcppunit-dev \
    python3 python3-dev python3-pip python3-thrift swig doxygen \
    libitpp-dev libpcap-dev libsndfile1 libsndfile1-dev sox \
    rtl-sdr librtlsdr-dev ca-certificates \
    ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && pip3 install --no-cache-dir waitress

# ------------------------------------------------------------------------------
# Build gr-osmosdr with only the RTL-SDR backend enabled
#
# We explicitly disable other SDR backends to keep the image smaller and
# to avoid pulling in device-specific dependencies we don't need.
# This is pinned to GR_OSMOSDR_PINNED_COMMIT for reproducible builds.
# ------------------------------------------------------------------------------

RUN git clone https://gitea.osmocom.org/sdr/gr-osmosdr.git /tmp/gr-osmosdr \
 && cd /tmp/gr-osmosdr \
 && git checkout "${GR_OSMOSDR_PINNED_COMMIT}" \
 && mkdir -p build && cd build \
 && cmake -Wno-dev \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_PREFIX_PATH=/usr/local \
      -DENABLE_PYTHON=ON \
      -DPYTHON_EXECUTABLE=/usr/bin/python3 \
      -DPYTHON3_EXECUTABLE=/usr/bin/python3 \
      -DENABLE_RTL=ON -DENABLE_FILE=ON \
      -DENABLE_RFSPACE=OFF -DENABLE_UHD=OFF -DENABLE_FCD=OFF -DENABLE_FCDPP=OFF \
      -DENABLE_HACKRF=OFF -DENABLE_BLADERF=OFF -DENABLE_AIRSPY=OFF -DENABLE_SOAPY=OFF \
      -DENABLE_REDPITAYA=OFF -DENABLE_XTRX=OFF -DENABLE_MIRI=OFF -DENABLE_AIRSPYHF=OFF \
      -DENABLE_SDRPLAY=OFF \
      .. \
 && make -j2 && make install && ldconfig \
 && python3 -c "import osmosdr; print('osmosdr:', osmosdr.__file__)" \
 && rm -rf /tmp/gr-osmosdr

# ------------------------------------------------------------------------------
# Clone and build OP25 (boatbod, pinned gr310 commit)
#
# This builds the P25 decoder and installs it into the GNU Radio environment.
# OP25 is pinned to OP25_PINNED_COMMIT for reproducible builds.
# We also ensure OP25 uses /usr/bin/python3 via the op25_python helper.
# ------------------------------------------------------------------------------

RUN git clone https://github.com/boatbod/op25 /op25 \
 && cd /op25 \
 && git checkout "${OP25_PINNED_COMMIT}" \
 && mkdir -p /op25/build \
 && sh -c 'echo "/usr/bin/python3" > /op25/op25/gr-op25_repeater/apps/op25_python' \
 && cd /op25/build && cmake .. && make -j1 && make install && ldconfig

# Default working directory is where rx.py lives
WORKDIR /op25/op25/gr-op25_repeater/apps

# ------------------------------------------------------------------------------
# Runtime defaults (can be overridden via environment)
#
# These match the variables documented in the README and used by start-radio.sh.
# All values can be overridden at docker run / compose time.
# ------------------------------------------------------------------------------

ENV \
  OP25_FREQ="463.725e6" \
  OP25_ARGS="rtl" \
  OP25_LNA="49" \
  OP25_SAMP_RATE="960000" \
  OP25_OFFSET="17000" \
  OP25_UDP_PORT="23456" \
  PCM_TCP_PORT="19000" \
  OP25_MIN_BUFFER_MS="250" \
  OP25_UI_PORT="8080" \
  MEDIAMTX_RTSP_URL="rtsp://127.0.0.1:8554/op25" \
  FFMPEG_LOGLEVEL="warning"

# ------------------------------------------------------------------------------
# UDP → continuous audio shim (OP25 UDP → TCP PCM for ffmpeg)
# ------------------------------------------------------------------------------

COPY op25_udp_shim.py /usr/local/bin/op25_udp_shim.py
RUN chmod +x /usr/local/bin/op25_udp_shim.py

# ------------------------------------------------------------------------------
# Startup script / entrypoint
# - starts the shim
# - supervises OP25 and ffmpeg in simple restart loops
# ------------------------------------------------------------------------------

COPY start-radio.sh /usr/local/bin/start-radio.sh
RUN chmod +x /usr/local/bin/start-radio.sh

ENTRYPOINT ["/usr/local/bin/start-radio.sh"]
