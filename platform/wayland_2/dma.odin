package wayland

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "egl"
import "gbm"
import gl "vendor:OpenGL"

open_drm_device :: proc() -> (fd: linux.Fd, ok: bool) {
	// Try render nodes first (don't need root/authentication)
	render_nodes := []cstring {
		"/dev/dri/renderD128",
		"/dev/dri/renderD129",
		"/dev/dri/card0",
		"/dev/dri/card1",
	}

	for node in render_nodes {
		fd_int, err := linux.open(node, {.RDWR}, nil)
		if err == .NONE {
			fmt.printfln("Opened DRM device: %s", node)
			return linux.Fd(fd_int), true
		}
	}

	fmt.println("Failed to open any DRM device")
	return 0, false
}

// https://registry.khronos.org/EGL/sdk/docs/man/html/eglIntro.xhtml
setup_gl :: proc(conn: ^Connection, st: ^State) -> Progress {
	fmt.print("\n\n\n=====================\n")

	drm_fd, ok := open_drm_device()
	assert(drm_fd != 0)
	st.drm_fd = drm_fd
	gbm_device := gbm.create_device(drm_fd)
	gbm_surface := gbm.surface_create(
		gbm_device,
		u32(st.w),
		u32(st.h),
		.ARGB8888,
		gbm.BO_USE_RENDERING | gbm.BO_USE_SCANOUT,
	)
	assert(gbm_surface != {})
	fmt.println(gbm_device, "gbm_device")
	fmt.println(gbm_surface, "gbm_surface")

	assert(st.wl_surface != 0)
	egl.load_extensions()
	major, minor: i32
	egl.BindAPI(egl.OPENGL_API)

	st.egl_display = egl.GetPlatformDisplay(egl.Platform.GBM_KHR, gbm_device, nil)
	if st.egl_display == nil {
		fmt.println("Failed to create egl display")
		return .Crash
	}
	assert(st.egl_display != {})
	initialized := egl.Initialize(st.egl_display, &major, &minor)
	assert(initialized == egl.TRUE)

	fmt.println(st.egl_display, "egl_display created")
	fmt.printfln("EGL v%i.%i", major, minor)

	config_attribs: [11]i32 = {
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
	configs: [256]egl.Config
	if egl.GetConfigs(st.egl_display, &configs[0], len(configs), &num_configs) {
		fmt.println("configs: ", num_configs)
		// fmt.println("configs: ", configs)
	}
	assert(num_configs > 0)
	egl_config: egl.Config
	if egl.ChooseConfig(st.egl_display, &config_attribs[0], &egl_config, 1, &num_configs) {
		fmt.println("configs: ", num_configs)
	}
	assert(num_configs == 1)


	/* 
	  Info may be found in Mesa's implementation at src/egl/drivers/dri2/platform_wayland.c"
	 * https://ziggit.dev/t/drawing-with-opengl-without-glfw-or-sdl-on-linux/3175/12
	 * https://blaztinn.gitlab.io/post/dmabuf-texture-sharing/
	 */

	st.egl_surface = egl.CreatePlatformWindowSurface(
		st.egl_display,
		egl_config,
		cast(egl.NativeWindowType)gbm_surface,
		nil,
	)
	fmt.println("egl surface: ", st.egl_surface)
	assert(st.egl_surface != {})

	egl.BindAPI(egl.OPENGL_API)

	context_attribs := []i32{egl.CONTEXT_MAJOR_VERSION, 3, egl.CONTEXT_MINOR_VERSION, 3, egl.NONE}
	st.egl_context = egl.CreateContext(
		st.egl_display,
		egl_config,
		egl.NO_CONTEXT,
		&context_attribs[0],
	)
	assert(st.egl_context != {})
	fmt.println(st.egl_context, "egl_context created")

	res := egl.MakeCurrent(st.egl_display, st.egl_surface, st.egl_surface, st.egl_context)
	assert(res == true)


	w, h: i32
	egl.QuerySurface(st.egl_display, st.egl_surface, egl.WIDTH, &w)
	egl.QuerySurface(st.egl_display, st.egl_surface, egl.HEIGHT, &h)
	fmt.printfln("egl %ix%i:", w, h)

	gl.load_up_to(3, 3, egl.gl_set_proc_address)
	st.gbm_device = gbm_device
	st.gbm_surface = gbm_surface
	init_buffers(conn, st)
	fmt.print("\n=====================\n")
	return .Continue
}
bos: [2]gbm.BufferObject
// fds: [2]linux.Fd
init_buffers :: proc(conn: ^Connection, st: ^State) {
	using st
	for &buffer, i in st.wl_buffer {
		// create dummy frame
		gl.ClearColor(1, 1, 1, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		egl.SwapBuffers(egl_display, egl_surface)
		gl.Finish()

		bo := gbm.surface_lock_front_buffer(gbm_surface)
		defer gbm.surface_release_buffer(gbm_surface, bo)
		assert(bo != {})

		fmt.println("new buffer", bo)
		w = gbm.bo_get_width(bo)
		h = gbm.bo_get_height(bo)
		format := gbm.bo_get_format(bo)
		modifier := gbm.bo_get_modifier(bo)

		// dmabuf_fd := linux.Fd(gbm.bo_get_fd(bo))
		// fmt.println("dmabuf fd", dmabuf_fd)

		params := zwp_linux_dmabuf_v1_create_params(conn, st.zwp_linux_dmabuf)
		plane_count := gbm.bo_get_plane_count(bo)
		for plane in 0 ..< plane_count {
			offset := gbm.bo_get_offset(bo, plane)
			stride := gbm.bo_get_stride_for_plane(bo, plane)
			dmabuf_fd := gbm.bo_get_fd_for_plane(bo, plane)
			fmt.println(st.w, "x", st.h, dmabuf_fd)
			assert(dmabuf_fd > 0)

			zwp_linux_buffer_params_v1_add(
				conn,
				params,
				auto_cast dmabuf_fd,
				u32(plane),
				offset,
				stride,
				u32(modifier >> 32),
				u32(modifier & 0xFFFFFFFF),
			)
			// linux.close(linux.Fd(dmabuf_fd))
		}
		buffer = zwp_linux_buffer_params_v1_create_immed(
			conn,
			params,
			i32(w),
			i32(h),
			format,
			auto_cast 0,
		)
		zwp_linux_buffer_params_v1_destroy(conn, params)
		// gbm.bo_destroy(bo)
		bos[i] = bo
		connection_flush(conn)
		recv_buf: [400]byte
		result, _ := linux.poll({linux.Poll_Fd{fd = conn.socket, events = {.IN}}}, 2)
		if result > 0 {
			connection_poll(conn, recv_buf[:])
			for {
				object, event := peek_event(conn) or_break
				prog := receive_events(conn, st, object, event)
			}
		}
	}
	fmt.println("bos", bos)
}

