package platform

import "core:log"
import "core:os"
import "core:sys/linux"
import "egl"
import "gbm"
import gl "vendor:OpenGL"
import wl "wayland"

open_drm_device :: proc() -> (fd: linux.Fd, ok: bool) {
	render_nodes := []cstring {
		"/dev/dri/renderD128", //Nvidia
		"/dev/dri/renderD129", // Intel
		"/dev/dri/card1", // Nvidia
		"/dev/dri/card2", // Intel
	}

	for node in render_nodes {
		fd_int, err := linux.open(node, {.RDWR}, {})
		if err == .NONE {
			log.debugf("Opened DRM device: %s", node)
			return linux.Fd(fd_int), true
		}
	}

	log.debug("Failed to open any DRM device")
	return 0, false
}

/* 
  Info may be found in Mesa's implementation at src/egl/drivers/dri2/platform_wayland.c"
 * https://ziggit.dev/t/drawing-with-opengl-without-glfw-or-sdl-on-linux/3175/12
 * https://blaztinn.gitlab.io/post/dmabuf-texture-sharing/
 */

// https://registry.khronos.org/EGL/sdk/docs/man/html/eglIntro.xhtml
setup_egl :: proc(conn: ^wl.Connection, st: ^State) -> bool {
	log.debug("\n\n\n=====================\n")

	st.drm_fd = open_drm_device() or_return
	gbm_device := gbm.create_device(st.drm_fd)
	gbm_surface := gbm.surface_create(
		gbm_device,
		u32(st.w),
		u32(st.h),
		.XRGB8888,
		gbm.BO_USE_SCANOUT | gbm.BO_USE_RENDERING,
	)
	assert(gbm_surface != {})

	assert(st.wl_surface != 0)
	major, minor: i32
	egl.BindAPI(egl.OPENGL_API)

	st.egl_display = egl.GetPlatformDisplay(egl.Platform.GBM_KHR, gbm_device, nil)
	// st.egl_display = egl.GetDisplay(egl.DEFAULT_DISPLAY)
	if st.egl_display == egl.NO_DISPLAY {
		log.error("Failed to create egl display")
		return false
	}

	if !egl.Initialize(st.egl_display, &major, &minor) {
		log.error("Failed to initialize egl")
		return false
	}
	log.infof("EGLv%i.%i Initialized", major, minor)

	config_attribs := []i32 {
		egl.SURFACE_TYPE,
		egl.WINDOW_BIT,
		egl.RENDERABLE_TYPE,
		egl.OPENGL_BIT,
		egl.RED_SIZE,
		8,
		egl.GREEN_SIZE,
		8,
		egl.BLUE_SIZE,
		8,
		egl.NONE,
	}
	num_configs: i32
	egl_config: egl.Config

	if !egl.ChooseConfig(st.egl_display, &config_attribs[0], &egl_config, 1, &num_configs) {
		log.error("Failed to choose egl config")
		return false
	}
	log.debug("configs: ", num_configs)

	if !egl.BindAPI(egl.OPENGL_API) {
		log.error("Bind API failed")
		return false
	}
	context_attribs := []i32 {
		egl.CONTEXT_MAJOR_VERSION,
		GL_MAJOR,
		egl.CONTEXT_MINOR_VERSION,
		GL_MINOR,
		egl.NONE,
	}
	st.egl_context = egl.CreateContext(
		st.egl_display,
		egl_config,
		egl.NO_CONTEXT,
		&context_attribs[0],
	)
	assert(st.egl_context != egl.NO_CONTEXT)
	log.debug(st.egl_context, "egl_context created")


	st.egl_surface = egl.CreatePlatformWindowSurface(st.egl_display, egl_config, gbm_surface, nil)
	// st.egl_surface = egl.CreateWindowSurface(
	// 	st.egl_display,
	// 	egl_config,
	// 	cast(egl.NativeWindowType)gbm_surface,
	// 	nil,
	// )
	log.debug("egl surface: ", st.egl_surface)
	assert(st.egl_surface != egl.NO_SURFACE)

	if !egl.MakeCurrent(st.egl_display, st.egl_surface, st.egl_surface, st.egl_context) {
		log.error("Failed to make egl context current")
		return false
	}
	w, h: i32
	egl.QuerySurface(st.egl_display, st.egl_surface, egl.WIDTH, &w)
	egl.QuerySurface(st.egl_display, st.egl_surface, egl.HEIGHT, &h)
	assert(u32(w) == st.w)
	log.debugf("EGL Context Current. size:%ix%i:", w, h)

	st.gbm_device = gbm_device
	st.gbm_surface = gbm_surface

	gl.load_up_to(GL_MAJOR, GL_MINOR, egl.gl_set_proc_address)

	log.infof("OpenGL %s", gl.GetString(gl.VERSION))
	log.infof("Renderer: %s", gl.GetString(gl.RENDERER))

	gl.Viewport(0, 0, i32(st.w), i32(st.h))
	if shader_program, vao, vbo, ok := renderer_make_program(); ok {
		st.shader_program, st.vao, st.vbo = shader_program, vao, vbo
	} else {
		log.error("failed to initialize shader program")
		return false
	}
	gl.Disable(gl.BLEND)

	init_buffers(conn, st, gbo[:], st.egl_surface, st.egl_display, st.gbm_surface)
	log.info("\n========= OPENGL READY ============\n")
	return true
}

