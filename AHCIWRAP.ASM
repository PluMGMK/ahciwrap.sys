	.8086
	.model	large

?TESTWITHVBOX	equ 0
?ONLYBUGFIXES	equ 0
?INSERTBKPTS	equ 0
?EMSAWARE	equ 1

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

ReadL	struc
	sHdr	RqHdr <?>
	bAMode	db ?		; addressing mode (RedBook / High Sierra)
	wBufOff	dw ?
	wBufSeg	dw ?
	wSectors dw ?
	dwStart	dd ?		; first sector
	bRMode	db ?		; read mode (cooked / raw) - use raw to get 930h
	bISize	db ?		; interleave size
	bISkip	db ?		; interleave skip factor
ReadL	ends

LocHead		struc
	bCode	db ?		; 1 for read
	bAMode	db ?		; addressing mode (RedBook / High Sierra)
	dwLoc	dd ?		; head location returned from driver
LocHead		ends

sDiskInfo	struc
	bCode	db ?		; 10 for read
	bLTrack	db ?
	bHTrack	db ?
	dwLOut	dd ?
sDiskInfo	ends

sTnoInfo	struc
	bCode	db ?		; 11 for read
	bTrack	db ?
	dwStart	dd ?
	bCtlADR	db ?
sTnoInfo	ends

QInfo		struc
	bCode	db ?		; 12 for read
	bCtlADR	db ?
	bTrack	db ?
	bPoint	db ?
	bMinute	db ?
	bSecond	db ?
	bFrame	db ?
	_resd	db ?		; zero
	bPMin	db ?
	bPSec	db ?
	bPFrame	db ?
QInfo		ends

; Code/data positions in Intel's AHCI driver
num_drives	equ byte ptr 15h
; Screwed-up mov instruction
SwapLBA		equ 20CAh	; function containing the instruction
badmov		equ word ptr 20CBh
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
ife	?ONLYBUGFIXES
; Location to patch in ReadLong function
ReadLongBadCom	equ word ptr 1EEBh
SeekBadCom	equ word ptr 1F2Eh
; Last four bytes of function to build ATAPI packet
AtapiPktTail	equ word ptr 2254h
; Function to send ATAPI command with transfer addx in ES:DI
send_pkt_addx	equ 20AAh
; Same thing but without specifying addx (uses internal transfer buf instead)
send_pkt	equ 208Ah
; speaking of which...
XferBuf		equ 0D36h
; where the interrupt routine checks the status
intchecksts	equ 1E09h
; places to inject near calls into the interrupt routine
intloadcmd	equ word ptr 1DCEh
intsavests	equ word ptr 1E0Dh
endif
if	?EMSAWARE
; where the driver fills a linear address into "CTBA" field of command header
fill_ctba	equ word ptr 2459h
; where the driver fills a linear address into "DBA" field of a PRDT entry
fill_prdt_dba	equ word ptr 247Ah
endif
; Endpoints
end_ahci_res	equ 2AC0h
end_ahci_init	equ 2F75h

; Relocation factors
S2FAC	equ	end_ahci_init - offset stage2
S2LEN	equ	end_stage3 - stage2	; we have to relocate both at once!
S3FAC	equ	end_ahci_res - offset stage3
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

if	?EMSAWARE
	push	ds
	push	cs
	pop	ds

	mov	ax,3D00h	; OPEN read-only
	xor	cl,cl
	mov	dx,offset emm_name
	int	21h
	pop	ds
	jc	@@noems

	mov	bx,ax
	mov	ax,4400h	; IOCTL - get device information
	int	21h
	jc	@@noems_fileopen
	bt	dx,7		; device node?
	jnc	@@noems_fileopen

	mov	ax,4407h	; IOCTL - get output status
	int	21h
	test	al,al		; device ready?
	jz	@@noems_fileopen

	mov	ax,0DE00h	; VCPI installation check
	mov	dx,bx		; save file handle
	int	67h
	mov	bx,dx		; get back file handle
	test	ah,ah
	jz	@@vcpiok

	mov	dx,offset novcpi
	call	init_msg
	jmp	@@noems_fileopen

