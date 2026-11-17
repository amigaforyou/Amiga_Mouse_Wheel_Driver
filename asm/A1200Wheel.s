;=============================================================================
; A1200Wheel - mouse wheel driver for the A1200HIDToDB9 USB mouse adapter
;
; Wheel, horizontal wheel, middle button and buttons 4/5 arrive over the
; middle-button pin (DB9 pin 5) of the MOUSE port - the joystick port stays
; free. Events are injected into input.device in the NewMouse standard:
;   wheel up/down     RAWKEY $7A/$7B   (+ IECLASS_NEWMOUSE)
;   wheel left/right  RAWKEY $7C/$7D   (+ IECLASS_NEWMOUSE)
;   button 4/5        RAWKEY $7E/$7F   (+ IECLASS_NEWMOUSE)
;   middle button     RAWMOUSE IECODE_MBUTTON
;
; Protocol (see firmware wheelproto.h), once per frame in a VBlank server:
;   pull pin 5 low for 1 line (request), release, wait for the start bit,
;   then sample the 15-bit packet, one bit per 64 us (one PAL line).
;
; Usage:  Run >NIL: A1200Wheel          (S:User-Startup)
;         or put it into WBStartup.
;         Start it again (or send CTRL-C) to stop it.
;         Options: QUIET/S  RAWKEYONLY/S (do not send IECLASS_NEWMOUSE)
;                  SPEED/N/K  scroll steps per wheel notch (1..20, default 1)
;
; Requires Kickstart 2.0 (V36) or newer. Assemble with vasm:
;   vasmm68k_mot -Fhunkexe -m68000 -nosym -o A1200Wheel A1200Wheel.s
;
; MIT License
;=============================================================================

; ---- exec ----
_LVODisable         equ -120
_LVOEnable          equ -126
_LVOForbid          equ -132
_LVOPermit          equ -138
_LVOAddIntServer    equ -168
_LVORemIntServer    equ -174
_LVOFindTask        equ -294
_LVOSetTaskPri      equ -300
_LVOWait            equ -318
_LVOSignal          equ -324
_LVOAllocSignal     equ -330
_LVOFreeSignal      equ -336
_LVOAddPort         equ -354
_LVORemPort         equ -360
_LVOGetMsg          equ -372
_LVOReplyMsg        equ -378
_LVOWaitPort        equ -384
_LVOFindPort        equ -390
_LVOCloseLibrary    equ -414
_LVOOpenDevice      equ -444
_LVOCloseDevice     equ -450
_LVODoIO            equ -456
_LVOOpenResource    equ -498
_LVOOpenLibrary     equ -552
_LVOCreateIORequest equ -654
_LVODeleteIORequest equ -660
_LVOCreateMsgPort   equ -666
_LVODeleteMsgPort   equ -672
; ---- dos ----
_LVOWrite           equ -48
_LVOOutput          equ -60
_LVOReadArgs        equ -798
_LVOFreeArgs        equ -858
; ---- potgo.resource ----
_LVOAllocPotBits    equ -6
_LVOFreePotBits     equ -12
_LVOWritePotgo      equ -18
; ---- input.device ----
_LVOPeekQualifier   equ -42

; ---- structures ----
pr_MsgPort          equ $5C
pr_CLI              equ $AC
LN_TYPE             equ 8
LN_PRI              equ 9
LN_NAME             equ 10
MP_SIGTASK          equ 16
IO_DEVICE           equ 20
IO_COMMAND          equ 28
IO_LENGTH           equ 36
IO_DATA             equ 40
IOSTD_SIZE          equ 48
IE_SIZE             equ 22
NT_INTERRUPT        equ 2
INTB_VERTB          equ 5
IND_WRITEEVENT      equ 11
SIGBREAKF_CTRL_C    equ $1000

IECLASS_RAWKEY      equ $01
IECLASS_RAWMOUSE    equ $02
IECLASS_NEWMOUSE    equ $16
IECODE_MBUTTON      equ $6A
IECODE_UP_PREFIX    equ $80
IEQUALIFIER_MIDBUTTON     equ $1000
IEQUALIFIER_RELATIVEMOUSE equ $8000
NM_WHEEL_UP         equ $7A
NM_WHEEL_DOWN       equ $7B
NM_WHEEL_LEFT       equ $7C
NM_WHEEL_RIGHT      equ $7D
NM_BUTTON_FOURTH    equ $7E
NM_BUTTON_FIFTH     equ $7F

; ---- custom chips ----
CUSTOM              equ $DFF000
VPOSR               equ $004
VHPOSR              equ $006
POTINP              equ $016

; ---- POTGO bits for port 0 pin 5 (LX) ----
POT_OUTLX           equ $0200
POT_DATLX           equ $0100
POT_BITS            equ POT_OUTLX|POT_DATLX
POTGO               equ $034
POTGO_SHADOW        equ $28             ; potgo.resource 37.5: copy of POTGO

; ---- protocol ----
WP_BITS             equ 15
CC_LINE             equ 227             ; colour clocks per 64 us
WP_FIRST_SLOT       equ 4               ; start bit begins 4 lines after the request
MAX_EDGE_CC         equ 70              ; max uncertainty of the start edge
MAX_GAP_CC          equ 40              ; max time between the two reads at the edge
SAMPLE_OFS          equ 75              ; sample point inside a 227 cc slot
START_MIN_CC        equ WP_FIRST_SLOT*CC_LINE-250   ; start edge window,
START_MAX_CC        equ WP_FIRST_SLOT*CC_LINE+40    ; relative to the request
MAX_LATE_CC         equ 100             ; max delay of a sample
HEARTBEAT_FRAMES    equ 50

