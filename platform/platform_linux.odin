package platform
import app "../app"
import "core:fmt"
import "core:sys/linux"
import wl "wayland"

start :: proc() {
	// fmt.println("linux ", app.TITLE)
	wl_connection, err := wl.connect_display()
	if err == linux.Errno.NONE {
		errno := wl.run(&wl_connection)
		fmt.println("Error: ", errno)
	} else {
		sdl_start()
	}
}

