package platform

import app "../app"
import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:strings"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

SDL_Context :: struct {
	window:                   ^sdl.Window,
	renderer:                 ^sdl.Renderer,
	texture:                  ^sdl.Texture,
	gl_context:               sdl.GLContext,
	shader_program, vao, vbo: u32,
	fb:                       []u8,
	w, h:                     c.int,
	use_software:             bool,
}
Sound_Output :: struct {
	sampleRate: i32,
	latency:    i16,
	stream:     ^sdl.AudioStream,
}

pl_draw :: proc(ctx: app.FrameBuffer, renderer: ^sdl.Renderer, texture: ^sdl.Texture) {
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
	sdl.RenderClear(renderer)

	pitch: i32 = 4 * ctx.w
	sdl.UpdateTexture(texture, nil, raw_data(ctx.fb), pitch)
	sdl.RenderTexture(renderer, texture, nil, nil)

	sdl.RenderPresent(renderer)
}

// Event docs: SDL_EventType.html
pl_handle_event :: proc(ctx: ^SDL_Context, sound: ^Sound_Output, event: sdl.Event) -> bool {
	pitch: u32

	#partial switch event.type {
	case .WINDOW_RESIZED:
		sdl.Log("resize (%d, %d)", event.window.data1, event.window.data2)
	case .WINDOW_PIXEL_SIZE_CHANGED:
		sdl.GetWindowSize(ctx.window, &ctx.w, &ctx.h)
		pl_resize_texture(ctx, event.window.data1, event.window.data2)
	case .KEY_DOWN, .KEY_UP:
		wasDown := event.key.repeat || event.type == .KEY_UP
		isDown := event.type == .KEY_DOWN
		// if wasDown != isDown {
		// if (isDown) do fmt.print("IsDown")
		// if (wasDown) do fmt.print("wasDown")
		// if event.key.repeat
		#partial switch event.key.scancode {
		case .W, .UP:
			app.key_input(app.Input.UP)
		case .A, .LEFT:
			app.key_input(app.Input.LEFT)
		case .S, .DOWN:
			app.key_input(app.Input.DOWN)
		case .D, .RIGHT:
			app.key_input(app.Input.RIGHT)
		case .Q:
		case .E:
		// }
		}
	case .WINDOW_EXPOSED:
		sdl.Log("draw")
		pl_draw(app.FrameBuffer{ctx.fb, ctx.w, ctx.h}, ctx.renderer, ctx.texture)
	case .JOYSTICK_ADDED:
		sdl.Log("JOYSTICK_ADDED")
	case .GAMEPAD_ADDED:
		sdl.Log("GAMEPAD_ADDED")
		pl_init_controller()
	case:
	// sdl.Log("unhandled event: %d", event.type)
	}
	return true
}

pl_resize_texture :: proc(ctx: ^SDL_Context, width, height: i32) -> (ok: bool) {
	if ctx.texture != nil do sdl.DestroyTexture(ctx.texture)
	if ctx.fb != nil do delete(ctx.fb)

	ctx.texture = sdl.CreateTexture(
		ctx.renderer,
		sdl.PixelFormat.ARGB8888,
		sdl.TextureAccess.STREAMING,
		width,
		height,
	)

	if ctx.texture == nil {return false}
	ctx.fb = make([]u8, width * height * 4)
	return true
}


pl_init_ui :: proc(
	width: c.int = 640,
	height: c.int = 480,
) -> (
	ctx: SDL_Context,
	err: Maybe(string),
) {
	_ignore := sdl.SetAppMetadata(app.TITLE, app.VERSION, app.APP_ID)
	if (!sdl.Init(sdl.INIT_VIDEO)) {
		return ctx, string(sdl.GetError())
	}


	ctx.window = sdl.CreateWindow(app.TITLE, width, height, {.OPENGL, .RESIZABLE})
	if ctx.window == nil {return ctx, string(sdl.GetError())}
	if !ctx.use_software {
		sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, GL_MAJOR)
		sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, GL_MINOR)
		sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GLProfile.CORE))
		sdl.GL_SetAttribute(.DOUBLEBUFFER, 1)
		sdl.GL_SetAttribute(.DEPTH_SIZE, 24)

		ctx.gl_context = sdl.GL_CreateContext(ctx.window)
		if ctx.gl_context == nil {
			return ctx, fmt.tprintf(
				"OpenGL context creation failed: %v",
				sdl.GetError(),
				newline = true,
			)
		}
		gl.load_up_to(GL_MAJOR, GL_MINOR, sdl.gl_set_proc_address)
		sdl.GL_SetSwapInterval(1)
		log.debugf("OpenGL Version: %v.%v", gl.loaded_up_to_major, gl.loaded_up_to_minor)
		log.debugf("GLSL Version: %s", gl.GetString(gl.SHADING_LANGUAGE_VERSION))
		log.debugf("Renderer: %s", gl.GetString(gl.RENDERER))
	}

	ctx.renderer = sdl.CreateRenderer(ctx.window, nil)
	if ctx.renderer == nil {return ctx, string(sdl.GetError())}
	sdl.SetRenderVSync(ctx.renderer, sdl.RENDERER_VSYNC_ADAPTIVE)

	return ctx, nil
}

