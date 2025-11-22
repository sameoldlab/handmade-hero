package platform

import "core:log"
import gl "vendor:OpenGL"

// Get started
// https://learnopengl.com
// Upgrade to 4.6 DSA
// (Direct State Access) and AZDO (Approcahing Zero Driver Overhead)
// https://docs.gl/
// https://antongerdelan.net/opengl/
// https://wikis.khronos.org/opengl/Debug_Output
// SDFs for UI
// https://zed.dev/blog/videogame
// https://hasen.substack.com/p/signed-distance-function-field

vertex_shader_source: cstring = `
#version 460 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec3 aCol;

out vec3 oCol;

void main() {
    gl_Position = vec4(aPos, 1.0);
    oCol = aCol;
}
`


fragment_shader_source: cstring = `
#version 460 core
in vec3 oCol;
out vec4 FragColor;

void main() {
    FragColor = vec4(oCol, 1.0);
}
`

triangle_vao: u32

renderer_draw :: proc(shader, vao: u32) {
	gl.ClearColor(0.2, 0.3, 0.4, 1.0)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

	gl.UseProgram(shader)

	gl.BindVertexArray(vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.BindVertexArray(0)
}

renderer_make_program :: proc() -> (program, vao, vbo: u32, ok: bool) {
	program = create_shader_program(
		&vertex_shader_source,
		&fragment_shader_source,
	) or_return

	triangle := []f32 {
		// pos           // col
		-0.5, -0.5, 0.0, 1.0, 0.0, 0.0, // bottom left (red)
		 0.5, -0.5, 0.0, 0.0, 1.0, 0.0, // bottom right (green)
		 0.0,  0.5, 0.0, 0.0, 0.0, 1.0, // top (blue)
	} 

	gl.CreateVertexArrays(1, &vao)
	gl.CreateBuffers(1, &vbo)
	log.debugf("VAO: %d, VBO: %d", vao, vbo)

	// gl.NamedBufferData(vbo, len(triangle) * size_of(f32), raw_data(triangle), gl.STATIC_DRAW)
	// gl.VertexArrayVertexBuffer(vao, 0, vbo, 0, 5 * size_of(f32))

	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		len(triangle) * size_of(f32),
		raw_data(triangle),
		gl.STATIC_DRAW,
	)

	// Position
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 6 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	// Color
	gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, 6 * size_of(f32), 3 * size_of(f32))
	gl.EnableVertexAttribArray(1)

	gl.BindVertexArray(0)
	return program, vao, vbo, true
}

create_shader_program :: proc(vertex_src, fragment_src: ^cstring) -> (shader_program: u32, ok: bool) {
	vertex_shader := compile_shader(vertex_src, gl.VERTEX_SHADER) or_return
	fragment_shader := compile_shader(fragment_src, gl.FRAGMENT_SHADER) or_return
	shader_program = gl.CreateProgram()

	gl.AttachShader(shader_program, vertex_shader)
	gl.AttachShader(shader_program, fragment_shader)
	gl.LinkProgram(shader_program)

	gl.DeleteShader(vertex_shader)
	gl.DeleteShader(fragment_shader)

	success: i32
	gl.GetProgramiv(shader_program, gl.LINK_STATUS, &success)
	if success == 0 {
		info_log: [512]u8
		gl.GetProgramInfoLog(shader_program, len(info_log), nil, raw_data(info_log[:]))
		log.errorf("Program linking failed: %s", cstring(raw_data(info_log[:])))
		return 0, false
	}

	return shader_program, true
}

compile_shader :: proc(source: ^cstring, shader_type: u32) -> (shader: u32, ok: bool) {
	shader = gl.CreateShader(shader_type)

	gl.ShaderSource(shader, 1, source, nil)
	gl.CompileShader(shader)

	success: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &success)
	if success == 0 {
		info_log: [512]u8
		gl.GetShaderInfoLog(shader, len(info_log), nil, raw_data(info_log[:]))
		log.errorf("Shader compilation failed: %s", cstring(raw_data(info_log[:])))
		return 0, false
	}

	return shader, true
}

