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
