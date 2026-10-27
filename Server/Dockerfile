# bookworm: trixie's newer glibc refuses the ctranslate2 4.5.0 wheel ("cannot enable executable stack").
FROM python:3.12-slim-bookworm
RUN pip install --no-cache-dir ctranslate2==4.5.0 sentencepiece==0.2.0
COPY app.py /app/app.py
USER nobody
EXPOSE 8700
CMD ["python", "-u", "/app/app.py"]
