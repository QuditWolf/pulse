FROM python:3.12-alpine
RUN adduser -D -u 10001 pulse && mkdir /data && chown pulse /data
WORKDIR /app
COPY app.py index.html ./
USER pulse
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=5s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["python", "-u", "app.py"]
