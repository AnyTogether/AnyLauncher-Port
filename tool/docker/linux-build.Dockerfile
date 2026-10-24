# A headless Linux build check: the Flutter SDK at the version this project uses, the Linux
# desktop toolchain, and `flutter build linux` on a copy of the sources.
#
#   docker build -f tool/docker/linux-build.Dockerfile -t anyps5-desktop-linux tool/docker
#   docker run --rm -v "$PWD":/src:ro anyps5-desktop-linux
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates clang cmake curl git libgtk-3-dev ninja-build pkg-config unzip xz-utils file \
 && rm -rf /var/lib/apt/lists/*

ARG FLUTTER_VERSION=3.47.1
RUN git config --global http.version HTTP/1.1 \
 && for attempt in 1 2 3 4 5; do \
      git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter && break; \
      rm -rf /opt/flutter; sleep 10; \
    done \
 && test -x /opt/flutter/bin/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN flutter config --no-analytics --enable-linux-desktop \
 && flutter precache --linux --no-android --no-ios --no-web --no-macos --no-windows --no-fuchsia

CMD ["sh", "-c", "cp -r /src /work && cd /work && rm -rf build .dart_tool && flutter pub get && flutter build linux --release && file build/linux/*/release/bundle/anyps5_desktop && ls -la build/linux/*/release/bundle"]
