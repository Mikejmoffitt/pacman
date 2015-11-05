.include "nes.inc"
.include "header.inc"


; This ordering is used so that you can reverse direction using EOR #$03
.enum
        WEST
        NORTH
        SOUTH
        EAST
.endenum


.include "ghosts.asm"
.include "pacman.asm"
.include "map.asm"


; Exports for easy debugging
.export HandleVblank
.export HandleIrq
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
fSpriteOverflow:    .res 1                  ; true values won't necessarily be $01
fRenderOn:          .res 1                  ; tells vblank handler not to mess with VRAM if zero
DisplayListIndex:   .res 1
Joy1State:          .res 1
Joy2State:          .res 1
VScroll:            .res 1
IrqVScroll:         .res 1
RngSeedL:           .res 1
RngSeedH:           .res 1
JsrIndAddrL:        .res 1                  ; Since we're on the zero page,
JsrIndAddrH:        .res 1                  ; we won't get bit by the $xxFF JMP bug

NumDots:            .res 1
Score:              .res 5                  ; 5-digit BCD


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
        sta     VScroll
        sta     DisplayListIndex
        sta     fRenderOn

        ; @TODO@ -- better way to init this?
        lda     #%11001001
        sta     RngSeedL
        sta     RngSeedH

        ; Second wait for vblank
@vblank2:
        bit     PPUSTATUS
        bpl     @vblank2

        ; Enable interrupts and NMIs
        cli
@wait_vblank_end:
        bit     PPUSTATUS
        bmi     @wait_vblank_end
        lda     #$80                        ; NMI on
        sta     PPUCTRL
        ; FALL THROUGH to NewGame

NewGame:
        lda     #0
        sta     Score
        sta     Score+1
        sta     Score+2
        sta     Score+3
        sta     Score+4
        ; FALL THROUGH to PlayRound

PlayRound:
        lda     #0
        sta     fRenderOn
        sta     PPUMASK
        jsr     LoadPalette
        jsr     LoadBoard
        jsr     LoadStatusBar
        lda     #1
        sta     fRenderOn
        lda     #$80
        sta     PPUCTRL

        lda     #244
        sta     NumDots

        jsr     InitLife
        jsr     Render
        ldy     #60
        jsr     WaitFrames
@game_loop:
        jsr     WaitForVblank
        jsr     ReadJoys
        ; Must move ghosts *before* Pac-Man since collision detection
        ; is done inside MoveGhosts.
        jsr     MoveGhosts
        jsr     MovePacMan
        jsr     Render
        lda     NumDots
        bne     @game_loop
        ; Round has been won
        ldy     #120
        jsr     WaitFrames
        jmp     PlayRound


InitLife:
        jsr     InitAI
        jsr     InitPacMan
        rts


; Input:
;   TmpL,H = address of number of points to add
.macro AddDigit num
.local end
        lda     Score+(4-num)
        adc     (TmpL),y
        dey
        cmp     #10
        blt     end                         ; carry flag will be clear
        sub     #10
        ; carry flag will be set
end:
        sta     Score+(4-num)
.endmacro

AddPoints:
        ldy     #4
        clc
        AddDigit 0
        AddDigit 1
        AddDigit 2
        AddDigit 3
        AddDigit 4
        rts


Render:
        ; Set scroll
        lda     PacTileY
        asl
        asl
        asl
        ora     PacPixelY
        sub     #99
        bcc     @too_high
        cmp     #56 + 1
        blt     @scroll_ok                  ; OK if scroll is 0-56
        lda     #56                         ; scroll is >56; snap to 56
        jmp     @scroll_ok
@too_high:
        lda     #0
@scroll_ok:
        sta     VScroll
        ; Now that we've set the scroll, we can put stuff in MyOAM
        jsr     DrawGhosts
        jsr     DrawPacMan
        jmp     DrawStatus


DrawStatus:
        ldx     DisplayListIndex
        ; Draw score
        lda     #5
        sta     DisplayList,x
        inx
        lda     #$2b
        sta     DisplayList,x
        inx
        lda     #$a6
        sta     DisplayList,x
        inx
        clc
