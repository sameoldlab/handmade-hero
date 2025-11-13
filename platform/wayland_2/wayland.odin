package wayland

import app "../../app"
import "core:bytes"
import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sys/linux"
import "core:sys/unix"


MAX_POOL_SIZE :: app.BUF_WIDTH * app.BUF_HEIGHT * 4 * 4
State :: struct {
	shm_pool_size, stride, w, h: i32,
	shm_fd:                      linux.Fd,
	shm_pool_data:               []u8,
	status:                      Status,
	wl_registry:                 Registry,
	wl_shm:                      Shm,
	wl_shm_pool:                 Shm_Pool,
	wl_buffer:                   Buffer,
	xdg_wm_base:                 Xdg_Wm_Base,
	xdg_surface:                 Xdg_Surface,
	wl_surface:                  Surface,
	wl_compositor:               Compositor,
	xdg_toplevel:                Xdg_Toplevel,
	wl_seat:                     Seat,
	wl_pointer:                  Pointer,
	wl_keyboard:                 Keyboard,
	data_device_manager:         Data_Device_Manager,
	data_source:                 Data_Source,
	cursor_shape_manager:        Wp_Cursor_Shape_Manager_V1,
	keymap:                      bool,
}
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

run :: proc() -> Progress {
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
		return .NoWayland
	}

	conn, wl_display := display_connect(socket)
	conn.object_types = make([dynamic]Object_Type, 2)
	conn.object_types[1] = .Display

	state := State {
		wl_registry = display_get_registry(&conn, wl_display),
		w           = 500,
		h           = 500,
	}
	display_sync(&conn, wl_display)

	state.stride = state.w * 4
	state.shm_pool_size = state.stride * state.h

	shm_fd, shm_err := create_shm_file(&state.shm_pool_data, MAX_POOL_SIZE)
	if shm_err != .NONE {
		return .Crash
	}
	state.shm_fd = shm_fd
	defer quit(&conn, state)

	recv_buf: [4096]byte
	// recv_buf := make([]u8, 1 << 16)
	fmt.println("ready")
	m: for {
		if err := connection_flush(&conn); err != .NONE {
			fmt.println("FLUSH Error:", err)
			fmt.println("Reading final messages")

			connection_poll(&conn, recv_buf[:])
			object, event, err := peek_event(&conn)
			receive_events(&conn, &state, object, event)
			return .Crash
		}

		pfd := linux.Poll_Fd {
			fd     = conn.socket,
			events = {.IN},
		}
		result, err := linux.poll({pfd}, 1)
		if result > 0 {
			connection_poll(&conn, recv_buf[:])
			// fmt.println("+ poll")
		}
		for {
			object, event := peek_event(&conn) or_break
			if prog := receive_events(&conn, &state, object, event); prog != .Continue do return prog
		}
		conn.data_cursor = 0
		conn.data = {}
		using state
		if wl_shm != 0 && wl_compositor != 0 && xdg_wm_base != 0 && wl_surface == 0 {
			wl_surface = compositor_create_surface(&conn, wl_compositor)
			xdg_surface = xdg_wm_base_get_xdg_surface(&conn, xdg_wm_base, wl_surface)
			xdg_toplevel = xdg_surface_get_toplevel(&conn, xdg_surface)
			surface_commit(&conn, wl_surface)
			fmt.println(xdg_surface, "xdg_surface")
			fmt.println(xdg_toplevel, "xdg_toplevel")
			fmt.println(wl_surface, "wl_surface")
			xdg_toplevel_set_title(&conn, state.xdg_toplevel, app.TITLE)
			xdg_toplevel_set_app_id(&conn, state.xdg_toplevel, app.APP_ID)
		}
		if wl_seat != 0 && wl_keyboard == 0 {
			wl_keyboard = seat_get_keyboard(&conn, wl_seat)
			wl_pointer = seat_get_pointer(&conn, wl_seat)
			fmt.println(wl_keyboard, "wl_keyboard")
			fmt.println(wl_pointer, "wl_pointer")
		}

		if status == .None do continue
		if wl_shm_pool == 0 && wl_buffer == 0 {
			wl_shm_pool = shm_create_pool(&conn, wl_shm, auto_cast shm_fd, i32(MAX_POOL_SIZE))
			fmt.println(wl_shm_pool, "shm created")
			wl_buffer = shm_pool_create_buffer(&conn, wl_shm_pool, 0, w, h, stride, .Xrgb8888)
			fmt.println(wl_buffer, "buffer created")
			assert(len(shm_pool_data) != 0)
			// assert(shm_pool_size != 0)
		}

		app.update_render(
			&{fb = state.shm_pool_data[:state.shm_pool_size], h = state.h, w = state.w},
		)
		surface_attach(&conn, wl_surface, wl_buffer, 0, 0)
		surface_commit(&conn, wl_surface)
		surface_damage_buffer(&conn, wl_surface, 0, 0, w, h)
		surface_commit(&conn, wl_surface)

		state.status = .SurfaceAttached
	}
	return .Exit
}

