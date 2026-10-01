# Film worker (ADR 0004). Build from the repository root so the app fonts
# can be copied:
#   docker build -f workers/film/Dockerfile -t bebegimin-film-worker .
FROM denoland/deno:alpine-2.1.4

RUN apk add --no-cache ffmpeg

WORKDIR /app
COPY workers/film/deno.json ./deno.json
COPY workers/film/src ./src
COPY assets/fonts/Nunito-Regular.ttf assets/fonts/Nunito-Bold.ttf ./fonts/
RUN deno cache src/main.ts

ENV FONT_DIR=/app/fonts \
    WORK_DIR=/tmp/film \
    FFMPEG_PATH=ffmpeg \
    FFPROBE_PATH=ffprobe

USER deno
CMD ["deno", "run", "--allow-net", "--allow-env", "--allow-read", "--allow-write", "--allow-run=ffmpeg,ffprobe", "src/main.ts"]
