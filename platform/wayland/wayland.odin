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
import "core:sys/linux"
import "core:sys/unix"


/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*.
                         HELPERS                            
.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

// Should provide a higher-level interface for common wayland tasks
// than what is available interacting soley the wayland specification.
// If 90% of usage examples show `do_thing()`, Helpers should include
// a do_thing function.


run :: proc(conn: ^Wl_Connection) -> linux.Errno {
	state := State {
		wl_registry = display_get_registry(conn) or_return,
		w           = app.BUF_WIDTH,
		h           = app.BUF_HEIGHT,
	}
	state.stride = state.w * 4
	state.shm_pool_size = state.stride * state.h * 2

	receive_events(conn, &state) or_return

	// these specifically get asserted because idk what
	// the registry global event will return. There is no need to
	// assert with the remaining binds because
	// if the object_id == 0 they will also return an error
	assert(state.wl_shm != 0)
	assert(state.xdg_wm_base != 0)
	assert(state.wl_compositor != 0)

	fmt.println("ready")
	state.wl_surface = wl_compositor_create_surface(conn, &state) or_return
	fmt.println(state.wl_surface, "created surface")
	state.xdg_surface = xdg_wm_base_get_xdg_surface(conn, &state) or_return
	fmt.println(state.xdg_surface, "xdg surface")
	state.xdg_toplevel = xdg_surface_get_toplevel(conn, &state) or_return
	fmt.println(state.xdg_toplevel, "xdg toplevel")
	wl_surface_commit(conn^, state) or_return
	fmt.println(state.wl_surface, "commited surface")
	receive_events(conn, &state) or_return

	if state.status == .SurfaceAckedConfigure {
		state.shm_pool_data = make([]u8, state.shm_pool_size)
		defer delete(state.shm_pool_data)
		state.shm_fd = create_shm_file(&state.shm_pool_data, state.shm_pool_size, state) or_return

		state.wl_shm_pool = wl_shm_create_pool(conn, state) or_return
		fmt.println(state.wl_shm_pool, "shm created")
		state.wl_buffer = wl_shm_pool_create_buffer(conn, state, 0, FORMAT_XRGB8888) or_return
		fmt.println(state.wl_buffer, "buffer created")
		receive_events(conn, &state) or_return

		app.draw_gradient(
			state.shm_pool_data[:state.h * state.stride],
			i32(state.w),
			i32(state.h),
			0,
			0,
		)
		wl_surface_attach(conn^, state) or_return
		fmt.println(state.wl_surface, "attached surface")
		wl_surface_commit(conn^, state) or_return
		fmt.println(state.wl_surface, "commited surface")
		state.status = .SurfaceAttached
		receive_events(conn, &state) or_return
	}


	return .NONE
}

connect_display :: proc() -> (conn: Wl_Connection, err: linux.Errno) {
	addr: linux.Sock_Addr_Un
	addr.sun_family = linux.Address_Family.UNIX
	conn.current_id = WL_DISPLAY_OBJECT_ID

	arena: mem.Arena
	mem.arena_init(&arena, addr.sun_path[:])
	path_allocator := mem.arena_allocator(&arena)

	xdg_runtime_dir := os.get_env("XDG_RUNTIME_DIR", path_allocator)
	if xdg_runtime_dir == "" do return conn, linux.Errno.EINVAL

	divider := new(u8, path_allocator)
	divider^ = '/'

	wayland_display := os.get_env("WAYLAND_DISPLAY", path_allocator)
	wayland_display = wayland_display if wayland_display != "" else "wayland-0"

	conn.fd = linux.socket(linux.Address_Family.UNIX, linux.Socket_Type.STREAM, nil, nil) or_return

	result := linux.connect(conn.fd, &addr)
	if result != linux.Errno.NONE {
		return conn, result
	}
	return conn, result
}

