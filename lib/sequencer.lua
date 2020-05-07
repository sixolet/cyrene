local ControlSpec = require 'controlspec'
local UI = include('lib/ui/util/devices')
local DrumMap = include('lib/grids_patterns')
local tabutil = require 'tabutil'

local PATTERN_FILE = "step.data"

local NUM_PATTERNS = 50
local ppqn = 24

local MAX_PATTERN_LENGTH = 32
local HEIGHT = 8
local NUM_TRACKS = HEIGHT - 1

local tempo_spec = ControlSpec.new(20, 300, ControlSpec.WARP_LIN, 0, 120, "BPM")
local swing_amount_spec = ControlSpec.new(0, 100, ControlSpec.WARP_LIN, 0, 0, "%")

local Sequencer = {}

function Sequencer:new()
  i = {}
  setmetatable(i, self)
  self.__index = self

  i.trigs = {}
  i:_init_trigs()
  i.playing = false
  i.playpos = -1
  i.ticks_to_next = nil
  i.queued_playpos = nil
  i.grids_x = nil
  i.grids_y = nil
  i.part_perturbations = {}
  for track=1,NUM_TRACKS do
    i.part_perturbations[track] = 0
  end
  i._clock_id = nil

  return i
end

function Sequencer:add_params()
  params:add {
    type="option",
    id="pattern_length",
    name="Pattern Length",
    options={8, 16, 32},
    default=2
  }

  params:add {
    type="number",
    id="pattern",
    name="Pattern",
    min=1,
    max=NUM_PATTERNS,
    default=1,
    action=function()
      UI.grid_dirty = true
    end
  }

  params:add {
    type="option",
    id="cut_quant",
    name="Quantize Cutting",
    options={"No", "Yes"},
    default=1
  }

  params:add {
    type="option",
    id="grid_resolution",
    name="Grid Resolution",
    options={"Quarters", "8ths", "16ths", "32nds"},
    default=3,
    action=function(val)
      if self.grids_x ~= nil and self.grids_y ~= nil then
        self:set_grids_xy(params:get("pattern"), params:get("grids_pattern_x"), params:get("grids_pattern_y"), true)
      end
      self:_update_clock_sync_resolution()
    end
  }

  local default_tempo_action = params:lookup_param("clock_tempo").action
  params:set_action("clock_tempo", function(val)
    default_tempo_action(val)
    UI.arc_dirty = true
    UI.screen_dirty = true
  end)

  params:add {
    type="control",
    id="swing_amount",
    name="Swing Amount",
    controlspec=swing_amount_spec,
    action=function(val)
      self:update_swing(val)
      UI.screen_dirty = true
      UI.arc_dirty = true
    end
  }
end

function Sequencer:initialize()
  self:_update_clock_sync_resolution()
  self:load_patterns()
end

function Sequencer:start()
  self.playing = true
  if self._clock_id ~= nil then
    clock.cancel(self._clock_id)
  end
  self._clock_id = clock.run(self._clock_tick, self)
end

function Sequencer:move_to_start()
  self.playpos = -1
  self.queued_playpos = 0
end

function Sequencer:stop()
  self.playing = false
  if self._clock_id ~= nil then
    clock.cancel(self._clock_id)
    self._clock_id = nil
  end
end

function Sequencer:set_trig(patternno, step, track, value)
  self.trigs[patternno][track][step] = value
end

function Sequencer:trig_level(patternno, x, y)
  return self.trigs[patternno][y][x]
end

function Sequencer:_init_trigs()
  for patternno=1,NUM_PATTERNS do
    self.trigs[patternno] = {}
    for y=1,NUM_TRACKS do
      self.trigs[patternno][y] = {}
      for x=1,MAX_PATTERN_LENGTH do
        self.trigs[patternno][y][x] = 0
      end
    end
  end
end

function Sequencer:get_pattern_length()
  local param_value = params:get("pattern_length")
  if param_value == 1 then
    return 8
  elseif param_value == 2 then
    return 16
  else
    return 32
  end
end

function Sequencer:set_pattern_length(pattern_length)
  local opt
  if pattern_length == 8 then
    opt = 1
  else
    opt = 2
  end
  params:set("pattern_length", opt)
end

function Sequencer:save_patterns()
  local fd=io.open(norns.state.data .. PATTERN_FILE,"w+")
  io.output(fd)
  for patternno=1,NUM_PATTERNS do
    for y=1,NUM_TRACKS do
      for x=1,MAX_PATTERN_LENGTH do
        io.write(self:trig_level(patternno, x, y) .. "\n")
      end
    end
  end
  io.close(fd)
end

function Sequencer:load_patterns()
  local fd=io.open(norns.state.data .. PATTERN_FILE,"r")
  if fd then
    io.input(fd)
    for patternno=1,NUM_PATTERNS do
      for track=1,NUM_TRACKS do
        for step=1,MAX_PATTERN_LENGTH do
          self:set_trig(patternno, step, track, tonumber(io.read()))
        end
      end
    end
    io.close(fd)
  end
end

local function u8mix(a, b, mix)
  -- Roughly equivalent to ((mix * b + (255 - mix) * a) >> 8), if this is too non-performant
  return util.round(((mix * b) + ((255 - mix) * a)) / 255)
end

