;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;MSDEXER -- Exercise MSD D-100 Floppy Controller/Drives
;
;This program is intended to exercise a MSD D-100 floppy 
;controller for the S-100 bus. This controller uses the 
;FD1771 floppy controller.
;
;Based on P. Linstruth's TFEXER, which is based on Mike 
;Douglas's AFEXER. Copyright (c) 2019 respective owners.
;
;(c) 2020 Glitch Works, LLC
;http://www.glitchwrks.com/
;
;Glitch Works code is released under the GNU GPL v3. See
;LICENSE in the project root.
;
;MSDEXER SUPPORTS THE FOLLOWING COMMANDS:
;
;  D [X]	Select drive X, If X omitted, current drive
;		number is displayed.
;  C		Compare track number read from disk with 
;		expected track number. If expected track
;		number is undefined, it is set to the track 
;		number read from disk.
;  F		Format current track
;  G		Display FD1771 registers
;  R X		Read sector X on current track and display
;  S X		Step to track X 
;  W X HH	Write sector X with hex HH on current track
;
;Immediate commands (execute on keypress):
;  I		Step in one track
;  O		Step out one track
;  Z		Restore to track zero
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;MSD D-100 Controller Equates
;
;This controller uses a FD1771 plus some board-specific
;control/status registers.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
DRVBASE	equ	030H		;drive base IO port
DRVSTAT	equ	DRVBASE+0	;drive status register (in)
DRVCMD	equ	DRVBASE+0	;drive command register (out)
DRVTRK	equ	DRVBASE+1	;drive track register (in/out)
DRVSEC	equ	DRVBASE+2	;drive sector register (in/out)
DRVDATA	equ	DRVBASE+3	;drive data register (in/out)
BRDCONT	equ	DRVBASE+4	;board control register (out)
DRVSEL	equ	DRVBASE+5	;drive select register (out)
BRDSTAT equ	DRVBASE+4	;board status register (in)

DEFSEL	equ	021H		;Default drive = 1 (only 1-3 valid)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;WD FD1771 Equates
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
BUSYMSK	equ	001H		;Mask to get busy bit alone
indxMsk	equ	002H		;Mask to get index bit alone
drqMsk	equ	002H		;Mask to get DRQ alone
TRK0MSK	equ	004H		;Mask to get TRACK0 bit alone
lostMsk	equ	004H		;Mask to get lost data bit alone
crcMsk	equ	008H		;Mask to get CRC error bit alone
seekMsk	equ	010H		;Mask to get seek error bit alone
notfMsk	equ	010H		;Mask to get not found bit alone
headMsk	equ	020H		;Mask to get head load bit alone
wrtfMsk	equ	020H		;Mask to get write fault bit alone
wrtpMsk	equ	040H		;Mask to get write protect bit alone
NRDYMSK	equ	080H		;Mask to get not ready bit alone
ERRMSK	equ	0fcH		;Mask to test for errors

DCREST	equ	000H		;Drive command - restore
DCSEEK	equ	010H		;Drive command - seek
DCSTEP	equ	020H		;Drive command - step
DCSTEPI	equ	040H		;Drive command - step in
DCSTEPO	equ	060H		;Drive command - step out
DCREAD	equ	08cH		;Drive command - read sector
DCWRITE	equ	0acH		;Drive command - write sector
DCRDTR	equ	0e4H		;Drive command - read track
DCWRTTR	equ	0f4H		;Drive command - write track
DCREADA	equ	0c4H		;Drive command - read address
DCINTR	equ	0d0H		;Drive command - force interrupt

FHEADLD	equ	008H		;Flag - head load
FVERIFY	equ	004H		;Flag - verify
FUPDATE	equ	010H		;Flag - update
FMULT	equ	010H		;Flag - multiple record
FLENGTH	equ	008H		;Flag - block length
FIMINT	equ	008H		;Flag - immediate interrupt
F10MS	equ	002H		;Flag - 10ms step rate

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Disk Subsystem Parameters
;
;The defaults here are compatible with Cromemco SSSD 5.25"
;formats, as used by CDOS.
;
;Note that the MSD D-100 only supports three drives, and
;that the first drive select is 0x01.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
SECLEN	equ	128		;Length of sector
NUMSPT	equ	18		;Sectors pertrack
MAXTRK	equ	40		;Max track number of tracks
MAXDRV	equ	4		;Max valid drive select

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;MITS 88-2SIO Equates
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
SIOACTL	equ	010H		;port A on 88-2SIO board
SIOADAT	equ	011H
SIOTMRE	equ	002H		;mask to test for xmit ready
SIORDRF	equ	001H		;mask to test for rcv read

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Misc Equates
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDLEN	equ	16		;length of command buffer
CR	equ	13		;ascii carriage return
LF	equ	10		;ascii line feed
BS	equ	8		;ascii backspace
notSet	equ	0FFH		;track or drive number not set
WBOOT	equ	0000H		;CP/M warm boot vector
JMPINS	equ	0C3H		;8080 jump instruction


	ORG	0100h		;Start at 0x0100

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;START -- Initialize SP, console, and data structures
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	LXI	SP, STACK	;Initialize stack pointer

	CALL	CHKCPM		;Determine if running under CP/M

	CALL	INISIO		;Initialize 2SIO if needed

	MVI	A, 01H		;Default to drive one
	STA	NEWDRV		;
	STA	CURDRV		;...for first drive selection

	LXI	H, VERS$	;Display version message
	CALL	PRTSTR
	LXI	H, AUTH$	;Display author message
	CALL	PRTSTR

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDLP -- Main command processing loop
;
;The stack is primed with the return address for this
;command loop, so that returns will end up back here.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDLP:	LXI	H, PRMPT$	;Display the prompt
	CALL	PRTSTR
	LXI	H, CMDLP	;Get return address for commands
	PUSH	H		;Prime stack

	CALL	RDCMD		;Get the command
	LXI	H, CMDBUF	;Assume first character is the command
	MOV	A, M
	INX	H		;Increment HL to params past command character

	CPI	'D'		;Select drive
	JZ	CMDSEL
	CPI	'Z'		;Restore to track zero
	JZ	CMDTK0
	CPI	'C'		;Compare track on disk to expected track
	JZ	CMDCMP
	CPI	'S'		;Step to track n
	JZ	CMDTKN
	CPI	'O'		;Immedate step out
	JZ	CMDOUT
	CPI	'I'		;Immediate step in
	JZ	CMDIN
	CPI	'F'		;Format current track
	JZ	CMDFMT
	CPI	'G'		;Display registers
	JZ	DSPREG
	CPI	'R'		;Read and display sector
	JZ	CMDRD
	CPI	'W'		;Write sector with value
	JZ	CMDWR
	CPI	'X'		;Exit MSDEXER
	CZ	EXITEX

	LXI	H, HELP$	;Invalid command entered, display help
	CALL	PRTSTR
	LXI	H, HELP2$
	JMP	PRTSTR		;Display and return to cmdLoop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;DSPREG -- Display registers
