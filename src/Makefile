# Out-of-tree build Makefile for mtk_t7xx (Fibocom FM350 / MediaTek T700)
# Patched to fix NULL pointer crash in port_ctl_uninit

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

obj-m := mtk_t7xx.o
mtk_t7xx-y := \
	t7xx_pci.o \
	t7xx_pcie_mac.o \
	t7xx_mhccif.o \
	t7xx_state_monitor.o \
	t7xx_modem_ops.o \
	t7xx_cldma.o \
	t7xx_hif_cldma.o \
	t7xx_port_proxy.o \
	t7xx_port_ctrl_msg.o \
	t7xx_port_wwan.o \
	t7xx_hif_dpmaif.o \
	t7xx_hif_dpmaif_tx.o \
	t7xx_hif_dpmaif_rx.o \
	t7xx_dpmaif.o \
	t7xx_netdev.o \
	t7xx_port_trace.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install

.PHONY: all clean install
