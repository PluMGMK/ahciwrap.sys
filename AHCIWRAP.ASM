	.8086
	.model	large

?TESTWITHVBOX	equ 0
?ONLYBUGFIXES	equ 1

; Structures
RqHdr	struc			; DOS driver request header
	bLen	db ?
	bUnit	db ?
	bCmd	db ?
	wStatus	dw ?
	_resd	dq ?
RqHdr	ends

InitRq	struc			; Init request from DOS
	sHdr	RqHdr <?>
	bUnits	db ?
	lpEnd	dd ?
	lpCmdLn	dd ?
	bDrvNum	db ?
	wErrMsg	dw ?
InitRq	ends

IOCTLRW	struc			; IOCTL read/write request
	sHdr	RqHdr <?>
	bMedDes	db ?
	wBufOff	dw ?
	wBufSeg	dw ?
	wCount	dw ?
	_resd2	dw ?		; starting sector number = 0 for MSCDEX
	_resd3	dd ?		; volume ID = 0 for MSCDEX
IOCTLRW	ends

; Code/data positions in Intel's AHCI driver
num_drives	equ byte ptr 15h
; Screwed-up mov instruction
badmov		equ word ptr 20CBh
?BREAKPOINT_BADMOV equ 1
; Inappropriate shl instruction
badshl		equ dword ptr 209Fh
; Dwords that are coded as little-endian which should be big-endian
;badendian0	equ dword ptr 1F3Eh	; they got it right for CloseTray
badendian1	equ dword ptr 1F74h
;badendian2	equ dword ptr 1F98h	; they got it right for Eject
badendian3	equ dword ptr 1FC2h
; References to CL that should be to CH
bad_ch0		equ byte ptr 1FE0h
bad_ch1		equ byte ptr 1FE3h
; Bad sequence of instructions in LockDoor
badlockdoor	equ dword ptr 1FEAh
; Hardcoded PCI addresses
hard_pci_addx0	equ word ptr 2BEAh
hard_pci_addx1	equ word ptr 2C04h
hard_pci_addx2	equ word ptr 2C2Dh
hard_pci_addx3	equ word ptr 2C52h
if	?TESTWITHVBOX
; hardcoded offset of index port from base port
idxport_offset	equ byte ptr 2C41h
endif
; Function tables
GeneralCmds	equ word ptr 1536h
CdromCmds	equ word ptr 1558h
IoctlReadCmds	equ word ptr 156Ah
IoctlWriteCmds	equ word ptr 158Ah
; Endpoints
end_ahci_res	equ 2AC0h
end_ahci_init	equ 2F75h

; Relocation factors
S2FAC	equ	end_ahci_init - stage2
S2LEN	equ	end_stage3 - stage2	; we have to relocate both at once!
S3FAC	equ	end_ahci_res - stage3
S3LEN	equ	end_stage3 - stage3

	.code
driver	segment	use16
; STAGE 1 = code/data loaded and executed in-place
; -------   * does not get relocated
; -------   * gets overwritten almost immediately
org	0
stage1:

lpNextDriver	dd -1
wAttrs		dw 0C800h	; Same as Intel AHCI driver itself
pStrategy	dw offset strat_stg1
pInterrupt	dw offset inter_stg1
drvName		db 'AHCIWRAP'

lpSavedReq	label dword
SavedReq_off	dw ?
SavedReq_seg	dw ?

sataraid_idcs	label dword
sata_idx	dw -1		; Index of SATA controller to try (if any)
raid_idx	dw -1		; Index of RAID controller to try (if any)

strat_stg1	proc far
	assume	ds:nothing,es:nothing,ss:nothing
	mov	[SavedReq_off],bx
	mov	[SavedReq_seg],es
	ret
strat_stg1	endp

inter_stg1	proc far
	assume	ds:nothing,es:nothing,ss:nothing

	push	es
	push	bx
	les	bx,[lpSavedReq]

	cmp	es:[bx].RqHdr.bCmd,0		; init - can't do owt else yet!
	je	@F

	mov	es:[bx].RqHdr.wStatus,8003h	; unknown command

	pop	bx
	pop	es
	ret

@@:
	push	ax
	pushf

	pushf
	pop	ax
	and	ah,0Fh	; unset upper four flags
	push	ax
	popf

	pushf
	pop	ax
	and	ah,0F0h
	cmp	ah,0F0h	; all upper flags set?
	je	@F

	or	ah,0F0h	; set upper four flags
	push	ax
	popf

	pushf
	pop	ax
	test	ah,0F0h	; upper flags set?
	; As I understand it, a 386 in Real Mode will have some of them set,
	; but a 286 in Real Mode will have none of them...
	jnz	@@386ok

