package main
import "core:c"
import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"

// Constants
BUF_WIDTH :: 1920
BUF_HEIGHT :: 1080
BYTES_PER_PIXEL :: 4

window: ^sdl.Window
renderer: ^sdl.Renderer
texture: ^sdl.Texture
w, h: c.int
fb: [BUF_WIDTH * BUF_HEIGHT * BYTES_PER_PIXEL]u8

render_gradient :: proc(x_off: int, y_off: int) {
	i := 0
	for y := 0; y < int(h); y += 1 {
		for x := 0; x < int(w); x += 1 {
			fb[i] = u8(x + x_off)
			i += 1
			fb[i] = u8(y + y_off)
			i += 1
			fb[i] = 000
			i += 1
			fb[i] = 255
			i += 1
		}
	}
}

draw :: proc() {
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
	sdl.RenderClear(renderer)

	pitch: i32 = BYTES_PER_PIXEL * w
	x_off := int(sdl.GetTicks())
	// y_off := int(sdl.GetTicks())
	render_gradient(x_off, 0)
	sdl.UpdateTexture(texture, nil, &fb, pitch)
	sdl.RenderTexture(renderer, texture, nil, nil)

	sdl.RenderPresent(renderer)
}

// Event docs: SDL_EventType.html
handle_event :: proc(event: ^sdl.Event) -> bool {
	pitch: u32

	#partial pix: switch event.type {
	case sdl.EventType.WINDOW_RESIZED:
		sdl.Log("resize (%d, %d)", event.window.data1, event.window.data2)
	case sdl.EventType.WINDOW_PIXEL_SIZE_CHANGED:
		sdl.GetWindowSize(window, &w, &h)
		resize_texture(event.window.data1, event.window.data2)
	// sdl.
	case sdl.EventType.KEY_DOWN:
		sdl.Log("key down: %d", event.window.data2)
	case sdl.EventType.KEY_UP:
		sdl.Log("key up: %d", event.window.data2)
	case sdl.EventType.WINDOW_EXPOSED:
		sdl.Log("draw")
		draw()
	case:
		sdl.Log("unhandled event: %d", event.type)
	}
	return true
}

resize_texture :: proc(width, height: i32) -> (ok: bool) {
	if texture != nil do sdl.DestroyTexture(texture)
	texture = sdl.CreateTexture(
		renderer,
		sdl.PixelFormat.ARGB8888,
		sdl.TextureAccess.STREAMING,
		width,
		height,
	)

	if texture == nil {return false}
	return true
}

init_ui :: proc() -> bool {
	_ignore := sdl.SetAppMetadata("Hero", "1.0", "supply.same.handmade")
	if (!sdl.Init(sdl.INIT_VIDEO)) {
		sdl.Log("Couldn't initialize SDL3: %s", sdl.GetError())
		return false
	}
	if (!sdl.CreateWindowAndRenderer("Hero", 640, 480, sdl.WINDOW_RESIZABLE, &window, &renderer)) {
		sdl.Log("Couldn't create window/renderer: %s", sdl.GetError())
		return false
	}
	return true
}

quit :: proc() {
	sdl.DestroyTexture(texture)
	sdl.DestroyWindow(window)
	sdl.Quit()
}

main :: proc() {
	if !init_ui() do panic("unable to initialize ui")
	defer quit()

	// fb = make([]u32, BUF_WIDTH * BUF_HEIGHT)
	// defer delete(fb)

	resize_texture(BUF_WIDTH, BUF_HEIGHT)
	done := false
	for !done {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if event.type == sdl.EventType.QUIT {done = true}
			handle_event(&event)
		}
		draw()
	}

}

