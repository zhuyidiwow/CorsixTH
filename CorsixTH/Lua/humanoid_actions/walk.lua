--[[ Copyright (c) 2009 Peter "Corsix" Cawley

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. --]]

--! Have a `Humanoid` walk from one tile on the map to another tile on the map.
class "WalkAction" {} (Action)

--!param ... Arguments for the base class constructor.
function WalkAction:WalkAction(...)
  self:Action(...)
end

function WalkAction:canRemoveFromQueue(is_high_priority)
  if self.is_active then
    -- When active, can only remove when high priority, in order to allow 
    -- animations to finish.
    if self.no_truncate or not is_high_priority then
      return false
    end
  else
    -- When inactive, can remove unless truncation is not permitted.
    if (self.truncate_only_on_high_priority and not is_high_priority)
    or self.no_truncate then
      return false
    end
  end
  return Action.canRemoveFromQueue(self, is_high_priority)
end

local flag_cache = {}
function WalkAction:postponeFor(action, index_in_queue)
  if self.is_active then
    local path_x = self.path_x
    local path_y = self.path_y
    local path_index = self.path_index
    
    if self.postponable == false
    or self.todo_postpone
    or self.reserve_on_resume
    or self.path_index == #self.path_x then
      return false
    end
    
    local x1, y1 = path_x[path_index  ], path_y[path_index  ]
    local x2, y2 = path_x[path_index+1], path_y[path_index+1]
    local map = self.humanoid.world.map.th
    if map:getCellFlags(x1, y1, flag_cache).roomId ~= 0
    or map:getCellFlags(x2, y2, flag_cache).roomId ~= 0 then
      return false
    end
    
    self.todo_postpone = action
    return true
  else
    if self.postponable == false then
      return false
    end
    self.humanoid:queueAction(action, index_in_queue - 1)
    return true
  end
end

function WalkAction:onRemoveFromQueue()
  local action = self
  local humanoid = self.humanoid
  
  -- Check for objects that the handyman was going to attend to.
  if humanoid.humanoid_class == "Handyman" and action.is_job then
    local obj = action.is_job
    if class.is(obj, Machine) then
      -- This handyman is no longer going to the machine, try
      -- to find another handyman to fix it instead.
      obj.approaching_handyman = nil
      humanoid.world:callForStaff(obj:getRoom(), obj)
    end
    action.is_job.reserved_for = nil
  end
  
  -- If the staff was heading for a room, remove that staff from the approaching list.
  if action.is_entering and action.is_entering ~= true then
    action.is_entering.approaching_staff[humanoid] = nil
    -- Make a new check. If there is still need for staff in the room someone else could go.
    humanoid.world:callForStaff(action.is_entering)
  end
  
  Action.onRemoveFromQueue(self)
end

function WalkAction:truncate(high_priority)
  local action = self
  local humanoid = self.humanoid

  if (action.truncate_only_on_high_priority and not high_priority)
  or action.no_truncate then
    return
  end
  
  if not action.path_x then
    -- TODO: Flag for later truncation?
    return
  end
  
  -- Truncate the remainder of the path
  for j = #action.path_x, action.path_index + 1, -1 do
    action.path_x[j] = nil
    action.path_y[j] = nil
  end
  
  -- Unreserve any door which we had reserved unless specifically told not to.
  -- TODO: Logic
  --[[
  if not action.keep_reserved then
    local door = action.reserve_on_resume
    if door and door.reserved_for == humanoid then
      door.reserved_for = nil
      if door.queue:size() > 0 then
        door.queue:pop()
        door:updateDynamicInfo()
      end
    end
  else
    -- This flag can be used only once at a time.
    action.keep_reserved = nil
  end
  --]]
end

local flag_list_bottom = 2048
local flag_early_list = 1024
local flag_flip_h = 1

local navigateDoor

