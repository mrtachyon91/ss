; Sega CD Mega Drive Module header, matching the IPX loader's MMD.i layout.
; Header fields are 16 bytes, padded to a 256-byte header block.

MMDHEADSZ = $100

MMD macro flags, origin, size, entry, hint, vint
		phase	$200000
		dc.b	flags, 0
		if origin = $200000
			dc.l	0			; Word RAM modules load directly at $200000
			dc.w	0
		else
			dc.l	origin		; Other modules are copied by the IPX loader
			dc.w	(size/4)-1
		endif
		dc.l	entry, hint, vint
		ALIGN	MMDHEADSZ
		endm
