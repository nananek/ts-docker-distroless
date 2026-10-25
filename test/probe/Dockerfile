# syntax=docker/dockerfile:1.7

# The build context is prepared by scripts/smoke-test.sh: it contains main.go,
# go.mod, and sandbox-exec copied out of the image under test. Building from
# scratch avoids depending on the test runner's local image store.
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /probe .

FROM scratch
COPY sandbox-exec /usr/local/bin/sandbox-exec
COPY --from=build /probe /probe
ENV PROBE_MODE=ssh
ENTRYPOINT ["/usr/local/bin/sandbox-exec", "/probe"]