create_shm_file :: proc(
	fb: ^[]u8,
	size: u32,
	state: State,
) -> (
	shm_fd: linux.Fd,
	err: linux.Errno,
) {
	shm_fd = linux.Fd(
		linux.syscall(linux.SYS_memfd_create, transmute(^u8)(cstring("wayland-shm")), 1),
	)
	// shm_fd = memfd_create("wayland-shm") or_return
	linux.ftruncate(shm_fd, i64(size)) or_return
	shm_ptr, mmap_err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, shm_fd, 0)
	if mmap_err != .NONE {
		linux.close(shm_fd)
		return 0, mmap_err
	}
	fb^ = mem.slice_ptr(cast(^byte)shm_ptr, int(size))
	return shm_fd, .NONE
}

@(private)
receive_events :: proc(ctx: ^Wl_Connection, state: ^State) -> linux.Errno {
	recv_buf: [4096]byte
	bytes_read, err := linux.read(ctx.fd, recv_buf[:])
	if err != .NONE do return err
	assert(bytes_read > HEADER_SIZE)

	buf := recv_buf[:bytes_read]

	for len(buf) > 0 {
		header: Wl_Header = (cast(^Wl_Header)raw_data(buf[:HEADER_SIZE]))^
		body := buf[HEADER_SIZE:header.message_size]
		switch header.object_id {
		case state.wl_registry:
			switch header.opcode {
			case WL_REGISTRY_EVENT_GLOBAL:
				name := buf_read_u32(&body)
				interface := buf_read_string(&body)
				version := buf_read_u32(&body)

				switch interface {
				case "wl_shm":
					state.wl_shm = wl_registry_bind(
						ctx,
						state.wl_registry,
						name,
						interface,
						version,
					) or_return
					fmt.println(name, interface, version, state.wl_shm)
				case "xdg_wm_base":
					state.xdg_wm_base = wl_registry_bind(
						ctx,
						state.wl_registry,
						name,
						interface,
						version,
					) or_return
					fmt.println(name, interface, "v", version, state.xdg_wm_base)
				case "wl_compositor":
					state.wl_compositor = wl_registry_bind(
						ctx,
						state.wl_registry,
						name,
						interface,
						version,
					) or_return
					fmt.println(name, interface, version, state.wl_compositor)
				}
			}
		case WL_DISPLAY_OBJECT_ID:
			switch header.opcode {
			case WL_DISPLAY_ERROR_EVENT:
				target_object_id := buf_read_u32(&body)
				code := buf_read_u32(&body)
				error := buf_read_string(&body)
				fmt.println("[ERROR] code:", Wl_display_error(code), "::", target_object_id, error)
			// return .NONE
			}
		case state.xdg_wm_base:
			switch header.opcode {
			case XDG_WM_BASE_EVENT_PING:
				ping := buf_read_u32(&body)
				xdg_wm_base_pong(ctx, state^, ping)
				fmt.println("Received XDG_WM_BASE ping:", ping)
			}
		case state.xdg_surface:
			switch header.opcode {
			case XDG_SURFACE_EVENT_CONFIGURE:
				configure := buf_read_u32(&body)
				xdg_surface_ack_configure(ctx, state^, configure)
				state.status = .SurfaceAckedConfigure
				fmt.println(state.status, configure)
			}
		case state.wl_shm:
			switch header.opcode {
			case WL_SHM_EVENT_FORMAT:
				// wl_shm format event
				format := buf_read_u32(&body)
				fmt.println("Received WL_SHM format", format)
				if format == FORMAT_XRGB8888 {
					fmt.println("FORMAT_XRGB8888 is supported by compositor!")
				}
			}
		case state.xdg_toplevel:
			switch header.opcode {
			case u16(xdg_toplevel_ev.configure):
				w := buf_read_u32(&body)
				h := buf_read_u32(&body)
				states := buf_read_array(&body)
				fmt.println("config: ", w, "x", h, "|| states: ", states, sep = "")
			// xdg_surface_ack_configure(ctx, state^, configure)
			case u16(xdg_toplevel_ev.close):
				fmt.println("CLOSE!!!")
			case u16(xdg_toplevel_ev.configure_bounds):
				w := buf_read_u32(&body)
				h := buf_read_u32(&body)
				fmt.println("config bounds: ", w, "x", h)
			case u16(xdg_toplevel_ev.wm_capabilities):
				capabilities := buf_read_array(&body)
				fmt.println("capabilities:", capabilities)
			}
		case:
			fmt.printf("unknown message header: %i; opcode: %i", header.object_id, header.opcode)
			fmt.println(buf[:header.message_size])
		}
		buf = buf[header.message_size:]
	}
	// if bytes_read <= 0 do break
	// fmt.println(recv_buf[0:][:40])
	return .NONE
}
/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*.
                     STRUCTS & CONSTANTS                            