@@:
	popf

	push	dx
	mov	dx,offset no386
	call	init_msg
	mov	word ptr es:[bx].InitRq.lpEnd,0	; unload
	mov	word ptr es:[bx+2].InitRq.lpEnd,cs
	mov	es:[bx].RqHdr.wStatus,800Ch	; general failure

	pop	dx
	pop	ax
	pop	bx
	pop	es
	ret

@@386ok:
	popf
	.386
	assume	fs:nothing,gs:nothing

	; OK, now it's safe to save all the 32-bit registers
	; Get rid of the 16-bit ones on the stack first...
	pop	ax
	pop	bx

	pushad
	; Reload the pointer to the init request

	mov	ax,3000h	; DOS version / OEM check
	int	21h
	les	bp,[lpSavedReq]
	cmp	al,5
	jb	@F	; assume we have enough memory and hope for the best...

	mov	esi,es:[bp].InitRq.lpEnd
	movzx	edx,si	; get the offset into EDX
	xor	si,si	; keep the segment in the upper half of ESI
	shr	esi,0Ch	; convert (seg SHL 10h) to actual number of bytes
	mov	eax,cs
	shl	eax,4	; convert segment to number of bytes
	sub	esi,eax
	add	edx,esi	; offset + segment*16 = total number of bytes
	; This here is the largest amount of memory we'll need
	; (after we relocate stage 2 but before we relocate stage 3)
	cmp	edx,offset end_stage3 + S2FAC
	jnb	@F

	mov	dx,offset insufmem
	jmp	@@genfailure

@@:
	xor	edi,edi
	mov	ax,0B101h	; PCI BIOS installation check
	int	1Ah
	test	ah,ah
	jnz	@F

	cmp	edx," ICP"
	je	@@pciok

@@:
	mov	dx,offset nopcibios
	jmp	@@genfailure

@@pciok:
	; Parse command line...
	push	ds
	lds	si,es:[bp].InitRq.lpCmdLn
	cld

	; Ignore first argument (our own filename)
	xor	cx,cx
	not	cx
	mov	al,' '
@@:	; any leading spaces
	lodsb
	cmp	al,' '
	loope	@B
@@:	; our filename itself
	lodsb
	cmp	al,' '
	loopne	@B

@@checkspaces:
	xor	cx,cx
	not	cx
@@:
	lodsb
	cmp	al,' '
	loope	@B

	dec	si
	lodsw
	cmp	al,'/'
	jne	@@havefilename

	; We have a switch, make sure it's uppercase
	and	ah,not 20h

	; Process the number we get
	xor	cx,cx
	lodsb
@@:
	sub	al,'0'
	jb	@@nonnumeric
	cmp	al,9
	ja	@@nonnumeric

	imul	cx,cx,10	; base 10
	add	cl,al
	adc	ch,0

	lodsb
	cmp	al,' '
	jne	@B

	; Switch is still in AH
	cmp	ah,'S'	; SATA controller
	jne	@F
	mov	[sata_idx],cx
	jmp	@@checkspaces

@@:
	cmp	ah,'R'	; RAID controller
	jne	@F
	mov	[raid_idx],cx
	jmp	@@checkspaces

@@:
	mov	dx,offset badswitch
	mov	[badswitchb],ah
	call	init_msg
	jmp	@@checkspaces

@@havefilename:
	; Up to the filename...
	call	check_eol
	jne	@F

	pop	ds
	mov	dx,offset nofilename
	jmp	@@genfailure

@@:
	push	si

	cmp	[sataraid_idcs],-1
	jne	@F
	; Neither SATA nor RAID controller idx specified,
	; try zero for both
	inc	[sataraid_idcs]
@@:
	mov	si,[sata_idx]
	cmp	si,-1
	je	@F
	mov	ax,0B103h	; find PCI class code
	mov	ecx,10601h	; SATA controller
	int	1Ah
	jc	@F
	test	ah,ah
	jz	@@devfound

@@:
	mov	si,[raid_idx]
	cmp	si,-1
	je	@@nodev
	mov	ax,0B103h	; find PCI class code
	mov	ecx,10400h	; RAID controller
	int	1Ah
	jc	@@nodev
	test	ah,ah
	jnz	@@nodev

@@devfound:
	pop	si

	; Get ready to ask DOS to open the file
	mov	dx,si
	; this is now the cmdline for the AHCI driver
	mov	word ptr es:[bp].InitRq.lpCmdLn,si

