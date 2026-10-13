FROM aquasec/trivy:0.75.0 AS scanner
FROM alpine:3.24
RUN apk add --no-cache python3 supercronic tzdata ca-certificates
COPY --from=scanner /usr/local/bin/trivy /usr/local/bin/trivy
COPY main.py /app/main.py
ENV PYTHONUNBUFFERED=1 TRIVY_CACHE_DIR=/state/cache TMPDIR=/state/tmp
ENTRYPOINT ["python3", "/app/main.py"]
CMD ["schedule"]
