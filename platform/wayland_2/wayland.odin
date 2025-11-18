package wayland

import app "../../app"
import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "egl"
import "gbm"
import gl "vendor:OpenGL"


MAX_POOL_SIZE :: app.BUF_WIDTH * app.BUF_HEIGHT * 4 * 4
BUF_LEN :: 2
State :: struct {
	buffer_size, stride, w, h:           u32,
	tick:                                u32,
	keymap, use_software, should_redraw: bool,
	status:                              Status,

	// WL
	wl_registry:                         Registry,
	wl_buffer:                           [BUF_LEN]Buffer,
	xdg_wm_base:                         Xdg_Wm_Base,
	xdg_surface:                         Xdg_Surface,
	wl_surface:                          Surface,
	surface_callback:                    Callback,
	wl_compositor:                       Compositor,
	xdg_toplevel:                        Xdg_Toplevel,
	wl_seat:                             Seat,
	wl_pointer:                          Pointer,
	wl_keyboard:                         Keyboard,
	data_device_manager:                 Data_Device_Manager,
	data_source:                         Data_Source,
	cursor_shape_manager:                Wp_Cursor_Shape_Manager_V1,

	// EGL
	egl_display:                         egl.Display,
	egl_surface:                         egl.Surface,
	egl_context:                         egl.Context,

	// GBM
	drm_fd:                              linux.Fd,
	gbm_device:                          gbm.Device,
	gbm_surface:                         gbm.Surface,
	zwp_linux_dmabuf:                    Zwp_Linux_Dmabuf_V1,

	// SHM
	shm_fd:                              linux.Fd,
	wl_shm:                              Shm,
	wl_shm_pool:                         Shm_Pool,
	shm_pool_data:                       []u8,
}

// // change to soa
// Gbo :: struct {
// 	bos:    [BUF_LEN]gbm.BufferObject,
// 	fds:    [BUF_LEN]linux.Fd,
// 	busy:   [BUF_LEN]bool,
// 	buffer: [BUF_LEN]Buffer,
// }
// gbo: Gbo

Gbo :: struct {
	bo:     gbm.BufferObject,
	fd:     linux.Fd,
	busy:   bool,
	buffer: Buffer,
}
gbo: #soa[2]Gbo

Progress :: enum {
	Continue,
	Exit,
	Crash,
	NoWayland,
}
Status :: enum {
	None,
	SurfaceAckedConfigure,
	SurfaceAttached,
}
GL :: #config(GL, false)

start :: proc() -> Progress {
	conn, display, ok := connect_display()
	if !ok do return .NoWayland
	st := State {
		wl_registry   = display_get_registry(&conn, display),
		w             = 500,
		h             = 500,
		use_software  = !GL,
		should_redraw = true,
	}

	recv_buf: [4096]byte

	st.stride = st.w * 4
	if st.use_software {
		st.buffer_size = st.stride * st.h

		shm_fd, shm_err := create_shm_file(&st.shm_pool_data, MAX_POOL_SIZE)
		if shm_err != .NONE {
			return .Crash
		}
		st.shm_fd = shm_fd
	}
	create_objects(&conn, &st, recv_buf[:])
	defer quit(&conn, st)

	i: u8 = 0
	m: for {
		if err := connection_flush(&conn); err != .NONE {
			fmt.println("FLUSH Error:", err)
			for {
				object, event := peek_event(&conn) or_break
				receive_events(&conn, &st, object, event)
			}
			return .Crash
		}

		{
			result, _ := linux.poll({linux.Poll_Fd{fd = conn.socket, events = {.IN}}}, 2)
			if result > 0 {
				connection_poll(&conn, recv_buf[:])

				for {
					object, event := peek_event(&conn) or_break
					if prog := receive_events(&conn, &st, object, event); prog != .Continue do return prog
				}
				conn.data_cursor = 0
				conn.data = {}
			}
		}
		if st.status == .None do continue

		// if st.should_redraw do
		draw(&conn, &st, u32(i))
		i += 1
	}
	return .Exit
}

