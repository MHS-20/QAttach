.PHONY: build build-agent build-module test lint clean

# Go
GOCMD := go
GOBUILD := $(GOCMD) build
GOTEST := $(GOCMD) test
GOLINT := golangci-lint
BINARY := cluster-agent

# Kernel
KERNEL_SRC := /lib/modules/$(shell uname -r)/build
MODULE_DIR := kernel

build: build-agent

build-agent:
	$(GOBUILD) -o bin/$(BINARY) ./cmd/cluster-agent/

build-module:
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD)/$(MODULE_DIR) modules

test:
	$(GOTEST) ./...

lint:
	$(GOLINT) run ./...

clean:
	rm -rf bin/
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD)/$(MODULE_DIR) clean 2>/dev/null || true