local function action_walk_raw(humanoid, x1, y1, x2, y2, map, timer_fn)
  local anims = humanoid.walk_anims
  local world = humanoid.world
  local notify_object = world:getObjectToNotifyOfOccupants(x2, y2)
  if notify_object then
    notify_object:onOccupantChange(1)
  end
  notify_object = world:getObjectToNotifyOfOccupants(x1, y1)
  if notify_object then
    notify_object:onOccupantChange(-1)
  end
  if x1 ~= x2 then
    if x1 < x2 then
      if map and map:getCellFlags(x2, y2, flag_cache).doorWest then
        return navigateDoor(humanoid, x1, y1, "east")
      else
        humanoid.last_move_direction = "east"
        humanoid:setAnimation(anims.walk_east, flag_early_list)
        humanoid:setTilePositionSpeed(x2, y2, -32, -16, 4, 2)
      end
    else
      if map and map:getCellFlags(x1, y1, flag_cache).doorWest then
        return navigateDoor(humanoid, x1, y1, "west")
      else
        humanoid.last_move_direction = "west"
        humanoid:setAnimation(anims.walk_north, flag_early_list + flag_flip_h)
        humanoid:setTilePositionSpeed(x1, y1, 0, 0, -4, -2)
      end
    end
  else
    if y1 < y2 then
      if map and map:getCellFlags(x2, y2, flag_cache).doorNorth then
        return navigateDoor(humanoid, x1, y1, "south")
      else
        humanoid.last_move_direction = "south"
        humanoid:setAnimation(anims.walk_east, flag_flip_h)
        humanoid:setTilePositionSpeed(x2, y2, 32, -16, -4, 2)
      end
    else
      if map and map:getCellFlags(x1, y1, flag_cache).doorNorth then
        return navigateDoor(humanoid, x1, y1, "north")
      else
        humanoid.last_move_direction = "north"
        humanoid:setAnimation(anims.walk_north)
        humanoid:setTilePositionSpeed(x1, y1, 0, 0, 4, -2)
      end
    end
  end
  humanoid:setTimer(8, timer_fn)
end