.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/


WL_DISPLAY_OBJECT_ID :: 1
WL_DISPLAY_GET_REGISTRY_OPCODE :: 1
WL_DISPLAY_ERROR_EVENT :: 0

Wl_display_op :: enum {
	sync         = 0,
	get_registry = 1,
}

Wl_display_ev :: enum {
	error     = 0,
	delete_id = 1,
}

Wl_display_error :: enum {
	// server could not find object
	invalid_object = 0,
	// method doesn't exist on the specified interface or malformed request
	invalid_method = 1,
	// server is out of memory
	no_memory      = 2,
	// implementation error in compositor
	implementaion  = 3,
}

Wl_registry_op :: enum {
	bind = 0,
}

WL_REGISTRY_EVENT_GLOBAL :: 0
Wl_Registry_ev_global :: struct {
	name:      u32, // Unique name for this global
	interface: string, // Interface name (e.g., "wl_compositor")
	version:   u32, // Interface version
}

WL_BUFFER_EVENT_RELEASE :: 0

WL_COMPOSITOR_CREATE_SURFACE_OPCODE :: 0

WL_SURFACE_ATTACH_OPCODE :: 1
WL_SURFACE_COMMIT_OPCODE :: 6

WL_SHM_CREATE_POOL_OPCODE :: 0
WL_SHM_POOL_CREATE_BUFFER_OPCODE :: 0
WL_SHM_EVENT_FORMAT :: 0

XDG_SURFACE_ACK_CONFIGURE_OPCODE :: 4
XDG_SURFACE_GET_TOPLEVEL_OPCODE :: 1
XDG_SURFACE_EVENT_CONFIGURE :: 0

XDG_WM_BASE_PONG_OPCODE :: 3
XDG_WM_BASE_GET_XDG_SURFACE_OPCODE :: 2
XDG_WM_BASE_EVENT_PING :: 0

xdg_toplevel_ev :: enum u16 {
	configure        = 0,
	close            = 1,
	configure_bounds = 2,
	wm_capabilities  = 3,
}
XDG_TOPLEVEL_EVENT_CLOSE :: 1
XDG_TOPLEVEL_EVENT_CONFIGURE :: 0

FORMAT_XRGB8888 :: 1
// object_id (4) + opcode|size (4)
HEADER_SIZE :: 8
COLOR_CHANNELS :: 4

Wl_Connection :: struct {
	fd:         linux.Fd,
	current_id: u32,
}

Wl_Header :: struct #packed {
	object_id:            u32,
	opcode, message_size: u16,
}
#assert(size_of(Wl_Header) == HEADER_SIZE)
#assert(offset_of(Wl_Header, object_id) == 0)

State :: struct {
	wl_registry, wl_shm, wl_shm_pool, wl_buffer, xdg_wm_base, xdg_surface: u32,
	wl_compositor, wl_surface, xdg_toplevel, stride, w, h, shm_pool_size:  u32,
	shm_fd:                                                                linux.Fd,
	shm_pool_data:                                                         []u8,
	status:                                                                Status,
}

Status :: enum {
	None,
	SurfaceAckedConfigure,
	SurfaceAttached,
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*.
                   PROTOCOL IMPLEMENTATION                    
.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
// 1-to-1 implementation of wayland object functions. Based on
// https://wayland.freedesktop.org/docs/ and /usr/share/wayland/wayland.xml
// wl_ prefixes have been left out for brevity (may change in future).


display_get_registry :: proc(ctx: ^Wl_Connection) -> (id: u32, err: linux.Errno) {
	MSG_SIZE :: HEADER_SIZE + size_of(u32)
	msg: [MSG_SIZE]byte

	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = WL_DISPLAY_OBJECT_ID,
		message_size = MSG_SIZE,
		opcode       = u16(Wl_display_op.get_registry),
	}

	ctx.current_id += 1
	buf_write_u32(msg[HEADER_SIZE:], ctx.current_id)

	send(ctx.fd, msg[:MSG_SIZE]) or_return

	return ctx.current_id, .NONE
}

