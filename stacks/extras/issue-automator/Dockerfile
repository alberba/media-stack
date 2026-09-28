# Image of the extras Profile's issue-automator: one Python file, standard library only.
# Built locally by `docker compose build`; every setting comes from the environment.
FROM python:3.12-alpine

WORKDIR /app
COPY main.py ./

EXPOSE 5056
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget --spider -q http://127.0.0.1:5056/health || exit 1

USER nobody
CMD ["python3", "-u", "main.py"]
