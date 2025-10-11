package main
import "base:intrinsics"
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

	pitch: i32 = 4 * app.w
	x_off := int(sdl.GetTicks())
	y_off := int(sdl.GetTicks())

	// sdl.Log("resize (%d, %d)", app.w, app.h)
	render_gradient(app.fb, int(app.w), int(app.h), x_off, 0)
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
		resize_texture(app, event.window.data1, event.window.data2)
	case .KEY_DOWN, .KEY_UP:
		wasDown := event.key.repeat || event.type == .KEY_UP
		isDown := event.type == .KEY_DOWN
		if wasDown != isDown {
			if (isDown) do fmt.print("IsDown")
			if (wasDown) do fmt.print("wasDown")
			fmt.print('\n')
			// if event.key.repeat
			#partial switch event.key.scancode {
			case .W:
			case .A:
			case .S:
			case .D:
			case .Q:
			case .E:
			case .UP:
			case .LEFT:
			case .DOWN:
			case .RIGHT:
			}
		}
	case .WINDOW_EXPOSED:
		sdl.Log("draw")
		draw(app)
	case .JOYSTICK_ADDED:
		sdl.Log("JOYSTICK_ADDED")
	case .GAMEPAD_ADDED:
		sdl.Log("GAMEPAD_ADDED")
		init_controller()
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


	app.window = sdl.CreateWindow("dbg:Hero", 640, 480, sdl.WINDOW_RESIZABLE)
	if app.window == nil {return app, string(sdl.GetError())}

	app.renderer = sdl.CreateRenderer(app.window, nil)
	if app.renderer == nil {return app, string(sdl.GetError())}

	return app, nil
}

init_sound :: proc() -> (stream: ^sdl.AudioStream, err: Maybe(string)) {
	if !sdl.InitSubSystem(sdl.INIT_AUDIO) {
		return stream, string(sdl.GetError())
	}
	spec := sdl.AudioSpec{sdl.AudioFormat.S16, 2, 44100}
	stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if stream == nil {
		return stream, string(sdl.GetError())
	}

	sdl.ResumeAudioDevice(sdl.GetAudioStreamDevice(stream))

	return stream, nil
}
init_controller :: proc() -> bool {
	if !sdl.InitSubSystem(sdl.INIT_GAMEPAD) {
		return false //, sdl.GetError()
	}
	count: c.int
	gamepadIds := sdl.GetGamepads(&count)
	gamepads := make([]^sdl.Gamepad, count)
	for i in 0 ..< count {
		gamepads[i] = sdl.OpenGamepad(gamepadIds[i])
	}
	return true
}
quit :: proc(app: SDL3_Offscreen_Buffer) {
	if app.fb != nil do delete(app.fb)
	sdl.DestroyTexture(app.texture)
	sdl.DestroyWindow(app.window)
	sdl.Quit()
}

main :: proc() {
	when ODIN_DEBUG {
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
	}
	app, err := init_ui()
	if err != nil do fmt.panicf("unable to initialize ui %s", err)
	defer quit(app)

	stream, stream_err := init_sound()
	if stream_err != nil do sdl.Log("unable to initialize audio", stream_err)

	init_controller()
	resize_texture(&app, BUF_WIDTH, BUF_HEIGHT)
	done: for {
		when ODIN_DEBUG {
			perfCount := sdl.GetPerformanceFrequency()
			lastCount := sdl.GetPerformanceCounter()
		}
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
		when ODIN_DEBUG {
			endCounter := sdl.GetPerformanceCounter()
			counterElapsed := endCounter - lastCount
			msPerFrame := (((1000 * counterElapsed) / perfCount))
			fps := perfCount / counterElapsed

			lastCycleCounter := intrinsics.read_cycle_counter()
			elapsed := i64(endCounter) - lastCycleCounter
			mcpf := elapsed / (2000)
			fmt.printfln("%.02f ms/f, %.02f/s, %.02mc/f,", msPerFrame, fps, mcpf)
		}
	}
}

