# Host tools.
#   make        builds u55c-flash (needs gcc)
#   make test   unit tests: u55c.py logic + u55c-flash against a simulated flash
CC     ?= gcc
CFLAGS ?= -O2 -Wall -Wextra

all: u55c-flash

u55c-flash: u55c_flash.c
	$(CC) $(CFLAGS) -o $@ $<

flash_test: u55c_flash.c test/flash_sim.c
	$(CC) $(CFLAGS) -Wno-unused-result -DFLASH_SIM -o $@ $^

test: flash_test
	python3 test/test_u55c.py
	bash test/run_flash_test.sh

clean:
	rm -f u55c-flash flash_test

.PHONY: all test clean
