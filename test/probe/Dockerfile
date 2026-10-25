# syntax=docker/dockerfile:1.7

# BASE must be the image under test. It already contains sandbox-exec.
ARG BASE
ARG GOLANG_IMAGE=golang:1.27-alpine

FROM ${GOLANG_IMAGE} AS build
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /probe .

FROM ${BASE}
COPY --from=build /probe /probe
ENV PROBE_MODE=ssh
ENTRYPOINT ["/usr/local/bin/sandbox-exec", "/probe"]
