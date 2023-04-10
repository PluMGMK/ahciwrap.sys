	.8086
	.model	large

?TESTWITHVBOX	equ 0
?ONLYBUGFIXES	equ 0
?INSERTBKPTS	equ 0
?VDSAWARE	equ 1
?BACKUP_STATE	equ 1	; backup port states before issuing IDENTIFY
?FIXUNALIGNED	equ 1

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

PlayReq	struc
	sHdr	RqHdr <?>
	bAMode	db ?		; addressing mode (RedBook / High Sierra)
	dwStart	dd ?		; first sector
	dwSectors dd ?
PlayReq	ends

LocHead	struc
	bCode	db ?		; 1 for read
	bAMode	db ?		; addressing mode (RedBook / High Sierra)
	dwLoc	dd ?		; head location returned from driver
LocHead	ends

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

sAudStat	struc
	bCode	db ?		; 15 for read
	wStatus	dw ?		; Bit 0 = paused, all others reserved
	dwStart	dd ?
	dwEnd	dd ?
sAudStat	ends

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

if	?VDSAWARE
; Extra flags used if ?VDSAWARE:
; Bit 4 = FIS DMA region locked
EBIT_FIS_DDS_LOCKED	equ 4
EFLAG_FIS_DDS_LOCKED	equ 1 SHL EBIT_FIS_DDS_LOCKED
; Bit 5 = CmdList DMA region locked
EBIT_CL_DDS_LOCKED	equ 5
EFLAG_CL_DDS_LOCKED	equ 1 SHL EBIT_CL_DDS_LOCKED
; Bit 6 = CmdTable DMA region locked
EBIT_CTBL_DDS_LOCKED	equ 6
EFLAG_CTBL_DDS_LOCKED	equ 1 SHL EBIT_CTBL_DDS_LOCKED
; Bit 7 = PRDT DMA region locked
EBIT_PRDT_EDDS_LOCKED	equ 7
EFLAG_PRDT_EDDS_LOCKED	equ 1 SHL EBIT_PRDT_EDDS_LOCKED
endif

; This structure is at SS:[BP] during most of AHCI.SYS's operation
ahcidrv_stack	struc
	lpDataBase	dd ?
	qwLBA		dq ?
	dwExpectedCount	dd ?
	wDwordCount	dw ?
	wPortOffset	dw ?
	bCount		db ?
	bPort		db ?
	bDevice		db ?	; For port multipliers
	bFlags		db ?	; We can use extra flags, as given above
	bSlotMask	db ?
	bCurSlot	db ?
if	?BACKUP_STATE
	qwSavedFB	dq ?
	qwSavedCLB	dq ?
	dwSavedCmd	dd ?
	unused		db 18 dup(?)
else
	unused		db 38 dup(?)
endif
	pushad_edi	dd ?
	pushad_esi	dd ?
	pushad_ebp	dd ?
	pushad_esp	dd ?
	pushad_ebx	dd ?
	pushad_edx	dd ?
	pushad_ecx	dd ?
	pushad_eax	dd ?
	client_ds	dw ?
	client_es	dw ?
	client_fs	dw ?
	client_gs	dw ?
ahcidrv_stack	ends

if	?VDSAWARE
; The most data we can transfer is a single segment is 10000h bytes.
; This is 10h pages, but the beginning and end aren't necessarily page-aligned
; so the data may span a total of 11h pages.
?MAX_PRDT_ENTRIES	equ 11h

HBA_PRDT_ENTRY	struc
	dba	dq ?
	rsv0	dd ?
	dbc	dd ?	; MSB = i = interrupt on completion
HBA_PRDT_ENTRY	ends

HBA_CMD_TBL	struc
	cfis	db 14h dup (?)
	_resd0	db 2Ch dup (?)
	acmd	db 10h dup (?)
	_resd1	db 30h dup (?)
	prdt	HBA_PRDT_ENTRY ?MAX_PRDT_ENTRIES dup (<?>)
HBA_CMD_TBL	ends

DD_Struc	struc
	DD_size		dd ?
	DD_offset	dd ?
	DD_segment	dw ?
	DD_bufid	dw ?
	DD_physaddx	dd ?
DD_Struc	ends

