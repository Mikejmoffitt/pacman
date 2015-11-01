.include "nes.inc"
.include "header.inc"


; This ordering is used so that you can reverse direction using EOR #$03
.enum Direction
        left
        up
        down
        right
.endenum


.include "ai.asm"
.include "pacman.asm"
.include "map.asm"


; Exports for easy debugging
.export HandleVblank
.export ReadJoys
.export ComputeTurn
.export MovePacMan
.export MoveGhosts
.export DisplayList


MyOAM = $200


.segment "ZEROPAGE"

TmpL:               .res 1
TmpH:               .res 1
Tmp2L:              .res 1
Tmp2H:              .res 1
FrameCounter:       .res 1
fRenderOff:         .res 1                  ; tells vblank handler not to mess with VRAM if nonzero
DisplayListIndex:   .res 1
Joy1State:          .res 1
Joy2State:          .res 1
HScroll:            .res 1
VScroll:            .res 1
JsrIndAddrL:        .res 1                  ; Since we're on the zero page,
JsrIndAddrH:        .res 1                  ; we won't get bit by the $xxFF JMP bug


.segment "BSS"

DisplayList:        .res 256                ; can shrink and move to zero page if we need a perfomance boost


.segment "CODE"


Main:
        sei
        cld
        ldx     #$40
        stx     $4017
        ldx     #$ff
        txs
        inx                                 ; X will now be 0
        stx     PPUCTRL                     ; no NMI
        stx     PPUMASK                     ; rendering off
        stx     DMCFREQ                     ; no DMC IRQs
        stx     $e000                       ; no MMC3 IRQs

        ; First wait for vblank
        bit     PPUSTATUS
@vblank1:
        bit     PPUSTATUS
        bpl     @vblank1

        ; Init sound regs and other stuff here
        ; @XXX@

        ; Init main RAM
        ; Value >= $ef should be used to clear OAM
        lda     #$ff
        ldx     #0
@init_ram:
        sta     $000,x
        sta     $100,x
        sta     $200,x
        sta     $300,x
        sta     $400,x
        sta     $500,x
        sta     $600,x
        sta     $700,x
        inx
        bne     @init_ram

        ; Clear VRAM ($2000-2fff)
        lda     #$20
        sta     PPUADDR
        lda     #$00
        sta     PPUADDR
        tax                                 ; X := 0
        ldy     #$10
@clear_vram:
        sta     PPUDATA
        dex
        bne     @clear_vram
        dey
        bne     @clear_vram

        ; Init mapper
        ; Set CHR banks
        ldx     #$c0
        stx     $8000
        inx
        ldy     #4
        sty     $8001
        iny
        iny
        stx     $8000
        sty     $8001
        ldx     #$c2
        stx     $8000
        inx
        ldy     #0
        sty     $8001
        iny
        stx     $8000
        inx
        sty     $8001
        iny
        stx     $8000
        inx
        sty     $8001
        iny
        stx     $8000
        sty     $8001

        ; Vertical mirroring
        lda     #$01
        sta     $a000

        ; Protect PRG-RAM
        lda     #$40
        sta     $a001

        ; Init variables
        lda     #0
        sta     FrameCounter
        sta     HScroll
        sta     VScroll
        sta     DisplayListIndex
        lda     #1
        sta     fRenderOff

        ; Second wait for vblank
@vblank2:
        bit     PPUSTATUS
        bpl     @vblank2

        ; Let's get started!
        lda     #1
        sta     fRenderOff
        jsr     LoadPalette
        jsr     LoadBoard
        lda     #0
        sta     fRenderOff

        ; Turn display back on
@wait_vblank_end:
        bit     PPUSTATUS
        bmi     @wait_vblank_end
        lda     #$a0                        ; NMI on, 8x16 sprites
        sta     PPUCTRL
        lda     #$1e                        ; render everything
        sta     PPUMASK

;*** BEGIN TEST ***
        jsr     InitLife