@@vcpiok:
	push	es
	push	cs
	pop	es
	assume	es:driver

	mov	di,offset end_stage3
	mov	ax,5800h	; Get mappable address array
	int	67h
	test	ah,ah
	jnz	@F
	mov	[ems_pgs],cx

	shl	cx,2
	add	di,cx
	mov	dword ptr [di],-1	; mark end of array

@@:
	pop	es
	assume	es:nothing

@@noems_fileopen:
	mov	ah,3Eh		; CLOSE
	int	21h
@@noems:
endif

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
if	?EMSAWARE
	movzx	eax,[ems_pgs]
	inc	eax	; include terminating -1
	shl	eax,2	; amount of memory required to store map data
	; After this, EAX is the largest amount of memory we'll need
	; (after we relocate stage 2 but before we relocate stage 3)
	add	eax,offset end_stage3 + S2FAC
	cmp	edx,eax
else
	; This here is the largest amount of memory we'll need
	; (after we relocate stage 2 but before we relocate stage 3)
	cmp	edx,offset end_stage3 + S2FAC
endif
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
if	?EMSAWARE
	mov	ax,[ems_pgs]
	test	ax,ax
	jz	@F
	inc	ax	; include terminating -1
	shl	ax,2	; amount of memory required to store map data
	add	cx,ax
@@:
endif
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
if	?EMSAWARE
	mov	si,[ems_pgs]
endif
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

if	?EMSAWARE
emm_name	db 'EMMXXXX0'	; device name for EMM
ems_pgs		dw 0		; firstly terminates name, later becomes counter
endif

; Messages
no386		db "No 386 CPU, AHCI driver cannot start!",0Dh,0Ah,'$'
nopcibios	db "No PCI BIOS, AHCI driver cannot find SATA controller!",0Dh,0Ah,'$'
insufmem	db "Insufficient memory for AHCI driver to relocate itself!",0Dh,0Ah,'$'
if	?EMSAWARE
novcpi		db "EMS detected but no VCPI, DMA transfers to EMS buffers may fail silently!",0Dh,0Ah,'$'
endif
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
	; * PCI bus/device/function in DI
	; * Stack has "PUSHAD", ES, and the far return addx for the "interrupt"
if	?EMSAWARE
	; * Number of EMS pages in SI
endif
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

if	?EMSAWARE
	mov	bp,si	; keep the number of EMS pages safe in BP...
	test	bp,bp
	jz	@F

	; replace "mov dword ptr [si],eax" with "call CheckEmSeg"
	mov	ds:[fill_prdt_dba],0E8h	; call rel16
	mov	ds:[fill_ctba],0E8h	; call rel16
	; use S2FAC since this will be called from within init
	; (i.e. before we relocate stage 3!)
	mov	si,offset CheckEmSeg + S2FAC - (fill_prdt_dba+3)
	mov	ds:fill_prdt_dba[1],si
	mov	si,offset CheckEmSeg + S2FAC - (fill_ctba+3)
	mov	ds:fill_ctba[1],si

@@:
endif

	; Fix a messed-up mov instruction in Intel's code
	; It is "mov ebx,0D3Eh" but should have been "mov ebx,dword ptr [0D3Eh]"
	; I know, right??
	; To make matters worse, this gets called from both LocHead and VolSize
	; while for VolSize it should *actually* be "dword ptr [0D36h]"!
	mov	di,ds:badmov[1]		; get operand of "mov ebx,imm32"
	mov	ds:badmov[0],1E8Bh	; "mov ebx,dword ptr [imm16]"
	mov	ds:badmov[2],di		; put in the immediate
if	?INSERTBKPTS
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
if	?INSERTBKPTS
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
	; QInfo is handled directly in ChkStatus
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

	; Patch ReadLong function
	; If it gets MSF addressing or Raw read mode, it returns "bad command"
	; (i.e. mov ax,8003h). Replace this with a jump to our own function!
	mov	ds:ReadLongBadCom[0],0E9h	; jmp rel16
	mov	si,offset OurReadLong + S3FAC - (ReadLongBadCom+3)
	mov	ds:ReadLongBadCom[1],si
	; Same story with Seek
	mov	ds:SeekBadCom[0],0E9h		; jmp rel16
	mov	si,offset OurSeek + S3FAC - (SeekBadCom+3)
	mov	ds:SeekBadCom[1],si
	; Patch function to build ATAPI packet
	; Replace the last three bytes before the RETN with a push instruction,
	; pushing an address of our own function tail so it jumps there instead!
	mov	ds:AtapiPktTail[0],68h		; push imm16
	mov	si,offset OurAtapiPktTail + S3FAC
	mov	ds:AtapiPktTail[1],si

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
	shr	cx,2
