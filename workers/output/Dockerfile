# Output worker: first-year film (ADR 0004) and offline HTML archive
# (ADR 0005). Build from the repository root so the app fonts can be copied:
#   docker build -f workers/output/Dockerfile -t bebegimin-output-worker .
FROM denoland/deno:alpine-2.1.4

RUN apk add --no-cache ffmpeg

WORKDIR /app
COPY workers/output/deno.json ./deno.json
COPY workers/output/src ./src
COPY assets/fonts/Nunito-Regular.ttf assets/fonts/Nunito-Bold.ttf assets/fonts/Lora-Regular.ttf ./fonts/
RUN deno cache src/main.ts

ENV FONT_DIR=/app/fonts \
    WORK_DIR=/tmp/film \
    FFMPEG_PATH=ffmpeg \
    FFPROBE_PATH=ffprobe

USER deno
CMD ["deno", "run", "--allow-net", "--allow-env", "--allow-read", "--allow-write", "--allow-run=ffmpeg,ffprobe", "src/main.ts"]