;
;Display the FD1771 registers and board status register.
;
;post: FD1771 registers and board status register printed
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
DSPREG:	LXI	H, TRKREG$	;Track register
	CALL	PRTSTR
	IN	DRVTRK
	CALL	PRTHEX

	LXI	H, SECREG$	;Sector register
	CALL	PRTSTR
	IN	DRVSEC		
	CALL	PRTHEX

	LXI	H, STREG$	;Status register
	CALL	PRTSTR
	IN	DRVSTAT
	CALL	PRTHEX

	LXI	H, MSDREG$	;MSD D-100 board status register
	CALL	PRTSTR
	IN	BRDSTAT
	JMP	PRTHEX		;PRTHEX returns to CMDLP

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDSEL -- Select drive command
;
;pre: command string contains a valid drive number
;post: specified drive is selected, or error printed
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDSEL:	CALL	GETTOK		;Get the drive number
	CALL	DECBIN		;Convert ASCII token to binary in A
	JNZ	NODRV		;No drive specified
	CPI	MAXDRV		;Valid drive number?
	JNC	BADDRV
	ORA	A		;Set flags off accumulator value
	JZ	BADDRV		;No DS0 on this controller
	STA	NEWDRV		;NEWDRV = the new drive to select	
	CALL	SELDRV		;Select the drive in NEWDRV

	LXI	H, SELDR$	;Display 'Selected Drive '
	CALL	PRTSTR
	LDA	CURDRV		;Display selected drive number
	CALL	PRTDEC

	LXI	H, DRVTRK$	;Display the track the drive is on
	CALL	PRTSTR
	IN	DRVTRK		;Get the current track to display
	JMP	PRTDEC		;Display and return to CMDLP

NODRV:	LXI	H, CURDRV$	;Display current drive prompt
	call	PRTSTR
	LDA	CURDRV		;Display current drive number
	JMP	PRTDEC		;Display and return to cmdLoop
	
BADDRV:	LXI	H, BADDRV$	;bad drive number specified	
	JMP	PRTSTR		;display and return to cmdLoop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDTK0 -- Seek to track 0 command
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDTK0:	CALL	SEEK0
	RZ			;exit if seek0 failed
	LXI	H, TRK0$	;display track 0 message
	JMP	PRTSTR		;display and return to cmdLoop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDOUT -- Step out one track
;
;STEP command is issued no matter what. If CURTRK is valid,
;update it. Returns to caller through MOVEXT.
;
;pre: drive selected
;post: STEP command issued
;post: CURTRK updated, if valid
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDOUT:	IN	DRVSTAT		;Already at track 0?
	ANI	TRK0MSK
	JNZ	ATDISP		;Display at track message

	CALL	DRVON		;Select and activate current drive
	LDA	HEADLD		;head load flag
	ORI	DCSTEPO		;step out command
	ORI	FUPDATE		;update track register
	ORI	F10MS		;10ms step rate
	OUT	DRVCMD
	CALL	WAIINT		;Wait for INTRQ

	IN	DRVTRK		;get track from drive
	MOV	c,a		;save track in c
	JMP	MOVEXT		;save and display it

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDIN -- Step in one track
;
;STEP command is issued no matter what. If CURTRK is valid,
;update it. Returns to caller through MOVEXT.
;
;pre: drive selected
;post: STEP command issued
;post: CURTRK updated, if valid
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDIN:	IN	DRVTRK		;Get current track from drive
	CPI	MAXTRK-1	;Already stepped in max
	JZ	ATDISP		;Display at track message

	CALL	DRVON		;Select and activate current drive
	LDA	HEADLD		;Head load flag
	ORI	DCSTEPI		;Step in command
	ORI	FUPDATE		;Update track register
	ORI	F10MS		;10ms step rate
	OUT	DRVCMD
	CALL	WAIINT		;Wait for INTRQ

	IN	DRVTRK		;Read track register
	MOV	C, A		;C = current track number
	JMP	MOVEXT		;Save and display it

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDTKN -- Seek to track specified
;
;pre: command line contains valid track
;post: selected drive seeked to specified track
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDTKN:	CALL	GETTOK		;get track token		
	CALL	DECBIN		;Convert ASCII token to binary in A and B
	JNZ	BADTRK		;Track specification invalid
	MVI	A,MAXTRK-1
	CMP	B		;reasonable track number?
	JC	BADTRK		;n: error

	MOV	A, B		;Track number in A register
	JMP	MOVTRK		;Move and return to CMDLP