EDD_Region	struc
	EDD_physaddx	dd ?
	EDD_physsize	dd ?
EDD_Region	ends

EDD_Struc	struc
	EDD_size	dd ?
	EDD_offset	dd ?
	EDD_segment	dd ?
	EDD_numavail	dw ?
	EDD_numused	dw ?
	EDD_regions	EDD_Region ?MAX_PRDT_ENTRIES dup (<?>)
EDD_Struc	ends

; A nice big structure to make better use of space lying idle in Intel's driver!
CmdTbl_plus_VDS	struc
	; The command table, as set up by Intel's driver itself
	CmdTable	HBA_CMD_TBL <?>
	; DDSes to lock the DMA regions for command table, command list and FIS
	CmdTbl_DDS	DD_Struc <?>
	CmdList_DDS	DD_Struc <?>
	FIS_DDS		DD_Struc <?>
	; An EDDS to lock the scatter/gather DMA region for the actual data transfer
	; (used in turn to fill in the PRDT)
	PRDT_EDDS	EDD_Struc <?>
CmdTbl_plus_VDS	ends
; Intel driver only gives us 1 kiB to play with...
.errnz ((sizeof CmdTbl_plus_VDS) gt 400h)
endif

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
if	?FIXUNALIGNED
; where the driver sets a transfer "offset" in a structure on the stack
setxferoff	equ word ptr 2320h
; where stopcmd gets called when a command is finished
call_stopcmd	equ word ptr 2553h
else
; Bad jump on encountering unaligned transfer addx
badjmp_unaln	equ byte ptr 2479h
endif
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
if	?VDSAWARE
; where the driver fills a linear address into "CLB" field of the port
set_cmdlistbase	equ word ptr 263Dh	; add eax,ebx
; where the driver fills a linear address into "FB" field of the port
set_fisbase	equ word ptr 2661h	; add eax,ebx
; where the driver fills a linear address into "CTBA" field of command header
fill_ctba	equ word ptr 2456h	; add eax,ebx
; where the driver starts setting up PRDT entries
setup_prdt	equ word ptr 246Fh	; shl edx,4
setup_prdt_done	equ 24AAh	; return to here to skip Intel's logic
; where the driver calls a function to wait for the CR bit to be unset
stop_cmd_wtcrus	equ word ptr 25FFh	; call wait_cr_unset
; the function it calls
wait_cr_unset	equ 2735h

pCmdTable	equ word ptr 30h
endif
if	?BACKUP_STATE
; where the driver calls "stop_cmd" before starting the IDENTIFY sequence
idn_stop_cmd	equ word ptr 22B3h
; where the driver calls "do_pio_cmd" to execute the IDENTIFY sequence
idn_do_pio_cmd	equ word ptr 22D2h
; the functions it's actually calling
stop_cmd	equ 25CCh
do_pio_cmd	equ 24EBh

; helper functions that we can also use
read_hbaport	equ 28ECh
write_hbaport	equ 2926h
endif

; Endpoints
end_ahci_res	equ 2AC0h
end_ahci_init	equ 2F75h

; Relocation factors
S2FAC	equ	end_ahci_init - offset stage2
S2LEN	equ	end_stage3 - stage2	; we have to relocate both at once!
S3FAC	equ	end_ahci_res - offset stage3
S3LEN	equ	end_stage3 - stage3

; Other miscellaneous equates
BDA_SEGMENT	equ 40h	; BIOS Data Area segment
EBDA_OFFSET	equ 0Eh	; Offset within BDA of pointer to Extended BDA segment
VDS_FLAG_OFFSET	equ 7Bh	; Offset within BDA of Virtual DMA Spec flags

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
; These can be in stage 2 since they're not needed after init
if	?BACKUP_STATE
SavePortState	proc near
	push	bx
	push	di
	mov	di,read_hbaport	; need to call indirectly...

	xor	bx,bx		; CLB is at offset zero
	call	di
	mov	dword ptr [bp.ahcidrv_stack.qwSavedCLB],eax
	add	bx,4		; upper half
	call	di
	mov	dword ptr [bp.ahcidrv_stack.qwSavedCLB+4],eax

	mov	bx,8		; FB is at offset 8
	call	di
	mov	dword ptr [bp.ahcidrv_stack.qwSavedFB],eax
	add	bx,4		; upper half
	call	di
	mov	dword ptr [bp.ahcidrv_stack.qwSavedFB+4],eax

	mov	bx,18h		; Cmd is at offset 18h
	call	di
	mov	dword ptr [bp.ahcidrv_stack.dwSavedCmd],eax

	pop	di
	pop	bx

	; Jump back to the original function (have to do it indirectly)
	mov	ax,stop_cmd
	jmp	ax