local flags_here, flags_there = {}, {}
local action_walk_tick; action_walk_tick = permanent"action_walk_tick"( function(humanoid)
  local action = humanoid.action_queue[1]
  local path_x = action.path_x
  local path_y = action.path_y
  local path_index = action.path_index
  local check_doors = not not humanoid.door_anims
  local x1, y1 = path_x[path_index  ], path_y[path_index  ]
  local x2, y2 = path_x[path_index+1], path_y[path_index+1]
  
  if not x2 then
    -- Arrival at final tile
    humanoid:setTilePositionSpeed(x1, y1)
    if action.on_next_tile_set then
      action.on_next_tile_set()
    end
    if action.is_active then
      humanoid:finishAction(action)
    end
    return
  end
  
  -- Make sure that the next tile hasn't somehow become impassable since our
  -- route was determined
  local map = humanoid.world.map.th
  map:getCellFlags(x1, y1, flags_here)
  map:getCellFlags(x2, y2, flags_there)
  local recalc_route = not flags_there.passable and flags_here.passable
  -- Also make sure that a room hasn't unexpectedly been built on top of the
  -- path since the route was calculated.
  if not recalc_route and flags_here.roomId ~= flags_there.roomId then
    local door = TheApp.objects.door.thob
    local door2 = TheApp.objects.swing_door_right.thob
    if ((flags_here.thob ~= door and flags_here.thob ~= door2) and (flags_there.thob ~= door 
    and flags_there.thob ~= door2)) and (not flags_there.room 
    or map:getCellFlags(path_x[#path_x], path_y[#path_y]).roomId ~= flags_there.roomId) then
      recalc_route = true
    end
  end
  if recalc_route then
    if map:getCellFlags(x1, y1).passable then
      humanoid:setTilePositionSpeed(x1, y1)
      if action.on_next_tile_set then
        action.on_next_tile_set()
      end
      return action:onRestart()
    end
  end
  
  -- on_next_tile_set can be set in the call to action_walk_raw, but it is
  -- then to be called AFTER the next raw walk or tile set, which is why we
  -- remember the previous value and call that, rather than call the new value.
  local on_next_tile_set = action.on_next_tile_set
  action_walk_raw(humanoid, x1, y1, x2, y2, check_doors and map, action_walk_tick)
  action.path_index = path_index + 1
  if on_next_tile_set then
    on_next_tile_set()
  end
end)

-- This is a slight hack, but is the easiest way to make walk functionality
-- available to other actions which want to do low-level walk operations.
strict_declare_global "HumanoidRawWalk"
HumanoidRawWalk = action_walk_raw

local action_walk_tick_door = permanent"action_walk_tick_door"( function(humanoid)
  local door = humanoid.user_of
  if not class.is(door, SwingDoor) then
    -- The doors will need to finish swinging before another humanoid can walk through.
    door:setUser(nil)
  end
  humanoid.user_of = nil
  return action_walk_tick(humanoid)
end)

navigateDoor = function(humanoid, x1, y1, dir)
  local action = humanoid.action_queue[1]
  local duration = 12
  local dx = x1
  local dy = y1
  if dir == "east" then
    dx = dx + 1
    duration = 10
  elseif dir == "south" then
    dy = dy + 1
    duration = 10
  end
  local swinging = false
  local door = humanoid.world:getObject(dx, dy, "door")
  if not door then
    swinging = true
    door = humanoid.world:getObject(dx, dy, "swing_door_right")
  end
  door.queue:unexpect(humanoid)
  door:updateDynamicInfo()
  local room = door:getRoom()
  local is_entering_room = room and humanoid:getRoom() ~= room
  if class.is(humanoid, Staff) and is_entering_room 
  and humanoid.humanoid_class ~= "Handyman" then
    -- A member of staff is entering, but is maybe no longer needed 
    -- in this room?
    if not room:staffFitsInRoom(humanoid) then
      humanoid:setTilePositionSpeed(x1, y1)
      local room = humanoid.world:getNearestRoomNeedingStaff(humanoid)
      if room then
        humanoid:setNextAction(room:createEnterAction())
      else
        humanoid:setNextAction(MeanderAction())
      end
      return
    end
  end
  if (door.user)
  or (door.reserved_for and door.reserved_for ~= humanoid)
  or (is_entering_room and not room:canHumanoidEnter(humanoid)) then
    local queue = door.queue
    if door.reserved_for == humanoid then
      -- Door is somehow reserved for us, but we cannot use it, so give
      -- someone else the opportunity to use it (if anyone is waiting).
      door.reserved_for = nil
      if queue:size() > 0 then
        queue:pop()
        door:updateDynamicInfo()
      end
    end
    humanoid:setTilePositionSpeed(x1, y1)
    local action_index = 0
    if is_entering_room and queue:size() == 0 and not room:getPatient()
    and not door.user and not door.reserved_for and humanoid.should_knock_on_doors 
    and room.room_info.required_staff and not swinging then
      humanoid:queueAction(KnockDoorAction{
        door = door,
        direction = dir,
      }, action_index)
      action_index = action_index + 1
    end
    humanoid:queueAction(QueueAction{
      x = x1,
      y = y1,
      queue = queue,
      reserve_when_done = door,
    }, action_index)
    -- If this walk action ever resumes, then we want to grab ownership of the
    -- door.
    action.reserve_on_resume = door
    return
  end
  if action.reserve_on_resume then
    -- We're about to become the user of the door, so no need to keep the door
    -- reserved if we get restarted again.
    assert(action.reserve_on_resume == door)
    action.reserve_on_resume = nil
  elseif is_entering_room and not action.done_knock and humanoid.should_knock_on_doors  
  and room.room_info.required_staff and not swinging then
    humanoid:setTilePositionSpeed(x1, y1)
    humanoid:queueAction(KnockDoorAction{
      door = door,
      direction = dir,
    }, 0)
    action.reserve_on_resume = door
    action.done_knock = true
    return
  end
  
  local to_x, to_y
  local anims = humanoid.door_anims
  if not anims.leaving or not anims.entering then
    local from_rm, to_rm = room.room_info.id, "corridor"
    if is_entering_room then
      from_rm, to_rm = to_rm, from_rm
    end
    error(("Humanoid (%s) without door animations trying to walk through "..
      "door (from %s to %s)"):format(humanoid.humanoid_class, from_rm, to_rm))
  end
  humanoid:setTilePositionSpeed(dx, dy)
  humanoid.user_of = door
  door:setUser(humanoid)
  local entering, leaving
  if swinging then
    entering = anims.entering_swing
    leaving = anims.leaving_swing
    duration = humanoid.world:getAnimLength(entering)
  else
    entering = anims.entering
    leaving = anims.leaving
  end
  local direction = "in"
  if dir == "north" then
    humanoid:setAnimation(leaving, flag_list_bottom)
    to_x, to_y = dx, dy - 1
    duration = humanoid.world:getAnimLength(leaving)
  elseif dir == "west" then
    humanoid:setAnimation(leaving, flag_list_bottom + flag_early_list + flag_flip_h)
    to_x, to_y = dx - 1, dy
    duration = humanoid.world:getAnimLength(leaving)
  elseif dir == "east" then
    humanoid:setAnimation(entering, flag_list_bottom + flag_early_list)
    to_x, to_y = dx, dy
    direction = "out"
  elseif dir == "south" then
    humanoid:setAnimation(entering, flag_list_bottom + flag_flip_h)
    to_x, to_y = dx, dy
    direction = "out"
  end
  humanoid.last_move_direction = dir
  if swinging then
    door:swingDoors(direction, duration)
  end
  
  -- We want to notify the rooms on either side of the door that the humanoid
  -- has entered / left, but we want to do this AFTER the humanoid has gone
  -- through the door (so that their tile position reflects the room which they
  -- are now in).
  local --[[persistable:action_walk_on_next_tile_set]] function on_next_tile_set()
    if action.on_next_tile_set == on_next_tile_set then
      action.on_next_tile_set = nil
    end
    local room = humanoid.world:getRoom(x1, y1)
    if room then
      room:onHumanoidLeave(humanoid)
    end
    room = humanoid.world:getRoom(to_x, to_y)
    if room then
      room:onHumanoidEnter(humanoid)
    end
  end
  action.on_next_tile_set = on_next_tile_set
  
  action.path_index = action.path_index + 1
  humanoid:setTimer(duration, action_walk_tick_door)
end

function WalkAction:onFinish()
  if self.reserve_on_resume then
    -- We reseved a door, but never got around to using it.
    local door = self.reserve_on_resume
    if door.reserved_for == self.humanoid then
      door.reserved_for = nil
      if door.queue:size() > 0 then
        door.queue:pop()
        door:updateDynamicInfo()
      end
    end
  end
  self.humanoid.timer_function = nil
  Action.onFinish(self)
end

function WalkAction:toString()
  return ("Walk to (%i,%i)"):format(self.x, self.y)
end

function WalkAction:onRestart()
  local action = self
  local humanoid = self.humanoid
  
  -- Possible future optimisation: when walking from somewhere inside the hospital
  -- to somewhere outside the hospital (or from one building to another?), do
  -- pathfinding in two steps, with the building door as a middle node
  local path_x, path_y = humanoid.world:getPath(humanoid.tile_x, humanoid.tile_y, action.x, action.y)
  if not path_x or #path_x == 1 then
    -- Finishing an action from within the start handler is a very bad idea, as
    -- it is normal when ordering several actions to setNextAction the first
    -- one, then queueAction the rest. If the first starts straight away, and
    -- then finishes straight away, then the humanoid is left with an empty
    -- action queue. Hence we wait one tick before finishing. We still need to
    -- set the humanoid animation / position though, which is delegated to the
    -- idle action (if this wasn't done, then the previous animation would be
    -- used, which might involve an object).
    IdleAction.setAnimation(self)
    humanoid:setTimer(1, humanoid.finishAction)
    return
  end
  action.path_x = path_x
  action.path_y = path_y
  action.path_index = 1
  
  -- TODO: Logic
  if action.reserve_on_resume then
    action.reserve_on_resume.reserved_for = humanoid
  end
  
  return action_walk_tick(humanoid)
end

function WalkAction:onStart()
  Action.onStart(self)
  self:onRestart()
end
