	.8086
	.model	tiny
	.code

	org	100h

; pointers to code in AHCI driver
pReadLong	equ 1E83h
pAtapiCall	equ 1EC1h
pAtapiFail	equ 1ED0h
pUnaligned	equ 24A8h

IOCTLRW	struc			; IOCTL read/write request
	bLen	db ?		; 3 for read, 12 for write
	bUnit	db ?
	bCmd	db ?
	wStatus	dw ?
	_resd	dq ?
	_resd1	db ?		; media descriptor byte = 0 for MSCDEX
	wBufOff	dw ?
	wBufSeg	dw ?
	wCount	dw ?
	_resd2	dw ?		; starting sector number = 0 for MSCDEX
	_resd3	dd ?		; volume ID = 0 for MSCDEX
IOCTLRW	ends

Raddr	struc
	bCode	db ?		; zero
	dwAddr	dd ?
Raddr	ends

; Frame	struc
; 	sEAX	dd ?
; 	sECX	dd ?
; 	sEDX	dd ?
; 	sEBX	dd ?
; 	sESP	dd ?
; 	sEBP	dd ?
; 	sESI	dd ?
; 	sEDI	dd ?
; 	sIP	dw ?
; 	sCS	dw ?
; 	sFLAGS	dw ?
; Frame	ends

	lea	sp,[stacktop]
	mov	ah,4Ah	; resize memory block
	mov	bx,sp
	add	bx,0Fh
	mov	cl,4
	shr	bx,cl	; we don't need more memory than this
	int	21h
	lea	dx,[outofmem]
	jc	@@failure

	mov	ax,1510h
	mov	cx,3
	mov	bx,offset ioctlinput
	mov	[ioctlinput.bLen],size IOCTLRW
	mov	[ioctlinput.bCmd],3
	mov	[ioctlinput.wBufOff],offset buf
	mov	[ioctlinput.wBufSeg],cs
	mov	[ioctlinput.wCount],size Raddr
	mov	[buf.bCode],0
	int	2Fh

	lea	dx,[drvnotfound]
	jc	@@failure
	.386
	bt	[ioctlinput.wStatus],0Fh
	jc	@@failure

	mov	ax,3501h		; get int1 vector
	int	21h
	mov	[old_int1_off],bx
	mov	[old_int1_seg],es

	lea	dx,[our_int1]
	mov	ah,25h			; set vector
	int	21h

	; get a copy of the debug registers
	call	read_drs

	les	bx,[buf.dwAddr]
	mov	eax,es
	shl	eax,4
	add	ax,bx
	jnc	@F
	add	eax,10000h
@@:
	lea	ebx,[eax+pReadLong]
	mov	debugregs[4*0],ebx	; DR0 = first breakpoint
	lea	ebx,[eax+pAtapiCall]
	mov	debugregs[4*1],ebx	; DR1 = second breakpoint
	lea	ebx,[eax+pAtapiFail]
	mov	debugregs[4*2],ebx	; DR2 = third breakpoint
	lea	ebx,[eax+pUnaligned]
	mov	debugregs[4*3],ebx	; DR3 = fourth breakpoint
	xor	ebx,ebx
	mov	debugregs[4*6],ebx	; Clear DR6

	mov	eax,debugregs[4*7]	; Get DR7
	test	al,al
	lea	dx,[debugregs_inuse]
	jnz	@@failure
	mov	al,10101010b		; enable global breakpoints 0,1,2,3
	or	ah,11b			; set bits 8-9 for good measure
	movzx	eax,ax			; unset upper half (make DR0-3 exec bps)
	mov	debugregs[4*7],eax	; Set DR7

	push	cs
	pop	es
	movzx	cx,byte ptr ds:[80h]	; byte count in cmdtail
	mov	si,81h			; pointer to actual cmdtail
	lea	di,[cmdtail_copy]
	rep	movsb			; copy the cmdtail

	mov	[lpCmdtail_seg],cs
	mov	[lpFCB1_seg],cs
	mov	[lpFCB2_seg],cs

	mov	es,word ptr ds:[2Ch]	; get environment
	xor	al,al
	xor	di,di
	lea	si,[comspec]

@@:
	push	si
	push	di
	mov	cx,2
	repe	cmpsd
	je	@@comspec_found

	pop	di
	pop	si
	scasb	; ES:DI = 0?
	lea	dx,[nocomspec]
	je	@@failure

	mov	cx,-1
	repne	scasb	; look for next zero
	jmp	@B

