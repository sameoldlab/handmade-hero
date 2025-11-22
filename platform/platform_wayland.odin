package platform

import app "../app"
import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "egl"
import "gbm"
import gl "vendor:OpenGL"
import wl "wayland"


MAX_POOL_SIZE :: app.BUF_WIDTH * app.BUF_HEIGHT * 4 * 4
BUF_LEN :: 2
State :: struct {
	buffer_size, stride, w, h:           u32,
	tick:                                u32,
	keymap, use_software, should_redraw: bool,
	status:                              Status,

	// WL
	wl_registry:                         wl.Registry,
	wl_buffer:                           [BUF_LEN]wl.Buffer,
	xdg_wm_base:                         wl.Xdg_Wm_Base,
	xdg_surface:                         wl.Xdg_Surface,
	wl_surface:                          wl.Surface,
	surface_callback:                    wl.Callback,
	wl_compositor:                       wl.Compositor,
	xdg_toplevel:                        wl.Xdg_Toplevel,
	wl_seat:                             wl.Seat,
	wl_pointer:                          wl.Pointer,
	wl_keyboard:                         wl.Keyboard,
	data_device_manager:                 wl.Data_Device_Manager,
	data_source:                         wl.Data_Source,
	cursor_shape_manager:                wl.Wp_Cursor_Shape_Manager_V1,

	// EGL
	egl_display:                         egl.Display,
	egl_surface:                         egl.Surface,
	egl_context:                         egl.Context,

	// GBM
	drm_fd:                              linux.Fd,
	gbm_device:                          gbm.Device,
	gbm_surface:                         gbm.Surface,
	zwp_linux_dmabuf:                    wl.Zwp_Linux_Dmabuf_V1,
	shader_program, vao, vbo:            u32,

	// SHM
	shm_fd:                              linux.Fd,
	wl_shm:                              wl.Shm,
	wl_shm_pool:                         wl.Shm_Pool,
	shm_pool_data:                       []u8,
}

Gbo :: struct {
	bo:     gbm.BufferObject,
	fd:     linux.Fd,
	busy:   bool,
	buffer: wl.Buffer,
}
gbo: #soa[BUF_LEN]Gbo

Error :: enum {
	None,
	Crash,
	NoWayland,
}
Status :: enum {
	None,
	SurfaceAckedConfigure,
	SurfaceAttached,
}
GL :: #config(GL, false)