draw :: proc(conn: ^Connection, st: ^State, i: u32) {
	fmt.println("====================START DRAW====================")
	using st
	if use_software {
		if !should_redraw do return
		i := i % len(st.wl_buffer)
		surface_frame(conn, wl_surface)
		app.update_render(st.shm_pool_data[((i)) * st.buffer_size:][:st.buffer_size], st.w, st.h)
		surface_attach(conn, wl_surface, wl_buffer[i], 0, 0)
		surface_damage_buffer(conn, wl_surface, 0, 0, i32(w), i32(h))
		surface_commit(conn, wl_surface)
		st.should_redraw = false
	} else {
		assert(st.zwp_linux_dmabuf != 0)
		free_idx := -1
		le := gbo.fd[0]

		for busy, i in gbo.busy {
			if !busy {
				free_idx = i
				break
			}
		}
		if free_idx == -1 {
			fmt.println("all busy")
			st.should_redraw = false
			return
		}
		gl.ClearColor(.5, .5, .8, .9)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		glscene()
		res := egl.SwapBuffers(egl_display, egl_surface)
		fmt.printfln("swap (%b32)", res)
		assert(res == true)

		bo := gbm.surface_lock_front_buffer(st.gbm_surface)
		fmt.println("post-lock", bo)
		assert(bo != {})

		i := free_idx
		if gbo[i].bo != {} && gbo[i].bo != bo {
			gbm.surface_release_buffer(gbm_surface, gbo[i].bo)
		}
		gbo[i].bo = bo


		fmt.println(gbo[i].buffer)
		surface_attach(conn, wl_surface, gbo[i].buffer, 0, 0)
		surface_damage_buffer(conn, wl_surface, 0, 0, i32(w), i32(h))
		surface_commit(conn, wl_surface)


		gbo[i].busy = true
		st.should_redraw = false
		fmt.println("====================END DRAW====================")
	}
}
glscene :: proc() {
	// Shader source that draws a textures quad
	vertex_shader_source: cstring =
		"#version 330 core\n" +
		"layout (location = 0) in vec3 aPos;\n" +
		"layout (location = 1) in vec2 aTexCoords;\n" +
		"out vec2 TexCoords;\n" +
		"void main()\n" +
		"{\n" +
		"   TexCoords = aTexCoords;\n" +
		"   gl_Position = vec4(aPos.x, aPos.y, aPos.z, 1.0);\n" +
		"}"
	fragment_shader_source: cstring =
		"#version 330 core\n" +
		"out vec4 FragColor;\n" +
		"in vec2 TexCoords;\n" +
		"uniform sampler2D Texture1;\n" +
		"void main()\n" +
		"{\n" +
		"   FragColor = texture(Texture1, TexCoords);\n" +
		"}"

	// vertex shader
	vertex_shader := gl.CreateShader(gl.VERTEX_SHADER)
	gl.ShaderSource(vertex_shader, 1, &vertex_shader_source, nil)
	gl.CompileShader(vertex_shader)
	// fragment shader
	fragment_shader := gl.CreateShader(gl.FRAGMENT_SHADER)
	gl.ShaderSource(fragment_shader, 1, &fragment_shader_source, nil)
	gl.CompileShader(fragment_shader)
	// link shaders
	shader_program := gl.CreateProgram()
	gl.AttachShader(shader_program, vertex_shader)
	gl.AttachShader(shader_program, fragment_shader)
	gl.LinkProgram(shader_program)
	// delete shaders
	gl.DeleteShader(vertex_shader)
	gl.DeleteShader(fragment_shader)

	// quad
	vertices := []f32 {
		0.5,
		0.5,
		0.0,
		1.0,
		0.0, // top right
		0.5,
		-0.5,
		0.0,
		1.0,
		1.0, // bottom right
		-0.5,
		-0.5,
		0.0,
		0.0,
		1.0, // bottom left
		-0.5,
		0.5,
		0.0,
		0.0,
		0.0, // top left
	}
	indices: []u32 = {
		0,
		1,
		3, // first Triangle
		1,
		2,
		3, // second Triangle
	}

	VBO, VAO, EBO: u32
	gl.GenVertexArrays(1, &VAO)
	gl.GenBuffers(1, &VBO)
	gl.GenBuffers(1, &EBO)
	gl.BindVertexArray(VAO)

	gl.BindBuffer(gl.ARRAY_BUFFER, VBO)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), raw_data(vertices), gl.STATIC_DRAW)

	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, EBO)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, size_of(indices), raw_data(indices), gl.STATIC_DRAW)

	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 5 * size_of(f32), 0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 5 * size_of(f32), (3 * size_of(f32)))

	gl.BindBuffer(gl.ARRAY_BUFFER, 0)

	gl.BindVertexArray(0)

	// Prebind needed stuff for drawing
	gl.UseProgram(shader_program)
	gl.BindVertexArray(VAO)
}
create_objects :: proc(conn: ^Connection, st: ^State, buff: []byte) -> linux.Errno {
	connection_flush(conn) or_return
	connection_poll(conn, buff)
	for {
		object, event := peek_event(conn) or_break
		if prog := receive_events(conn, st, object, event); prog != .Continue do return .NONE
	}
	conn.data_cursor = 0
	conn.data = {}
	assert(st.wl_compositor != 0)
	assert(st.xdg_wm_base != 0)
	assert(st.wl_seat != 0)

	st.wl_surface = compositor_create_surface(conn, st.wl_compositor)
	st.xdg_surface = xdg_wm_base_get_xdg_surface(conn, st.xdg_wm_base, st.wl_surface)
	st.xdg_toplevel = xdg_surface_get_toplevel(conn, st.xdg_surface)
	st.wl_keyboard = seat_get_keyboard(conn, st.wl_seat)
	st.wl_pointer = seat_get_pointer(conn, st.wl_seat)

	xdg_toplevel_set_title(conn, st.xdg_toplevel, app.TITLE)
	xdg_toplevel_set_app_id(conn, st.xdg_toplevel, app.APP_ID)
	surface_commit(conn, st.wl_surface)

	fmt.println(st.xdg_surface, "xdg_surface")
	fmt.println(st.wl_keyboard, "wl_keyboard")
	fmt.println(st.wl_pointer, "wl_pointer")
	connection_flush(conn) or_return
	connection_poll(conn, buff)
	for {
		object, event := peek_event(conn) or_break
		if prog := receive_events(conn, st, object, event); prog != .Continue do return .NONE
	}
	if st.use_software {
		using st
		if wl_shm != 0 && wl_shm_pool == 0 && wl_buffer == 0 {
			wl_shm_pool = shm_create_pool(conn, wl_shm, auto_cast shm_fd, i32(MAX_POOL_SIZE))
			for &b, i in wl_buffer {
				b = shm_pool_create_buffer(
					conn,
					wl_shm_pool,
					i32(u32(i) * buffer_size),
					i32(w),
					i32(h),
					i32(stride),
					.Argb8888,
				)
			}
			assert(len(shm_pool_data) != 0)
			assert(buffer_size != 0)
			fmt.println(wl_shm_pool, "shm created")
			fmt.println(wl_buffer, "buffers created")
		}
	} else do setup_egl(conn, st)
	return .NONE
}

