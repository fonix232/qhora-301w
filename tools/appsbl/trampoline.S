/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * APPSBL trampoline for the QNAP QHora-301W (IPQ8074).
 *
 * SBL1 enters APPSBL in AArch32. This stub copies the arm64 U-Boot that
 * follows it to RUN_ADDR, cleans it to the point of coherency, and asks
 * TrustZone to enter it in AArch64 at EL1: the same SMC the stock QCA
 * U-Boot uses to start a 64-bit kernel (jump_kernel64() in QCA's
 * arch/arm/cpu/armv7/qca/common/scm.c). Our U-Boot therefore starts in
 * exactly the state it has when the stock U-Boot chainloads it.
 *
 * Position independent: SBL1 runs it from 0x4a900000, and for testing the
 * stock U-Boot can run it from any RAM address with `go`.
 * See docs/findings/0003-ipq807x-boot-chain.md.
 */

#ifndef RUN_ADDR
#define RUN_ADDR	0x41000000
#endif
#ifndef PAYLOAD
#error "define PAYLOAD as the path of the arm64 u-boot.bin"
#endif

#define SCM_EL1_SWITCH	0x0200010f	/* SiP, SCM_ARCH64_SWITCH_ID 1, SCM_EL1SWITCH_CMD_ID 0xf */
#define SCM_ARGINFO	0x12		/* 2 arguments, the first a read buffer */

	.syntax	unified
	.arch	armv7-a
	.arch_extension sec
	.arm
	.text
	.global	_start
_start:
	cpsid	aif

	adr	r4, _start		@ r4: payload in this image (PC-relative)
	ldr	r0, payload_offset
	add	r4, r4, r0
	ldr	r5, run_addr		@ r5: where it runs
	ldr	r6, payload_size	@ r6: bytes to copy

	mov	r0, r5
	mov	r1, r4
	mov	r2, r6
1:	ldr	r3, [r1], #4
	str	r3, [r0], #4
	subs	r2, r2, #4
	bgt	1b

	/* smallest D-cache line from CTR.DminLine (log2 of words) */
	mrc	p15, 0, r3, c0, c0, 1
	ubfx	r3, r3, #16, #4
	mov	r7, #4
	lsl	r7, r7, r3

	/* TZ and the AArch64 side read memory, not our cache */
	mov	r0, r5
	add	r1, r5, r6
	bl	clean_range
	adr	r0, params
	add	r1, r0, #80
	bl	clean_range
	/*
	 * Same CPU state whoever called us: SBL1 hands over with the MMU and
	 * caches off, the stock U-Boot (`go`, for RAM tests) with them on. Our
	 * data is clean to PoC, and U-Boot maps memory 1:1, so turn them off.
	 */
	mrc	p15, 0, r0, c1, c0, 0	@ SCTLR
	bic	r0, r0, #(1 << 0)	@ M: MMU
	bic	r0, r0, #(1 << 2)	@ C: D-cache
	bic	r0, r0, #(1 << 12)	@ I: I-cache
	mcr	p15, 0, r0, c1, c0, 0
	isb
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	@ ICIALLU
	dsb	sy
	isb

	ldr	r0, fn_id
	mov	r1, #SCM_ARGINFO
	adr	r2, params		@ kernel_params: x0..x8, kernel_start
	mov	r3, #80			@ sizeof(kernel_params)
	mov	r4, #0
	mov	r5, #0
	smc	#0

	/* only reached if TZ refused the switch */
2:	wfi
	b	2b

/* clean [r0, r1) to PoC by VA; r7 = line size */
clean_range:
	sub	r3, r7, #1
	bic	r0, r0, r3
3:	mcr	p15, 0, r0, c7, c10, 1	@ DCCMVAC
	add	r0, r0, r7
	cmp	r0, r1
	blo	3b
	bx	lr

	.align	2
fn_id:		.word	SCM_EL1_SWITCH
run_addr:	.word	RUN_ADDR
payload_size:	.word	payload_end - payload
payload_offset:	.word	payload - _start

	.align	3
params:		.quad	0, 0, 0, 0, 0, 0, 0, 0, 0	/* x0..x8: no FDT, U-Boot uses its own */
		.quad	RUN_ADDR			/* kernel_start */

	.align	12
payload:
	.incbin	PAYLOAD
	.balign	4
payload_end:
