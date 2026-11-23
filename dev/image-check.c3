module image_check;
import std::io;
import raylib6::rl;
import bmu::image, bmu::sys;

fn image::Result wait(image::Loader* loader)
{
	image::Result result;
	for (int i; i < 5000; i++)
	{
		if (loader.take(&result)) return result;
		sys::c_usleep(1000);
	}
	unreachable("Image worker timeout");
}

fn void main()
{
	image::Loader loader;
	defer loader.close();
	assert(loader.request("dev/fixtures/image-wide.png"));
	image::Result wide = wait(&loader);
	assert(wide.status == READY && wide.width == 3200 && wide.height == 1600);
	assert(wide.pixels.width == 1600 && wide.pixels.height == 800);
	rl::unload_image(wide.pixels);
	assert(!loader.take(&wide));
	// JPEG must decode (raylib 6.0 disables it by default; build-raylib.sh enables it).
	assert(loader.request("dev/fixtures/image-small.jpg"));
	image::Result jpg = wait(&loader);
	assert(jpg.status == READY && jpg.width == 5 && jpg.height == 4);
	rl::unload_image(jpg.pixels);
	// Per-loader limits: full size for a viewer, then a smaller preview edge.
	image::Loader full;
	defer full.close();
	full.limits.max_edge = image::MAX_EDGE;
	assert(full.request("dev/fixtures/image-wide.png"));
	image::Result big = wait(&full);
	assert(big.status == READY && big.pixels.width == 3200 && big.pixels.height == 1600);
	rl::unload_image(big.pixels);
	full.limits.max_edge = 400;
	assert(full.request("dev/fixtures/image-wide.png"));
	big = wait(&full);
	assert(big.status == READY && big.pixels.width == 400 && big.pixels.height == 200);
	rl::unload_image(big.pixels);
	full.limits.max_pixels = 1000;
	assert(full.request("dev/fixtures/image-wide.png"));
	assert(wait(&full).status == TOO_LARGE);
	assert(loader.request("dev/fixtures/image-too-many-pixels.png"));
	assert(wait(&loader).status == TOO_LARGE);
	assert(loader.request("dev/fixtures/image-edge.png"));
	assert(wait(&loader).status == TOO_LARGE);
	assert(loader.request("dev/fixtures/image-broken.png"));
	assert(wait(&loader).status == INVALID_IMAGE);
	assert(loader.request("dev/fixtures/missing.png"));
	assert(wait(&loader).status == READ_ERROR);
	for (int i; i < 50; i++) assert(loader.request("dev/fixtures/image-wide.png"));
	assert(loader.request("dev/fixtures/image-small.PNG"));
	image::Result small = wait(&loader);
	assert(small.status == READY && small.width == 2 && small.height == 3);
	rl::unload_image(small.pixels);
	assert(loader.request("dev/fixtures/image-wide.png"));
	loader.cancel();
	sys::c_usleep(100000);
	assert(!loader.take(&small));
	loader.close();
	loader.close();
	assert(loader.request("dev/fixtures/image-small.PNG"));
	small = wait(&loader);
	assert(small.status == READY);
	rl::unload_image(small.pixels);
	io::printn("ALL IMAGE CHECKS PASSED");
}