; ---- server data (srv) ----
SRV_POTGO           equ 0               ; potgo.resource base
SRV_TASK            equ 4
SRV_SIGMASK         equ 8
SRV_LINELEN         equ 12              ; colour clocks per video line
SRV_PACKET          equ 14              ; last received 14-bit packet
SRV_LASTSIG         equ 16
SRV_HEART           equ 18
SRV_SHARED          equ 20              ; 1 = pin owned by gameport, write POTGO directly
SRV_ACK             equ 22              ; 1 = last requested frame was received OK
SRV_ACCV            equ 24              ; vertical notches not yet handled by the task
SRV_ACCH            equ 26              ; horizontal notches
SRV_TOGM            equ 28              ; button edges not yet handled (middle, 4, 5)
SRV_TOG4            equ 29
SRV_TOG5            equ 30
SRV_SYNCED          equ 31
SRV_LASTV           equ 32
SRV_LASTH           equ 33
SRV_LASTBTN         equ 34
SRV_SIZE            equ 36

;=============================================================================
            section code,code
;=============================================================================

Start:
            move.w  #1,Speed
            move.l  4.w,a6
            move.l  a6,SysBase
            sub.l   a1,a1
            jsr     _LVOFindTask(a6)
            move.l  d0,a4
            move.l  d0,MyTask
            tst.l   pr_CLI(a4)
            bne.s   .cli
            ; started from Workbench: get the startup message
            lea     pr_MsgPort(a4),a0
            jsr     _LVOWaitPort(a6)
            lea     pr_MsgPort(a4),a0
            jsr     _LVOGetMsg(a6)
            move.l  d0,WBMsg
.cli:
            lea     DosName(pc),a1
            moveq   #36,d0
            jsr     _LVOOpenLibrary(a6)
            move.l  d0,DOSBase
            beq     ExitNoDos

            ; CLI arguments
            tst.l   WBMsg
            bne.s   .noargs
            move.l  DOSBase,a6
            move.l  #ArgTemplate,d1
            move.l  #ArgArray,d2
            moveq   #0,d3
            jsr     _LVOReadArgs(a6)
            move.l  d0,RDArgs
            bne.s   .argsok
            lea     MsgUsage(pc),a0
            bsr     PrintAlways
            bra     Cleanup
.argsok:
            tst.l   ArgArray
            sne     Quiet
            tst.l   ArgArray+4
            sne     RawkeyOnly
            move.l  ArgArray+8,d0           ; SPEED=n (pointer to a LONG)
            beq.s   .noargs
            move.l  d0,a0
            move.l  (a0),d0
            moveq   #1,d1
            cmp.l   d1,d0
            blt.s   .spmin
            moveq   #20,d1
            cmp.l   d1,d0
            ble.s   .spok
            moveq   #20,d0
            bra.s   .spok
.spmin:     moveq   #1,d0
.spok:      move.w  d0,Speed
.noargs:
            move.l  SysBase,a6

            ; already running? -> stop the running copy
            jsr     _LVOForbid(a6)
            lea     PortName(pc),a1
            jsr     _LVOFindPort(a6)
            tst.l   d0
            beq.s   .first
            move.l  d0,a0
            move.l  MP_SIGTASK(a0),a1
            move.l  #SIGBREAKF_CTRL_C,d0
            jsr     _LVOSignal(a6)
            jsr     _LVOPermit(a6)
            lea     MsgStopping(pc),a0
            bsr     Print
            bra     Cleanup
.first:
            jsr     _LVOCreateMsgPort(a6)
            move.l  d0,PubPort
            beq.s   .noport
            move.l  d0,a1
            move.l  #PortName,LN_NAME(a1)
            clr.b   LN_PRI(a1)
            jsr     _LVOAddPort(a6)
.noport:
            jsr     _LVOPermit(a6)
            tst.l   PubPort
            beq     ErrMem

            ; potgo.resource: own pin 5 of the mouse port
            lea     PotgoName(pc),a1
            jsr     _LVOOpenResource(a6)
            move.l  d0,PotgoBase
            beq     ErrPotgo
            move.l  d0,a6
            move.l  #POT_BITS,d0
            jsr     _LVOAllocPotBits(a6)
            move.w  d0,PotBits
            cmp.w   #POT_BITS,d0
            beq.s   .ownpot
            ; Normally the pin is not free: gameport.device (the system mouse
            ; driver) allocates POTGO bits $0F00 of the mouse port and reads
            ; the middle button on pin 5 in its VBlank server. Share the pin:
            ; our requests write POTGO directly, keeping the other bits as the
            ; system set them (copy kept by potgo.resource). Both servers run
            ; in VBlank, one after the other, so they never overlap.
            tst.w   d0
            beq.s   .nopart
            ext.l   d0
            jsr     _LVOFreePotBits(a6)     ; give back a partial allocation
.nopart:    clr.w   PotBits
            bsr     CheckPotgo              ; known potgo.resource layout?
            tst.l   d0
            beq     ErrPotBits
            st      SharedPot
            bra.s   .potok
.ownpot:    move.l  #POT_BITS,d0            ; output, high (released)
            move.l  d0,d1
            jsr     _LVOWritePotgo(a6)