wl_registry_bind :: proc(
	ctx: ^Wl_Connection,
	wl_registry: u32,
	name: u32,
	interface: string,
	version: u32,
) -> (
	id: u32,
	err: linux.Errno,
) {
	msg_size: u16 =
		HEADER_SIZE +
		size_of(u32) +
		(size_of(u32) + u16(align(len(interface) + 1))) +
		size_of(u32) +
		size_of(u32)

	msg: [64]byte

	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = wl_registry,
		message_size = msg_size,
		opcode       = u16(Wl_registry_op.bind),
	}

	body := buf_write_u32(msg[HEADER_SIZE:], name)
	body = buf_write_string(body[:], interface)
	body = buf_write_u32(body[:], version)
	ctx.current_id += 1
	body = buf_write_u32(body[:], ctx.current_id)

	// fmt.println("msg:", msg[:msg_size], len(msg[:msg_size]), "msg_size:", msg_size)

	send(ctx.fd, msg[:msg_size]) or_return

	return ctx.current_id, .NONE
}

wl_compositor_create_surface :: proc(
	ctx: ^Wl_Connection,
	state: ^State,
) -> (
	id: u32,
	err: linux.Errno,
) {
	MSG_SIZE :: HEADER_SIZE + size_of(u32)
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.wl_compositor,
		message_size = MSG_SIZE,
		opcode       = WL_COMPOSITOR_CREATE_SURFACE_OPCODE,
	}
	ctx.current_id += 1
	buf_write_u32(msg[HEADER_SIZE:], ctx.current_id)

	send(ctx.fd, msg[:MSG_SIZE]) or_return
	return ctx.current_id, .NONE
}

wl_shm_create_pool :: proc(ctx: ^Wl_Connection, state: State) -> (id: u32, err: linux.Errno) {
	MSG_SIZE :: HEADER_SIZE + (size_of(u32) * 2)
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.wl_shm,
		message_size = MSG_SIZE,
		opcode       = WL_SHM_CREATE_POOL_OPCODE,
	}
	ctx.current_id += 1
	body := buf_write_u32(msg[HEADER_SIZE:], ctx.current_id)
	body = buf_write_u32(body, state.shm_pool_size)


	fmt.println(msg[:MSG_SIZE], state.shm_pool_size, state.shm_fd)
	stat_buf: linux.Stat
	if linux.fstat(state.shm_fd, &stat_buf) != .NONE {
		fmt.println("Invalid fd!")
	}
	fmt.println("fd size:", stat_buf.size) // Should match shm_pool_size
	send_with_fd(ctx.fd, msg[:MSG_SIZE], state.shm_fd) or_return
	return ctx.current_id, .NONE
}

wl_shm_pool_create_buffer :: proc(
	ctx: ^Wl_Connection,
	state: State,
	offset: i32,
	format: u32,
) -> (
	id: u32,
	err: linux.Errno,
) {
	MSG_SIZE :: HEADER_SIZE * (size_of(u32) * 6)
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.wl_shm_pool,
		message_size = MSG_SIZE,
		opcode       = WL_SHM_POOL_CREATE_BUFFER_OPCODE,
	}
	ctx.current_id += 1
	body := buf_write_u32(msg[HEADER_SIZE:], ctx.current_id)
	body = buf_write_u32(body, offset)
	buf_write_u32(body, state.w)
	buf_write_u32(body, state.h)
	buf_write_u32(body, state.stride)
	buf_write_u32(body, format)

	send(ctx.fd, msg[:MSG_SIZE]) or_return
	return ctx.current_id, .NONE
}

wl_surface_attach :: proc(
	ctx: Wl_Connection,
	state: State,
	x: u32 = 0,
	y: u32 = 0,
) -> (
	err: linux.Errno,
) {
	MSG_SIZE :: HEADER_SIZE * (size_of(u32) * 3)
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.wl_surface,
		message_size = MSG_SIZE,
		opcode       = WL_SURFACE_ATTACH_OPCODE,
	}
	body := buf_write_u32(msg[HEADER_SIZE:], state.wl_buffer)
	body = buf_write_u32(body, x)
	buf_write_u32(body, y)

	send(ctx.fd, msg[:MSG_SIZE]) or_return
	return .NONE
}