@@:
	lodsb
	call	check_eol
	je	@F
	cmp	al,' '
	jne	@B

@@:
	; Temporarily null-terminate the filename
	dec	si
	xor	cx,cx
	xchg	ch,ds:[si]

	; Is it illegal to do Unix-type file IO in init code??
	; It seems to work though...
	mov	ax,3D00h	; OPEN read-only
	xor	cl,cl
	int	21h
	xchg	ch,ds:[si]	; restore character that was there
	pop	ds
	jnc	@F

	mov	dx,offset cantopen
	jmp	@@genfailure

@@:
	mov	di,bx		; save PCI bus/device/function
	mov	bx,ax		; file handle

	mov	ax,4202h	; LSEEK from end
	xor	cx,cx		; end of file
	mov	dx,cx
	int	21h
	jc	@@seekerr

	test	dx,dx
	jnz	@@badsize
	cmp	ax,end_ahci_init
	jne	@@badsize

	mov	ax,4200h	; LSEEK from beginning
	mov	dx,4		; skip over the pointer to next driver
	int	21h
	jc	@@seekerr

	; Relocate Stage 2
	push	es
	push	di

	push	cs
	pop	es
	assume	es:driver
	std	; start from the end since we're relocating forward
	mov	si,offset stage2
	mov	di,end_ahci_init
	mov	cx,S2LEN
	add	si,cx
	add	di,cx
	dec	si
	dec	di
	rep	movsb es:[di],es:[si]
	pop	di
	pop	es
	assume	es:nothing

	; Stage 2 is relocated, let's jump into it with a retf...
	push	cs
	push	offset stage2_init + S2FAC
	ret

@@nodev:
	pop	si
	pop	ds
	mov	dx,offset nodev
	jmp	@@genfailure
@@seekerr:
	mov	dx,offset seekerr
	jmp	@@genfailure
@@badsize:
	mov	dx,offset badsize
	jmp	@@genfailure
@@nonnumeric:
	pop	ds
	mov	dx,offset nonnumeric
@@genfailure:
	call	init_msg

	mov	es:[bp].InitRq.lpEnd,0		; unload
	mov	word ptr es:[bp+2].InitRq.lpEnd,cs
	mov	es:[bp].RqHdr.wStatus,800Ch	; general failure
	popad
	pop	es
	ret
inter_stg1	endp

; Check if character in AL is a terminator (CR/LF/NUL) - sets ZF if so
check_eol	proc near
	cmp	al,0Dh	; end of command line!
	je	@F
	cmp	al,0Ah	; end of command line!
	je	@F
	test	al,al
@@:
	ret
check_eol	endp

; Destroys AX, takes message in DX
init_msg	proc near	uses ds
	push	cs
	pop	ds
	assume	ds:driver

	mov	ah,9	; write to stdout
	int	21h
	ret

	assume	ds:nothing
init_msg	endp

; Messages
no386		db "No 386 CPU, AHCI driver cannot start!",0Dh,0Ah,'$'
nopcibios	db "No PCI BIOS, AHCI driver cannot find SATA controller!",0Dh,0Ah,'$'
insufmem	db "Insufficient memory for AHCI driver to relocate itself!",0Dh,0Ah,'$'
nonnumeric	db "Invalid non-numeric option for switch",0Dh,0Ah,'$'
badswitch	db "Ignoring unrecognized switch /"
badswitchb	db ?,0Dh,0Ah,'$'
nodev		db "Could not find AHCI controller!",0Dh,0Ah,'$'
nofilename	db "No path to Intel AHCI driver given, wrapper cannot start!",0Dh,0Ah,'$'
cantopen	db "Could not open Intel AHCI driver file!",0Dh,0Ah,'$'
seekerr		db "Could not seek Intel AHCI driver file!",0Dh,0Ah,'$'
badsize		db "File specified does not appear to be Intel AHCI driver file! (wrong size)",0Dh,0Ah,'$'

