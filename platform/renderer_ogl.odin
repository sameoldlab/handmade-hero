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
layout (location = 0) in vec2 aPos;

void main() {
    gl_Position = vec4(aPos, 0.0, 1.0);
}
`


fragment_shader_source: cstring = `
#version 460 core
out vec4 FragColor;

void main() {
    FragColor = vec4(1., vec2(.1), 1.0);
}
`

triangle_vao: u32

renderer_draw :: proc(shader, vao: u32) {
	gl.UseProgram(shader)
	gl.BindVertexArray(vao)
	gl.DrawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, nil)
	gl.BindVertexArray(0)
}

renderer_make_program :: proc() -> (program, vao, vbo: u32, ok: bool) {
	program = create_shader_program(
		&vertex_shader_source,
		&fragment_shader_source,
	) or_return

	triangle := []f32 {
		// pos           // col
		-0.5, -0.5, 0.0, 1.0, 0.0, 0.0, // BL
		 0.5, -0.5, 0.0, 0.0, 1.0, 0.0, // BR
		 0.0,  0.5, 0.0, 0.0, 0.0, 1.0, // TC
	} 
	
	quad := []f32 {
		 1.0,  1.0, // TR
		 1.0, -1.0, // BR
		-1.0, -1.0, // BL
		-1.0,  1.0, // TL
	}
	indices: []u32 = {
		0, 1, 3,
		1, 2, 3,
	}

	ebo: u32
	gl.CreateVertexArrays(1, &vao)
	gl.CreateBuffers(1, &vbo)
	gl.CreateBuffers(1, &ebo)

	gl.NamedBufferData(vbo, len(quad) * size_of(f32), raw_data(quad), gl.STATIC_DRAW)
	gl.NamedBufferData(ebo, len(indices) * size_of(f32), raw_data(indices), gl.STATIC_DRAW)

	gl.VertexArrayVertexBuffer(vao, 0, vbo, 0, 2 * size_of(f32))
	gl.VertexArrayElementBuffer(vao, ebo)

	gl.EnableVertexArrayAttrib(vao, 0)
	gl.VertexArrayAttribFormat(vao, 0, 2, gl.FLOAT, gl.FALSE, 0)
	gl.VertexArrayAttribBinding(vao, 0, 0)

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

