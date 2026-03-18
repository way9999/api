FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY codex_proxy.py .

EXPOSE 9006

CMD ["gunicorn", "-b", "0.0.0.0:9006", "-w", "4", "--timeout", "300", "codex_proxy:app"]