SavePortState	endp

RestPortState	proc near
	; Call through to the original function (have to do it indirectly)
	mov	ax,do_pio_cmd
	call	ax

	push	eax
	push	bx
	push	di
	mov	di,write_hbaport; need to call indirectly...

	xor	bx,bx		; CLB is at offset zero
	mov	eax,dword ptr [bp.ahcidrv_stack.qwSavedCLB]
	call	di
	add	bx,4		; upper half
	mov	eax,dword ptr [bp.ahcidrv_stack.qwSavedCLB+4]
	call	di

	mov	bx,8		; FB is at offset 8
	mov	eax,dword ptr [bp.ahcidrv_stack.qwSavedFB]
	call	di
	add	bx,4		; upper half
	mov	eax,dword ptr [bp.ahcidrv_stack.qwSavedFB+4]
	call	di

	mov	bx,18h		; Cmd is at offset 8
	mov	eax,dword ptr [bp.ahcidrv_stack.dwSavedCmd]
	call	di

	pop	di
	pop	bx
	pop	eax

	; set CF as appropriate for return from do_pio_cmd
	cmp	ah,1
	cmc
	ret
RestPortState	endp
endif

stage2_init	proc far
	; At this point, we have the following:
	; * File handle for Intel driver in BX
	; * DOS "Init" device request in ES:BP
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

if	?VDSAWARE
	; replace "add eax,ebx" with "call FixupCLB" / "call FixupFB"
	mov	ds:[set_cmdlistbase],0E8h	; call rel16
	mov	ds:[set_fisbase],0E8h		; call rel16
	mov	ds:[fill_ctba],0E8h		; call rel16
	mov	ds:[setup_prdt],0E8h		; call rel16
if	?INSERTBKPTS
	mov	ds:setup_prdt[2],0CC00h		; int3 after three bytes
else
	mov	ds:setup_prdt[2],9000h		; nop after three bytes
endif
	; use S2FAC since this will be called from within init
	; (i.e. before we relocate stage 3!)
	mov	si,offset FixupCLB + S2FAC - (set_cmdlistbase+3)
	mov	ds:set_cmdlistbase[1],si
	mov	si,offset FixupFB + S2FAC - (set_fisbase+3)
	mov	ds:set_fisbase[1],si
	mov	si,offset FixupCTBA + S2FAC - (fill_ctba+3)
	mov	ds:fill_ctba[1],si
	mov	si,offset FixupPRDT + S2FAC - (setup_prdt+3)
	mov	ds:setup_prdt[1],si
	; this is already a call, so no need to insert 0E8h
	mov	si,offset stop_cmd_redir + S2FAC - (stop_cmd_wtcrus+3)
	mov	ds:stop_cmd_wtcrus[1],si
endif

if	?BACKUP_STATE
	; Intel's AHCI CD driver is designed to operate in conjunction with its
	; AHCI firmware, which handles int 13h requests. Intel's firmware and CD
	; driver both reinitialize the FB, CLB and Cmd registers before every
	; transaction, which means there is no conflict between them, even when
	; the CD driver temporarily takes control of each port to identify the
	; attached devices.
	; HOWEVER, other firmware (e.g. SeaBIOS) naively assumes that nobody
	; interferes with FB, CLB and Cmd, which results in all int 13h requests
	; timing out after this driver attempts to identify the devices.
	; To prevent this, we save FB, CLB and Cmd before each IDENTIFY command
	; is issued, and restore them afterwards.

	; these are already calls, so no need to insert 0E8h
	mov	si,offset SavePortState + S2FAC - (idn_stop_cmd+3)
	mov	ds:idn_stop_cmd[1],si
	mov	si,offset RestPortState + S2FAC - (idn_do_pio_cmd+3)
	mov	ds:idn_do_pio_cmd[1],si
	; Note: we don't need to fix these up later, since the IDENTIFY sequence
	; is only ever called from the init code!
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

