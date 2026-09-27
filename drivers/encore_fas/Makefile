# SPDX-License-Identifier: GPL-2.0-only
obj-$(CONFIG_ENCORE_FAS) += encore_fas.o
encore_fas-y := encore_fas_main.o \
		encore_fas_ctx.o \
		encore_fas_evq.o \
		encore_fas_time.o

ccflags-y += -I$(src)/include

# This tree is Linux 4.19: uprobe_register(inode, offset, uc) returns int and
# uprobe_unregister(inode, offset, uc) is the only teardown call, so
# FAS_UPROBE_API=1. hrtimer_setup() does not exist, and the compat header falls
# back to hrtimer_init() + ->function. HRTIMER_MODE_REL_PINNED_SOFT is present.
ccflags-y += -DFAS_UPROBE_API=1
ccflags-y += -DFAS_HAVE_HRTIMER_SOFT
ccflags-y += -DFAS_VERSION=1
ccflags-y += -DFAS_BRANCH=\"gale\"