connect_display :: proc() -> (conn: Connection, display: Display, ok: bool) {
	socket := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, {}) or_else panic("")
	addr: linux.Sock_Addr_Un = {
		sun_family = .UNIX,
	}
	fmt.bprintf(
		addr.sun_path[:],
		"%v/%v",
		os.get_env("XDG_RUNTIME_DIR", context.temp_allocator),
		os.get_env("WAYLAND_DISPLAY", context.temp_allocator),
	)

	if err := linux.connect(socket, &addr); err != .NONE {
		return
	}

	conn, display = display_connect(socket)
	conn.object_types = make([dynamic]Object_Type, 2)
	conn.object_types[1] = .Display

	return conn, display, true
}

create_shm_file :: proc(fb: ^[]u8, size: u32) -> (shm_fd: linux.Fd, err: linux.Errno) {
	shm_fd = linux.Fd(
		linux.syscall(linux.SYS_memfd_create, transmute(^u8)(cstring("wayland-shm")), 1),
	)
	// shm_fd = memfd_create("wayland-shm") or_return
	linux.ftruncate(shm_fd, i64(size)) or_return
	shm_ptr, mmap_err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, shm_fd)
	if mmap_err != .NONE {
		linux.close(shm_fd)
		return 0, mmap_err
	}
	fb^ = mem.slice_ptr(cast(^byte)shm_ptr, int(size))
	return shm_fd, .NONE
}