if	?EMSAWARE
	test	bp,bp
	jz	@F
	add	cx,bp
	inc	cx	; include terminating -1
@@:
endif
	rep	movsd
	pop	es
	assume	es:nothing

	; Intel's driver has stated that it ends at end_ahci_res, but our full
	; driver actually ends S3LEN later - fix that up with DOS!
	add	word ptr es:[bx].InitRq.lpEnd,S3LEN

if	?EMSAWARE
	test	bp,bp
	jz	@F

	; CheckEmSeg has been relocated so fixup the calls to it
	;mov	si,(S3FAC) - (S2FAC)	; assembler refuses to assemble this
	mov	si,end_ahci_res - end_ahci_init
	sub	si,(offset stage3) - (offset stage2)
	add	ds:fill_prdt_dba[1],si
	add	ds:fill_ctba[1],si

	inc	bp	; include terminating -1
	shl	bp,2	; multiply by four to get full size of EMS table entries
	add	word ptr es:[bx].InitRq.lpEnd,bp
	jmp	@@lenfixed

@@:
	sub	word ptr es:[bx].InitRq.lpEnd,(end_stage3 - end_stage3_noems)

@@lenfixed:
endif

	; patch the interrupt function to point to Stage 3
	; change "mov al,es:[si].RqHdr.bCmd" to "call ChkStatus"
	mov	si,offset ChkStatus + S3FAC - offset intloadcmd[4]
if	?INSERTBKPTS
	mov	ds:intloadcmd[0],0E8CCh
else
	mov	ds:intloadcmd[0],0E890h
endif
	mov	ds:intloadcmd[2],si
	; change "mov es:[bx].RqHdr.wStatus,ax" to "call SetStatus"
	mov	si,offset SetStatus + S3FAC - offset intsavests[4]
if	?INSERTBKPTS
	mov	ds:intsavests[0],0E8CCh
else
	mov	ds:intsavests[0],0E890h
endif
	mov	ds:intsavests[2],si

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
wAudStat	dw 0	; word that can be ORed with return code to set busy bit

sHSGread	ReadL {<?>}

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

; Takes RedBook M:S:F address in EAX and returns HSG sector in EAX
redbook2hsg	proc near	uses edx ecx
	mov	edx,eax
	shr	edx,10h	; EDX = minutes
	imul	edx,edx,60
	movzx	ecx,ah	; seconds
	add	edx,ecx
	imul	edx,edx,75
	movzx	ecx,al	; frames
	lea	eax,[ecx+edx-150]
	ret
redbook2hsg	endp

; Takes HSG sector in EAX and returns RedBook M:S:F address in EAX
hsg2redbook	proc near	uses edx ecx bx
	add	eax,150
	xor	edx,edx
	mov	ecx,75
	div	ecx
	; Now EDX = frames, EAX = seconds + 60*minutes
	mov	bl,dl
	xor	edx,edx
	mov	ecx,60
	div	ecx
	; Now EDX = seconds, EAX = minutes
	mov	bh,dl
	shl	eax,10h	; Move minutes into upper word
	mov	ax,bx	; Get seconds and frames into lower word
	ret
hsg2redbook	endp

; Called at beginning of interrupt to check for "busy" status
ChkStatus	proc near
	movzx	ax,es:[si].RqHdr.bCmd
	movzx	bp,es:[si].RqHdr.bUnit

	mov	ebx,42h		; ATAPI "READ SUB-CHANNEL"
	mov	ecx,10000h	; Big-Endian: second byte is 01h
				; (sub-channel data format = CD-ROM position)
	mov	edx,4		; Just the header

	cmp	ax,3		; IOCTL Read?
	jne	@@issuecmd

	push	es
	push	si
	les	si,dword ptr es:[si].IOCTLRW.wBufOff
	mov	ah,es:[si]
	pop	si
	pop	es
	cmp	ah,12		; QInfo
	je	@F
	cmp	ah,1		; LocHead
	je	@F
	xor	ah,ah
	jmp	@@issuecmd

