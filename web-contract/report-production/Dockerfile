FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        fontconfig \
        fonts-dejavu-core \
        libde265-0 \
        libheif1 \
        libjpeg62-turbo \
        libopenjp2-7 \
        poppler-utils \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY web-contract/report-production/requirements.txt /tmp/report-worker-requirements.txt
RUN python -m pip install --upgrade pip \
    && python -m pip install --no-cache-dir -r /tmp/report-worker-requirements.txt

COPY web-contract ./web-contract

ENTRYPOINT ["python", "web-contract/report-production/report_worker_cli.py"]
CMD ["--runtime-check", "--pretty", "--require-heif"]
