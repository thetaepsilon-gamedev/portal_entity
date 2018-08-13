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

-- applying friction to the entity on solid surfaces
local m_friction_calc = mtrequire("ds2.minetest.drag_physics.mt_default_friction_calc")
local friction_sampler = m_friction_calc.friction_sampler
m_apply = mtrequire("ds2.minetest.drag_physics.apply_surface_friction")
local apply_surface_friction = m_apply.apply
local apply = function(dtime, selfent)
	return apply_surface_friction(
		dtime,
		selfent,
		selfent:get_properties(),
		friction_sampler)
end



local ndebug = function() end
local ydebug = print
local debug = ydebug
local kill = function(msg)
	debug(msg)
	return true
end
local ok = function()
	debug("ok")
end
local vec3 = vector.new
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
	-- let them move normally again *if they're on a solid surface*.
	local vel = self.object:get_velocity()
	local speed = vector.length(vel)
	-- TODO: what if this changes in future
	local pos = self.object:get_pos()
	if speed < 4 then
		local feet = vec3(pos.x, pos.y-0.05, pos.z)
		local node = minetest.get_node(feet)
		-- in the event of anything failing, keep the entity attached.
		if node then
			local n = node.name
			debug("name: ", n)
			local def = minetest.registered_nodes[n]
			-- we don't treat ignore as a blocking condition.
			-- this way we're not detached if the world can't keep up
			if def then
				if def.walkable then
					return kill("stood on solid node")
				end
			end
		end
	end

	-- assuming we passed all that, we can continue.
	return ok()
end



-- when attached to a player, we take on their cbox.
-- however, the default one as returned by the player properties has some -Y padding.
-- to fix this, alter the cbox such that it's dimensions are the same,
-- but it's Y values are shifted up such that it's bottom side is zero.
-- WARNING: mutates argument in place!
local adjust_cbox_mut = function(cbox)
	local bottom = cbox[2]
	local top = cbox[5]
	cbox[2] = 0
	cbox[5] = top - bottom
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
	adjust_cbox_mut(current.collisionbox)
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
		self:cleanup()
		return
	end

	-- save the player ref for easy access later.
	self.playerref = player

	-- otherwise we should be good
end

local on_step = function(self, dtime)
	-- surface drag calculations
	apply(dtime, self.object)
	-- check the player is still appropriate, else remove ourselves
	local kill = check_self_kill(self)
	if kill then
		debug("object no longer suitable")
		self:cleanup()
	end
end

-- clean-up routine which detaches the player properly before removing the object.
-- hopefully to counter some weird invisibility bugs for players
local cleanup = function(self)
	local p = self.playerref
	if p and self.object:get_bone_position("player") then
		p:set_detach()
	end
	self.object:remove()
end

local on_activate = function(self, staticdata, dtime_s)
	-- this entity is not intended to be persistent across loads.
	if staticdata ~= "new" then
		debug("tried to re-create from save")
		cleanup(self)
		return
	end
	-- otherwise, created fresh.
	-- provide injector method
	self.set_player = set_player
	self.cleanup = cleanup
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

-- to fling a player that might already be in flight,
-- we need to find their root attachment object and move that instead;
-- if that's a regular entity, then we just offset that entity's velocity.
-- returns the actual entity that was altered;
-- this may be a newly created motion entity.
local fling_entity = function(ent, addvel)
	-- seek for the root of the attachment hierachy
	local current = ent
	local iterate = function()
		local parent, bone, pos = current:get_attach()
		if parent then current = parent end
		return parent
	end
	for _ in iterate do end
	-- we will end up with the root entity.
	local vel
	local isp = current:is_player()
	vel = isp and current:get_player_velocity() or current:get_velocity()
	local tvel = vector.add(vel, addvel)
	if isp then
		return fling_player(current, tvel)
	else
		current:set_velocity(tvel)
		return current
	end
end
i.fling_entity = fling_entity

-- an example item using this routine.
local n = "portal_entity:thors_hammer"
local hammer_power = 50
local hammer_throw = function(user, ent)
	local lookdir = user:get_look_dir()
	local vel = vector.multiply(lookdir, hammer_power)
	return fling_entity(ent, vel)
end
local throwme = function(item, user, pointed)
	-- NB: do NOT return something weird from on_* callbacks for items...
	-- that way lies segfaults and sadness
	hammer_throw(user, user)
end
minetest.register_craftitem(n, {
	description = "Debug fling hammer (try punching an object/player)",
	inventory_image = "portal_entity_motion_debug_hammer.png",
	on_use = function(item, user, pointed)
		if pointed.type ~= "object" then return nil end
		local target = pointed.ref
		hammer_throw(user, target)
	end,
	on_place = throwme,
	on_secondary_use = throwme,
})

-- a debug item which lets admins detach themselves or other objects from any parent.
-- mainly useful if the attachment entity bugs out and won't let go of a player.
local n = "portal_entity:ungrabber"
local releaseme = function(item, user, pointed)
	user:set_detach()
end
minetest.register_craftitem(n, {
	description = "The Ungrabber" ..
		" (left click to detach object, right click to detach self)",
	inventory_image = "portal_entity_motion_debug_ungrabber.png",
	on_use = function(item, user, pointed)
		if pointed.type ~= "object" then return nil end
		pointed.ref:set_detach()
	end,
	on_place = releaseme,
	on_secondary_use = releaseme,
	groups = { not_in_creative_inventory = 1 },
})



return i