@@:
	; We're going to execute the command here, so change the return addx
	add	sp,2		; discard the old one
	push	intchecksts

	mov	edx,10h		; The full set of sub-channel data
	bts	ecx,1Eh		; SubQ bit (Big-Endian)

	mov	di,es:[si].IOCTLRW.wCount
	cmp	ah,12
	jne	@F
	cmp	di,sizeof QInfo
	jb	@@badlen
@@:
	cmp	di,sizeof LocHead
	jnb	@F
@@badlen:
	mov	bp,8005h	; bad length
	jmp	@@done

@@:
	cmp	ah,12
	je	@F

	; if we're here, it's LocHead
	push	es
	push	si
	les	si,dword ptr es:[si].IOCTLRW.wBufOff
	cmp	es:[si].LocHead.bAMode,1
	pop	si
	pop	es

	jb	@@issuecmd
	je	@F
	mov	bp,8003h	; unknown command
	jmp	@@done

@@:
	mov	bh,2		; set MSF bit in ATAPI packet, using EBX

@@issuecmd:
	push	es
	push	si
	push	ax

	mov	ax,bp		; get the unit number
	mov	bp,send_pkt
	call	bp
	mov	bp,ax		; save return code

	pop	ax
	pop	si
	pop	es
	jc	@@done

	xor	dx,dx
	cmp	byte ptr ds:XferBuf[1],11h	; audio status == playing
	jne	@@setstatcode
	bts	dx,9		; "busy"

	cmp	ax,80h		; READ LONG
	je	@@failbusy
	cmp	ax,82h		; READ LONG PREFETCH
	je	@@failbusy
	cmp	ax,83h		; SEEK
	jne	@@setstatcode

@@failbusy:
	mov	ax,8002h	; drive not ready
	mov	bp,ax		; since this sets AH!
	add	sp,2		; discard the old return addx
	push	intchecksts

@@setstatcode:
	mov	di,offset wAudStat + S3FAC
	mov	[di],dx

	test	ah,ah		; did we already service the command?
	jz	@@done		; nope, proceed to Intel command service logic

	push	es
	push	si
	les	si,dword ptr es:[si].IOCTLRW.wBufOff

	cmp	ah,12		; QInfo
	jne	@F		; LocHead

	; A little knowledge is a dangerous thing...
	; ATAPI CD-ROM drives do some conversion of the Q-Channel info before
	; sending it to the host, which is generally helpful.
	; They swap the control and ADR nibbles and convert all the BCD numbers.
	; The MSCDEX spec requires the MSF frames to be converted from BCD, so
	; in this case the hardware has already done that for us, we're good.
	; *BUT* the MSCDEX spec requires that Control/ADR, Track Number and
	; Index number be "passed through as they appear on the disc".
	; So for those, we need to *undo* the hardware's helpful conversion :(
	push	eax
	mov	eax,ds:XferBuf[5]
	ror	al,4		; swap Control/ADR
	mov	es:[si].QInfo.bCtlADR,al

	shr	eax,8		; AL = Track, AH = Index
	mov	cl,ah		; Save Index
	aam
	shl	ah,4
	or	al,ah

	xchg	al,cl		; Get back the Index
	aam
	shl	ah,4
	or	ah,al

	mov	al,cl		; Get back the Track
	mov	word ptr es:[si].QInfo.bTrack,ax

	; Pass through non-BCD MSF values
	; MSCDEX puts time-on-track first, opposite of ATAPI...
	mov	eax,ds:XferBuf[13]
	mov	dword ptr es:[si].QInfo.bMinute,eax
	mov	eax,ds:XferBuf[9]
	mov	dword ptr es:[si].QInfo._resd,eax

	pop	eax
	jmp	@@ioctldone

@@:
	mov	bx,SwapLBA
	call	bx
	mov	es:[si].LocHead.dwLoc,ebx

@@ioctldone:
	pop	si
	pop	es
@@done:
	test	ah,ah
	jz	@F
	mov	ax,bp		; get return code
	bt	ax,0Fh		; set carry if AX & 8000h
