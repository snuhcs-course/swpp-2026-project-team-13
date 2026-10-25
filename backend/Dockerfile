FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN python -m pip install --no-cache-dir -r requirements.txt
COPY . .
RUN useradd --create-home --uid 10001 sori && mkdir -p media .tmp .local && chown -R sori:sori /app
USER sori
EXPOSE 8000
CMD ["python", "boot.py"]