BADTRK:	LXI	H, BADTRK$	;Bad track message
	JMP	PRTSTR		;Display and return to CMDLP

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDRD -- Read and display a sector
;
;This subroutine reads in the specified sector on the
;current selected track/drive. The sector is then printed
;as hex data.
;
;pre: drive and track selected
;post: specified sector (or error) printed to console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDRD:	CALL	GETTOK		;Get sector token		
	CALL	DECBIN		;Convert ASCII token to binary in A and B
	JNZ	BADSEC		;Sector specification invalid
	MVI	A, NUMSPT
	CMP	B		;Reasonable sector number?
	JC	BADSEC		;No, print error
	XRA	A		;Sector 0 error
	CMP	B
	JZ	BADSEC	

	LXI	H,SECBUF	;HL => sector buffer

	CALL	DRVON		;Select and activate current drive
	CALL	CHKRDY		;Is drive ready?
	JNZ	NOTRDY		;No - not ready message and return

	MOV	A, B		;Send sector to drive
	OUT	DRVSEC

	MVI	A, DCREAD	;Send read command
	OUT	DRVCMD

CMDRD1:	IN	BRDSTAT		;Get board status
	ANI	0C0H		;Mast off DRQ and INTRQ
	JZ	CMDRD1
	ANI	040H		;Mask INTRQ bit
	JNZ	CMDRD2		;Done if INTRQ

	IN	DRVDATA		;Get byte
	MOV	M, A		;Store byte
	INX	H
	JMP	CMDRD1		;Get next byte

CMDRD2:	IN	DRVSTAT		;Get status
	ORA	A		;
	JZ	PRTSEC		;No error - display sector

RDERR:	MOV	E, A		;Error value in E register
	LXI	H, RDERR$	;Read error message
	JMP	PRTERR		;Display error - return

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDWR -- Write a value to a sector
;
;This subroutine writes the specified byte to the specified
;sector. All values in the sector are set to the specified
;byte.
;
;pre: drive and track selected
;post: sector written or error printed
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDWR:	CALL	GETTOK		;Get sector token		
	CALL	DECBIN		;convert ASCII token to binary in A and B
	JNZ	BADSEC		;Sector value invalid
	MVI	A, NUMSPT
	CMP	B		;Valid sector number?
	JC	BADSEC		;No, print error
	XRA	A		;Sector 0 error
	CMP	B
	JZ	BADSEC	
	MOV	A, B
	STA	WRSEC		;Save sector number

	CALL	GETTOK		;Get value to write
	CALL	HEXBIN
	JNZ	NOVAL		;Write value not specified
	STA	WRVAL		;Save write value

	CALL	DRVON		;Select and activate current drive
	CALL	CHKRDY		;Is drive ready?
	JNZ	NOTRDY		;No - not ready message and return

	LDA	WRSEC		;A = sector number
	OUT	DRVSEC		;Send it to controller

	MVI	A, DCWRITE	;Send write command
	OUT	DRVCMD

CMDWR1:	IN	BRDSTAT		;Get board status
	ANI	0C0H		;Mask off DRQ and INTRQ
	JZ	CMDWR1		;Neither, wait
	ANI	040H		;Mask off INTRQ
	JNZ	CMDWR2		;Write finished

	LDA	WRVAL		;Get write value
	OUT	DRVDATA		;Write byte
	JMP	CMDWR1		;Write next byte

CMDWR2:	IN	DRVSTAT		;Get status
	ORA	A		;
	RZ			;No error - return

	MOV	A, A		;Save error
	LXI	H, WRERR$	;Write error
	JMP	PRTERR		;Display error - return

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;BADSEC -- Display bad sector message
;
;Returns to caller through PRTSTR
;
;post: bad sector message printed to console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
BADSEC:	LXI	H, BADSEC$	;Bad sector message
	JMP	PRTSTR		;Display and return to CMDLP

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;NOVAL -- Display bad value message
;
;Returns to caller through PRTSTR
;
;post: bad value message printed to console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
NOVAL:	LXI	H, BADVAL$	;Bad value message
	JMP	PRTSTR		;Display and return to cmdLoop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PRTERR -- Print error message and number
;
;pre: HL points to NULL-terminated string
;pre: E register contains error number
;post: error message and value printed to console
;post: A register NULL
;post: Z flag set
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PRTERR: CALL	PRTSTR		;Print the error message
	MOV	A, E
	CALL	PRTHEX		;Print error code
	LXI	H, CRLF$
	CALL	PRTSTR
	XRA	A		;Set zero flag
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDCMP -- Compare selected track with actual track
;
;This routine reads and displays the track number as read
;from disk along with the current selected track. If the
;expected track is not valid and a valid track number was
;found on disk, CURTRK is set to the new value.
;
;Returns to caller through PRTDEC.
;
;pre: drive and track selected
;post: current track and actual disk track printed
;post: CURTRK set if valid track and not previously set
;post: errors printed if encountered
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDCMP:	CALL	DRVON		;Select and activate current drive
	CALL	CHKRDY
	JNZ	NOTRDY

	CALL	RDTKID		;Read track ID from disk
	MOV	B, A		;Store it in B register

	MOV	E, B		;Track ID from disk in E
	LXI	H, TRKID$	;Display track ID message
	CALL	PRTSTR
	MOV	A, E		;A = track number read
	CALL	PRTDEC		;Display it

	LXI	H, EXPTRK$	;Display expected track number message
	CALL	PRTSTR

	IN	DRVTRK		;A = expected track
	JMP	PRTDEC		;Display it and exit

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;RDTKID -- Read track number from the next sector found
;
;pre: drive and track selected
;post: A register contains track number if found
;post: invalid sector number if none found
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
RDTKID:	CALL	CHKRDY		;Drive must be ready
	JNZ	NOTRDY

	LXI	H, ADDRBUF

	MVI	A, DCREADA	;Read address command
	OUT	DRVCMD