; STAGE 2 = code/data that needs to coexist with Intel's init code/data
; -------   * gets relocated beyond the end of the loaded driver
; -------   * gets discarded when we tell DOS how much to keep allocated
stage2:
stage2_init	proc far
	; At this point, we have the following:
	; * File handle for Intel driver in BX
	; * DOS "Init" device request in ES:BP
	; * Timeout ticks in SI
	; * PCI bus/device/function in DI
	; * Stack has "PUSHAD", ES, and the far return addx for the "interrupt"
	push	ds
	push	cs
	pop	ds
	assume	ds:driver
	mov	dx,4			; skip over pointer to next driver
	mov	ah,3Fh			; READ
	mov	cx,end_ahci_init-4	; exclude pointer to next driver
	int	21h
	jc	@@readerr
	cmp	ax,cx
	jb	@@readerr

	mov	ah,3Eh			; CLOSE
	int	21h

	mov	bx,bp			; get back our pointer to the init req
	push	cs			; since strategy is a far function
	call	[pStrategy]		; this is now a pointer to Intel's strat

	; Fix hardcoded PCI addresses before calling "interrupt"
	mov	ds:[hard_pci_addx0],di
	mov	ds:[hard_pci_addx1],di
	mov	ds:[hard_pci_addx2],di
	mov	ds:[hard_pci_addx3],di

	; Fix a messed-up mov instruction in Intel's code
	; It is "mov ebx,0D3Eh" but should have been "mov ebx,dword ptr [0D3Eh]"
	; I know, right??
	; To make matters worse, this gets called from both LocHead and VolSize
	; while for VolSize it should *actually* be "dword ptr [0D36h]"!
	mov	di,ds:badmov[1]		; get operand of "mov ebx,imm32"
	mov	ds:badmov[0],1E8Bh	; "mov ebx,dword ptr [imm16]"
	mov	ds:badmov[2],di		; put in the immediate
if	?BREAKPOINT_BADMOV
	or	ds:badmov[4],0CCh	; spare byte: make it a breakpoint
else
	or	ds:badmov[4],90h	; spare byte: make it a nop
endif

	; Fix a sequence "shl edx,10h ; mov dx,1" which results in ATAPI packet
	; requests only transferring a single byte of data!
	; The correct instruction is "imul edx,10001h", which replicates the
	; same number in the upper and lower halves of EDX.
	; Happily we can fix this by changing exactly four bytes in the code :)
	mov	ds:[badshl],1D269h

	; Fix some integers that are passed as little-endian (usual for x86),
	; forgetting that they will then be translated to big-endian during the
	; construction of an ATAPI packet
	mov	eax,ds:[badendian1]
	xchg	al,ah
	ror	eax,10h
	xchg	al,ah
	mov	ds:[badendian1],eax
	mov	eax,ds:[badendian3]
	xchg	al,ah
	ror	eax,10h
	xchg	al,ah
	mov	ds:[badendian3],eax

	; Fix references to CL that should be to CH, for locking/unlocking door
	mov	ds:[bad_ch0],6Ch	; mov ch,byte ptr ...
	mov	ds:[bad_ch1],0FDh	; cmp ch,imm8
	; Right after this, there is a sequence of instructions that pass bad
	; parameters to a function that is supposed to dispatch an ATAPI packet
	; to the AXth unit of the driver.
	; But, Intel set AX to 8003h in anticipation of bad input, and then they
	; don't fix it back to the unit number.
	; Fortunately we can change twelve bytes to fix it. We change:
	;	mov	ebx,1Eh
	;	mov	edx,0
	; To:
	;	nop	; or int3
	;	mov	ax,bx
	;	mov	ebx,1Eh
	;	xor	edx,edx
if	?BREAKPOINT_BADMOV
	mov	ds:badlockdoor[0],66D889CCh
else
	mov	ds:badlockdoor[0],66D88990h
endif
	mov	ds:badlockdoor[4],1EBBh
	mov	ds:badlockdoor[8],0D2316600h

if	?TESTWITHVBOX
	; VirtualBox has the index port at offset 8 from the base port,
	; as opposed to 10h on QEMU and real hardware...
	; TODO: Detect VirtualBox instead of compile-time switch!
	int	3
	mov	ds:[idxport_offset],8
endif

	; Patch the function tables
	; VolSize patch is to fix a bug
	mov	si,offset OurVolSize + S3FAC
	xchg	ds:IoctlReadCmds[8*2],si
	mov	di,offset pVolSize + S2FAC
	mov	[di],si