.potok:     move.l  SysBase,a6

            ; signal for the interrupt server
            moveq   #-1,d0
            jsr     _LVOAllocSignal(a6)
            move.b  d0,SigBit
            bmi     ErrMem
            moveq   #0,d1
            bset    d0,d1
            move.l  d1,SigMask

            ; input.device
            jsr     _LVOCreateMsgPort(a6)
            move.l  d0,InputPort
            beq     ErrMem
            move.l  d0,a0
            moveq   #IOSTD_SIZE,d0
            jsr     _LVOCreateIORequest(a6)
            move.l  d0,InputIO
            beq     ErrMem
            lea     InputName(pc),a0
            moveq   #0,d0
            move.l  InputIO,a1
            moveq   #0,d1
            jsr     _LVOOpenDevice(a6)
            tst.l   d0
            bne     ErrInput
            st      InputOpen
            move.l  InputIO,a0
            move.l  IO_DEVICE(a0),InputBase

            ; interrupt server
            lea     Srv,a0
            move.l  PotgoBase,SRV_POTGO(a0)
            move.l  MyTask,SRV_TASK(a0)
            move.l  SigMask,SRV_SIGMASK(a0)
            moveq   #0,d0
            tst.b   SharedPot
            beq.s   .nsh
            moveq   #1,d0
.nsh:       move.w  d0,SRV_SHARED(a0)
            bsr     MeasureLine
            lea     Srv,a0
            move.w  d0,SRV_LINELEN(a0)
            moveq   #INTB_VERTB,d0
            lea     IntServer,a1
            jsr     _LVOAddIntServer(a6)
            st      ServerOn
            move.l  MyTask,a1               ; react quickly, like other mouse drivers
            moveq   #5,d0
            jsr     _LVOSetTaskPri(a6)

            lea     MsgStart(pc),a0
            bsr     Print

;----------------------------------------------------------------------------
MainLoop:
            move.l  SysBase,a6
            move.l  SigMask,d0
            or.l    #SIGBREAKF_CTRL_C,d0
            jsr     _LVOWait(a6)
            btst    #12,d0                  ; CTRL-C
            bne.s   .quit
            bsr     MeasureLine             ; follow screen mode changes
            lea     Srv,a0
            move.w  d0,SRV_LINELEN(a0)
            bsr     HandlePacket
            bra.s   MainLoop
.quit:
            lea     MsgStopped(pc),a0
            bsr     Print
            bra     Cleanup

;----------------------------------------------------------------------------
ErrMem:     lea     MsgErrMem(pc),a0
            bra.s   ErrPrint
ErrPotgo:   lea     MsgErrPotgo(pc),a0
            bra.s   ErrPrint
ErrPotBits: lea     MsgErrPotBits(pc),a0
            bra.s   ErrPrint
ErrInput:   lea     MsgErrInput(pc),a0
ErrPrint:   bsr     PrintAlways
            ; fall through

;----------------------------------------------------------------------------
Cleanup:
            move.l  SysBase,a6
            tst.b   ServerOn
            beq.s   .c1
            moveq   #INTB_VERTB,d0
            lea     IntServer,a1
            jsr     _LVORemIntServer(a6)
.c1:        move.w  PotBits,d0
            beq.s   .c2
            move.l  PotgoBase,a6
            cmp.w   #POT_BITS,d0
            bne.s   .c1b
            move.l  #POT_BITS,d0            ; leave the line released
            move.l  d0,d1
            jsr     _LVOWritePotgo(a6)
            move.w  PotBits,d0
.c1b:       ext.l   d0
            jsr     _LVOFreePotBits(a6)
            move.l  SysBase,a6
.c2:        tst.b   InputOpen
            beq.s   .c3
            move.l  InputIO,a1
            jsr     _LVOCloseDevice(a6)
.c3:        move.l  InputIO,d0
            beq.s   .c4
            move.l  d0,a0
            jsr     _LVODeleteIORequest(a6)
.c4:        move.l  InputPort,d0
            beq.s   .c5
            move.l  d0,a0
            jsr     _LVODeleteMsgPort(a6)
.c5:        move.b  SigBit,d0
            bmi.s   .c6
            ext.w   d0
            ext.l   d0
            jsr     _LVOFreeSignal(a6)
.c6:        move.l  PubPort,d0
            beq.s   .c7
            move.l  d0,a1
            jsr     _LVORemPort(a6)
            move.l  PubPort,a0
            jsr     _LVODeleteMsgPort(a6)
.c7:        move.l  RDArgs,d1
            beq.s   .c8
            move.l  DOSBase,a6
            jsr     _LVOFreeArgs(a6)
            move.l  SysBase,a6
.c8:        move.l  DOSBase,a1
            jsr     _LVOCloseLibrary(a6)
ExitNoDos:
            move.l  SysBase,a6
            move.l  WBMsg,d0
            beq.s   .x
            jsr     _LVOForbid(a6)
            move.l  WBMsg,a1
            jsr     _LVOReplyMsg(a6)
.x:         moveq   #0,d0
            rts

