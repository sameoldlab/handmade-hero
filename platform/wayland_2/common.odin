/*
 * https://github.com/FrancisTheCat/wayland_odin
 * MIT License

 * Copyright (c) 2025 Franz Höltermann

 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
*/

package wayland

import "base:intrinsics"

import "core:sys/linux"

import "core:bytes"
import "core:os"
import "core:slice"

Fd :: os.Handle
Object :: distinct u32

Connection :: struct {
	buffer:       bytes.Buffer,
	data:         []byte,
	data_cursor:  int,
	object_types: [dynamic]Object_Type,
	fds_in:       [dynamic]Fd,
	fds_out:      [dynamic]Fd,
	free_ids:     [dynamic]u32,
	socket:       linux.Fd,
}

generate_id :: proc(connection: ^Connection, type: Object_Type) -> (id: u32) {
	if len(connection.free_ids) != 0 {
		id = pop(&connection.free_ids)
		connection.object_types[id] = type
	} else {
		id = u32(len(connection.object_types))
		append(&connection.object_types, type)
	}
	return id
}

connection_flush :: proc(connection: ^Connection) -> linux.Errno {
	data := bytes.buffer_to_bytes(&connection.buffer)

	if len(data) == 0 {
		return .NONE
	}
	msg := linux.Msg_Hdr {
		iov     = {{base = raw_data(data), len = len(data)}},
		control = make(
			[]byte,
			16 + ((len(connection.fds_out) + 7) & -8) * 4,
			context.temp_allocator,
		),
	}

	hdr := cast(^struct {
		len:         u64,
		level, type: i32,
	})raw_data(msg.control)
	hdr.len = u64(len(msg.control))
	hdr.level = i32(linux.SOL_SOCKET)
	hdr.type = 1

	copy(msg.control[16:], slice.to_bytes(connection.fds_out[:]))

	n, errno := linux.sendmsg(connection.socket, &msg, {.CMSG_CLOEXEC, .NOSIGNAL})

	bytes.buffer_reset(&connection.buffer)
	clear(&connection.fds_out)
	connection.data_cursor = 0
	return errno
}

display_connect :: proc(
	socket: linux.Fd,
	allocator := context.allocator,
) -> (
	Connection,
	Display,
) {
	return {socket = socket}, 1
}

connection_poll :: proc(connection: ^Connection, buffer: []byte) {
	control: [256]byte
	msg: linux.Msg_Hdr = {
		iov     = {transmute(linux.IO_Vec)buffer},
		control = control[:],
	}
	n, errno := linux.recvmsg(connection.socket, &msg, {.CMSG_CLOEXEC, .NOSIGNAL})
	connection.data = buffer[:n]

	if control[0] != 0 {
		hdr := cast(^struct {
			len:         u64,
			level, type: i32,
		})raw_data(msg.control)
		if hdr.level == i32(linux.SOL_SOCKET) && hdr.type == 1 {
			num_fds := (int(hdr.len) - 16) / 4
			for i in 0 ..< num_fds {
				fd := (cast(^linux.Fd)(&msg.control[16 + i * 4]))^
				append(&connection.fds_in, auto_cast fd)
			}
		}
	}
	assert(errno == .NONE || errno == .EAGAIN)
}

peek_event :: proc(connection: ^Connection) -> (object: u32, event: Event, ok: bool) {
	for {
		object, event, ok = _peek_event(connection)
		if !ok {
			return
		}
		if deleted, ok := event.(Event_Display_Delete_Id); ok {
			append(&connection.free_ids, deleted.id)
		} else {
			return
		}
	}
}

_peek_event :: proc(connection: ^Connection) -> (object: u32, event: Event, ok: bool) {
	if len(connection.data) - connection.data_cursor < 8 {
		return
	}
	intrinsics.mem_copy(&object, &connection.data[connection.data_cursor], 4)
	opcode, size: u16
	intrinsics.mem_copy(&opcode, &connection.data[connection.data_cursor + 4], 2)
	intrinsics.mem_copy(&size, &connection.data[connection.data_cursor + 6], 2)
	if len(connection.data) - connection.data_cursor < int(size) ||
	   int(object) >= len(connection.object_types) {
		return
	}
	connection.data_cursor += 8
	return object, parse_event(connection, connection.object_types[object], u32(opcode))
}

read :: proc {
	read_fd,
	read_int,
	read_f64,
	read_array,
	read_string,
}

read_fd :: proc(connection: ^Connection, data: ^Fd) -> bool {
	data^ = pop_front_safe(&connection.fds_in) or_return
	return true
}

read_int :: proc(
	connection: ^Connection,
	data: ^$T,
) -> bool where intrinsics.type_is_integer(T) ||
	intrinsics.type_is_enum(T) {
	value: i32
	intrinsics.mem_copy(&value, &connection.data[connection.data_cursor], size_of(value))
	connection.data_cursor += 4
	data^ = T(value)
	return true
}

read_f64 :: proc(connection: ^Connection, data: ^f64) -> bool {
	value: bit_field u32 {
		integer: i32 | 24,
		decimal: i32 | 8,
	}
	intrinsics.mem_copy(&value, &connection.data[connection.data_cursor], size_of(value))
	connection.data_cursor += 4
	data^ = f64(value.integer) + f64(value.decimal) / 256.0
	return true
}

read_array :: proc(connection: ^Connection, data: ^[]byte) -> bool {
	length: i32
	intrinsics.mem_copy(&length, &connection.data[connection.data_cursor], size_of(length))
	connection.data_cursor += 4
	data^ = connection.data[connection.data_cursor:][:length]
	connection.data_cursor = (connection.data_cursor + int(length) + 3) & -4
	return true
}

read_string :: proc(connection: ^Connection, data: ^string) -> bool {
	length: i32
	intrinsics.mem_copy(&length, &connection.data[connection.data_cursor], size_of(length))
	connection.data_cursor += 4
	data^ = string(connection.data[connection.data_cursor:][:length - 1])
	connection.data_cursor = (connection.data_cursor + int(length) + 3) & -4
	return true
}

