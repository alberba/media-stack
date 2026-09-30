# The Wiring: Recyclarr's image (for the quality profiles) plus Python for the rest.
FROM ghcr.io/recyclarr/recyclarr:8.7.2
USER root
RUN apk add --no-cache python3
COPY wire /opt/wire/wire
ENV PYTHONPATH=/opt/wire PYTHONDONTWRITEBYTECODE=1
ENTRYPOINT ["python3", "-m", "wire"]