;----------------------------------------------------------------------------
; HandlePacket - decode Srv.packet and send input events
;----------------------------------------------------------------------------
HandlePacket:
            movem.l d2-d7,-(sp)
            ; take what the interrupt has collected
            move.l  SysBase,a6
            jsr     _LVODisable(a6)
            lea     Srv,a0
            move.w  SRV_ACCV(a0),d4
            clr.w   SRV_ACCV(a0)
            move.w  SRV_ACCH(a0),d5
            clr.w   SRV_ACCH(a0)
            moveq   #0,d6
            move.b  SRV_TOGM(a0),d6         ; d6 = edges M<<16 | B4<<8 | B5
            swap    d6
            move.b  SRV_TOG4(a0),d6
            lsl.w   #8,d6
            move.b  SRV_TOG5(a0),d6
            clr.b   SRV_TOGM(a0)
            clr.b   SRV_TOG4(a0)
            clr.b   SRV_TOG5(a0)
            jsr     _LVOEnable(a6)

            ; vertical wheel
            move.w  d4,d2
            beq.s   .v_done
            bmi.s   .v_down
            subq.w  #1,d2
.v_up:      moveq   #NM_WHEEL_UP,d0
            bsr     SendNotch
            dbf     d2,.v_up
            bra.s   .v_done
.v_down:    neg.w   d2
            subq.w  #1,d2
.v_dn:      moveq   #NM_WHEEL_DOWN,d0
            bsr     SendNotch
            dbf     d2,.v_dn
.v_done:
            ; horizontal wheel
            move.w  d5,d2
            beq.s   .h_done
            bmi.s   .h_left
            subq.w  #1,d2
.h_r:       moveq   #NM_WHEEL_RIGHT,d0
            bsr     SendNotch
            dbf     d2,.h_r
            bra.s   .h_done
.h_left:    neg.w   d2
            subq.w  #1,d2
.h_l:       moveq   #NM_WHEEL_LEFT,d0
            bsr     SendNotch
            dbf     d2,.h_l
.h_done:
            ; middle button: every edge becomes a press or a release
            move.l  d6,d3
            swap    d3
            and.w   #$FF,d3
            bra.s   .m_next
.m_loop:    bchg    #2,BtnState
            beq.s   .m_down                 ; was up -> now down
            move.w  #IECODE_MBUTTON|IECODE_UP_PREFIX,d0
            move.w  #IEQUALIFIER_RELATIVEMOUSE,d1
            move.w  #IEQUALIFIER_MIDBUTTON,d2
            bsr     SendMouse
            bra.s   .m_next
.m_down:    moveq   #IECODE_MBUTTON,d0
            move.w  #IEQUALIFIER_MIDBUTTON|IEQUALIFIER_RELATIVEMOUSE,d1
            moveq   #0,d2
            bsr     SendMouse
.m_next:    dbf     d3,.m_loop
            ; button 4
            move.w  d6,d3
            lsr.w   #8,d3
            bra.s   .b4_next
.b4_loop:   moveq   #NM_BUTTON_FOURTH,d0
            bchg    #1,BtnState
            beq.s   .b4s
            or.w    #IECODE_UP_PREFIX,d0
.b4s:       bsr     SendKey
.b4_next:   dbf     d3,.b4_loop
            ; button 5
            move.w  d6,d3
            and.w   #$FF,d3
            bra.s   .b5_next
.b5_loop:   moveq   #NM_BUTTON_FIFTH,d0
            bchg    #0,BtnState
            beq.s   .b5s
            or.w    #IECODE_UP_PREFIX,d0
.b5s:       bsr     SendKey
.b5_next:   dbf     d3,.b5_loop
            movem.l (sp)+,d2-d7
            rts

; sign-extend a 5-bit difference in d2 (-16..15)
Sext5:      and.w   #$1F,d2
            cmp.w   #16,d2
            bcs.s   .p
            sub.w   #32,d2
.p:         rts

; sign-extend a 3-bit difference in d2 (-4..3)
Sext3:      and.w   #$07,d2
            cmp.w   #4,d2
            bcs.s   .p
            subq.w  #8,d2
.p:         rts

; one wheel notch = SPEED key clicks. d0 = code
SendNotch:  movem.l d0/d3,-(sp)
            move.w  Speed,d3
            subq.w  #1,d3
.n:         move.l  (sp),d0                 ; code (saved d0)
            bsr.s   SendKeyClick
            dbf     d3,.n
            movem.l (sp)+,d0/d3
            rts

; key down + key up (one wheel notch). d0 = code
SendKeyClick:
            move.w  d0,-(sp)
            bsr.s   SendKey
            move.w  (sp)+,d0
            or.w    #IECODE_UP_PREFIX,d0
            ; fall through

; RAWKEY (and NEWMOUSE) event. d0 = code
SendKey:
            movem.l d0/d2,-(sp)
            move.w  d0,d2
            moveq   #IECLASS_RAWKEY,d0
            move.w  d2,d1
            bsr.s   SendEvent
            tst.b   RawkeyOnly
            bne.s   .nonm
            moveq   #IECLASS_NEWMOUSE,d0
            move.w  d2,d1
            bsr.s   SendEvent
.nonm:      movem.l (sp)+,d0/d2
            rts

; RAWMOUSE button event. d0 = code, d1 = qualifiers to set, d2 = to clear
SendMouse:
            movem.l d3,-(sp)
            move.w  d1,d3
            move.w  d0,d1
            moveq   #IECLASS_RAWMOUSE,d0
            bsr.s   SendEventQ
            movem.l (sp)+,d3
            rts

; d0 = class, d1 = code
SendEvent:
            movem.l d2-d3,-(sp)
            moveq   #0,d2
            moveq   #0,d3
            bsr.s   SendEventQ
            movem.l (sp)+,d2-d3
            rts