@@:
	; Restore upper halves of regs to zero, as they were in the interrupt
	; routine itself!
	movzx	eax,ax
	movzx	ebx,bx
	movzx	ecx,cx
	movzx	edx,dx

	ret
ChkStatus	endp

; Called at end of interrupt to set "busy" status bit in return structure
SetStatus	proc near
	mov	di,offset wAudStat + S3FAC
	or	ax,[di]
	mov	es:[bx].RqHdr.wStatus,ax
	ret
SetStatus	endp

OurAtapiPktTail	proc near
	; At this point, DS:SI points to a valid ATAPI packet, except
	; this one byte that didn't get filled in because of our patching:
	mov	[si+8],dl

	; Now, check if it's a "read raw"...
	cmp	byte ptr [si],0BEh
	jne	@F
	; If so, fill in the "data selection" field:
	mov	byte ptr [si+9],0F8h ; Sync & All Headers & User Data + EDC/ECC

@@:
	; Maybe it's a "read TOC"?
	cmp	byte ptr [si],43h
	jne	@F
	; Then [SI+5] contains a track number, which should be in [SI+6]
	xchg	cl,byte ptr [si+5]	; CL should be zero
	xchg	cl,byte ptr [si+6]

@@:
	ret
OurAtapiPktTail	endp

OurReadLong	proc near
	cmp	es:[si].ReadL.bAMode,1
	ja	@@invalid
	je	@@msf

	cmp	es:[si].ReadL.bRMode,1
	ja	@@invalid
	; Don't need to check for bRMode = 0 because this function should never
	; be reached when bAMode and bRMode are both zero...

	; If we're here then we need to do a raw read
	mov	ebx,0BEh	; ATAPI "READ CD"
	mov	ecx,es:[si].ReadL.dwStart
	movzx	edx,es:[si].ReadL.wSectors
	imul	edx,9300001h	; Upper half = #bytes, lower half = #sectors
	jo	@@invalid	; Data won't fit in one segment!

	push	es
	push	di
	les	di,dword ptr es:[si].ReadL.wBufOff
	mov	si,send_pkt_addx
	call	si
	pop	di
	pop	es
	ret

@@msf:
	cmp	byte ptr es:[si].ReadL.dwStart,75
	jnb	@@invalid
	cmp	byte ptr es:[si+1].ReadL.dwStart,60
	jnb	@@invalid
	cmp	byte ptr es:[si+2].ReadL.dwStart,100
	jnb	@@invalid

	; Right, all good. Create a copy of the request block...
	push	es
	push	si
	push	fs
	
	push	es
	pop	fs
	push	ds
	pop	es
	assume	fs:nothing,es:driver
	mov	cx,sizeof ReadL
	mov	di,offset sHSGread + S3FAC
	rep	movsb es:[di],fs:[si]

	mov	si,offset sHSGread + S3FAC
	; ... and convert its starting point from redbook to HSG
	push	eax
	mov	eax,es:[si].ReadL.dwStart
	call	redbook2hsg
	mov	es:[si].ReadL.dwStart,eax
	pop	eax
	dec	es:[si].ReadL.bAMode

	; Now pass this HSG-mode request through to the original function!
	call	ds:CdromCmds[0]

	pop	fs
	pop	si
	pop	es
	assume	es:nothing,fs:driver
	ret

@@invalid:
	mov	ax,8008h	; sector not found
	ret
OurReadLong	endp

OurSeek		proc near
	dec	es:[si].ReadL.bAMode
	jnz	@@invalid

	cmp	byte ptr es:[si].ReadL.dwStart,75
	jnb	@@invalid
	cmp	byte ptr es:[si+1].ReadL.dwStart,60
	jnb	@@invalid
	cmp	byte ptr es:[si+2].ReadL.dwStart,100
	jnb	@@invalid

	; Right, all good. Create a copy of the request block...
	push	es
	push	si
	push	fs
	
	push	es
	pop	fs
	push	ds
	pop	es
	assume	fs:nothing,es:driver
	mov	cx,sizeof ReadL
	mov	di,offset sHSGread + S3FAC
	rep	movsb es:[di],fs:[si]

	mov	si,offset sHSGread + S3FAC
	; ... and convert its starting point from redbook to HSG
	push	eax
	mov	eax,es:[si].ReadL.dwStart
	call	redbook2hsg
	mov	es:[si].ReadL.dwStart,eax
	pop	eax

	; Now pass this HSG-mode request through to the original function!
	call	ds:CdromCmds[6]

	pop	fs
	pop	si
	pop	es
	assume	es:nothing,fs:driver
	ret

