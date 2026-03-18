FROM mcr.microsoft.com/playwright/python:v1.58.0-noble

WORKDIR /app

# Install system deps for curl_cffi
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl libcurl4-openssl-dev build-essential && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY register.py .
COPY register_api.py .
COPY upgrade_team.py .
COPY inject.py .
COPY dashboard.py .
COPY register_browser.py .
COPY dom_extract.js .
COPY entrypoint.sh .
COPY templates/ templates/
RUN sed -i 's/\r$//' entrypoint.sh && chmod +x entrypoint.sh

EXPOSE 9005

ENTRYPOINT ["./entrypoint.sh"]