ife	?FIXUNALIGNED
	; this JMP goes two bytes too far, pull it back
	sub	ds:[badjmp_unaln],2
endif

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

	mov	si,offset Play + S3FAC
	mov	ds:CdromCmds[4*2],si
	mov	si,offset StopPlay + S3FAC
	mov	ds:CdromCmds[5*2],si
	mov	si,offset Resume + S3FAC
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
.erre	S3LEN LE ($ + S2FAC) - end_ahci_res, <"Stage 3 too big!">
	rep	movsd
	pop	es
	assume	es:nothing

	; Intel's driver has stated that it ends at end_ahci_res, but our full
	; driver actually ends S3LEN later - fix that up with DOS!
	add	word ptr es:[bx].InitRq.lpEnd,S3LEN

if	?VDSAWARE
	; FixupCLB & co. have been relocated so fixup the calls to them
	;mov	si,(S3FAC) - (S2FAC)	; assembler refuses to assemble this
	mov	si,end_ahci_res - end_ahci_init
	sub	si,(offset stage3) - (offset stage2)
	add	ds:set_cmdlistbase[1],si
	add	ds:set_fisbase[1],si
	add	ds:fill_ctba[1],si
	add	ds:setup_prdt[1],si
	add	ds:stop_cmd_wtcrus[1],si
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

if	?FIXUNALIGNED
	; change "mov [bp+0],ax" to "call ChkAlign"
	mov	ds:setxferoff[0],0E8h	; call rel16
	mov	si,offset ChkAlign + S3FAC - offset setxferoff[3]
	mov	ds:setxferoff[1],si
	; change "call stopcmd" to "call FixAlign"
	mov	si,offset FixAlign + S3FAC - offset call_stopcmd[3]
	xchg	si,ds:call_stopcmd[1]
	add	si,offset call_stopcmd[3]
	mov	di,offset pStopcmd + S3FAC
	mov	[di],si				; save addx of actual stopcmd
endif

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
if	?FIXUNALIGNED
pStopcmd	dw ?	; pointer to original stopcmd function
bSavedByte	db ?
bUnaligned	db 0	; set to 1 when an unaligned read is in progress
endif
ife	?ONLYBUGFIXES
pDevStat	dw ?	; pointer to original DevStat function
wAudStat	dw 0	; word that can be ORed with return code to set busy bit

sHSGread	ReadL {<?>}
curAudStat	sAudStat {?}

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
	cmp	ax,85h		; STOP AUDIO (pause)
	jne	@F

	mov	edx,10h		; The full set of sub-channel data
	bts	ecx,1Eh		; SubQ bit (Big-Endian)

@@:
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
	cmp	byte ptr ds:XferBuf[1],12h	; audio status == paused
	mov	di,offset curAudStat.wStatus + S3FAC
	setz	[di]				; set bit 0 of AudStat word

	mov	di,offset wAudStat + S3FAC
	mov	[di],dx

	cmp	ax,85h		; STOP AUDIO (pause)
	jne	@F
	mov	bx,SwapLBA
	call	bx
	mov	di,offset curAudStat.dwStart + S3FAC
	mov	[di],ebx

@@:
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

Play		proc near
	cmp	es:[si].RqHdr.bLen,sizeof PlayReq
	jae	@F

	mov	ax,8005h	; bad length
	ret

@@:
	cmp	es:[si].PlayReq.bAMode,1
	jna	@F
@@badsec:
	mov	ax,8008h	; sector not found
	ret

@@:
	mov	bp,ax		; save unit number
	mov	eax,es:[si].PlayReq.dwStart
	jb	@F		; we got a HSG address
	call	redbook2hsg