; d0 = class, d1 = code, d3 = qualifiers to set, d2 = qualifiers to clear
SendEventQ:
            movem.l d2-d5/a2/a6,-(sp)
            move.w  d0,d4
            move.w  d1,d5
            lea     Event,a2
            clr.l   (a2)                    ; ie_NextEvent
            move.b  d4,4(a2)                ; ie_Class
            clr.b   5(a2)                   ; ie_SubClass
            move.w  d5,6(a2)                ; ie_Code
            move.l  InputBase,a6
            jsr     _LVOPeekQualifier(a6)
            not.w   d2
            and.w   d2,d0
            or.w    d3,d0
            move.w  d0,8(a2)                ; ie_Qualifier
            clr.l   10(a2)                  ; ie_X, ie_Y
            clr.l   14(a2)                  ; ie_TimeStamp
            clr.l   18(a2)
            move.l  InputIO,a1
            move.w  #IND_WRITEEVENT,IO_COMMAND(a1)
            move.l  #IE_SIZE,IO_LENGTH(a1)
            move.l  a2,IO_DATA(a1)
            move.l  SysBase,a6
            jsr     _LVODoIO(a6)
            movem.l (sp)+,d2-d5/a2/a6
            rts

;----------------------------------------------------------------------------
; CheckPotgo - is potgo.resource the known version (37.5, unchanged from
; Kickstart 2.04 to 3.2.3) whose WritePotgo keeps the POTGO copy at $28?
; Returns d0 = 1 if yes.
;----------------------------------------------------------------------------
CheckPotgo:
            movem.l a0-a1,-(sp)
            move.l  PotgoBase,a0
            cmp.w   #$4EF9,_LVOWritePotgo(a0)       ; JMP abs.l
            bne.s   .no
            move.l  _LVOWritePotgo+2(a0),a0
            lea     WritePotgoCode(pc),a1
            moveq   #(WritePotgoEnd-WritePotgoCode)/2-1,d0
.cmp:       cmpm.w  (a0)+,(a1)+
            bne.s   .no
            dbf     d0,.cmp
            moveq   #1,d0
            bra.s   .x
.no:        moveq   #0,d0
.x:         movem.l (sp)+,a0-a1
            rts

; potgo.resource 37.5 WritePotgo: and.w d1,d0 / not.w d1 / ... /
; and.w d1,$28(a6) / or.w $28(a6),d0 / move.w d0,$dff034
WritePotgoCode:
            dc.w    $c041,$4641,$206e,$0022,$33fc,$4000,$00df,$f09a
            dc.w    $5228,$0126,$c36e,$0028,$806e,$0028,$33c0,$00df,$f034
WritePotgoEnd:

;----------------------------------------------------------------------------
; MeasureLine - colour clocks per video line (227 PAL, 228 NTSC long line,
; about half of that in 31 kHz modes). Returns d0.w
;----------------------------------------------------------------------------
MeasureLine:
            movem.l d1-d2/a0,-(sp)
            lea     CUSTOM,a0
            moveq   #0,d1
            move.w  #4000-1,d2
.l:         moveq   #0,d0
            move.b  VHPOSR+1(a0),d0
            cmp.w   d1,d0
            bls.s   .n
            move.w  d0,d1
.n:         dbf     d2,.l
            addq.w  #1,d1
            cmp.w   #80,d1                  ; sanity
            bcs.s   .def
            cmp.w   #240,d1
            bls.s   .ok
.def:       move.w  #CC_LINE,d1
.ok:        move.w  d1,d0
            movem.l (sp)+,d1-d2/a0
            rts

;----------------------------------------------------------------------------
; Print a0 (null terminated) to the CLI, unless QUIET or no output
;----------------------------------------------------------------------------
Print:      tst.b   Quiet
            bne.s   PrintEnd
PrintAlways:
            movem.l d0-d3/a0-a1/a6,-(sp)
            move.l  a0,d2
            moveq   #-1,d3
.len:       addq.l  #1,d3
            tst.b   (a0)+
            bne.s   .len
            move.l  DOSBase,d0
            beq.s   .x
            move.l  d0,a6
            jsr     _LVOOutput(a6)
            move.l  d0,d1
            beq.s   .x
            jsr     _LVOWrite(a6)
.x:         movem.l (sp)+,d0-d3/a0-a1/a6
PrintEnd:   rts

;=============================================================================
; VBlank interrupt server.  A1 = Srv
; May use d0/d1/a0/a1/a5/a6, must keep the others.
;
; Beam positions are words (V<<8)|H, H in colour clocks (227 per PAL line).
; Timing is taken from the falling edge of the start bit, so the duration of
; WritePotgo() does not matter. A sample that is taken too late (higher
; priority interrupt) makes the whole frame invalid - it is dropped, and
; because the adapter sends absolute counters nothing is lost.
;=============================================================================
VertBServer:
            movem.l d2-d7/a2-a4,-(sp)
            move.l  a1,a2
            lea     CUSTOM,a3

            ; heartbeat: wake the task once a second (screen mode check)
            addq.w  #1,SRV_HEART(a2)
            cmp.w   #HEARTBEAT_FRAMES,SRV_HEART(a2)
            bcs.s   .nohb
            clr.w   SRV_HEART(a2)
            bsr     .signal