pl_init_sound :: proc(sampleRate: c.int) -> (stream: ^sdl.AudioStream, err: Maybe(string)) {
	if !sdl.InitSubSystem(sdl.INIT_AUDIO) {
		return stream, string(sdl.GetError())
	}
	spec := sdl.AudioSpec{sdl.AudioFormat.F32, 2, sampleRate}
	stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if stream == nil {
		return stream, string(sdl.GetError())
	}

	sdl.ResumeAudioDevice(sdl.GetAudioStreamDevice(stream))

	return stream, nil
}

pl_init_controller :: proc() -> bool {
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
pl_quit :: proc(ctx: ^SDL_Context) {
	delete(ctx.fb)
	gl.DeleteVertexArrays(1, &ctx.vao)
	gl.DeleteBuffers(1, &ctx.vbo)
	gl.DeleteProgram(ctx.shader_program)
	sdl.GL_DestroyContext(ctx.gl_context)
	sdl.DestroyTexture(ctx.texture)
	sdl.DestroyWindow(ctx.window)
	sdl.Quit()
}
pl_get_mode :: proc(window: ^sdl.Window) -> ^sdl.DisplayMode {
	mode := sdl.GetCurrentDisplayMode(sdl.GetDisplayForWindow(window))
	return mode
}
pl_set_refresh_rate :: proc(mode: ^sdl.DisplayMode) -> f32 {
	if mode.refresh_rate == 0 {
		return 60
	} else {
		return math.min(mode.refresh_rate, 120)
	}
}
sdl_start :: proc() {
	// Initialize Graphics
	ctx, err := pl_init_ui()
	if err != nil do fmt.panicf("unable to initialize ui %s", err)
	defer pl_quit(&ctx)
	mode := sdl.GetCurrentDisplayMode(sdl.GetDisplayForWindow(ctx.window))
	targetFps: f32 = 1 / pl_set_refresh_rate(mode)

	// Initialize Sound
	SampleRate :: 44100
	stream, stream_err := pl_init_sound(SampleRate)
	if stream_err != nil do sdl.Log("unable to initialize audio", stream_err)
	sound := Sound_Output {
		sampleRate = SampleRate,
		stream     = stream,
		latency    = SampleRate / 12,
	}

	if shader_program, vao, vbo, ok := renderer_make_program(); ok {
		ctx.shader_program, ctx.vao, ctx.vbo = shader_program, vao, vbo
	} else {
		log.error("failed to initialize shader program")
		return
	}
	pl_init_controller()
	// will run on starup from a resize event
	// pl_resize_texture(&app, mode.w, mode.h)

	perfCountFreq := sdl.GetPerformanceFrequency()
	lastPerfCount := sdl.GetPerformanceCounter()
	// 
	// Start Main Loop
	// 
	done: for {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if event.type == sdl.EventType.QUIT ||
			   (event.type == sdl.EventType.KEY_DOWN &&
					   event.key.scancode == sdl.Scancode.ESCAPE) {
				break done
			}
			pl_handle_event(&ctx, &sound, event)
		}

		{
			bytesPerSample: i32 = size_of(f32) * 2
			bytesToWrite :=
				(i32(sound.latency) * bytesPerSample) - sdl.GetAudioStreamQueued(sound.stream)
			if bytesToWrite > 0 {
				samples := make([]f32, max(bytesToWrite, 2), context.temp_allocator)

				app.output_sound(
					&app.SampleBuffer {
						sampleRate = sound.sampleRate,
						sampleCount = bytesToWrite / bytesPerSample,
						samples = samples,
					},
				)
				sdl.PutAudioStreamData(sound.stream, &samples[0], bytesToWrite * 4)
			}
			if ctx.use_software {
				app.update_render(ctx.fb, u32(ctx.w), u32(ctx.h))
				pl_draw(app.FrameBuffer{ctx.fb, ctx.w, ctx.h}, ctx.renderer, ctx.texture)
				// if !res {
				// 	sdl.Log("failed to put audio %s", sdl.GetError())
				// }
			} else {
				renderer_draw(ctx.shader_program, ctx.vao)
				sdl.GL_SwapWindow(ctx.window)
			}
		}
		endPerfCount := sdl.GetPerformanceCounter()
		counterElapsed := endPerfCount - lastPerfCount
		lastPerfCount = endPerfCount

		msPerFrame := (((1000 * counterElapsed) / perfCountFreq))
		currentFps := perfCountFreq / counterElapsed

		for (f32(sdl.GetPerformanceCounter() - lastPerfCount) / f32(perfCountFreq) < targetFps) {
			// fmt.println(
			// 	(
			// 		targetFps -
			// 		f32(sdl.GetPerformanceCounter() - lastPerfCount) / f32(perfCountFreq) 
			// 	),
			// )
			sdl.DelayNS(50)
			// fmt.println((f32(counterElapsed) / f32(perfCountFreq)))
		}
		lastCycleCounter := intrinsics.read_cycle_counter()
		when ODIN_DEBUG {
			fps := perfCountFreq / counterElapsed
			elapsed := i64(endPerfCount) - lastCycleCounter
			mcpf := elapsed / (2000)
			fmt.printfln("%d ms/f | %dfps | %d mc/f,", msPerFrame, fps, mcpf)
		}
	}
}