ife	?ONLYBUGFIXES
	; DevStat patch is to advertise new functionality
	mov	si,offset OurDevStat + S3FAC
	xchg	ds:IoctlReadCmds[6*2],si
	mov	di,offset pDevStat + S2FAC
	mov	[di],si
	; New features - TODO: implement them!
	; Objective is to reach feature parity with UDVD2
	; mov	si,offset rAudInfo + S3FAC	; UDVD doesn't have this
	; mov	ds:IoctlReadCmds[4*2],si
	; mov	si,offset rDrvBytes + S3FAC	; or this
	; mov	ds:IoctlReadCmds[5*2],si
	mov	si,offset DiskInfo + S3FAC
	mov	ds:IoctlReadCmds[10*2],si
	mov	si,offset TnoInfo + S3FAC
	mov	ds:IoctlReadCmds[11*2],si
	mov	si,offset QInfo + S3FAC
	mov	ds:IoctlReadCmds[12*2],si
	; mov	si,offset SubChanInfo + S3FAC	; UDVD doesn't have this
	; mov	ds:IoctlReadCmds[13*2],si
	; mov	si,offset UPCCode + S3FAC	; or this
	; mov	ds:IoctlReadCmds[14*2],si
	mov	si,offset AudStat + S3FAC
	mov	ds:IoctlReadCmds[15*2],si
	; mov	si,offset wAudInfo + S3FAC	; UDVD doesn't have this
	; mov	ds:IoctlWriteCmds[3*2],si
	; mov	si,offset wDrvBytes + S3FAC	; or this
	; mov	ds:IoctlWriteCmds[4*2],si

	; TODO: Probably no need to patch function table for ReadLong,
	; we may be able to just replumb the function itself with inline patches
	mov	si,offset PlayReq + S3FAC
	mov	ds:CdromCmds[4*2],si
	mov	si,offset StopPlayReq + S3FAC
	mov	ds:CdromCmds[5*2],si
	mov	si,offset ResumeReq + S3FAC
	mov	ds:CdromCmds[8*2],si
endif

	; call the actual init function
	push	cs			; since interrupt is a far function
	call	[pInterrupt]		; this is now a pointer to Intel's int

	; check if it actually found any drives
	cmp	ds:[num_drives],0
	jnz	@F

	mov	ah,9				; write to stdout
	mov	dx,offset nodrives + S2FAC
	int	21h
	mov	es:[bx].InitRq.lpEnd,0		; unload
	mov	word ptr es:[bx+2].InitRq.lpEnd,cs
	mov	es:[bx].RqHdr.wStatus,8002h	; drive not ready
	jmp	@@finished

@@:
	; Relocate Stage 3
	push	es
	push	cs
	pop	es
	assume	es:driver

	cld	; start from the beginning since we're relocating backward
	mov	si,offset stage3 + S2FAC
	mov	di,end_ahci_res
	mov	cx,S3LEN
	bt	cx,0
	jnc	@F
	movsb
@@:
	bt	cx,1
	jnc	@F
	movsw
@@:
	rep	movsd
	pop	es
	assume	es:nothing

	; Intel's driver has stated that it ends at end_ahci_res, but our full
	; driver actually ends S3LEN later - fix that up with DOS!
	add	word ptr es:[bx].InitRq.lpEnd,S3LEN
	jmp	@@finished

@@readerr:
	mov	ah,9				; write to stdout
	mov	dx,offset readerr + S2FAC
	int	21h
	mov	es:[bp].InitRq.lpEnd,0		; unload
	mov	word ptr es:[bp+2].InitRq.lpEnd,cs
	mov	es:[bp].RqHdr.wStatus,800Ch	; general failure

@@finished:
	pop	ds
	assume	ds:nothing
	popad
	pop	es
	ret
stage2_init	endp

readerr		db "Error reading Intel AHCI driver into memory!",0Dh,0Ah,'$'
nodrives	db "Intel AHCI driver found no drives, unloading...",0Dh,0Ah,'$'

; STAGE 3 = resident code/data
; -------   * gets relocated beyond the resident portion of Intel's driver
; -------   * stays resident
align	4
stage3:
; Functions called from inside Intel's interrupt routine
	assume	ds:driver,ss:driver,fs:driver,gs:driver

pVolSize	dw ?	; pointer to original VolSize function
ife	?ONLYBUGFIXES
pDevStat	dw ?	; pointer to original DevStat function

OurDevStat	proc near
	mov	bx,offset pDevStat + S3FAC
	mov	bx,[bx]
	call	bx
	jc	@F

	; Advertise our additional functionality
	; (Raw reading, audio playback, MSF addressing)
	or	word ptr es:[si+1],214h

@@:
	ret
OurDevStat	endp
endif

OurVolSize	proc near
	; The same data-access function is called from both LocHead and VolSize
	; while for VolSize it should be accessing data 8 bytes earlier.
	; So, temporarily fix up the pointer...
	sub	ds:badmov[2],8
	mov	bx,offset pVolSize + S3FAC
	mov	bx,[bx]
	call	bx
	add	ds:badmov[2],8
	ret
OurVolSize	endp

end_stage3:
driver	ends

end