.nohb:
            ; only near the top of the frame (no V counter wrap)
            btst    #0,VPOSR+1(a3)          ; V8
            bne     .exit
            move.w  VHPOSR(a3),d0
            cmp.w   #$C000,d0               ; V < 192
            bcc     .exit
            ; pin 5 must be high (released); low = plain mouse middle
            ; button held, or adapter in legacy mode with the button pressed
            move.w  POTINP(a3),d0
            btst    #8,d0
            beq     .exit
            move.w  SRV_LINELEN(a2),d6
            beq     .exit
            move.l  SRV_POTGO(a2),a6
            ; slot (227 cc) as a beam position step: dV lines + dH colour clocks
            moveq   #0,d0
            move.w  #CC_LINE,d0
            divu.w  d6,d0                   ; d0 = dH<<16 | dV
            move.l  d0,d1
            swap    d1
            move.w  d1,a4                   ; a4 = dH
            lsl.w   #8,d0
            move.w  d0,-(sp)                ; (sp) = dV<<8

            ; ---- request: pin 5 low for 1 line. "ACK" (the previous frame
            ; was received) = a second short low pulse 1.5 .. 2 lines after
            ; the request. The adapter moves its counters on only after an ACK,
            ; so they can never run away. A lost ACK only makes the adapter
            ; repeat the same counters. ----
            move.w  SRV_ACK(a2),d4          ; d4 = ACK for the previous frame
            clr.w   SRV_ACK(a2)             ; set again only if this frame is OK
            tst.w   SRV_SHARED(a2)
            beq.s   .rq_api
            move.w  POTGO_SHADOW(a6),d0     ; system POTGO bits
            and.w   #$FE00,d0               ; DATLX = 0, no START
            or.w    #POT_OUTLX,d0           ; pin 5 output low
            move.w  d0,POTGO(a3)
            bra.s   .rq_done
.rq_api:    move.l  #POT_OUTLX,d0
            move.l  #POT_BITS,d1
            jsr     _LVOWritePotgo(a6)
.rq_done:
            move.w  VHPOSR(a3),d2           ; d2 = request position
            move.l  d2,a5                   ; keep it in a5
            ; all times are computed now, while the request line runs:
            ; a slow 68000 has no time for it between the steps below
            move.w  d2,d0
            move.w  #(WP_FIRST_SLOT+1)*CC_LINE+CC_LINE/2,d1
            bsr     .posadd
            move.w  d0,d5                   ; d5 = deadline for the start bit
            move.w  d2,d0
            move.w  #CC_LINE+CC_LINE/2,d1
            bsr     .posadd
            move.w  d0,a1                   ; a1 = ACK pulse start (1.5 lines)
            move.w  d2,d0
            move.w  #2*CC_LINE,d1
            bsr     .posadd
            move.w  d0,d3                   ; d3 = ACK pulse end (2 lines)
            move.w  d2,d0
            move.w  #CC_LINE,d1
            bsr     .posadd
            bsr     .waitpos
            bsr     .pin_high               ; end of the request (1 line)
            tst.w   d4
            beq.s   .noack
            move.w  a1,d0
            bsr     .waitpos
            bsr     .pin_low                ; ACK pulse
            move.w  d3,d0
            bsr     .waitpos
            bsr     .pin_high
.noack:
            bra     .find_start

; pin 5 high (released) / low, keeping the system POTGO bits
.pin_high:  tst.w   SRV_SHARED(a2)
            beq.s   .rl_api
            move.w  POTGO_SHADOW(a6),d0
            and.w   #$FF00,d0
            or.w    #POT_BITS,d0            ; pin 5 output high
            move.w  d0,POTGO(a3)
            rts
.rl_api:    move.l  #POT_BITS,d0
            move.l  d0,d1
            jmp     _LVOWritePotgo(a6)
.pin_low:   tst.w   SRV_SHARED(a2)
            beq.s   .pl_api
            move.w  POTGO_SHADOW(a6),d0
            and.w   #$FE00,d0
            or.w    #POT_OUTLX,d0
            move.w  d0,POTGO(a3)
            rts
.pl_api:    move.l  #POT_OUTLX,d0
            move.l  #POT_BITS,d1
            jmp     _LVOWritePotgo(a6)

.find_start:
            ; ---- find the start bit: line high, then falling edge ----
            ; (d5 = deadline, computed above)
.ph:        move.w  VHPOSR(a3),d3           ; wait until the line is high
            cmp.w   d5,d3                   ; (released after the request)
            bcc     .exitpop
            move.w  POTINP(a3),d0
            btst    #8,d0
            beq.s   .ph
            move.w  d3,d2
.pb:        move.w  VHPOSR(a3),d3           ; d3 = time before this read
            move.w  POTINP(a3),d0
            btst    #8,d0
            beq.s   .fell
            move.w  d3,d2                   ; d2 = time before the last high read
            cmp.w   d5,d3
            bcs.s   .pb
            bra     .exitpop                ; no start bit (no adapter)
.fell:      move.w  VHPOSR(a3),d1           ; time after the low read
            move.w  d3,d0
            bsr     .dcc                    ; an interrupt between the reads?
            cmp.w   #MAX_GAP_CC,d0
            bhi     .exitpop
            move.w  d3,d1
            move.w  d2,d0
            bsr     .dcc                    ; d0 = uncertainty of the edge
            cmp.w   #MAX_EDGE_CC,d0
            bhi     .exitpop
            lsr.w   #1,d0
            move.w  d2,a1                   ; edge = a1 + a0 (checked later)
            move.w  d0,a0
            move.w  d0,d1
            add.w   #2*CC_LINE+SAMPLE_OFS,d1  ; bit 2 (start and sync skipped)
            move.w  d2,d0
            bsr     .posadd
            move.w  d0,d5                   ; d5 = sample position
            moveq   #0,d0                   ; d3 = d5 + MAX_LATE_CC (limit)
            move.b  d5,d0
            add.w   #MAX_LATE_CC,d0
            move.w  d5,d3
