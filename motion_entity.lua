--[[
Minetest doesn't currently allow manipulation of the player's velocity;
currently the client is mostly responsible for determining player speed (!!),
and the server is unable to report events that would affect the player's velocity;
this means that we e.g. can't throw the player up into the air.

This makes portals a bit boring, as we can't execute fling motions on the player.
However, consider the following:
when a player would be moving really fast in mid-air,
realistically the player shouldn't be able to magically mid-air strafe
(they've got nothing to push on).
Therefore, it doesn't matter if we lock the player's controls and do the motion for them.

The best way to do this is to attach them to an invisible entity.
This entity *can* be flung around, so we just manipulate that;
e.g. when the portal warps a player moving at speed,
stick them on this "motion entity" and use that to control their velocity.
When the player's speed has returned to within normal range
(e.g. how fast they could normally walk - usually about 2m/s),
the entity detaches the player and removes itself.
]]

local ndebug = function() end
local ydebug = print
local debug = ndebug
local kill = function(msg)
	debug(msg)
	return true
end
local ok = function()
	debug("ok")
end
local check_self_kill = function(self)
	if not self.setup then return kill("not initialised") end
	-- we can't retrieve child objects in attached bones.
	-- therefore we have to keep track of it some other way:
	-- when we're spawned, we expect to have a player object present in our lua entity.
	-- if this is missing or invalid, die so as to not cause problems.
	local player = self.player
	if player == nil then return kill("nil player ref") end
	if not player:is_player() then return kill("not a player") end

	-- has this player ref vanished (e.g. the player disconnected)?
	local pos = player:get_pos()
	if pos == nil then return kill("not in the world") end
	-- player attached to something else (say they clicked on a boat)?
	local parent = player:get_attach()
	if parent ~= self.object then return kill("wrong parent") end
	-- player dead? (otherwise they could be stuck there on respawn)
	if player:get_hp() <= 0 then return kill("player is dead") end

	-- check our current velocity.
	-- if it happens to be lower than the player's normal walking threshold,
	-- let them move normally again
	local vel = self.object:get_velocity()
	local speed = vector.length(vel)
	-- TODO: what if this changes in future
	if speed < 4 then return kill("walking pace") end

	-- assuming we passed all that, we can continue.
	return ok()
end

local zero = vector.new(0,0,0)
-- is there a better way to do this...
local gravity = vector.new(0, -9.8, 0)
local attach_player = function(self, player)
	self.player = player

	-- physics properties
	local pprops = player:get_properties()
	local o = self.object
	local current = o:get_properties()
	current.weight = pprops.weight
	current.collisionbox = pprops.collisionbox
	o:set_properties(current)
	o:set_acceleration(gravity)

	-- move to correct location and attach
	self.object:set_pos(player:get_pos())
	player:set_attach(o, "player", zero, zero)

	self.setup = true
	debug("player attached")
end

-- use this method on get_luaentity() to set up this entity.
-- this should only be called once;
-- to do this to another player, create a new instance.
local set_player = function(self, player)
	assert(not self.setup, "duplicate :set_player() call")
	assert(player ~= nil, "nil ref passed")
	assert(player:is_player(), "tried to set a non-player on motion entity")
	-- the caller is assumed to have checked both this and the player's velocity;
	-- usually you want to traverse the chain of objects from a starting point,
	-- to find the parent that isn't attached to anything.
	local parent = player:get_attach()
	assert(parent == nil, "target player was already parented")

	-- attach the player to us and adjust our physics properties
	attach_player(self, player)
	-- check that the player is currently moving fast enough etc.
	local kill = check_self_kill(self)
	if kill then
		debug("premature death")
		self.object:remove()
		return
	end

	-- otherwise we should be good
end

local on_step = function(self, dtime)
	-- check the player is still appropriate, else remove ourselves
	local kill = check_self_kill(self)
	if kill then
		debug("object no longer suitable")
		self.object:remove()
	end
end

local on_activate = function(self, staticdata, dtime_s)
	-- this entity is not intended to be persistent across loads.
	if staticdata ~= "new" then
		debug("tried to re-create from save")
		self.object:remove()
		return
	end
	-- otherwise, created fresh.
	-- provide injector method
	self.set_player = set_player
end

-- TODO: make invisible when debugged?
local def = {
	physical = true,
	collide_with_objects = true,
	visual = "sprite",
	textures = { "portal_entity_motion_debug.png" },
	on_step = on_step,
	on_activate = on_activate,
}
local name = "portal_entity:motion"
minetest.register_entity(name, def)



-- now for some helper functions
local i = {}
local fling_player = function(player, vel)
	-- position doesn't matter as it will shortly be moved
	local ent = minetest.add_entity(zero, name, "new")
	local self = ent:get_luaentity()
	ent:set_velocity(vel)
	self:set_player(player)
	return ent
end
i.fling_player = fling_player

return i


