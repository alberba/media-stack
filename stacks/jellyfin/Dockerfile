# renovate: datasource=docker depName=jellyfin/jellyfin
ARG JELLYFIN_IMAGE=jellyfin/jellyfin:12.1.20260915-010956
FROM ${JELLYFIN_IMAGE}
COPY web/syncplay-web-player.js /jellyfin/jellyfin-web/media-stack-syncplay.js
# Fail the build if a future web client changes its entry point.
RUN test "$(grep -o '</head>' /jellyfin/jellyfin-web/index.html | wc -l)" -eq 1 \
    && sed -i 's@</head>@<script src="media-stack-syncplay.js"></script></head>@' /jellyfin/jellyfin-web/index.html
