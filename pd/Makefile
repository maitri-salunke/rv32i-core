# pd/Makefile - OpenLane2 (Docker, arm64 image) hardening of rv32i_core on sky130_fd_sc_hd
#   make pd TAG=base [PERIOD=20]   full RTL->GDS flow, then extract metrics
#   make metrics TAG=base          (re)extract metrics from runs/<TAG>
IMAGE  ?= ghcr.io/efabless/openlane2:2.3.10
PROJ   := $(abspath ..)
PDKDIR ?= $(abspath ../../tools/pdk)
TAG    ?= base
PERIOD ?=
CFG    ?= config.json
MEM    ?= 6g
CPUS   ?= 4

.PHONY: pd metrics
pd:
	@mkdir -p $(PDKDIR)
	docker run --rm -m $(MEM) --cpus $(CPUS) \
	  -v $(PROJ):$(PROJ) -v $(PDKDIR):$(PDKDIR) -w $(PROJ)/pd \
	  -e PDK_ROOT=$(PDKDIR) $(IMAGE) \
	  openlane --pdk-root $(PDKDIR) --run-tag $(TAG) --overwrite \
	  $(if $(PERIOD),-c CLOCK_PERIOD=$(PERIOD)) $(CFG)
	python3 extract_metrics.py runs/$(TAG)

metrics:
	python3 extract_metrics.py runs/$(TAG)
