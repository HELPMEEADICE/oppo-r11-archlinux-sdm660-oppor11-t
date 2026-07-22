.section .text
.global _start

_start:
	/* Flush filesystems before requesting a bootloader restart. */
	mov	x8, #81
	svc	#0

	ldr	x0, =0xfee1dead
	ldr	x1, =0x28121969
	ldr	x2, =0xa1b2c3d4
	adr	x3, restart_arg
	mov	x8, #142
	svc	#0

1:	wfe
	b	1b

restart_arg:
	.asciz "bootloader"
