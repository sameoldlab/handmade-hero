package main
import "core:c"
import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"

// Constants
BUF_WIDTH :: 1920
BUF_HEIGHT :: 1080

SDL3_Offscreen_Buffer :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	texture:  ^sdl.Texture,
	fb:       []u8,
	w, h:     c.int,
}

render_gradient :: proc(fb: []u8, w, h, x_off, y_off: int) {
	i := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
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

draw :: proc(app: ^SDL3_Offscreen_Buffer) {
	sdl.SetRenderDrawColor(app.renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
	sdl.RenderClear(app.renderer)

	pitch: i32 = 4 * BUF_WIDTH
	x_off := int(sdl.GetTicks())
	y_off := int(sdl.GetTicks())

	// sdl.Log("resize (%d, %d)", app.w, app.h)
	render_gradient(app.fb, BUF_WIDTH, BUF_HEIGHT, x_off, 0)
	sdl.UpdateTexture(app.texture, nil, raw_data(app.fb), pitch)
	sdl.RenderTexture(app.renderer, app.texture, nil, nil)

	sdl.RenderPresent(app.renderer)
}

// Event docs: SDL_EventType.html
handle_event :: proc(app: ^SDL3_Offscreen_Buffer, event: sdl.Event) -> bool {
	pitch: u32

	#partial switch event.type {
	case .WINDOW_RESIZED:
		sdl.Log("resize (%d, %d)", event.window.data1, event.window.data2)
	case .WINDOW_PIXEL_SIZE_CHANGED:
		sdl.GetWindowSize(app.window, &app.w, &app.h)
	// resize_texture(app, event.window.data1, event.window.data2)
	// sdl.
	case .KEY_DOWN:
		sdl.Log("key down: %d", event.window.data2)
	case .KEY_UP:
		sdl.Log("key up: %d", event.window.data2)
	case .WINDOW_EXPOSED:
		sdl.Log("draw")
		draw(app)
	case:
		sdl.Log("unhandled event: %d", event.type)
	}
	return true
}

resize_texture :: proc(app: ^SDL3_Offscreen_Buffer, width, height: i32) -> (ok: bool) {
	if app.texture != nil do sdl.DestroyTexture(app.texture)
	if app.fb != nil do delete(app.fb)

	app.texture = sdl.CreateTexture(
		app.renderer,
		sdl.PixelFormat.ARGB8888,
		sdl.TextureAccess.STREAMING,
		width,
		height,
	)

	if app.texture == nil {return false}
	app.fb = make([]u8, width * height * 4)
	return true
}

init_ui :: proc() -> (app: SDL3_Offscreen_Buffer, err: Maybe(string)) {
	_ignore := sdl.SetAppMetadata("Hero", "1.0", "supply.same.handmade")
	if (!sdl.Init(sdl.INIT_VIDEO)) {
		return app, string(sdl.GetError())
	}


	app.window = sdl.CreateWindow("Hero", 640, 480, sdl.WINDOW_RESIZABLE)
	if app.window == nil {return app, string(sdl.GetError())}

	app.renderer = sdl.CreateRenderer(app.window, nil)
	if app.renderer == nil {return app, string(sdl.GetError())}

	return app, nil
}

quit :: proc(app: SDL3_Offscreen_Buffer) {
	if app.fb != nil do delete(app.fb)
	sdl.DestroyTexture(app.texture)
	sdl.DestroyWindow(app.window)
	sdl.Quit()
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		if len(track.allocation_map) > 0 {
			fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
			for _, entry in track.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if len(track.bad_free_array) > 0 {
			fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
			for entry in track.bad_free_array {
				fmt.eprintf("- %p bytes @ %v\n", entry.memory, entry.location)
			}
		}
		mem.tracking_allocator_destroy(&track)
	}

	app, err := init_ui()
	if err != nil do fmt.panicf("unable to initialize ui %s", err)
	defer quit(app)
	resize_texture(&app, BUF_WIDTH, BUF_HEIGHT)

	done: for {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if event.type == sdl.EventType.QUIT ||
			   (event.type == sdl.EventType.KEY_DOWN &&
					   event.key.scancode == sdl.Scancode.ESCAPE) {
				break done
			}
			handle_event(&app, event)
		}
		draw(&app)
	}
}

