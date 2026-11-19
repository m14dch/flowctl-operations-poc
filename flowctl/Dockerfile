# The upstream flowctl image ships without an HTTP client; the script executor needs curl.
FROM ghcr.io/cvhariharan/flowctl:0.16.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
