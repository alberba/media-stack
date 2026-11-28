# Image of the extras Profile's issue-automator: one Python file, standard library only.
# Built locally by `docker compose build`; every setting comes from the environment.
FROM python:3.15-alpine

WORKDIR /app
# The NAS follower checks out with umask 077; without --chmod the file would be
# root-only inside the image and the non-root user could not read it.
COPY --chmod=0644 main.py ./

EXPOSE 5056
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget --spider -q http://127.0.0.1:5056/health || exit 1

USER nobody
CMD ["python3", "-u", "main.py"]