.lm:        cmp.w   d6,d0
            bcs.s   .lmx
            sub.w   d6,d0
            add.w   #$100,d3
            bra.s   .lm
.lmx:       move.b  d0,d3
            move.w  (sp),d2                 ; d2 = dV<<8

            ; ---- bits 2..14 (inline, fast enough for a 7 MHz 68000) ----
            moveq   #1,d7                   ; bit 0 (start) = 0, bit 1 (sync) = 1
            moveq   #WP_BITS-3,d4
.bit:
.bw:        move.w  VHPOSR(a3),d0
            cmp.w   d5,d0
            bcs.s   .bw
            move.w  POTINP(a3),d1
            move.w  VHPOSR(a3),d0
            cmp.w   d3,d0
            bhi     .exitpop                ; sample too late - drop the frame
            add.w   d7,d7
            btst    #8,d1
            beq.s   .b0
            addq.w  #1,d7
.b0:        moveq   #0,d0                   ; next sample position
            move.b  d5,d0
            add.w   a4,d0
            cmp.w   d6,d0
            bcs.s   .t1
            sub.w   d6,d0
            add.w   #$100,d5
.t1:        move.b  d0,d5
            add.w   d2,d5
            moveq   #0,d0                   ; next limit
            move.b  d3,d0
            add.w   a4,d0
            cmp.w   d6,d0
            bcs.s   .t2
            sub.w   d6,d0
            add.w   #$100,d3
.t2:        move.b  d0,d3
            add.w   d2,d3
            dbf     d4,.bit
            addq.l  #2,sp

            ; the edge must have come where the start bit is expected,
            ; otherwise it was a data bit (request/release delayed)
            move.w  a1,d0
            move.w  a0,d1
            bsr     .posadd                 ; edge position
            move.w  d0,d1
            move.l  a5,d0
            bsr     .posdiff
            cmp.w   #START_MIN_CC,d0
            bcs     .exit
            cmp.w   #START_MAX_CC,d0
            bhi     .exit

            ; ---- check the packet: start 0, sync 1, stop 1, odd parity ----
            btst    #14,d7
            bne     .exit
            btst    #13,d7
            beq     .exit
            btst    #0,d7
            beq     .exit
            move.w  d7,d1
            lsr.w   #1,d1
            moveq   #0,d0
            moveq   #14-1,d3
.pc:        lsr.w   #1,d1
            bcc.s   .pc0
            addq.w  #1,d0
.pc0:       dbf     d3,.pc
            btst    #0,d0
            beq     .exit

            move.w  d7,SRV_PACKET(a2)
            move.w  #1,SRV_ACK(a2)          ; ACK it with the next request

            ; ---- accumulate changes here, in the interrupt: the task may be
            ; held up by other programs, the counters must not run away ----
            move.w  d7,d4
            lsr.w   #8,d4
            and.w   #$1F,d4                 ; vertical counter (5 bits)
            move.w  d7,d5
            lsr.w   #5,d5
            and.w   #$07,d5                 ; horizontal counter (3 bits)
            move.w  d7,d6
            lsr.w   #2,d6
            and.w   #$07,d6                 ; buttons %M45
            tst.b   SRV_SYNCED(a2)
            bne.s   .sy
            st      SRV_SYNCED(a2)          ; first packet: take the counters
            move.b  d4,SRV_LASTV(a2)
            move.b  d5,SRV_LASTH(a2)
            clr.b   SRV_LASTBTN(a2)
.sy:        moveq   #0,d3                   ; d3 <> 0: something changed
            moveq   #0,d0
            move.b  SRV_LASTV(a2),d0
            move.b  d4,SRV_LASTV(a2)
            sub.w   d0,d4
            and.w   #$1F,d4
            cmp.w   #16,d4
            bcs.s   .v1
            sub.w   #32,d4                  ; -16..15
.v1:        add.w   d4,SRV_ACCV(a2)
            or.w    d4,d3
            moveq   #0,d0
            move.b  SRV_LASTH(a2),d0
            move.b  d5,SRV_LASTH(a2)
            sub.w   d0,d5
            and.w   #$07,d5
            cmp.w   #4,d5
            bcs.s   .h1
            subq.w  #8,d5                   ; -4..3
.h1:        add.w   d5,SRV_ACCH(a2)
            or.w    d5,d3
            move.b  SRV_LASTBTN(a2),d0
            move.b  d6,SRV_LASTBTN(a2)
            eor.b   d6,d0                   ; changed buttons
            btst    #2,d0
            beq.s   .t4
            addq.b  #1,SRV_TOGM(a2)
.t4:        btst    #1,d0
            beq.s   .t5
            addq.b  #1,SRV_TOG4(a2)
.t5:        btst    #0,d0
            beq.s   .t6
            addq.b  #1,SRV_TOG5(a2)
.t6:        or.b    d0,d3
            tst.w   d3
            beq.s   .exit
            bsr     .signal
            bra.s   .exit
.exitpop:   addq.l  #2,sp
.exit:
            movem.l (sp)+,d2-d7/a2-a4
            lea     CUSTOM,a0
            moveq   #0,d0
            rts

.signal:    move.l  4.w,a6
            move.l  SRV_TASK(a2),a1
            move.l  SRV_SIGMASK(a2),d0
            jsr     _LVOSignal(a6)
            move.l  SRV_POTGO(a2),a6
            rts