RDTKI1:	IN	BRDSTAT		;Get board status
	ANI	0C0H		;Mast DRQ and INTRQ
	JZ	RDTKI1		;Neither, wait
	ANI	040H		;Mask INTRQ bit
	JNZ	RDTKI2		;INTRQ = done

	IN	DRVDATA		;read the track byte
	MOV	M, A		;save in address buffer
	INX	H
	JMP	RDTKI1

RDTKI2:	IN	DRVSTAT		;Check for error
	ANI	ERRMSK
	JNZ	RDERR		;Yes - display error

	LDA	ADDRBUF		;Return first byte in A
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CHKRDY -- Check if the controller is ready
;
;post: nonzero if drive is ready, zero otherwise
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CHKRDY:	IN	DRVSTAT
	ANI	NRDYMSK
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;NOTRDY -- Display "Not Ready" error message
;
;post: "Not Ready" message displayed
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
NOTRDY:	LXI	H,NORDY$
	JMP	PRTSTR

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;RESDRV -- Reset the current drive
;
;pre: CURDRV contains the drive to reset
;post: drive is reset
;post: drive status in A register
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
RESDRV:	MVI	A, DCINTR	;Force interrupt
	ORI	FIMINT		;Immediate interrupt
	OUT	DRVCMD

	CALL	WAIINT		;Wait for INTRQ

	IN	DRVSTAT		;A = drive status
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;SELDRV -- Select/reset the drive specified in NEWDRV
;
;Destroy A, C, DE, and HL register contents.
;
;pre: NEWDRV contains the drive number to select
;post: drive is selected, reset, and on track 0
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
SELDRV:	LDA	NEWDRV		;drive number to select
	LXI	H,CURDRV	;point to currently selected drive number
	MOV	M,A

	ANI	003H		;drive number 0-3
	ORI	020H		;set READY bit
	OUT	DRVSEL		;select new drive

	CALL	RESDRV		;reset drive and get status

	JMP	SEEK0		;seek to track 0 - return

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;SEEK0 -- Seek current drive to track 0
;
;This routine steps in three thracks before seeking back
;out to track zero in case the track 0 stop is incorrect.
;The max number of steps outward is the max number of
;tracks on the disk, plus 16. These extra steps will cause
;a SA400 minidisk to find track 0 even if the actuator
;mechanism is out of its spiral groove.
;
;pre: drive is selected
;post: drive seeked to track 0, or error displayed
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
SEEK0:	CALL	DRVON		;Select and activate current drive
	LDA	HEADLD		;Head load flag
	ORI	DCREST		;Issue restore command
	ORI	F10MS		;10ms step rate
	OUT	DRVCMD
	CALL	WAIINT		;Wait for INTRQ

	CALL	WAIBSY		;Kill some time for zero flag

	IN	DRVSTAT		;Get status register
	ANI	04H		;Check track 0 flag
	RNZ			;No error - return

	MOV	E, A		;save error in e
	LXI	H, STPERR$	;step error
	JMP	PRTERR		;display error - return

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;MOVTRK -- Move to specified track
;
;Destroys A, C, DE, and HL registers. Falls through to
;MOVEXT.
;
;pre: A register contains valid track number
;post: current drive moved to specified track
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
MOVTRK:	OUT	DRVDATA		;Store A in track register

	CALL	DRVON		;Select and activate current drive
	LDA	HEADLD		;Head load flag
	ORI	DCSEEK		;Issue SEEK
	ORI	F10MS		;10ms step rate
	OUT	DRVCMD		;
	CALL	WAIINT		;Wait for INTRQ

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;MOVEXT -- Exit routine for commands that move the heads
;
;Returns to caller through PRTDEC.
;
;pre: DRVTRK valid
;post: track move message and track number printed to
;      console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
MOVEXT:	LXI	H ,TRKN$	;'Moved to track '
	CALL	PRTSTR
	IN	DRVTRK		;Display track number from binary value
	JMP	PRTDEC		;Print value, returns to caller

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;ATDISP -- Print "Already at" track message and number
;
;pre: DRVTRK is valid
;post: message and track number printed to console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
ATDISP:	LXI	H, ATTRK$	;'Already at track '
	CALL	PRTSTR
	IN	DRVTRK		;display track number from binary value
	JMP	PRTDEC		;display and exit

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CMDFMT -- Format current track
;
;This command formats the current track based on the
;constants NUMSPT and SECLEN.
;
;pre: desired drive and track are selected
;post: track is formatted, or error printed
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDFMT:	CALL	DINION		;Enable disk initialization
	LXI	H, DINIT1$	;Disk Initialization On message
	CALL	PRTSTR		;Display it

	MVI	D, 1		;D = sector counter
	MVI	E, NUMSPT	;E = max number of sectors
	MVI	B, 40		;Gap 4 preindex, 40 bytes of 0xFF

	MVI	A, DCWRTTR	;Track write command
	OUT	DRVCMD		;Issue track write

PREIND:	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0FFH		;Load preindex fill character
	OUT	DRVDATA		;Write it on disk
	DCR	B		;Count = count - 1
	JNZ	PREIND		;Not zero, continue

	MVI	B, 6		;6 bytes of 0x00
PREIN1:	CALL	WAIFMT		;Wait for DRQ
	XRA	A
	OUT	DRVDATA
	DCR	B
	JNZ	PREIN1

	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0FCH		;Load address mark character
	OUT	DRVDATA		;Write it on disk

PSTGAP:	MVI	B, 10		;B = post gap byte count