forever:
        jsr     WaitForVblank
        jsr     ReadJoys
        ; Must move ghosts *before* Pac-Man since collision detection
        ; is done inside MoveGhosts.
        jsr     MoveGhosts
        jsr     MovePacMan
        ; Set scroll
        lda     PacTileY
        asl
        asl
        asl
        ora     PacPixelY
        sub     #112
        bcc     @too_high
        cmp     #32
        blt     @scroll_ok                  ; OK if scroll is 0-32
        lda     #32                         ; scroll is >32; snap to 32
        jmp     @scroll_ok
@too_high:
        lda     #0
@scroll_ok:
        sta     VScroll
        ; Now that we've set the scroll, we can put stuff in OAM
        jsr     DrawGhosts
        jsr     DrawPacMan
        jmp     forever
;*** END TEST ***


InitLife:
        jsr     InitAI
        jsr     InitPacMan
        rts


LoadPalette:
        ; Load palette
        lda     #$3f
        sta     PPUADDR
        lda     #$00
        sta     PPUADDR
        ldx     #0
@copy_palette:
        lda     Palette,x
        sta     PPUDATA
        inx
        cpx     #PaletteSize
        bne     @copy_palette
        rts


HandleVblank:
        pha
        txa
        pha
        tya
        pha
        lda     fRenderOff
        beq     :+
        jmp     @end
:
        lda     #$00
        sta     OAMADDR
        lda     #>MyOAM
        sta     OAMDMA

        ; Render display list
        ldx     #0
@display_list_loop:
        ldy     DisplayList,x               ; size of chunk to copy
        beq     @display_list_end           ; size of zero means end of display list
        inx
        lda     DisplayList,x               ; PPU address LSB
        sta     PPUADDR
        inx
        lda     DisplayList,x               ; PPU address MSB
        sta     PPUADDR
        inx
@copy_block:
        lda     DisplayList,x
        sta     PPUDATA
        inx
        dey
        bne     @copy_block
        jmp     @display_list_loop
@display_list_end:
        lda     #0
        sta     DisplayListIndex

        ; Set scroll
        lda     #$a0                        ; NMI on, 8x16 sprites
        sta     PPUCTRL
        lda     HScroll
        sta     PPUSCROLL
        lda     VScroll
        sta     PPUSCROLL
@end:
        inc     FrameCounter
        pla
        tay
        pla
        tax
        pla
        rti

WaitForVblank:
        lda     #0                          ; mark end of display list
        ldx     DisplayListIndex
        sta     DisplayList,x
        lda     FrameCounter
@loop:
        cmp     FrameCounter
        beq     @loop
        rts


HandleIrq:
        rti


ReadJoys:
        ldy     #0                          ; controller 1
        jsr     ReadOneJoy
        iny                                 ; controller 2
        jmp     ReadOneJoy

; Inputs:
;   Y = number of controller to read (0 = controller 1)
;
; Expects Joy2State to follow Joy1State in memory
; Expects controllers to already have been strobed
ReadOneJoy:
        jsr     ReadJoyImpl
@no_match:
        sta     Joy1State,y
        jsr     ReadJoyImpl
        cmp     Joy1State,y
        bne     @no_match
        rts

ReadJoyImpl:
        ldx     #1
        stx     JOYSTROBE
        dex
        stx     JOYSTROBE
        txa
        ldx     #8
@loop:
        pha
        lda     JOY1,y
        and     #$03
        cmp     #$01                        ; carry will be set if A is nonzero
        pla                                 ; (i.e., if the button is pressed)
        ror
        dex
        bne     @loop
        rts


DeltaXTbl:
        .byte   -1                          ; left
        .byte   0                           ; up
        .byte   0                           ; down
        .byte   1                           ; right

DeltaYTbl:
        .byte   0                           ; left
        .byte   -1                          ; up
        .byte   1                           ; down
        .byte   0                           ; right


Palette:
.incbin "../assets/palette.dat"
PaletteSize = * - Palette


; Indirect JSR
; To use: load address into JsrIndAddrL and JsrIndAddrH
; Then just JSR JsrInd
JsrInd:
        jmp     (JsrIndAddrL)


.segment "VECTORS"

        .addr   HandleVblank                ; NMI
        .addr   Main                        ; RESET
        .addr   HandleIrq                   ; IRQ/BRK


.segment "CHR"
.incbin "../assets/gfx.chr"