@@:
	mov	ebx,45h		; ATAPI "PLAY AUDIO"
	mov	ecx,eax
	mov	edx,es:[si].PlayReq.dwSectors
	cmp	edx,10000h	; can't play more than ~14.5 mins with command
	jnb	@@badsec	; 45h... Should be enough for most usecases?

	mov	ax,bp		; restore unit number
	lea	ebp,[ecx+edx]	; end of the play window

	; We have to be careful with the way the Intel driver handles data
	; transfer. Because we have set a transfer length in sectors in DX,
	; it will assume we want to read DX*2048 bytes into a buffer somewhere,
	; unless we set the upper half of EDX to some other number.
	; Set it to 1 to stop this (as it rounds down to nearest DWORD).
	or	edx,10000h
	push	es
	push	di

	push	cs
	pop	es
	mov	di,offset curAudStat + S3FAC	; unused byte
	mov	si,send_pkt_addx
	call	si
	jc	@F

	; audio is now playing!
	bts	ax,9
	mov	[di].sAudStat.wStatus,0
	mov	[di].sAudStat.dwStart,ecx
	mov	[di].sAudStat.dwEnd,ebp

@@:
	pop	di
	pop	es
	ret
Play		endp

StopPlay	proc near
	xor	ecx,ecx
	xor	edx,edx

	mov	bx,offset curAudStat + S3FAC
	bt	word ptr [bx].sAudStat.wStatus,0
	jnc	@@pause	; not paused, so go do that

	; already paused, so stop altogether
	mov	ebx,4Eh
	mov	bp,send_pkt
	call	bp
	jc	@F

@@zeroblock:
	; zero out the audio status block
	mov	bx,offset curAudStat + S3FAC
	mov	[bx].sAudStat.wStatus,cx
	mov	[bx].sAudStat.dwStart,ecx
	mov	[bx].sAudStat.dwEnd,ecx
@@:
	ret

@@pause:
	mov	bp,offset wAudStat + S3FAC
	btr	word ptr ds:[bp],9

	mov	bp,ax		; save unit number
	mov	ax,100h		; "successfully" ignore request
	jnc	@@zeroblock	; not playing, nothing to pause

	mov	ebx,4Bh		; ATAPI "PAUSE/RESUME"
	mov	ax,bp		; get the unit number
	mov	bp,send_pkt
	call	bp
	jnc	@B		; all good, return

	bts	ax,9		; still playing since we failed to pause...
	ret
StopPlay	endp

Resume		proc near
	mov	bx,offset curAudStat + S3FAC
	bt	word ptr [bx].sAudStat.wStatus,0
	jc	@F

	; not paused, nothing to do...
	mov	ax,8002h	; not ready
	ret

@@:
	mov	ebx,4Bh		; ATAPI "PAUSE/RESUME"
	xor	ecx,ecx
	mov	dx,1		; resume flag

	mov	bp,send_pkt
	call	bp
	jc	@F

	bt	ax,9		; playing
@@:
	ret
Resume		endp

AudStat		proc near
	cmp	cx,size sAudStat
	jnb	@F
	mov	ax,8005h	; bad length
	ret

@@:
	lea	di,[si+1]	; now ES:DI points to user buffer, after bCode
	mov	si,offset curAudStat + S3FAC + 1
	dec	cx
	cld
	rep	movsb
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

if	?FIXUNALIGNED
ChkAlign	proc near	uses es di si
	mov	di,offset bSavedByte + S3FAC

	btr	ax,0
	setc	[di+1]
	jnc	@F

	mov	es,dx
	mov	si,ax

	push	ax
	mov	al,es:[si]
	mov	[di],al
	pop	ax

@@:
	mov	[bp],ax
	ret
ChkAlign	endp

FixAlign	proc near
	mov	bx,offset pStopcmd + S3FAC
	mov	bx,[bx]
	call	bx

	mov	bx,offset bSavedByte + S3FAC
	btr	word ptr [bx],8
	jnc	@F

	mov	es,[bp+2]	; transfer segment
	mov	si,[bp]		; transfer offset
	mov	cx,[bp+10h]	; number of dwords

	std	; start from the end since we're moving dwords forwards
	mov	di,cx
	dec	di
	shl	di,2
	add	si,di
	lea	di,[si+1]	; move forwards by one byte
	rep	movsd es:[di],es:[si]

	mov	al,[bx]
	mov	es:[si],al	; restore saved byte

@@:
	ret
FixAlign	endp
endif