POSTID:	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0FFH		;Load fill data, 0xFF
	OUT	DRVDATA		;Write it on disk
	DCR	B		;Count = count - 1
	JNZ	POSTID		;Not zero, continue

	MVI	B, 4		;B = number of bytes
SECTOR:	CALL	WAIFMT		;Wait for DRQ
	XRA	A		;A = 0
	OUT	DRVDATA		;Write it on disk
	DCR	B		;Count = count - 1
	JNZ	SECTOR		;Not zero, continue

	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0FEH		;Load ID Address Mark character
	OUT	DRVDATA		;Write it on disk

	CALL	WAIFMT		;Wait for DRQ
	IN	DRVTRK		;Get track number
	OUT	DRVDATA		;Write it on disk

	CALL	WAIFMT		;Wait for DRQ
	XRA	A		;One byte of 0x00
	OUT	DRVDATA		;Write it on disk

	CALL	WAIFMT		;Wait for DRQ
	MOV	A, D		;Get sector number
	OUT	DRVDATA		;Write it on disk

	CALL	WAIFMT		;Wait for DRQ
	XRA	A		;One byte of 0x00
	OUT	DRVDATA		;Write it on disk
	INR	D		;Increment sector count

	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0F7H		;Load WRITE CRC character
	OUT	DRVDATA		;Send it to controller (writes two CRC bytes)

	MVI	B, 11		;Pre-data 0xFF gap byte count
PREDAT:	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0FFh
	OUT	DRVDATA		;Write it on disk
	DCR	B		;Reduce count by 1
	JNZ	PREDAT		;Not zero, continue

	MVI	B, 6		;Pre-data 0x00 gap byte count
PREDA1:	CALL	WAIFMT		;Wait for DRQ
	XRA	A
	out	DRVDATA
	DCR	B
	JNZ	PREDA1

	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0FBH		;Load Data Address Mark character
	OUT	DRVDATA		;Write it on disk

	MVI	B, SECLEN	;B = sector length
DFILL:	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0E5H		;Load format fill byte
	OUT	DRVDATA		;Write it on disk
	DCR	B		;Decrement data byte count
	JNZ	DFILL		;Not zero, continue

	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0F7H		;Load WRITE CRC character
	OUT	DRVDATA		;Send it to controller (writes two CRC bytes)

	DCR	E		;Decrement sector count
	JZ	ENDTRK		;Zero, do end-of-track

DATGAP:	CALL	WAIFMT		;Wait for DRQ
	MVI	A, 0FFH		;Load 0xFF data gap fill character
	OUT	DRVDATA		;Write it on disk
	JMP	PSTGAP		;Continue with next sector
		
ENDTRK:	IN	BRDSTAT		;Get board status
	ANI	0C0H		;Mask off DRQ and INTRQ
	JZ	ENDTRK		;Neither, wait
	ANI	040H		;Mask INTRQ bit
	JNZ	FMDONE		;INTRQ set, track write finished

	MVI	A, 0FFH		;Load 0xFF fill character
	OUT	DRVDATA		;Write it on disk
	JMP	ENDTRK

FMDONE:	IN	DRVSTAT		;Read status of write track command
	ORA	A		;Set flags
	JNZ	FMFAIL		;Any flags set indicate error(s)

	LXI	H, FMTDON$	;Format complete message
	JMP	PRTSTR		;Display message and return

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;WAIFMT -- cmdFmtN specific wait subroutine
;
;This routine waits for DRQ or INTRQ to be asserted, and
;returns if only DRQ was asserted. If INTRQ was asserted,
;the format is assumed to have failed and an error is
;printed.
;
;post: return with A=0x80 if DRQ has been asserted
;post: print error and return to command loop if INTRQ
;      has been asserted
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
WAIFMT:	IN	BRDSTAT		;Get board status
	ANI	0C0H		;Mask DRQ and INTRQ
	JZ	WAIFMT		;Neither, wait
	ANI	040H		;Mask INTRQ
	RZ			;Not set, return
FMFAIL:	MOV	E, A		;Save error in E register
	LXI	H, FMTERR$	;Format fail message
	JMP	PRTERR		;Print it, return to main loop when done

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;WAIBSY -- Wait for BUSY flag to clear
;
;post: BUSY status flag is cleared
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
WAIBSY:	IN	DRVSTAT
	ANI	BUSYMSK
	JNZ	WAIBSY
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;WAIDRQ -- Wait for DRQ flag
;
;Destroys A register
;
;post: DRQ bit is high
;post: A register contains board status byte
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
WAIDRQ:	IN	BRDSTAT		;Get board status
	ORA	A		;Set flags
	JP	WAIDRQ		;Wait until DRQ bit set
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;WAIINT -- Wait for INTRQ flag
;
;Destroys A register
;
;post: INTRQ bit is high
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
WAIINT:	IN	BRDSTAT		;get board status
	ANI	040H		;mask off INTRQ
	JZ	WAIINT		;Wait until set
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;DRVON -- Activate currently selected drive
;
;This controller has a READY flip-flop with a timeout,
;since 5.25" drives don't have a *READY line. We need to
;poke the drive select register to wake it up.
;
;Destroys A register
;
;post: Currently selected drive is on/READY asserted
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
DRVON:	IN	BRDSTAT		;get board status
	ANI	03H		;mask off drive select bits
	ORI	020H		;set the READY flip-flop bit
	OUT	DRVSEL		;write to DRVSEL port
