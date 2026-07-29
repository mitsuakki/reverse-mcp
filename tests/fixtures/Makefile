all: hello.elf

hello.elf: hello.c
	gcc -o hello.elf hello.c

# 32-bit build (requires gcc-multilib on the host)
hello32.elf: hello.c
	gcc -m32 -o hello32.elf hello.c

clean:
	rm -f hello.elf hello32.elf

.PHONY: all clean