if	?VDSAWARE
; Takes:
; DI = offset of DDS within CmdTbl_plus_VDS
; DS:EBX = location of region to lock
; ECX = size of region to lock
; DX = flag to check/set on stack
LockRegion	proc near	uses es
	add	eax,ebx		; this is the instruction we've overwritten

	call	Check_VDS
	jnc	@F

	bt	word ptr [bp.ahcidrv_stack.bFlags],dx
	jc	@F

	push	cs
	pop	es

	add	di,ds:[pCmdTable]
	mov	es:[di.DD_Struc.DD_size],ecx
	; The segment is in DS, and the offset is in EBX
	mov	es:[di.DD_Struc.DD_offset],ebx
	mov	es:[di.DD_Struc.DD_segment],ds

	push	eax
	push	dx
	mov	ax,8103h; LOCK DMA REGION
	mov	dx,4	; buffer should not be allocated if non-contiguous
	int	4Bh
	pop	dx
	pop	eax

	jc	@F	; use the Linear Address and hope for the best
	mov	eax,es:[di.DD_Struc.DD_physaddx]
	bts	word ptr [bp.ahcidrv_stack.bFlags],dx

@@:
	ret
LockRegion	endp

FixupCLB	proc near	uses ecx di dx
	mov	ecx,400h	; A command list can be up to 1 kiB long
	mov	di,CmdTbl_plus_VDS.CmdList_DDS
	mov	dx,EBIT_CL_DDS_LOCKED
	call	LockRegion
	ret
FixupCLB	endp

FixupFB		proc near	uses ecx di dx
	mov	ecx,100h	; FIS is 100h bytes long
	mov	di,CmdTbl_plus_VDS.FIS_DDS
	mov	dx,EBIT_FIS_DDS_LOCKED
	call	LockRegion
	ret
FixupFB		endp

FixupCTBA	proc near	uses ecx di dx
	mov	ecx,size HBA_CMD_TBL
	mov	di,CmdTbl_plus_VDS.CmdTbl_DDS
	mov	dx,EBIT_CTBL_DDS_LOCKED
	call	LockRegion
	ret
FixupCTBA	endp

FixupPRDT	proc near
	call	Check_VDS
	jnc	@F

	bt	word ptr [bp.ahcidrv_stack.bFlags],EBIT_PRDT_EDDS_LOCKED
	jc	@F

	push	eax
	push	edx
	push	es
	push	di

	push	cs
	pop	es

	mov	di,ds:[pCmdTable]
	add	di,CmdTbl_plus_VDS.PRDT_EDDS
	; The segment is in EDX, and the offset is in EAX
	mov	es:[di.EDD_Struc.EDD_offset],eax
	mov	es:[di.EDD_Struc.EDD_segment],edx
	mov	es:[di.EDD_Struc.EDD_numavail],?MAX_PRDT_ENTRIES
	; The size is on the stack:
	movzx	eax,[bp.ahcidrv_stack.wDwordCount]
	shl	eax,2
	mov	es:[di.EDD_Struc.EDD_size],eax

	mov	ax,8105h; SCATTER/GATHER LOCK REGION
	xor	dx,dx	; no flags
	int	4Bh

	pop	di
	pop	es
	pop	edx
	pop	eax

	jnc	@@fill_prdt
@@:
	; If we're here, then we didn't lock an EDDS
	shl	edx,4	; carry out the instruction we overwrote
	ret

@@fill_prdt:
	; Firstly, change the return address since we're skipping over Intel's
	; logic that assumes only one PRDT entry
	add	sp,2
	push	setup_prdt_done

	; At this point, DS:SI points to the beginning of the PRDT, and needs to
	; be filled with addresses / sizes from the EDDS we just locked.
	; As far as I can tell, we can scratch BX here.
	mov	bx,ds:[pCmdTable]
	add	bx,CmdTbl_plus_VDS.PRDT_EDDS
	; CX needs to contain the total number of PRDT entries
	mov	cx,[bx.EDD_Struc.EDD_numused]
	push	cx
	add	bx,EDD_Struc.EDD_regions