DRVON1:	IN	DRVSTAT		;Get controller status
	ANI	080H		;Mask off NOT READY bit
	JNZ	DRVON1		;Wait until not set
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;DINION -- Switch on disk initialization
;
;This controller has a flip-flop that controls whether the
;FD1771 is allowed to initialize disks (format tracks). It
;must be set up before attempting a format or you'll get a
;write protect fault, even if the disk isn't write
;protected!
;
;This setting is ignored if SW1 position 8 is OPEN -- OPEN
;hard disables disk init.
;
;Destroys A register
;
;post: Currently selected drive is on/READY asserted
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
DINION:	MVI	A, 010H		;READY arm mask
	OUT	BRDCONT		;Write to board control register
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;RDCMD -- Read a command line from the console
;
;This routine reads an editable command line from the
;console and stores it in CMDBUF. Terminates entry on CR.
;Input is automatically upcased.
;
;Destroys A, B, C, HL register contents.
;
;pre: console is initialized
;post: CMDBUF contains processed command line input
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
RDCMD:	MVI	B, 0		;B = stored character count
	LXI	H, CMDBUF	;HL = pointer to CMDBUF
NEXCH:	CALL	CIN		;Get character from console
	CPI	CR		;Carriage return?
	JZ	CMDONE
	CPI	BS		;Backspace?
	JZ	CMBACK
	CPI	020H		;Ignore control characters 
	JC	NEXCH
	CPI	060H		;Convert lower to upper case (garbage past 'z')
	JC	UPPER
	SUI	020H
UPPER:	MOV	C, A		;Save the character in C
	MOV	A, B		;Check if CMDBUF full
	CPI	CMDLEN-1	
	JZ	NEXCH		;Out of room, ignore character
	MOV	M, C		;Store character in CMDBUF
	INX	H		;Increment buffer pointer
	INR	B		;Increment stored character counter
	CALL	COUT		;Echo character in C

	MOV	a,c		;A = current char, check for immediate commands
	CPI	'Z'
	JZ	TEST1		;See if first character on the line
	CPI	'I'
	JZ	TEST1		;See if first character on the line
	CPI	'O'
	JNZ	NEXCH		;Not first on the line, continue

TEST1:	MOV	A, B		;See if character count == 1 
	DCR	A
	JZ	CMDONE		;Yes, immediate at first character
	JMP	NEXCH		;No, keep looping

CMBACK:	MOV	A, B		;See if already at zero characters
	ORA	A
	JZ	NEXCH		;Yes, nothing to delete
	DCR	B		;Decrement the character count
	DCX	H		;...and the the buffer pointer
	MVI	C, BS		;Echo BS, space, BS to do a delete
	CALL	COUT	
	MVI	c,' '
	CALL	COUT
	MVI	C, BS
	CALL	COUT
	JMP	NEXCH

CMDONE:	MVI	M, 0		;Store NULL terminator
	LXI	H, CRLF$	;Print CR, LF
	JMP	PRTSTR

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;GETTOK -- Moves the next token into the buffer
;
;This routine moves the next token pointed to by HL to the
;TOKEN buffer. Leading spaces and commas are skipped.
;Trailing space, comma, or terminating NULL in the input
;buffer terminates the token. The token is NULL terminated.
;
;Destroys A, D, and E register contents.
;HL register updated to allow subsequent calls for the next
;token.
;
;pre: HL points to buffer that contains data to be
;     tokenized
;post: HL points to position in buffer for next call
;post: TOKEN contains token extracted from buffer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
GETTOK:	LXI	D, TOKEN	;DE points to token string
SKPLEA:	MOV	A, M		;Move from CMDBUF to TOKEN
	STAX	D				
	ORA	A		;End of string?
	RZ			;Yes, all done
	INX	H		;No, move to next input character
	CPI	' '		;Skip leading spaces
	JZ	SKPLEA
	CPI	','		;Treat commas as spaces
	JZ	SKPLEA
	INX	D		;Move to next token spot

TOKLOP:	MOV	A, M		;Get next character from CMDBUF
	STAX	D				
	ORA	A		;End of string?
	RZ			;Yes, all done
	INX	H		;No, move to next input character
	CPI	' '		;Trailing space terminates token
	JZ	TODONE
	CPI	','
	JZ	TODONE
	INX	d		;Move to next token spot
	JMP	TOKLOP

TODONE:	XRA	A		;Store terminating null
	STAX	D
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;DECBIN -- Convert ASCII-decimal token to binary
;
;Destroys C, D, E register contents.
;
;pre: TOKEN buffer contains data
;post: A, B registers contain binary value
;post: Z flag set if valid result
;post: Z flag not set if invalid
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
DECBIN:	MVI	B, 0		;B accumulates result
	LXI	D, TOKEN	;DE is TOKEN pointer
	LDAX	D		;Test for NULL string
	ORA	A
	JZ	DECBAD
	
DELOOP:	LDAX	D		;Next ASCII digit
	ORA	A		;End of string?
	JZ	DEDONE		;Yes, we're done
	SUI	'0'		;Subtract ASCII offset
	RC			;Before '0' - invalid digit (Z flag is cleared)
	CPI	10		;Past 9?
	JNC	DECBAD	
	MOV	C, A		;Save digit in C
	MOV	A, B		;Multiply value so far by 10
	ADD	A		;*2
	ADD	A		;*4
	ADD	B		;*5
	ADD	A		;*10
	ADD	C		;Add in new digit to ones position
	MOV	B, A		;Leave result in B
	INX	D		;Move to next digit
	JMP	DELOOP

DEDONE:	MOV	A, B		;Results in A, B registers
	RET			;Zero flag was true upon entry to DEDONE

DECBAD:	XRA	A
	INR	A		;Force zero flag
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;HEXBIN -- Convert ASCII-hex token to binary
;
;Destroys C, D, E register contents.
;
;pre: TOKEN buffer contains data
;post: A, B registers contain binary value
;post: Z flag set if valid result
;post: Z flag not set if invalid
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
HEXBIN:	MVI	B, 0		;B accumulates result
	LXI	D, TOKEN	;DE is TOKEN pointer
	LDAX	D		;Test for NULL string
	ORA	A
	JZ	DECBAD
	