function Sequencer:set_grids_xy(patternno, x, y, force)
  -- Short-circuit this expensive operation if there's no change
  if not force and x == self.grids_x and y == self.grids_y then
    return
  end
  -- The DrumMap is at 32nd-note resolution,
  -- so we'll want to set different triggers depending on our desired grid resolution
  local grid_resolution = self:_grid_resolution()
  local step_offset_multiplier = math.floor(32/grid_resolution)
  local pattern_length = self:get_pattern_length()
  -- Chose four drum map nodes based on the first two bits of x and y
  local i = math.floor(x / 64) + 1 -- (x >> 6) + 1
  local j = math.floor(y / 64) + 1 -- (y >> 6) + 1
  local a_map = DrumMap.map[j][i]
  local b_map = DrumMap.map[j + 1][i]
  local c_map = DrumMap.map[j][i + 1]
  local d_map = DrumMap.map[j + 1][i + 1]
  for track=1,3 do
    local track_offset = ((track - 1) * DrumMap.PATTERN_LENGTH)
    for step=1,pattern_length do
      local step_offset = (((step - 1) * step_offset_multiplier) % DrumMap.PATTERN_LENGTH) + 1
      local offset = track_offset + step_offset
      local a = a_map[offset]
      local b = b_map[offset]
      local c = c_map[offset]
      local d = d_map[offset]
      -- Crossfade between the values at the chosen drum nodes depending on the last 6 bits of x and y
      local x_xfade = (x * 4) % 256 -- x << 2
      local y_xfade = (y * 4) % 256 -- y << 2
      local trig_level = u8mix(u8mix(a, b, y_xfade), u8mix(c, d, y_xfade), x_xfade)
      self:set_trig(patternno, step, track, trig_level)
    end
  end
  self.grids_x = x
  self.grids_y = y
end

function Sequencer:_clock_tick()
  while true do
    clock.sync(self._clock_sync_resolution)
    self:tick()
  end
end

function Sequencer:tick()
  if queued_playpos and params:get("cut_quant") == 1 then
    self.ticks_to_next = 0
  end

  if (not self.ticks_to_next) or self.ticks_to_next == 0 then
    local patternno = params:get("pattern")
    -- Update the triggers to match the selected MI-Grids X and Y parameters
    self:set_grids_xy(patternno, params:get("grids_pattern_x"), params:get("grids_pattern_y"))
    -- If there's a queued cut, set it and forget it
    local previous_playpos = self.playpos
    if self.queued_playpos then
      self.playpos = self.queued_playpos
      self.queued_playpos = nil
    else
      -- otherwise, advance by a beat
      self.playpos = (self.playpos + 1) % self:get_pattern_length()
    end
    if self.playpos == 0 then
      -- At the start of the pattern, figure out how much to bump up our trigger level by based on the chaos parameter
      for track=1,NUM_TRACKS do
        local chaos = math.floor(params:get("pattern_chaos") * 255 / 100 / 4)
        local random_byte = math.random(0, 255)
        self.part_perturbations[track] = math.floor(random_byte * chaos / 256)
      end
    end

    local ts = {}
    for y=1,7 do
      local trig_level = self:trig_level(patternno, self.playpos+1, y)
      -- The original MI Grids algorithm makes it possible that a track would trigger on every beat
      -- If density > ~77%, chaos at 100%, and the random byte rolls full (or if density is higher, chaos can be lower, etc.)
      -- This seems... wrong to me, so I've made sure that if the trigger map says zero, that means no triggers happen.
      trig_level = trig_level ~= 0 and util.clamp(trig_level + self.part_perturbations[y], 0, 255) or 0
      local threshold
      if y == 1 then
        threshold = 255 - util.round(params:get("kick_density") * 255 / 100)
      elseif y == 2 then
        threshold = 255 - util.round(params:get("snare_density") * 255 / 100)
      elseif y == 3 then
        threshold = 255 - util.round(params:get("hat_density") * 255 / 100)
      else
        threshold = math.random(0, 255)
      end
      ts[y] = trig_level > threshold and 1 or 0
    end
    engine.multiTrig(ts[1], ts[2], ts[3], ts[4], ts[5], ts[6], ts[7], 0)

    if previous_playpos ~= -1 or self.playpos ~= -1 then
      UI.grid_dirty = true
    end
    -- Figure out how many ticks to wait for the next beat, based on swing
    local is_even_side_swing = self:_is_even_side_swing()
    if is_even_side_swing == nil then
      self.ticks_to_next = ppqn
    elseif is_even_side_swing then
      self.ticks_to_next = self.even_ppqn
    else
      self.ticks_to_next = self.odd_ppqn
    end
    UI.screen_dirty = true
  end
  self.ticks_to_next = self.ticks_to_next - 1
end

function Sequencer:_grid_resolution()
  local param_grid_resolution = params:get("grid_resolution")
  if param_grid_resolution == 1 then return 4 end
  if param_grid_resolution == 2 then return 8 end
  if param_grid_resolution == 3 then return 16 end
  return 32
end

function Sequencer:_update_clock_sync_resolution()
  self._clock_sync_resolution = 4/ppqn/self:_grid_resolution()
end

function Sequencer:_is_even_side_swing()
  -- If resolution is 16th or higher, we do 16th note swing. At 8th notes, we do 8th note swing
  local grid_resolution = self:_grid_resolution()
  if grid_resolution == 4 then return nil end
  if grid_resolution == 8 then return self.playpos % 2 == 0 end
  if grid_resolution == 16 then return self.playpos % 2 == 0 end
  return math.floor(self.playpos/2) % 2 == 0
end

function Sequencer:update_swing(swing_amount)
  local swing_ppqn = ppqn*swing_amount/100*0.75
  self.even_ppqn = util.round(ppqn+swing_ppqn)
  self.odd_ppqn = util.round(ppqn-swing_ppqn)
end

function Sequencer:has_pattern_file()
  return util.file_exists(norns.state.data .. PATTERN_FILE,"r")
end

return Sequencer
