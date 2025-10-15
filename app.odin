package main
import "core:math"

Context :: struct {
	x_offset, y_offset, current_sample: i32,
	tSine, toneHz:                      f32,
}
ctx: Context = {0, 0, 0, 0, 256}

Color :: struct #packed {
	B, G, R, A: u8,
}
Pixel :: struct #raw_union {
	value: u32,
	color: Color,
}
drawGradient :: proc(fb: []u8, w, h, x_off, y_off: i32) {
	pitch := w * 4
	for y in 0 ..< h {
		for x in 0 ..< w {
			pix := cast(^Pixel)&fb[(x * 4 + y * pitch)]
			pix.color.G = u8(i32(y) + y_off)
			pix.color.B = u8(i32(x) + x_off)
			pix.color.A = 255
		}
	}
}


updateAndRender :: proc(buffer: ^OffscreenBuffer) {
	drawGradient(buffer.fb, buffer.w, buffer.h, ctx.x_offset, ctx.y_offset)
}

gameOutputSound :: proc(sound: ^GameSoundBuffer) {
	ToneVolume :: .5
	wavePeriod: f32 = f32(sound.sampleRate) / ctx.toneHz

	for i in 0 ..< (len(sound.samples) / 2) {
		t: f32 = 2.0 * math.PI * f32(ctx.current_sample) / wavePeriod
		ctx.tSine += 2.0 * math.PI / wavePeriod
		if ctx.tSine >= math.PI * 2 {ctx.tSine = 0}
		val := math.sin_f32(ctx.tSine) * ToneVolume
		sound.samples[i * 2] = val
		sound.samples[i * 2 + 1] = val
		ctx.current_sample += 1
	}

	ctx.current_sample %= sound.sampleRate
}