HEXLP:	LDAX	D		;Next ASCII digit
	ORA	A		;End of string?
	JZ	DEDONE		;Yes, we're done
	CPI	'9'+1		;Below ASCII 9?
	JC	HC1		;Yes: deal with digit
	CPI	'A'		;Between 9 & A?
	RC			;Yes, error (Z flag is cleared)
	SUI	'A'-'9'-1	;No, subtract offset	
HC1:	SUI	'0'
	CPI	10H		;Above 0x0F?
	JNC	DECBAD		;Yes, error
	MOV	C, A		;Save digit in C
	MOV	A, B		;Multiply value so far by 16
	ADD	A
	ADD	A
	ADD	A
	ADD	A
	ADD	C		;Add in new digit to ones position
	MOV	B, A		;Results in A, B registers
	INX	D		;Move to next digit
	JMP	HEXLP
	
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PRTDEC -- Print decimal value on console
;
;Displays values from 0-99, greater values are undefined.
;
;pre: A register contains value to print
;post: value printed in decimal on console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PRTDEC:	MVI	C, '0'-1	;C accumulates the 10's digit in ASCII
PRTDE1:	INR	C		;Count the number of 10's in ASCII
	SUI	10		;Divide A by 10 to get the 10's digit
	JP	PRTDE1

	ADI	'0'+10		;Compute final 1's digit in ASCII
	MOV	B, A		;Save 1's digit in B
	MOV	A, C		;Zero suppress 10's digit
	CPI	'0'
	CNZ	COUT		;Print the 10's digit
	MOV	C, B		;Print the 1's digit
	CALL	COUT
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PRTSEC -- Print a sector to console
;
;Prints a sector from SECBUF to the console in hex.
;
;pre: SECBUF contains sector to print
;post: sector printed to console in hex
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PRTSEC: LXI	H,SECBUF
	MVI	D, 0H		;Zero byte counter
PRTSE1:	PUSH	H
	MOV	A, M
	CALL	PRTHEX
	MVI	C, ' '
	CALL	COUT
	MOV	A, D		;A = byte counter value
	ANI	07H		;If 7th byte, send CR
	CPI	07H
	JNZ	PRTSE2		;No, don't print CR, LF

	LXI	H, CRLF$	;Get CR, LF string
	CALL	PRTSTR		;Print it

PRTSE2:	POP	H
	INR	D
	MVI	A, SECLEN	;A = sector length
	CMP	D		;Byte count == sector length?
	RZ			;Yes, done

	INX	H		;No, SECBUF pointer increment
	JMP	PRTSE1

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PRTHEX -- Print hex value to console
;
;Destroys A, B, and C register contents. PRTNIB returns to
;caller.
;
;pre: A register contains value to be printed
;post: value printed as two-digit hexidecimal value
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PRTHEX:	MOV	B, A		;Store value in b
	ANI	0F0H		;Mask high nybble
	RRC
	RRC
	RRC
	RRC
	CALL	PRTNIB		;Print the 16's digit
	MOV	A, B
	ANI	0FH
	JMP	PRTNIB		;Print the 1's digit

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PRTNIB -- Print a hex nybble on the console
;
;Destroy A and C register contents. COUT returns to caller.
;
;pre: A register contains hex nybble to print
;post: hex nybble printed to console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PRTNIB:	CPI	10		;Greater than 9?
	JC	PRTNI1		;0-9, print it
	ADI	07H		

PRTNI1:	ADI	'0'
	MOV	C, A
	JMP	COUT

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PRTANY -- Print string and "any key to abort" message
;
;This subroutine falls through to PRTSTR.
;
;pre: HL points to NULL-terminated string
;post: string and "any key" message printed to console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PRTANY:	CALL	PRTSTR		;print message
	LXI	H, ANYKE$	;followed by ". any key to abort"

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;PRTSTR -- Print a NULL-terminated string;
;
;Destroys A, C, HL register contents. Clears A, sets Z.
;
;pre: HL points to NULL-terminated string
;post: string is printed to console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PRTSTR:	MOV	A, M		;next character to send
	ORA	A		;exit on null
	RZ
	MOV	C, A		;send the character
	CALL	COUT
	INX	H
	JMP	PRTSTR

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;COUT -- Print a character to the console
;
;Destroy A register contents.
;
;pre: C register contains character to print
;post: character printed to console
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
COUT:	IN	SIOACTL		;wait until OK to xmit
	ANI	SIOTMRE
	JZ	COUT
	MOV	A, C		
	OUT	SIOADAT		;send the character
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CIN -- Get a character from the console
;
;This subroutine waits indefinitely for a character to
;become available
;
;pre: console is initialized
;post: A register contains received character
;post: Z flag is set if character is NULL
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CIN:	IN	SIOACTL		;Get channel 0 status
	ANI	SIORDRF		;Mask reader full bit
	JZ	CIN		;Nothing yet, wait
	IN	SIOADAT		;A = received character
	ANI	07FH		;Strip parity, clear Z unless NULL
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;CHKCPM -- Check if we're running under CP/M
;
;Determine if we're currently running under CP/M. Set flags
;and adjust some data depending on result.
;
;We assume CP/M if there's a JMP instruction at 0x0000 and
;the destination address points to five more JMPs.
;
;post: CPMFLG is nonzero if running under CP/M
;post: CPMFLG is zero if not running under CP/M
;post: EXIT$ message suppressed if not running under CP/M
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CHKCPM:	XRA	A
	STA	CPMFLG		;Clear CP/M flag
	STA	EXIT$		;Prevent CP/M exit message from showing

	LDA	WBOOT		;See if jump instruction present for CP/M
	CPI	JMPINS
	RNZ			;No, not CP/M

	LXI	H, WBOOT+1	;Point to LSB of JMP address
	MOV	E, M		;E=low byte of JMP
	INX	H
	MOV	D, M		;DE = destination of JMP
	MVI	B, 5		;Look for 5 more JMPs (a jump table)