wl_start :: proc() -> Error {
	conn, display, ok := connect_display()
	if !ok do return .NoWayland
	st := State {
		wl_registry   = wl.display_get_registry(&conn, display),
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
	if create_objects(&conn, &st, recv_buf[:]) != .NONE {
		fmt.println("Initial object creation failed")
		return .Crash
	}
	defer quit(&conn, st)

	i: u8 = 0
	fmt.println("Entering main loop")
	m: for {
		if err := wl.connection_flush(&conn); err != .NONE {
			fmt.println("FLUSH Error:", err)
			for {
				object, event := wl.peek_event(&conn) or_break
				receive_events(&conn, &st, object, event)
			}
			return .Crash
		}

		{
			result, _ := linux.poll({linux.Poll_Fd{fd = conn.socket, events = {.IN}}}, 2)
			if result > 0 {
				wl.connection_poll(&conn, recv_buf[:])

				for {
					object, event := wl.peek_event(&conn) or_break
					if exit := receive_events(&conn, &st, object, event); exit do return .None
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
	return .None
}

draw :: proc(conn: ^wl.Connection, st: ^State, i: u32) {
	fmt.println("====================START DRAW====================")
	using st
	if use_software {
		if !should_redraw do return
		i := i % len(st.wl_buffer)
		wl.surface_frame(conn, wl_surface)
		app.update_render(st.shm_pool_data[((i)) * st.buffer_size:][:st.buffer_size], st.w, st.h)
		wl.surface_attach(conn, wl_surface, wl_buffer[i], 0, 0)
		wl.surface_damage_buffer(conn, wl_surface, 0, 0, i32(w), i32(h))
		wl.surface_commit(conn, wl_surface)
		st.should_redraw = false
	} else {
		assert(st.zwp_linux_dmabuf != 0)
		buf: Gbo

		for tmp_buf, i in gbo {
			fmt.println("trying: ", tmp_buf)
			if !tmp_buf.busy {
				fmt.println("found free")
				buf = tmp_buf
				break
			}
		}
		if buf.busy {
			st.should_redraw = false
			fmt.println("busy")
			fmt.println("====================END DRAW====================")
			return
		}

		fmt.println("clear")
		renderer_draw(st.shader_program, st.vao)
		fmt.println("swap")
		res := egl.SwapBuffers(egl_display, egl_surface)
		fmt.printfln("swap (%b32)", res)
		assert(res == true)

		bo := gbm.surface_lock_front_buffer(st.gbm_surface)
		fmt.println("post-lock", bo)
		assert(bo != {})

		if buf.bo != {} && buf.bo != bo {
			last_bo := buf.bo
			if buffer, bound_bo, ok := init_buffer(
				conn,
				st,
				buf,
				egl_surface,
				egl_display,
				gbm_surface,
			); ok {
				buf.bo = bound_bo
				buf.buffer = buffer
				buf.busy = false
			}
			gbm.surface_release_buffer(gbm_surface, last_bo)
		}

		wl.surface_attach(conn, wl_surface, buf.buffer, 0, 0)
		wl.surface_damage_buffer(conn, wl_surface, 0, 0, i32(w), i32(h))
		wl.surface_commit(conn, wl_surface)
		wl.surface_commit(conn, wl_surface)


		buf.busy = true
		st.should_redraw = false
		fmt.println("====================END DRAW====================")
	}
}
create_objects :: proc(conn: ^wl.Connection, st: ^State, buff: []byte) -> linux.Errno {
	wl.connection_flush(conn) or_return
	wl.connection_poll(conn, buff)
	for {
		object, event := wl.peek_event(conn) or_break
		if exit := receive_events(conn, st, object, event); exit do return .NONE
	}
	conn.data_cursor = 0
	conn.data = {}
	assert(st.wl_compositor != 0)
	assert(st.xdg_wm_base != 0)
	assert(st.wl_seat != 0)

	st.wl_surface = wl.compositor_create_surface(conn, st.wl_compositor)
	st.xdg_surface = wl.xdg_wm_base_get_xdg_surface(conn, st.xdg_wm_base, st.wl_surface)
	st.xdg_toplevel = wl.xdg_surface_get_toplevel(conn, st.xdg_surface)
	st.wl_keyboard = wl.seat_get_keyboard(conn, st.wl_seat)
	st.wl_pointer = wl.seat_get_pointer(conn, st.wl_seat)

	wl.xdg_toplevel_set_title(conn, st.xdg_toplevel, app.TITLE)
	wl.xdg_toplevel_set_app_id(conn, st.xdg_toplevel, app.APP_ID)
	wl.surface_commit(conn, st.wl_surface)
	if st.zwp_linux_dmabuf != 0 {
		wl.zwp_linux_dmabuf_v1_get_surface_feedback(conn, st.zwp_linux_dmabuf, st.wl_surface)
	}

	fmt.println(st.xdg_surface, "xdg_surface")
	fmt.println(st.wl_keyboard, "wl_keyboard")
	fmt.println(st.wl_pointer, "wl_pointer")
	wl.connection_flush(conn) or_return
	wl.connection_poll(conn, buff)
	for {
		object, event := wl.peek_event(conn) or_break
		if exit := receive_events(conn, st, object, event); exit do return .NONE
	}
	conn.data_cursor = 0
	conn.data = {}
	if st.use_software {
		using st
		if wl_shm != 0 && wl_shm_pool == 0 && wl_buffer == 0 {
			wl_shm_pool = wl.shm_create_pool(conn, wl_shm, auto_cast shm_fd, i32(MAX_POOL_SIZE))
			for &b, i in wl_buffer {
				b = wl.shm_pool_create_buffer(
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
	} else {
		if !setup_egl(conn, st) {
			fmt.println("Error in GL creation")
			return .EADV
		}
	}
	return .NONE
}

connect_display :: proc() -> (conn: wl.Connection, display: wl.Display, ok: bool) {
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
		fmt.println("Wayland connection failed:", err)
		return
	}

	conn, display = wl.display_connect(socket)
	conn.object_types = make([dynamic]wl.Object_Type, 2)
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
receive_events :: proc(conn: ^wl.Connection, st: ^State, obj: u32, ev: wl.Event) -> (exit: bool) {
	#partial switch e in ev {
	case wl.Event_Registry_Global:
		switch e.interface {
		case "wl_shm":
			if st.use_software {
				st.wl_shm = wl.registry_bind(
					conn,
					st.wl_registry,
					e.name,
					e.interface,
					e.version,
					wl.Shm,
				)
			}
		case "xdg_wm_base":
			st.xdg_wm_base = wl.registry_bind(
				conn,
				st.wl_registry,
				e.name,
				e.interface,
				e.version,
				wl.Xdg_Wm_Base,
			)
		case "wl_compositor":
			st.wl_compositor = wl.registry_bind(
				conn,
				st.wl_registry,
				e.name,
				e.interface,
				e.version,
				wl.Compositor,
			)
		case "wl_seat":
			st.wl_seat = wl.registry_bind(
				conn,
				st.wl_registry,
				e.name,
				e.interface,
				e.version,
				wl.Seat,
			)
		case "zwp_linux_dmabuf_v1":
			st.zwp_linux_dmabuf = wl.registry_bind(
				conn,
				st.wl_registry,
				e.name,
				e.interface,
				4,
				wl.Zwp_Linux_Dmabuf_V1,
			)
		// zwp_linux_dmabuf_v1_get_default_feedback(conn, st.zwp_linux_dmabuf)
		}
	// fmt.println(e.interface)
	case wl.Event_Display_Error:
		fmt.println("[ERROR] code:", e.code, "::", e.object_id, e.message)
	case wl.Event_Shell_Surface_Ping:
		wl.xdg_wm_base_pong(conn, wl.Xdg_Wm_Base(obj), e.serial)
		fmt.println("Received XDG_WM_BASE ping:", e.serial)
	case wl.Event_Xdg_Surface_Configure:
		wl.xdg_surface_ack_configure(conn, st.xdg_surface, e.serial)
		st.status = .SurfaceAckedConfigure
		fmt.println(st.status, e.serial)
	case wl.Event_Shm_Format:
		fmt.println("Received WL_SHM format", e.format)
		if e.format == .Argb8888 {
			fmt.println("ARGB8888 supported by compositor!")
		}
	case wl.Event_Xdg_Toplevel_Configure:
		fmt.println("config: ", e.height, "x", e.height, "|| states: ", e.states, sep = "")
		if st.use_software {
			if e.height == 0 || e.width == 0 do break
			if st.wl_buffer != 0 && i32(st.buffer_size) != e.height * e.width * 4 {
				resize_pool(st, e.width, e.height)
				for &b, i in st.wl_buffer {
					if b != 0 do wl.buffer_destroy(conn, b)
					b = wl.shm_pool_create_buffer(
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
				wl.shm_pool_resize(conn, st.wl_shm_pool, i32(st.buffer_size))
			}
		}
	case wl.Event_Xdg_Toplevel_Close:
		return true
	case wl.Event_Callback_Done:
		when ODIN_DEBUG do fmt.printfln("%ims", e.callback_data - st.tick)
		st.tick = e.callback_data
		st.should_redraw = true
	case wl.Event_Xdg_Toplevel_Configure_Bounds:
		fmt.println("config bounds: ", e.width, "x", e.height)
	case wl.Event_Xdg_Toplevel_Wm_Capabilities:
		fmt.println("capabilities:", e.capabilities)
	case wl.Event_Buffer_Release:
		fmt.println("Buffer released")
	case wl.Event_Zwp_Linux_Dmabuf_Feedback_V1_Main_Device:
		fmt.println("wl.Event_Zwp_Linux_Dmabuf_Feedback_V1_Main_Device", e)
	case wl.Event_Zwp_Linux_Dmabuf_Feedback_V1_Format_Table:
		fmt.println("wl.Event_Zwp_Linux_Dmabuf_Feedback_V1_Format_Table", e)
	case wl.Event_Seat_Capabilities:
		capabilities := u32(e.capabilities)
		fmt.println("Seat capabilities: ", capabilities)
		pointer_available := capabilities > 1
		keyboard_available := capabilities > 2
		touch_available := capabilities > 4
	case wl.Event_Seat_Name:
	case wl.Event_Keyboard_Keymap:
		fmt.println("Keymap", e.fd, e.size, st.keymap)
		assert(e.format == .Xkb_V1)
		fd: linux.Fd = auto_cast e.fd
		if (!st.keymap) {
			if ptr, err := linux.mmap(0, uint(e.size), {.READ}, {.PRIVATE}, fd); err != .NONE {
				fmt.println("mmap failed, ", err)
				linux.close(fd)
				return false
			} else {
				st.keymap = true
				linux.munmap(ptr, uint(e.size))
			}
			linux.close(fd)
		}
	case:
		when ODIN_DEBUG do fmt.printf("unknown message header: %i; opcode: %i\n", obj, e)
	}
	return false
}

resize_pool :: proc(state: ^State, w, h: i32) {
	state.w = auto_cast w
	state.h = auto_cast h
	state.stride = state.w * 4
	state.buffer_size = state.stride * state.h
}

quit :: proc(conn: ^wl.Connection, state: State) {
	// TODO: Single destroy command for any wl.object
	for b in state.wl_buffer {
		if b != 0 do wl.buffer_destroy(conn, b)
	}
	if state.wl_shm_pool != 0 do wl.shm_pool_destroy(conn, state.wl_shm_pool)
	if state.xdg_toplevel != 0 do wl.xdg_toplevel_destroy(conn, state.xdg_toplevel)
	if state.xdg_surface != 0 do wl.xdg_surface_destroy(conn, state.xdg_surface)
	if state.wl_surface != 0 do wl.surface_destroy(conn, state.wl_surface)
	if state.wl_seat != 0 do wl.seat_release(conn, state.wl_seat)
	if state.wl_keyboard != 0 do wl.keyboard_release(conn, state.wl_keyboard)
	if state.wl_pointer != 0 do wl.pointer_release(conn, state.wl_pointer)
	wl.connection_flush(conn)
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