; d0 = position + d1 colour clocks (d6 = colour clocks per line)
.posadd:    move.w  d0,-(sp)
            and.w   #$FF,d0                 ; H
            add.w   d1,d0
            move.w  (sp)+,d1
            lsr.w   #8,d1                   ; V
.pa:        cmp.w   d6,d0
            bcs.s   .pax
            sub.w   d6,d0
            addq.w  #1,d1
            bra.s   .pa
.pax:       lsl.w   #8,d1
            or.w    d1,d0
            rts

; d0 = d1 - d0 in colour clocks (positions, d1 later), $7FFF if negative
.posdiff:   move.l  d2,-(sp)
            move.w  d1,d2
            lsr.w   #8,d2                   ; Vb
            move.w  d0,-(sp)
            lsr.w   #8,d0                   ; Va
            sub.w   d0,d2                   ; d2 = Vb - Va
            bmi.s   .pdneg
            move.w  (sp)+,d0
            and.w   #$FF,d0                 ; Ha
            and.w   #$FF,d1                 ; Hb
            sub.w   d0,d1                   ; Hb - Ha
            tst.w   d2
            beq.s   .pd0
            cmp.w   #1,d2
            bne.s   .pdmul
            add.w   d6,d1                   ; next line (fast path)
            bra.s   .pd0
.pdmul:     mulu.w  d6,d2
            add.w   d2,d1
.pd0:       tst.w   d1
            bmi.s   .pdfar
            move.w  d1,d0
            move.l  (sp)+,d2
            rts
.pdneg:     addq.l  #2,sp
.pdfar:     move.w  #$7FFF,d0
            move.l  (sp)+,d2
            rts

; d0 = d1 - d0 in colour clocks, only for positions at most one line apart
; ($7FFF otherwise)
.dcc:       move.l  d2,-(sp)
            move.w  d1,d2
            lsr.w   #8,d2
            move.w  d0,-(sp)
            lsr.w   #8,d0
            sub.w   d0,d2                   ; V difference
            move.w  (sp)+,d0
            and.w   #$FF,d0
            and.w   #$FF,d1
            sub.w   d0,d1
            tst.w   d2
            beq.s   .dc0
            subq.w  #1,d2
            bne.s   .dcfar
            add.w   d6,d1
.dc0:       tst.w   d1
            bmi.s   .dcfar
            move.w  d1,d0
            move.l  (sp)+,d2
            rts
.dcfar:     move.w  #$7FFF,d0
            move.l  (sp)+,d2
            rts

; wait until the beam is at or past position d0
.waitpos:   move.w  d0,d1
            move.w  #$7FFF,d0               ; safety limit
.w:         cmp.w   VHPOSR(a3),d1
            bls.s   .wx
            dbf     d0,.w
.wx:        rts

;----------------------------------------------------------------------------
DosName:        dc.b    "dos.library",0
PotgoName:      dc.b    "potgo.resource",0
InputName:      dc.b    "input.device",0
PortName:       dc.b    "A1200Wheel",0
ArgTemplate:    dc.b    "QUIET/S,RAWKEYONLY/S,SPEED/N/K",0
MsgStart:       dc.b    "A1200Wheel 1.2: wheel driver started (run again to stop)",10,0
MsgStopping:    dc.b    "A1200Wheel: stopping the running driver",10,0
MsgStopped:     dc.b    "A1200Wheel: stopped",10,0
MsgUsage:       dc.b    "Usage: A1200Wheel [QUIET] [RAWKEYONLY] [SPEED=1..20]",10,0
MsgErrMem:      dc.b    "A1200Wheel: out of memory",10,0
MsgErrPotgo:    dc.b    "A1200Wheel: cannot open potgo.resource",10,0
MsgErrPotBits:  dc.b    "A1200Wheel: cannot share the middle button pin (unknown potgo.resource)",10,0
MsgErrInput:    dc.b    "A1200Wheel: cannot open input.device",10,0
VersionTag:     dc.b    "$VER: A1200Wheel 1.2 (17.11.2026)",0
                even

;=============================================================================
            section data,data
;=============================================================================
IntServer:  dc.l    0,0                     ; ln_Succ, ln_Pred
            dc.b    NT_INTERRUPT,0          ; ln_Type, ln_Pri
            dc.l    IntName                 ; ln_Name
            dc.l    Srv                     ; is_Data
            dc.l    VertBServer             ; is_Code
IntName:    dc.b    "A1200Wheel",0
            even
SigBit:     dc.b    -1
            even

;=============================================================================
            section bss,bss
;=============================================================================
SysBase:    ds.l    1
DOSBase:    ds.l    1
MyTask:     ds.l    1
WBMsg:      ds.l    1
RDArgs:     ds.l    1
ArgArray:   ds.l    3
PubPort:    ds.l    1
PotgoBase:  ds.l    1
InputPort:  ds.l    1
InputIO:    ds.l    1
InputBase:  ds.l    1
SigMask:    ds.l    1
Srv:        ds.b    SRV_SIZE
Event:      ds.b    IE_SIZE
PotBits:    ds.w    1
Quiet:      ds.b    1
RawkeyOnly: ds.b    1
            even
Speed:      ds.w    1
SharedPot:  ds.b    1
InputOpen:  ds.b    1
ServerOn:   ds.b    1
Synced:     ds.b    1
BtnState:   ds.b    1
LastV:      ds.b    1
LastH:      ds.b    1
LastBtn:    ds.b    1
            even