init_buffers :: proc(
	conn: ^wl.Connection,
	st: ^State,
	buffers: #soa[]Gbo,
	egl_surface: egl.Surface,
	egl_display: egl.Display,
	gbm_surface: gbm.Surface,
	// w, h: u32,
) {
	log.debug("creating buffer pool...")
	for &buf, i in buffers {
		buf.busy = true
		buffer, bound_bo, ok := init_buffer(conn, st, buf, egl_surface, egl_display, gbm_surface)
		if ok {
			buf.bo = bound_bo
			buf.buffer = buffer
			buf.busy = false
		}
	}
	log.debug(buffers)
}
init_buffer :: proc(
	conn: ^wl.Connection,
	st: ^State,
	buf: Gbo,
	egl_surface: egl.Surface,
	egl_display: egl.Display,
	gbm_surface: gbm.Surface,
	// w, h: u32,
) -> (
	wl_buffer: wl.Buffer,
	bound_bo: gbm.BufferObject,
	ok: bool,
) {
	gl.ClearColor(1, 1, 1, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.Flush()
	if !egl.SwapBuffers(egl_display, egl_surface) {
		log.error("Swap Buffers failed")
		err := gl.GetError()
		if err != gl.NO_ERROR {
			log.errorf("OpenGL error: %d", err)
		}
		return
	}

	bo := gbm.surface_lock_front_buffer(gbm_surface)
	assert(bo != {})

	log.debug("---------------------------------------\nGetting properties for buffer:", bo)
	w := gbm.bo_get_width(bo)
	h := gbm.bo_get_height(bo)
	format := gbm.bo_get_format(bo)
	modifier := gbm.bo_get_modifier(bo)
	// dma_fd := linux.Fd(gbm.bo_get_fd(bo))
	// log.debug("dma_fd", dma_fd)
	fds_to_close: [dynamic]u32
	defer {
		for fd in fds_to_close {
			linux.close(linux.Fd(fd))
		}
		delete(fds_to_close)
	}
	zwp_params := wl.zwp_linux_dmabuf_v1_create_params(conn, st.zwp_linux_dmabuf)
	plane_count := gbm.bo_get_plane_count(bo)
	for plane in 0 ..< plane_count {
		offset := gbm.bo_get_offset(bo, plane)
		stride := gbm.bo_get_stride_for_plane(bo, plane)
		plane_fd := gbm.bo_get_fd_for_plane(bo, plane)
		log.debug("plane_fd", plane_fd)
		append(&fds_to_close, plane_fd)

		assert(plane_fd > 0)

		wl.zwp_linux_buffer_params_v1_add(
			conn,
			zwp_params,
			auto_cast plane_fd,
			u32(plane),
			offset,
			stride,
			u32(modifier >> 32),
			u32(modifier & 0xFFFFFFFF),
		)
	}
	wl.zwp_linux_buffer_params_v1_create(conn, zwp_params, i32(w), i32(h), format, auto_cast 0)

	wl.connection_flush(conn)
	recv_buf: [4096]byte
	result, _ := linux.poll({linux.Poll_Fd{fd = conn.socket, events = {.IN}}}, 16)
	if result <= 0 {
		log.error("hung waiting for buffer creation")
		return
	}
	wl.connection_poll(conn, recv_buf[:])
	for {
		object, event := wl.peek_event(conn) or_break
		#partial switch e in event {
		case wl.Event_Zwp_Linux_Buffer_Params_V1_Created:
			log.info("Buffer creation success for", zwp_params, bo)
			wl.zwp_linux_buffer_params_v1_destroy(conn, zwp_params)
			return e.buffer, bo, true
		case wl.Event_Zwp_Linux_Buffer_Params_V1_Failed:
			log.errorf("Buffer creation failed for %i", zwp_params)
			wl.zwp_linux_buffer_params_v1_destroy(conn, zwp_params)
		case:
			receive_events(conn, st, object, event)
		}
	}
	conn.data_cursor = 0
	conn.data = {}
	return
}

