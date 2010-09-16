import gtk

import project
from canvas import NetCanvas, MultiCanvas
from net import EmptyVisualConfig
import gtkutils
import utils

class SimView(gtk.VBox):
	def __init__(self, app, simulation):
		gtk.VBox.__init__(self)
		self.simulation = simulation
		self.registered = False

		notebook = gtk.Notebook()
		notebook.set_tab_pos(gtk.POS_BOTTOM)
		self.pack_start(notebook)

		self.canvas = self._create_canvas()
		notebook.append_page(self.canvas, gtk.Label("Overview"))

		sc = gtk.ScrolledWindow()
		self.instance_canvas = self._create_instances_canvas()
		sc.add_with_viewport(self.instance_canvas)
		notebook.append_page(sc, gtk.Label("Instances"))
		notebook.show_all()

		simulation.set_callback("changed", self._simulation_changed)
		simulation.set_callback("output", lambda line: app.console_write(line, "output"))

	def redraw(self):
		self.canvas.redraw()

	def get_net(self):
		return self.simulation.get_net()

	def _create_canvas(self):
		c = NetCanvas(self.get_net(), None, EmptyVisualConfig())
		c.connect("button_press_event", self._button_down)
		c.connect("button_release_event", self._button_up)
		c.connect("motion_notify_event", self._mouse_move)
		c.show()
		return c

	def _create_instances_canvas(self):
		c = MultiCanvas()
		return c

	def _button_down(self, w, event):
		if event.button == 3:
			self._context_menu(event)
			return
		position = (event.x, event.y)
		net = self.simulation.get_net()
		t = net.get_transition(position)
		if t:
			self.simulation.fire_transition_random_instance(t)

	def _context_menu(self, event):
		def fire_fn(i):
			return lambda w: self.simulation.fire_transition(t, i)
		position = (event.x, event.y)
		net = self.simulation.get_net()
		t = net.get_transition(position)
		if t:
			iids = self.simulation.enabled_instances_of_transition(t)
			if iids:
				gtkutils.show_context_menu([("Fire " + str(i), fire_fn(i)) for i in iids ], event)

	def _button_up(self, w, event):
		pass

	def _mouse_move(self, w, event):
		pass

	def _view_for_area(self, area):
		sz = utils.vector_add(area.get_size(), (80, 80))
		pos = utils.vector_diff(area.get_position(), (40, 40))
		return (sz, pos)

	def _simulation_changed(self):
		def draw_callback(area, i):
			vconfig = InstanceVisualConfig(self.simulation, i)
			return lambda cr: self.simulation.get_net().draw(cr, vconfig)
		if not self.registered:
			self.registered = True
			for area in self.get_net().areas():
				callbacks = [ draw_callback(area, i) for i in xrange(self.simulation.get_area_instances_number(area)) ]
				sz, pos = self._view_for_area(area)
				self.instance_canvas.register_line(sz, pos, callbacks)
			self.instance_canvas.end_of_registration()
			self.canvas.set_vconfig(OverviewVisualConfig(self.simulation))
		self.redraw()

class OverviewVisualConfig:

	def __init__(self, simulation):
		self.simulation = simulation

	def get_token_strings(self, place):
		r = []
		tokens = self.simulation.get_tokens_of_place(place)
		for iid in tokens:
			r += [ t + "@" + str(iid) for t in tokens[iid] ]
		return r

	def is_transition_enabled(self, transition):
		return len(self.simulation.enabled_instances_of_transition(transition)) > 0

class InstanceVisualConfig:

	def __init__(self, simulation, iid):
		self.simulation = simulation
		self.iid = iid

	def get_token_strings(self, place):
		tokens = self.simulation.get_tokens_of_place(place)
		return tokens[self.iid]

	def is_transition_enabled(self, transition):
		return self.simulation.is_transition_enabled(transition, self.iid)