@@:
	; Set the base address
	mov	eax,[bx.EDD_Region.EDD_physaddx]
	mov	dword ptr [si.HBA_PRDT_ENTRY.dba],eax
	; Zero out unused fields
	xor	eax,eax
	mov	dword ptr [si.HBA_PRDT_ENTRY.dba+4],eax
	mov	[si.HBA_PRDT_ENTRY.rsv0],eax
	; And the size
	mov	eax,[bx.EDD_Region.EDD_physsize]
	btr	eax,1Fh	; disable interrupts
	mov	[si.HBA_PRDT_ENTRY.dbc],eax

	; Next please...
	add	bx,size EDD_Region
	add	si,size HBA_PRDT_ENTRY
	loop	@B

	; Successfully locked, set the flag!
	bts	word ptr [bp.ahcidrv_stack.bFlags],EBIT_PRDT_EDDS_LOCKED
	; Return success, with the number of entries in CX
	pop	cx
	xor	ah,ah
	ret
FixupPRDT	endp

; This function redirects the return of "stop_cmd" to UnlockAll, below,
; by intercepting a call to "wait_cr_unset".
stop_cmd_redir	proc near
	pop	ax
	call	@F
@@:
	pop	bx			; get address of @@ in BX
	add	bx,UnlockAll - @B	; get address of UnlockAll in BX
	push	bx			; put it on the stack
	push	ax			; put our return address on the stack
	mov	ax,wait_cr_unset
	jmp	ax			; jump to the original function
	; now wait_cr_unset will return to stop_cmd as expected,
	; then stop_cmd will return to UnlockAll below!
stop_cmd_redir	endp

; Unlock all the DMA regions once the command is complete.
; Note that Intel's AHCI firmware (for hard drives) unlocks immediately after
; locking, and only uses VDS to get physical addresses. That would certainly be
; easier to do here as well, but a bit risky. In the case of the firmware, the
; regions don't really need to be locked since they are all used within a single
; int 13h call, so no sane OS would swap out those pages while that's going on.
; For a CD driver though, in theory an OS could decide to swap out pages while a
; transaction is ongoing, since technically CD and HDD I/O are not mutually
; exclusive!
UnlockAll	proc near
	push	di
	push	dx
	push	es
	push	eax

	push	cs
	pop	es

	btr	word ptr [bp.ahcidrv_stack.bFlags],EBIT_FIS_DDS_LOCKED
	jnc	@F

	mov	ax,8104h; UNLOCK DMA REGION
	xor	dx,dx	; no flags
	mov	di,ds:[pCmdTable]
	add	di,CmdTbl_plus_VDS.FIS_DDS
	int	4Bh

@@:
	btr	word ptr [bp.ahcidrv_stack.bFlags],EBIT_CL_DDS_LOCKED
	jnc	@F

	mov	ax,8104h; UNLOCK DMA REGION
	xor	dx,dx	; no flags
	mov	di,ds:[pCmdTable]
	add	di,CmdTbl_plus_VDS.CmdList_DDS
	int	4Bh

@@:
	btr	word ptr [bp.ahcidrv_stack.bFlags],EBIT_CTBL_DDS_LOCKED
	jnc	@F

	mov	ax,8104h; UNLOCK DMA REGION
	xor	dx,dx	; no flags
	mov	di,ds:[pCmdTable]
	add	di,CmdTbl_plus_VDS.CmdTbl_DDS
	int	4Bh

@@:
	btr	word ptr [bp.ahcidrv_stack.bFlags],EBIT_PRDT_EDDS_LOCKED
	jnc	@F

	mov	ax,8106h; SCATTER/GATHER UNLOCK REGION
	xor	dx,dx	; no flags
	mov	di,ds:[pCmdTable]
	add	di,CmdTbl_plus_VDS.PRDT_EDDS
	int	4Bh

@@:
	pop	eax
	pop	es
	pop	dx
	pop	di

	; set CF as appropriate for return from stop_cmd
	cmp	ah,1
	cmc
	ret
UnlockAll	endp

; Check if VDS is available: sets CF if yes, clears it if no
Check_VDS	proc near	uses es
	push	BDA_SEGMENT
	pop	es
	assume	es:nothing
	bt	word ptr es:[VDS_FLAG_OFFSET], 5
	ret
Check_VDS	endp
endif

align	4
end_stage3:
driver	ends

end
