FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1 AS build

WORKDIR /app

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY app/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r ./requirements.txt

FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1 AS runtime

ENV PATH="/opt/venv/bin:$PATH" \
    PORT=8080

WORKDIR /app

RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /opt/venv /opt/venv
COPY gunicorn.conf.py ./gunicorn.conf.py
COPY app/app.py ./app.py

USER 10001:10001

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import os, urllib.request as r; r.urlopen('http://127.0.0.1:' + os.environ['PORT'] + '/healthz', timeout=2)"]

ARG VERSION=dev

LABEL org.opencontainers.image.source="https://github.com/kolawoluu/greeting-container" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"

CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:app"]