connect_display :: proc() -> (conn: Connection, display: Display, err: linux.Errno) {
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

	err = linux.connect(socket, &addr)
	assert(err == {})

	conn, display = display_connect(socket)
	conn.object_types = make([dynamic]Object_Type, 2)
	conn.object_types[1] = .Display

	return conn, display, err
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
receive_events :: proc(conn: ^Connection, state: ^State, obj: u32, ev: Event) -> Progress {
	#partial switch e in ev {
	case Event_Registry_Global:
		switch e.interface {
		case "wl_shm":
			state.wl_shm = registry_bind(
				conn,
				state.wl_registry,
				e.name,
				e.interface,
				e.version,
				Shm,
			)
			fmt.println(e.name, e.interface, e.version, state.wl_shm)
		case "xdg_wm_base":
			state.xdg_wm_base = registry_bind(
				conn,
				state.wl_registry,
				e.name,
				e.interface,
				e.version,
				Xdg_Wm_Base,
			)
			fmt.println(e.name, e.interface, "v", e.version, state.xdg_wm_base)
		case "wl_compositor":
			state.wl_compositor = registry_bind(
				conn,
				state.wl_registry,
				e.name,
				e.interface,
				e.version,
				Compositor,
			)
			fmt.println(e.name, e.interface, e.version, state.wl_compositor)
		case "wl_seat":
			state.wl_seat = registry_bind(
				conn,
				state.wl_registry,
				e.name,
				e.interface,
				e.version,
				Seat,
			)
		}
	case Event_Display_Error:
		fmt.println("[ERROR] code:", e.code, "::", e.object_id, e.message)
	case Event_Shell_Surface_Ping:
		xdg_wm_base_pong(conn, Xdg_Wm_Base(obj), e.serial)
		fmt.println("Received XDG_WM_BASE ping:", e.serial)
	case Event_Xdg_Surface_Configure:
		xdg_surface_ack_configure(conn, state.xdg_surface, e.serial)
		state.status = .SurfaceAckedConfigure
		fmt.println(state.status, e.serial)
	case Event_Shm_Format:
		fmt.println("Received WL_SHM format", e.format)
		if e.format == .Xrgb8888 {
			fmt.println("XRGB8888 supported by compositor!")
		}
	case Event_Xdg_Toplevel_Configure:
		fmt.println("config: ", e.height, "x", e.height, "|| states: ", e.states, sep = "")
		if e.height == 0 || e.width == 0 do break
		if state.wl_buffer != 0 && state.shm_pool_size != e.height * e.width * 4 {
			resize_pool(state, e.width, e.height)
			buffer_destroy(conn, state.wl_buffer)
			state.wl_buffer = shm_pool_create_buffer(
				conn,
				state.wl_shm_pool,
				0,
				state.w,
				state.h,
				state.stride,
				.Xrgb8888,
			)
			state.status = .None
		}
		if (state.wl_shm_pool != 0 && state.shm_pool_size * 2 > MAX_POOL_SIZE) {
			shm_pool_resize(conn, state.wl_shm_pool, state.shm_pool_size)
		}
	case Event_Xdg_Toplevel_Close:
		return .Exit
	case Event_Callback_Done:
		fmt.println("DONE!!!")
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
		fmt.println("Keymap", e.fd, e.size, state.keymap)
		assert(e.format == .Xkb_V1)
		fd: linux.Fd = auto_cast e.fd
		if (!state.keymap) {
			if ptr, err := linux.mmap(0, uint(e.size), {.READ}, {.PRIVATE}, fd); err != .NONE {
				fmt.println("mmap failed, ", err)
				linux.close(fd)
				return .Crash
			} else {
				state.keymap = true
				linux.munmap(ptr, uint(e.size))
			}
			linux.close(fd)
		}
	case:
		fmt.printf("unknown message header: %i; opcode: %i\n", obj, e)
	}
	return .Continue
}
resize_pool :: proc(state: ^State, w, h: i32) -> i32 {
	state.w = w
	state.h = h
	state.stride = state.w * 4
	state.shm_pool_size = state.stride * state.h
	return state.shm_pool_size
}
quit :: proc(conn: ^Connection, state: State) {
	if state.wl_buffer != 0 do buffer_destroy(conn, state.wl_buffer)
	if state.wl_shm_pool != 0 do shm_pool_destroy(conn, state.wl_shm_pool)
	if state.xdg_toplevel != 0 do xdg_toplevel_destroy(conn, state.xdg_toplevel)
	if state.xdg_surface != 0 do xdg_surface_destroy(conn, state.xdg_surface)
	if state.wl_surface != 0 do surface_destroy(conn, state.wl_surface)
	if state.wl_seat != 0 do seat_release(conn, state.wl_seat)
	if state.wl_keyboard != 0 do keyboard_release(conn, state.wl_keyboard)
	if state.wl_pointer != 0 do pointer_release(conn, state.wl_pointer)
	connection_flush(conn)
	fmt.println("closing shm_fd", state.shm_fd)
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

