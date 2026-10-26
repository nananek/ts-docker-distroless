TAILSCALE_TAG ?= $(shell ./scripts/latest-unstable-tag.sh 2>/dev/null)
IMAGE ?= ts-docker-distroless:dev
TUN_IMAGE ?= ts-docker-distroless:tun

.PHONY: image image-tun test test-tun seccomp check

image:
	@tag="$(TAILSCALE_TAG)"; \
	test -n "$$tag" || { echo "could not resolve a Tailscale nightly tag" >&2; exit 1; }; \
	docker build \
	  --build-arg "TAILSCALE_IMAGE=ghcr.io/tailscale/tailscale:$$tag" \
	  -t "$(IMAGE)" .

image-tun:
	@tag="$(TAILSCALE_TAG)"; \
	test -n "$$tag" || { echo "could not resolve a Tailscale nightly tag" >&2; exit 1; }; \
	docker build \
	  -f Dockerfile.tun \
	  --build-arg "TAILSCALE_IMAGE=ghcr.io/tailscale/tailscale:$$tag" \
	  -t "$(TUN_IMAGE)" .

test: image
	./scripts/smoke-test.sh $(IMAGE)

test-tun: image-tun
	./scripts/smoke-test-tun.sh $(TUN_IMAGE)

seccomp:
	./scripts/update-seccomp.sh
	./scripts/check-seccomp.sh

check:
	./scripts/check-seccomp.sh
	for script in scripts/*.sh; do bash -n "$$script"; done
	cd cmd/sandbox-exec && go vet ./... && go build -o /dev/null .
