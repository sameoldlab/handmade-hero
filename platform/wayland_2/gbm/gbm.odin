package gbm
foreign import gbm "system:gbm"
import "core:sys/linux"
foreign import drm "system:drm"

Device :: distinct rawptr
Surface :: distinct rawptr
BufferObject :: distinct rawptr
Bitfield :: u32
// same as DRM fourcc codes
Formats :: enum u32 {
	XRGB8888 = 0x34325258,
	ARGB8888 = 0x34325241,
}

// GBM flags
BO_USE_SCANOUT :: 1 << 0
BO_USE_RENDERING :: 1 << 2
BO_USE_LINEAR :: 1 << 4

@(default_calling_convention = "c", link_prefix = "gbm_")
foreign gbm {
	create_device :: proc(fd: linux.Fd) -> Device ---
	device_destroy :: proc(device: Device) ---

	surface_create :: proc(device: Device, width: u32, height: u32, format: Formats, flags: Bitfield) -> Surface ---
	surface_lock_front_buffer :: proc(surface: Surface) -> BufferObject ---
	surface_release_buffer :: proc(surface: Surface, bo: BufferObject) ---
	surface_destroy :: proc(surface: Surface) ---

	bo_get_width :: proc(bo: BufferObject) -> u32 ---
	bo_get_height :: proc(bo: BufferObject) -> u32 ---
	bo_get_stride :: proc(bo: BufferObject) -> u32 ---
	bo_get_format :: proc(bo: BufferObject) -> u32 ---
	bo_get_fd :: proc(bo: BufferObject) -> i32 ---
	bo_get_plane_count :: proc(bo: BufferObject) -> i32 ---
	bo_get_offset :: proc(bo: BufferObject, plane: i32) -> u32 ---
	bo_get_stride_for_plane :: proc(bo: BufferObject, plane: i32) -> u32 ---
	bo_get_fd_for_plane :: proc(bo: BufferObject, plane: i32) -> u32 ---
	bo_get_modifier :: proc(bo: BufferObject) -> u64 ---
	bo_destroy :: proc(bo: BufferObject) ---
}