.repeat 5, I
        lda     Score+I
        adc     #'0'
        sta     DisplayList,x
        inx
.endrepeat
        stx     DisplayListIndex
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


LoadStatusBar:
        lda     #$2b
        sta     PPUADDR
        lda     #$40
        sta     PPUADDR
        ldx     #0
@loop:
        lda     StatusBar,x
        beq     @end
        sta     PPUDATA
        inx
        jmp     @loop
@end:
        rts


HandleVblank:
        pha
        txa
        pha
        tya
        pha
        lda     fRenderOn
        bne     :+
        jmp     @end
:

        ; OAM DMA
        lda     #$00
        sta     OAMADDR
        lda     #>MyOAM
        sta     OAMDMA

        ; Enable IRQ for split screen
        lda     #31                         ; number of scanlines before IRQ
        sta     $c000
        sta     $c001                       ; reload IRQ counter (value irrelevant)
        sta     $e001                       ; enable IRQ (value irrelevant)

        ; Check if sprites overflowed on previous frame
        lda     PPUSTATUS
        and     #$20
        sta     fSpriteOverflow

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
        lda     #$a2                        ; NMI on, 8x16 sprites, second nametable (where status bar is)
        sta     PPUCTRL
        lda     #0
        sta     PPUSCROLL
        lda     #208
        sta     PPUSCROLL

        ; BG on, sprites off
        lda     #$08
        sta     PPUMASK

        ; Save VScroll for IRQ handler
        ; (IRQ using VScroll directly causes a race condition and IRQ may use
        ;  the value for the next frame)
        lda     VScroll
        sta     IrqVScroll

@end:
        inc     FrameCounter
        pla
        tay
        pla
        tax
        pla
        rti

; Won't touch Y
WaitForVblank:
        lda     #0                          ; mark end of display list
        ldx     DisplayListIndex
        sta     DisplayList,x
        lda     FrameCounter
@loop:
        cmp     FrameCounter
        beq     @loop
        rts

; Input:
;   Y = number of frames to wait (0 = 256)
WaitFrames:
        jsr     WaitForVblank
        dey
        bne     WaitFrames
        rts


HandleIrq:
        pha
        sta     $e000                       ; acknowledge and disable IRQ (value irrelevant)

        ; Wait until we're nearly at hblank
.repeat 34
        nop
.endrepeat

        ; See: http://wiki.nesdev.com/w/index.php/PPU_scrolling#Split_X.2FY_scroll
        ; NES hardware is weird, man
        lda     #0
        sta     PPUADDR
        lda     IrqVScroll
        sta     PPUSCROLL
        lda     #0
        sta     PPUSCROLL
        lda     IrqVScroll
        and     #$f8
        asl
        asl
        sta     PPUADDR
        ; BG and sprites on
        lda     #$18
        sta     PPUMASK
        pla
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


; http://wiki.nesdev.com/w/index.php/Random_number_generator
Rand:
        ldx     #8                          ; iteration count: controls entropy quality (max 8,7,4,2,1 min)
        lda     RngSeedL
@loop:
        asl                                 ; shift the register
        rol     RngSeedH
        bcc     :+
        eor     #$2D                        ; apply XOR feedback whenever a 1 bit is shifted out
:
        dex
        bne     @loop
        sta     RngSeedL
        rts


DeltaXTbl:
        .byte   -1                          ; west
        .byte   0                           ; north
        .byte   0                           ; south
        .byte   1                           ; east

DeltaYTbl:
        .byte   0                           ; west
        .byte   -1                          ; north
        .byte   1                           ; south
        .byte   0                           ; east


StatusBar:
        .byte   "                                "
        .byte   "                                "
        .byte   "        1UP   HIGH SCORE        "
        .byte   "           0         0          "
        .byte   0


Points10:   .byte   0,0,0,0,1
Points50:   .byte   0,0,0,0,5

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
