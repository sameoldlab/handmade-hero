#define SOKOL_IMPL 
#define SOKOL_GLCORE
// #define SOKOL_GLES3

#include "vendor/sokol/sokol_app.h"
#include "vendor/sokol/sokol_log.h"
#include "vendor/sokol/sokol_gfx.h"
#include "vendor/sokol/sokol_glue.h"

// static struct {
//     sg_pipeline pip;
//     sg_bindings bind;
//     sg_pass_action pass_action;
// } state;

static void init(void) {}

void frame(void) {
    // sg_begin_pass(&(sg_pass){ .action = state.pass_action, .swapchain = sglue_swapchain() });
    // sg_apply_pipeline(state.pip);
    // sg_apply_bindings(&state.bind);
    // sg_draw(0, 3, 1);
    // sg_end_pass();
    // sg_commit();
}

void cleanup(void) {
    sg_shutdown();
}

sapp_desc sokol_main(int argc, char* argv[]) {
    (void)argc; (void)argv;
    return (sapp_desc){
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = 640,
        .height = 480,
        .window_title = "Pengu",
        .icon.sokol_default = true,
        .logger.func = slog_func,
    };
}