CHKCP1:	LDAX	D		;A = opcode at JMP destination
	SUI	JMPINS		;Another JMP present?
	RNZ			;No, not CP/M
	INX	D		;Move to next JMP
	INX	D
	INX	D
	DCR	D
	JNZ	CHKCP1

	MVI	A, ' '		;Running under CP/M
	STA	EXIT$		;Allow CP/M exit message to print
	STA	CPMFLG		;Set CP/M flag to non-zero value
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;EXITEX -- Exit MSDEXER
;
;Exit MSDEXER to CP/M if we're running under CP/M. If 
;running under CP/M, prompt the user to insert the system
;disk and select default drive.
;
;pre: CPMFLG is valid
;post: exit to CP/M if running under CP/M
;post: return if not running under CP/M
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
EXITEX:	LDA	CPMFLG		;Running under CP/M?
	ORA	A		;Test for zero
	RZ			;No, not CP/M, return

	MVI	A, DEFSEL	;Select default drive
	OUT	DRVSEL
	LXI	H, CPMDSK$	;Display "Insert CP/M disk"	
	CALL	PRTSTR
	CALL	CIN		;Wait for a character
	JMP	WBOOT		;Warm boot CP/M

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;INISIO -- Initialize MITS 88-2SIO Channel 0
;
;This subroutine will return without action if running
;under CP/M.
;
;pre: CPMFLG contents valid
;post: no action if CPMFLG is set
;post: MITS 88-2SIO channel 0 initialized if CPMFLG == 0
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
INISIO:	LDA	CPMFLG		;running under CP/M?
	ORA	A
	RNZ			;yes, 2SIO already initialized
	MVI	A, 3		;reset ACIA
	OUT	SIOACTL
	MVI	A, 015H		;RTS on, 8N1
	OUT	SIOACTL
	RET

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Message Strings
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
VERS$:	db	'MSD D-100 Controller/Disk Exerciser, v0.0.1', CR, LF, 0
AUTH$:	db	'(c) 2020 Glitch Works, LLC', CR, LF
	db	'(c) 2019 Deltec Enterprises LLC/P. Linstruth, Mike Douglas', CR, LF
	db	'http://www.glitchwrks.com/', CR, LF, 0
PRMPT$:	db	CR, LF, 'CMD>', 0

HELP$:	db	CR, LF, 'Valid commands are:', CR, LF
	db	'  D [X]        Select drive X or display current', CR, LF
	db	'               drive if X omitted', CR, LF
	db	'  C            Compare the track number read from', CR, LF
	db	'               disk with the expected track number', CR, LF
	db	'  F            Format current track', CR, LF
	db	'  G            Display FD1771 and MSD board registers', CR, LF
	db	'  R X          Read sector X', CR, LF
	db	'  S X          Step to track X', CR, LF
	db	'  W X HH       Write sector X with hex HH', CR, LF
EXIT$:	db	'  X            Exit to CP/M', CR, LF, 0

HELP2$:	db	LF, 'Immediate commands:', CR, LF
	db	'  O            Step out one track', CR, LF
	db	'  I            Step in one track', CR, LF
	db	'  Z            Restore to track zero', CR, LF, 0

TRK0$	db	'Moved to track zero', 0
TRKN$	db	'Moved to track ', 0
FMTDON$	db	'Format complete', 0
FMTERR$	db	'Format error ', 0
ATTRK$	db	'Already at track ', 0
TRKID$	db	'Track ID from disk: ', 0
NOTKID$	db	'Track ID could not be read', 0
EXPTRK$	db	CR, LF, 'Expected track: ', 0
SELDR$	db	'Selected drive ', 0
CURDRV$	db	'Current drive is ', 0
NORDY$	db	CR, LF, 'Drive not ready', CR, LF, 0
DRVTRK$	db	CR, LF, 'Current track is ', 0
TRKREG$	db	'     Track Register: ', 0
SECREG$	db	CR, LF, '    Sector Register: ', 0
STREG$	db	CR, LF, '    Status Register: ', 0
MSDREG$ db	CR, LF, LF, 'MSD Status Register: ', 0
NOSET$	db	'not set', 0
BADDRV$	db	'Invalid drive number', 0
BADTRK$	db	'Invalid track number', 0
BADSEC$	db	'Invalid sector number', 0
BADVAL$	db	'Invalid write value', 0
mWrtDat	db	CR, LF, 'Writing to disk', 0
ANYKE$	db	'. Press any key to abort.', 0
RDERR$	db	'Read error: ', 0
WRERR$	db	'Write error: ', 0
STPERR$	db	'Step error: ', 0
CPMDSK$	db	CR, LF, 'Insert CP/M disk into drive A, then press Return...', 0
CRLF$	db	CR, LF, 0
DINIT1$	db	'Disk Initialization ENABLED', CR, LF, 0


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Command Buffer and Variable Declarations
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
CMDBUF	ds	16		;command input buffer
TOKEN	ds	16		;token buffer
WRSEC	ds	1		;write sector number
WRVAL	ds	1		;write sector value
NEWDRV	ds	1		;new drive # to select
CURDRV	ds	1		;currently selected drive #
SECBUF	ds	SECLEN		;Sector buffer
ADDRBUF	ds	6		;address buffer
HEADLD	db	0		;head load flag
CPMFLG	ds	1		;non-zero if running under CP/M

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;Stack Space
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	ds	64
STACK	equ	$

	END