wl_surface_commit :: proc(ctx: Wl_Connection, state: State) -> (err: linux.Errno) {
	MSG_SIZE :: HEADER_SIZE
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.wl_surface,
		message_size = MSG_SIZE,
		opcode       = WL_SURFACE_COMMIT_OPCODE,
	}

	send(ctx.fd, msg[:MSG_SIZE]) or_return
	return .NONE
}

xdg_wm_base_get_xdg_surface :: proc(
	ctx: ^Wl_Connection,
	state: ^State,
) -> (
	id: u32,
	err: linux.Errno,
) {
	MSG_SIZE :: HEADER_SIZE + (size_of(u32) * 2)
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.xdg_wm_base,
		message_size = MSG_SIZE,
		opcode       = XDG_WM_BASE_GET_XDG_SURFACE_OPCODE,
	}
	ctx.current_id += 1
	body := buf_write_u32(msg[HEADER_SIZE:], ctx.current_id)
	buf_write_u32(body, state.wl_surface)


	send(ctx.fd, msg[:MSG_SIZE]) or_return
	return ctx.current_id, .NONE
}

xdg_wm_base_pong :: proc(
	ctx: ^Wl_Connection,
	state: State,
	ping: u32,
) -> (
	id: u32,
	err: linux.Errno,
) {
	MSG_SIZE :: HEADER_SIZE + size_of(u32)
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.xdg_wm_base,
		message_size = MSG_SIZE,
		opcode       = XDG_WM_BASE_PONG_OPCODE,
	}
	ctx.current_id += 1
	buf_write_u32(msg[HEADER_SIZE:], ping)

	send(ctx.fd, msg[:MSG_SIZE]) or_return
	return ctx.current_id, .NONE
}
xdg_surface_get_toplevel :: proc(
	ctx: ^Wl_Connection,
	state: ^State,
) -> (
	id: u32,
	err: linux.Errno,
) {
	MSG_SIZE :: HEADER_SIZE + size_of(u32)
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.xdg_surface,
		message_size = MSG_SIZE,
		opcode       = XDG_SURFACE_GET_TOPLEVEL_OPCODE,
	}
	ctx.current_id += 1
	buf_write_u32(msg[HEADER_SIZE:], ctx.current_id)

	send(ctx.fd, msg[:MSG_SIZE]) or_return
	return ctx.current_id, .NONE
}
xdg_surface_ack_configure :: proc(
	ctx: ^Wl_Connection,
	state: State,
	serial: u32,
) -> (
	id: u32,
	err: linux.Errno,
) {
	MSG_SIZE :: HEADER_SIZE + size_of(u32)
	msg: [MSG_SIZE]byte
	header := (^Wl_Header)(raw_data(msg[:]))
	header^ = Wl_Header {
		object_id    = state.xdg_surface,
		message_size = MSG_SIZE,
		opcode       = XDG_SURFACE_ACK_CONFIGURE_OPCODE,
	}
	ctx.current_id += 1
	buf_write_u32(msg[HEADER_SIZE:], serial)

	send(ctx.fd, msg[:MSG_SIZE]) or_return
	return ctx.current_id, .NONE
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:
                         UTILITES                            
.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

@(private)
send :: proc(fd: linux.Fd, msg: []u8) -> linux.Errno {
	result, errno := linux.write(fd, msg)
	if result != len(msg) {
		fmt.println("Partial send: ", result, "of", len(msg))
		return .EIO
	}
	return errno
}

Msg_Hdr :: struct {
	len:   u64,
	level: i32,
	type:  i32,
}
@(private)
send_with_fd :: proc(fd: linux.Fd, msg: []u8, send_fd: linux.Fd) -> linux.Errno {

	control: [24]u8
	data := linux.Msg_Hdr {
		iov     = {{base = raw_data(msg), len = len(msg)}},
		control = control[:],
	}
	hdr := (^Msg_Hdr)(raw_data(control[:]))
	hdr.len = len(control)
	hdr.level = i32(linux.SOL_SOCKET)
	hdr.type = 1 //SCM_RIGHTS
	fmt.println(hdr)
	fmt.println(send_fd)

	fd_ptr := cast(^linux.Fd)(uintptr(raw_data(data.control)) + 16)
	fd_ptr^ = send_fd

	fmt.println(data)
	result, errno := linux.sendmsg(fd, &data, {.CMSG_CLOEXEC, .NOSIGNAL})
	if result != len(msg) {
		fmt.println("Partial send: ", result, "of", len(msg))
		return .EIO
	}
	return errno
}

@(private)
align :: proc(#any_int n: int) -> int {
	switch n % 4 {
	case 1:
		return n + 3
	case 3:
		return n + 1
	case 2:
		return n + 2
	case 0:
		return n
	}
	return n
}

// Buffer writing helpers
@(private)
buf_write_u32 :: #force_inline proc(buf: []byte, #any_int value: u32) -> []byte {
	assert(len(buf) >= size_of(u32))
	assert(uintptr(raw_data(buf)) % size_of(u32) == 0)

	(^u32)(raw_data(buf))^ = value
	return buf[size_of(u32):]
}

