module hello;
import raylib6::rl;
import bmu::ui, bmu::txt;

char[128] name;   // text field storage: a fixed char buffer, edited in place

fn void main(String[] args)
{
	ui::open("hello", 640, 360, 480, 280);
	defer ui::close();
	ui::app_args(args);
	while (ui::running())
	{
		ui::frame_begin();
		ui::text("Hello, bmu", 30, 30, 28, ui::YELLOW);
		ui::label(30, 90, "Your name");
		bool enter = false;
		ui::input(1, { 30, 112, 300, 36 }, &name, "type here", &enter);
		if (ui::button({ 30, 164, 140, 40 }, "Greet", PRIMARY, ui::I_CHECK) || enter) @pool()
		{
			ui::toast(string::tformat("Hi, %s!", txt::empty(&name) ? "stranger" : txt::view(&name)));
		};
		ui::frame_end();
	}
}