@@invalid:
	mov	ax,8008h	; sector not found
	ret
OurSeek		endp

; TODO: Implement these
PlayReq		proc near
PlayReq		endp

StopPlayReq	proc near
StopPlayReq	endp

ResumeReq	proc near
ResumeReq	endp

AudStat		proc near
	mov	ax,8003h	; not implemented yet...
	ret
AudStat		endp

; Takes unit number in AX and track number in CL
; Reads TOC info for at most one track to internal transfer buffer
; Returns track starting point (MSF) in EBX, return code in AX
ReadTOC		proc near	uses es si di ; due to calling send_pkt!
	mov	ebx,243h	; ATAPI "READ TOC" with MSF bit set
	movzx	ecx,cl		; Format = 0 = data for specified track
	mov	edx,0Ch		; Enough space for one track descriptor
	
	mov	bp,send_pkt
	call	bp
	jc	@F

	; Track starting point is at XferBuf[8]
	mov	bx,SwapLBA
	call	bx
	clc

@@:
	ret
ReadTOC		endp

DiskInfo	proc near
	cmp	cx,size sDiskInfo
	jnb	@F
	mov	ax,8005h	; bad length
	ret

@@:
	mov	ecx,0AAh	; leadout track
	call	ReadTOC
	jnc	@F
	ret

@@:
	mov	es:[si].sDiskInfo.dwLOut,ebx
	mov	bx,word ptr ds:XferBuf[2]
	mov	word ptr es:[si].sDiskInfo.bLTrack,bx
	ret
DiskInfo	endp

TnoInfo		proc near
	cmp	cx,size sTnoInfo
	jnb	@F
	mov	ax,8005h	; bad length
	ret

@@:
	mov	cl,es:[si].sTnoInfo.bTrack
	call	ReadTOC
	jnc	@F
	ret

@@:
	mov	es:[si].sTnoInfo.dwStart,ebx
	mov	bl,byte ptr ds:XferBuf[5]
	ror	bl,4	; Swap Control/ADR!
	mov	es:[si].sTnoInfo.bCtlADR,bl
	clc
	ret
TnoInfo		endp
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

if	?EMSAWARE
end_stage3_noems:
CheckEmSeg	proc near uses di bx ecx edx
	smsw	di
	bt	di,0
	jnc	@@done	; not in Protected Mode, no need to check anything

	call	@F
@@:
	pop	di
	; get (non-constant) address of end_stage3 into DI
	add	di,(end_stage3 - @B)

	; Iterate through EMS pages and figure out if buffer is in any of them
	mov	ecx,eax
	shr	ecx,4	; get the segment

@@:
	cmp	dword ptr [di],-1
	je	@@done
	cmp	cx,[di]	; is the buffer after the start of this page?
	jb	@@next	; nope, check next one

	mov	bx,cx
	sub	bx,[di]
	cmp	bx,400h	; is the buffer before the end of this page?
	jnb	@@next	; nope, check next one

	mov	bx,ax
	and	bx,0FFFh; offset in page
	shr	ecx,8	; turn segment into page index
	mov	ax,0DE06h; get physical address of 4K Page
	int	67h

	test	ah,ah
	jz	@@success

	; uh-oh, VCPI couldn't tell us the physical page addx!
	; just reconstruct the linear one and hope for the best...
	movzx	eax,cx
	shl	eax,12
	or	ax,bx
	jmp	@@done

@@next:
	add	di,4
	jmp	@B

@@success:
	; EDX = beginning of physical page
	mov	eax,edx
	; BX = offset
	or	ax,bx
	; Now EAX = physical addx of buffer
	; TODO: What about buffers on non-contiguous pages??

@@done:
	mov	[si],eax
	ret
CheckEmSeg	endp
endif

align	4
end_stage3:
driver	ends

end