@@comspec_found:
	add	sp,4
	mov	dx,di
	push	es
	pop	ds			; DS:DX = %COMSPEC%

	push	cs
	pop	es
	lea	bx,[paramblock]

	; ready to exec, setup the debug regs!
	call	write_drs

	mov	ax,4B00h		; EXEC
	int	21h
	; restore stack on child exit
	mov	ss,cs:[lpCmdtail_seg]
	lea	sp,[stacktop]

	push	cs
	pop	ds
	call	read_drs
	mov	byte ptr debugregs[4*7],0; disable all BPs
	call	write_drs

	lds	dx,[old_int1]
	mov	ax,2501h		; set int1 vector
	int	21h

	; pass up errorlevel
	mov	ah,4Dh			; Errorlevel
	int	21h
	mov	ah,4Ch			; EXIT
	int	21h

@@failure:
	call	print_bios
	mov	ax,4CFFh		; EXIT with errorlevel FF
	int	21h

our_int1	proc
	call	read_drs
	cmp	cs:debugregs[4*6],1111b	; DR0/1/2/3 triggered?
	jz	@@done

	pushad
	btr	cs:debugregs[4*6],0
	jnc	@F

	; breakpoint 0 = ReadLong
	mov	cs:[iterations],0	; reset number of sector-read iterations
	jmp	@@restore

@@:
	btr	cs:debugregs[4*6],1
	jnc	@F

	; breakpoint 1 = AtapiCall
	inc	cs:[iterations]
	mov	cs:[last_AX],ax
	mov	cs:[last_EBX],ebx
	mov	cs:[last_ECX],ecx
	mov	cs:[last_EDX],edx
	mov	cs:[last_ES],es
	mov	cs:[last_DI],di
	jmp	@@restore

@@:
	; breakpoint 2 = AtapiFail
	btr	cs:debugregs[4*6],2
	jnc	@F

	push	ds
	push	cs
	pop	ds
	lea	dx,[atapi_failed]
	call	print_bios
	call	prtxw	; AX has the status
	lea	dx,[atapi_failed1]
	call	print_bios
	mov	ax,[iterations]
	call	prtxw
	lea	dx,[atapi_failed2]
	call	print_bios
	mov	ax,[last_AX]
	call	prtxw
	lea	dx,[atapi_failed3]
	call	print_bios
	mov	ax,word ptr last_EBX[2]
	call	prtxw
	mov	ax,word ptr last_EBX[0]
	call	prtxw
	lea	dx,[atapi_failed4]
	call	print_bios
	mov	ax,word ptr last_ECX[2]
	call	prtxw
	mov	ax,word ptr last_ECX[0]
	call	prtxw
	lea	dx,[atapi_failed5]
	call	print_bios
	mov	ax,word ptr last_EDX[2]
	call	prtxw
	mov	ax,word ptr last_EDX[0]
	call	prtxw
	lea	dx,[atapi_failed6]
	call	print_bios
	mov	ax,[last_ES]
	call	prtxw
	lea	dx,[atapi_failed7]
	call	print_bios
	mov	ax,[last_DI]
	call	prtxw
	lea	dx,[atapi_failed8]
	call	print_bios
	pop	ds

	jmp	@@restore

@@:
	; breakpoint 3 = Unaligned
	btr	cs:debugregs[4*6],3
	jnc	@F

	push	ds
	push	cs
	pop	ds
	lea	dx,[unaligned_xfer]
	call	print_bios
	ror	eax,10h		; EAX has the linear addx for the transfer
	call	prtxw
	ror	eax,10h		; EAX has the linear addx for the transfer
	call	prtxw
	lea	dx,[atapi_failed8]
	call	print_bios
	pop	ds

	jmp	@@restore

@@:
	push	ds
	push	cs
	pop	ds
	lea	dx,[dbgdisappeared]
	call	print_bios
	pop	ds

@@restore:
	popad
	call	write_drs

	; because we're in Real Mode and want to set the Resume Flag, we have to
	; go through this convoluted little setup...
	sub	sp,6
	push	bp
	mov	bp,sp
	add	bp,2

	xchg	ax,[bp+6]	; get IP
	mov	[bp],ax		; set lower half of EIP
	mov	word ptr [bp+2],0 ; blank upper half
	mov	ax,[bp+6]	; restore AX

	xchg	ax,[bp+8]	; get CS
	mov	[bp+4],ax	; set CS
	mov	word ptr [bp+6],0 ; blank upper half
	mov	ax,[bp+8]	; restore AX

	xchg	ax,[bp+0Ah]	; get FLAGS
	mov	[bp+8],ax	; set lower half of EFLAGS
	pushfd
	mov	ax,[bp-2-2]	; get upper half of EFLAGS
	popfd
	bts	ax,0		; set Resume Flag
	xchg	ax,[bp+0Ah]	; restore AX and set upper half of EFLAGS

	pop	bp
	iretd			; return with Resume Flag set

@@done:
	jmp	cs:old_int1
our_int1	endp

read_drs	proc near	uses eax es di
	push	cs
	pop	es
	lea	di,[debugregs]

	smsw	ax
	bt	ax,0
	jc	@F

	mov	eax,dr0
	stosd
	mov	eax,dr1
	stosd
	mov	eax,dr2
	stosd
	mov	eax,dr3
	stosd
	xor	eax,eax
	stosd
	stosd
	mov	eax,dr6
	stosd
	mov	eax,dr7
	stosd
	ret

