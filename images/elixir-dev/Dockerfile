# Sandbox image for Peon checks and previews: runs unreviewed app code.
# Containers run as the host user (--user), so Mix and Hex live in shared,
# world-readable locations instead of /root.
FROM elixir:1.18.3-otp-27
RUN apt-get update \
 && apt-get install -y --no-install-recommends inotify-tools git build-essential ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ENV MIX_HOME=/opt/mix HEX_HOME=/cache/hex HOME=/tmp
RUN mix local.hex --force && mix local.rebar --force && chmod -R a+rX /opt/mix
RUN git config --system --add safe.directory '*'
WORKDIR /app