@(private)
buf_write_string :: proc(buf: []byte, data: string) -> []byte {
	data_len := u32(len(data) + 1)
	padded_len := align(data_len)

	assert(size_of(u32) + padded_len <= len(buf))

	buf := buf_write_u32(buf, data_len)
	copy(buf, data)

	// Zero out padding bytes
	for i in len(data) ..< padded_len {
		buf[i] = 0
	}

	return buf[padded_len:]
}

@(private)
buf_write_array :: proc(buf: []byte, data: []byte) -> []byte {
	data_len := u32(len(data))
	padded_len := align(data_len)

	assert(size_of(u32) + padded_len <= len(buf))

	buf := buf_write_u32(buf, data_len)
	copy(buf, data)

	// Zero out padding bytes
	for i in len(data) ..< padded_len {
		buf[i] = 0
	}

	return buf[padded_len:]
}

@(private)
buf_read_u32 :: #force_inline proc(buf: ^[]byte) -> u32 {
	assert(len(buf) >= size_of(u32))
	assert(uintptr(raw_data(buf^)) % size_of(u32) == 0)

	// value = (cast(^u32)raw_data(buf^))^
	value := (^u32)(raw_data(buf^))^
	buf^ = buf[size_of(u32):]
	return value
}
@(private)
buf_read_i32 :: proc(buf: ^[]byte) -> i32 {
	assert(len(buf) >= size_of(i32))
	assert(uintptr(raw_data(buf^)) % size_of(i32) == 0)

	value := (^i32)(raw_data(buf^))^
	buf^ = buf[size_of(i32):]
	return value
}

@(private)
buf_read_fixed :: proc(buf: ^[]byte) -> f64 {
	fixed := buf_read_i32(buf)
	return f64(fixed) / 256.0
}

@(private)
buf_read_string :: #force_inline proc(buf: ^[]byte, allocator := context.allocator) -> string {
	data_len := buf_read_u32(buf)
	padded_len := align(data_len)
	assert(len(buf) >= padded_len)

	result := buf[:data_len - 1]
	// result := make([]byte, data_len - 1, allocator)
	// copy(result, buf[:data_len - 1])

	buf^ = buf[padded_len:]
	return string(result)
}

@(private)
buf_read_array :: proc(buf: ^[]byte, allocator := context.allocator) -> []byte {
	data_len := align(buf_read_u32(buf))
	padded_len := align(data_len)

	assert(len(buf) >= padded_len)

	result := make([]byte, data_len, allocator)
	copy(result, buf[:data_len])

	// result := buf[:data_len - 1]
	buf^ = buf[padded_len:]

	return result
}

// Read n bytes without padding (for raw data)
@(private)
buf_read_n :: proc(buf: ^[]byte, dst: []byte) {
	assert(len(buf) >= len(dst))
	copy(dst, buf[:len(dst)])
	buf^ = buf[len(dst):]
}