@(private)
receive_events :: proc(conn: ^Connection, st: ^State, obj: u32, ev: Event) -> Progress {
	#partial switch e in ev {
	case Event_Registry_Global:
		switch e.interface {
		case "wl_shm":
			if st.use_software {
				st.wl_shm = registry_bind(
					conn,
					st.wl_registry,
					e.name,
					e.interface,
					e.version,
					Shm,
				)
			}
		case "xdg_wm_base":
			st.xdg_wm_base = registry_bind(
				conn,
				st.wl_registry,
				e.name,
				e.interface,
				e.version,
				Xdg_Wm_Base,
			)
		case "wl_compositor":
			st.wl_compositor = registry_bind(
				conn,
				st.wl_registry,
				e.name,
				e.interface,
				e.version,
				Compositor,
			)
		case "wl_seat":
			st.wl_seat = registry_bind(conn, st.wl_registry, e.name, e.interface, e.version, Seat)
		case "zwp_linux_dmabuf_v1":
			st.zwp_linux_dmabuf = registry_bind(
				conn,
				st.wl_registry,
				e.name,
				e.interface,
				4,
				Zwp_Linux_Dmabuf_V1,
			)
		}
	case Event_Display_Error:
		fmt.println("[ERROR] code:", e.code, "::", e.object_id, e.message)
	case Event_Shell_Surface_Ping:
		xdg_wm_base_pong(conn, Xdg_Wm_Base(obj), e.serial)
		fmt.println("Received XDG_WM_BASE ping:", e.serial)
	case Event_Xdg_Surface_Configure:
		xdg_surface_ack_configure(conn, st.xdg_surface, e.serial)
		st.status = .SurfaceAckedConfigure
		fmt.println(st.status, e.serial)
	case Event_Shm_Format:
		fmt.println("Received WL_SHM format", e.format)
		if e.format == .Argb8888 {
			fmt.println("ARGB8888 supported by compositor!")
		}
	case Event_Xdg_Toplevel_Configure:
		fmt.println("config: ", e.height, "x", e.height, "|| states: ", e.states, sep = "")
		if st.use_software {
			if e.height == 0 || e.width == 0 do break
			if st.wl_buffer != 0 && i32(st.buffer_size) != e.height * e.width * 4 {
				resize_pool(st, e.width, e.height)
				for &b, i in st.wl_buffer {
					if b != 0 do buffer_destroy(conn, b)
					b = shm_pool_create_buffer(
						conn,
						st.wl_shm_pool,
						i32(i) * i32(st.buffer_size),
						i32(st.w),
						i32(st.h),
						i32(st.stride),
						.Argb8888,
					)
				}
				st.status = .None
			}
			if (st.wl_shm_pool != 0 && st.buffer_size * 2 > MAX_POOL_SIZE) {
				shm_pool_resize(conn, st.wl_shm_pool, i32(st.buffer_size))
			}
		}
	case Event_Xdg_Toplevel_Close:
		return .Exit
	case Event_Callback_Done:
		when ODIN_DEBUG do fmt.printfln("%ims", e.callback_data - st.tick)
		st.tick = e.callback_data
		st.should_redraw = true
	case Event_Xdg_Toplevel_Configure_Bounds:
		fmt.println("config bounds: ", e.width, "x", e.height)
	case Event_Xdg_Toplevel_Wm_Capabilities:
		fmt.println("capabilities:", e.capabilities)
	case Event_Seat_Capabilities:
		capabilities := u32(e.capabilities)
		fmt.println("Seat capabilities: ", capabilities)
		pointer_available := capabilities > 1
		keyboard_available := capabilities > 2
		touch_available := capabilities > 4
	case Event_Seat_Name:
	case Event_Keyboard_Keymap:
		fmt.println("Keymap", e.fd, e.size, st.keymap)
		assert(e.format == .Xkb_V1)
		fd: linux.Fd = auto_cast e.fd
		if (!st.keymap) {
			if ptr, err := linux.mmap(0, uint(e.size), {.READ}, {.PRIVATE}, fd); err != .NONE {
				fmt.println("mmap failed, ", err)
				linux.close(fd)
				return .Crash
			} else {
				st.keymap = true
				linux.munmap(ptr, uint(e.size))
			}
			linux.close(fd)
		}
	case:
		when ODIN_DEBUG do fmt.printf("unknown message header: %i; opcode: %i\n", obj, e)
	}
	return .Continue
}

resize_pool :: proc(state: ^State, w, h: i32) {
	state.w = auto_cast w
	state.h = auto_cast h
	state.stride = state.w * 4
	state.buffer_size = state.stride * state.h
}

quit :: proc(conn: ^Connection, state: State) {
	for b in state.wl_buffer {
		if b != 0 do buffer_destroy(conn, b)
	}
	if state.wl_shm_pool != 0 do shm_pool_destroy(conn, state.wl_shm_pool)
	if state.xdg_toplevel != 0 do xdg_toplevel_destroy(conn, state.xdg_toplevel)
	if state.xdg_surface != 0 do xdg_surface_destroy(conn, state.xdg_surface)
	if state.wl_surface != 0 do surface_destroy(conn, state.wl_surface)
	if state.wl_seat != 0 do seat_release(conn, state.wl_seat)
	if state.wl_keyboard != 0 do keyboard_release(conn, state.wl_keyboard)
	if state.wl_pointer != 0 do pointer_release(conn, state.wl_pointer)
	connection_flush(conn)
	if len(state.shm_pool_data) > 0 {
		linux.munmap(raw_data(state.shm_pool_data), len(state.shm_pool_data))
	}
	linux.close(state.shm_fd)
	linux.close(conn.socket)
	delete(conn.object_types)
	delete(conn.fds_in)
	delete(conn.fds_out)
	delete(conn.free_ids)
	bytes.buffer_destroy(&conn.buffer)
}