@@:
	mov	ax,0DE08h	; Read Debug Registers
	int	67h
	ret
read_drs	endp

write_drs	proc near	uses eax es si di
	push	cs
	pop	es
	lea	si,[debugregs]
	mov	di,si

	smsw	ax
	bt	ax,0
	jc	@F

	lodsd	es:[si]
	mov	dr0,eax
	lodsd	es:[si]
	mov	dr1,eax
	lodsd	es:[si]
	mov	dr2,eax
	lodsd	es:[si]
	mov	dr3,eax
	lodsd	es:[si]
	lodsd	es:[si]
	lodsd	es:[si]
	mov	dr6,eax
	lodsd	es:[si]
	mov	dr7,eax
	ret

@@:
	mov	ax,0DE09h	; Load Debug Registers
	int	67h
	ret
write_drs	endp

; Print to screen without invoking DOS
; (since our int1 handler will run on a DOS stack!)
; Same calling convention as int 21h AH=9
print_bios	proc near	uses ax bx bp si
	mov	si,dx
	mov	ah,0Eh		; teletype output
	xor	bx,bx		; page 0, white foreground
@@:
	lodsb
	cmp	al,'$'
	je	@F
	int	10h
	jmp	@B
@@:
	ret
print_bios	endp

; Print hex nibble
; In:	AL (low nibble)
; Out:	Nothing
; Kill: AX, BX
;
prtxn	proc	near
	cmp	al, 10
	jb	not_asc
	add	al, 'A' - '0' - 10
not_asc:
	add	al, '0'
	mov	ah,0Eh		; teletype output
	xor	bx,bx		; page 0, white foreground
	int	10h
	ret
prtxn	endp


; Print hex byte
; In:	AL
; Out:	Nothing
; Kill: AX, CL, DX, BX
;
prtxb	proc	near
	mov	dh, al
	mov	cl, 4
	shr	al, cl
	call	prtxn
	mov	al, dh
	and	al, 0fh
	call	prtxn
	ret
prtxb	endp


; Print hex word
; In:	AX
; Out:	Nothing
; Kill: AX, CL, DX, BX
;
prtxw	proc	near
	push	ax
	xchg	al, ah
	call	prtxb
	pop	ax
	call	prtxb
	ret
prtxw	endp

outofmem	db "Unable to resize memory block!",0Dh,0Ah,'$'
drvnotfound	db "Unable to find driver header!",0Dh,0Ah,'$'
debugregs_inuse	db "Someone else is using the debug registers!",0Dh,0Ah,'$'
nocomspec	db "Couldn't read %COMSPEC%",0Dh,0Ah,'$'

atapi_failed	db "ATAPI READ call failed with status ",'$'
atapi_failed1	db " on iteration#",'$'
atapi_failed2	db " with parameters:",0Dh,0Ah
		db "AX: ",'$'
atapi_failed3	db 0Dh,0Ah,"EBX: ",'$'
atapi_failed4	db 0Dh,0Ah,"ECX: ",'$'
atapi_failed5	db 0Dh,0Ah,"EDX: ",'$'
atapi_failed6	db 0Dh,0Ah,"ES:DI: ",'$'
atapi_failed7	db ":",'$'
atapi_failed8	db 0Dh,0Ah,'$'
unaligned_xfer	db "Attempted unaligned transfer to linear address ",'$'
dbgdisappeared	db "Breakpoint state disappeared! :/",0Dh,0Ah,'$'

comspec		db "COMSPEC="	; two dwords

cmdtail		db " /c"	; tell COMMAND.COM what to run
cmdtail_copy	db 80h dup (0)	; copy our own cmdtail in here

align	2
paramblock:
envseg		dw 0		; copy parent env
lpCmdtail	label dword
lpCmdtail_off	dw offset cmdtail
lpCmdtail_seg	dw ?		; copy CS here at runtime
lpFCB1		label dword
lpFCB1_off	dw 5Ch		; copy our own FCB1
lpFCB1_seg	dw ?		; copy CS here at runtime
lpFCB2		label dword
lpFCB2_off	dw 5Ch		; copy our own FCB2
lpFCB2_seg	dw ?		; copy CS here at runtime

	.data?
ioctlinput	IOCTLRW <?>
buf		Raddr <?>

align	2

old_int1	label dword
old_int1_off	dw ?
old_int1_seg	dw ?

iterations	dw ?
last_AX		dw ?
last_EBX	dd ?
last_ECX	dd ?
last_EDX	dd ?
last_DI		dw ?
last_ES		dw ?

debugregs	dd 8 dup (?)

ourstack	dw 400h dup (?)
stacktop	label word

end
