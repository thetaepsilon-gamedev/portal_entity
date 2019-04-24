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
-- get the extradata (node definitions) out as a table structure,
-- useful below in squish() to detect if nodes have been collided with.
local mkxface = function(face, xalbl, xahbl, xalbh, xahbh)
	return { xalbl, xahbl, xalbh, xahbh }
end
local mkxcube = function(exmin, eymin, ezmin, exmax, eymax, ezmax)
	return {
		xmin = exmin,
		xmax = exmax,
		ymin = eymin,
		ymax = eymax,
		zmin = ezmin,
		zmax = ezmax,
	}
end
local friction_sampler =
	m_friction_calc.mk_sampler_with_extradata(mkxface, mkxcube)

m_apply = mtrequire("ds2.minetest.drag_physics.apply_surface_friction")
local apply_surface_friction = m_apply.apply
local apply = function(dtime, selfent)
	return apply_surface_friction(
		dtime,
		selfent,
		selfent:get_properties(),
		friction_sampler)
end




-- calls used during development, normally debug should = ndebug
local ndebug = function() end
local ydebug = print
local debug = ndebug





-- determine if a player is stood on a solid node at any corners of the hitbox.
-- if so, they are allowed to become detached from the motion entity
-- (see check_self_kill() below)
local vec3 = vector.new
local is_solid = function(node_def)
	return node_def and node_def.walkable or false
end
local getnode = minetest.get_node
local defs = minetest.registered_nodes
local get = function(pos)
	local n = getnode(pos)
	return defs[n.name]
end
local is_standing = function(self, pos)
	local px, pz = pos.x, pos.z
	local feet = { y = pos.y - 0.05 }	-- x/z filled below
	local n1, n2, n3, n4	-- nodes underneath each corner
	local g1, g2, g3, g4	-- whether each corner has grip on something
	local xmin = self.cxmin
	local xmax = self.cxmax
	local zmin = self.czmin
	local zmax = self.czmax

	-- corner -/-
	feet.x = px + xmin
	feet.z = pz + zmin
	n1 = get(feet)
	g1 = is_solid(n1)
	--debug("grip g1: "..tostring(g1))

	-- corner -/+
	feet.x = px + xmin
	feet.z = pz + zmax
	n2 = get(feet)
	g2 = is_solid(n2)
	--debug("grip g2: "..tostring(g2))

	-- corner +/-
	feet.x = px + xmax
	feet.z = pz + zmin
	n3 = get(feet)
	g3 = is_solid(n3)
	--debug("grip g3: "..tostring(g3))

	-- corner +/+
	feet.x = px + xmax
	feet.z = pz + zmax
	n4 = get(feet)
	g4 = is_solid(n4)
	--debug("grip g4: "..tostring(g4))

	local r = g1 or g2 or g3 or g4
	--debug("grip result: "..tostring(r))
	return r
end





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
	-- let them move normally again *if they're on a solid surface*.
	local vel = self.object:get_velocity()
	local speed = vector.length(vel)
	-- TODO: what if this changes in future
	local pos = self.object:get_pos()
	if speed < 4 then
		local grip = is_standing(self, pos)
		--debug("grip: "..tostring(grip))
		if grip then
			return kill("stood on solid node")
		end

		if speed < 1 then
			-- allow the player to roam free if they're swimming.
			local lname = getnode(pos).name
			local ldef = minetest.registered_nodes[lname]
			-- where's C#'s ?? operator when you need it
			local lt = ldef and ldef.liquidtype or nil
			if lt == "source" or lt == "flowing" then
				return kill("swimming in liquid")
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





-- function used below to save cbox bounds for use elsewhere.
-- in particular, x/z are used for the standing-on-node checks.
local save_cbox_feet_bounds = function(self, cbox)
	self.cxmin = cbox[1]
	self.czmin = cbox[3]

	self.cxmax = cbox[4]
	self.czmax = cbox[6]
end





local zero = vector.new(0,0,0)
-- is there a better way to do this...
local gravity = vector.new(0, -20, 0)
local attach_player = function(self, player)
	self.player = player

	-- physics properties
	local pprops = player:get_properties()
	local o = self.object
	local current = o:get_properties()
	current.weight = pprops.weight
	current.collisionbox = pprops.collisionbox
	adjust_cbox_mut(current.collisionbox)
	save_cbox_feet_bounds(self, current.collisionbox)
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







-- it's not the fall that kills you, it's the sudden stop at the end.
-- hurt the player on sudden acceleration.
-- the numbers below are approximately gathered from experiments in MT:
-- the player starts to take fall damage from 6 blocks of fall;
-- at the moment the player hits the ground they are moving at around 13.4m/s.
-- assuming a perfect 0.1 second tick speed,
-- this means the player can endure a 134m/s^2 deceleration before hurting.
-- after that, damage increases roughly every 10m/s^2.
local get_collide_multiplier = function(face)
	local total = 0
	local corner
	for i = 1, 4, 1 do
		corner = is_solid(face[i]) and 1 or 0
		total = total + corner
	end
	return total / 4
end
local abs = math.abs
local floor = math.floor

-- more tweak constants...
local sq_threshold = 13.4
local sq_scaler = 0.2
local sq_exp = 1.5
local threshold_sub = function(v, threshold)
	local r = v - threshold
	return (r <= 0) and 0 or r
end
local squish_axis = function(vdiff, face_min, face_max, debuglabel)
	-- if we a negative delta, i.e. slowed down going +X,
	-- we expect the offending nodes to be in the +X direction.
	local face = (vdiff < 0) and face_max or face_min
	local vabs = abs(vdiff)
	local mult = get_collide_multiplier(face)
	local dmg = ((threshold_sub(vabs, sq_threshold) * sq_scaler) ^ sq_exp) * mult
	return dmg
end





local sub = vector.subtract
local len = vector.length
local squish = function(self, selfobj, dtime, cvel, defs)
	local old = self.oldvel
	local new = cvel
	local p = self.playerref
	if not p then return end	-- cleanup will catch this too
	self.oldvel = new

	-- first step, no previous velocity... so skip.
	if not old then return end

	local acc = sub(new, old)
	-- for each axis, if there is a sudden change in velocity,
	-- check if there has been a node encounted at the friction step.
	-- if so, scale the damage by the number of "solid" nodes
	-- (uses the same walkable logic for now).
	-- TODO: make some nodes more harmful at speed? e.g. big spikes
	local dmg_x = squish_axis(acc.x, defs.xmin, defs.xmax, "x")
	local dmg_y = squish_axis(acc.y, defs.ymin, defs.ymax, "y")
	local dmg_z = squish_axis(acc.z, defs.zmin, defs.zmax, "z")
	local hp = floor(dmg_x + dmg_y + dmg_z)
	if hp > 0 then
		local oldhp = p:get_hp()
		local newhp = oldhp - hp
		if newhp < 0 then newhp = 0 end

		-- NB: 5.0.0 had a bug causing this to murder the server.
		-- 5.0.1 or higher is required.
		local reason = {type="fall"}
		p:set_hp(newhp, reason)
	end
end







local on_step = function(self, dtime)
	-- surface drag calculations
	local cvel, fextra = apply(dtime, self.object)

	-- slow-down damage
	squish(self, self.object, dtime, cvel, fextra)

	-- check the player is still appropriate, else remove ourselves
	local kill = check_self_kill(self)
	if kill then
		debug("object no longer suitable")
		self:cleanup()
		return
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



-- entity is invulnerable and not punchable by the player.
-- this is so they can't escape from being flung by punching it.
local groups = {
	immortal = 1,
	punch_operable = 1,
}
local on_activate = function(self, staticdata, dtime_s)
	-- this entity is not intended to be persistent across loads.
	if staticdata ~= "new" then
		debug("tried to re-create from save")
		cleanup(self)
		return
	end
	self.object:set_armor_groups(groups)
	-- otherwise, created fresh.
	-- provide injector method
	self.set_player = set_player
	self.cleanup = cleanup
end

-- TODO: make invisible when debugged?

local def = {
	physical = true,
	collide_with_objects = true,
	pointable = false,
	selectionbox = {0,0,0,0,0,0},
	visual = "sprite",
	textures = { "portal_entity_motion_debug.png" },
	on_step = on_step,
	on_activate = on_activate,
	armor_groups = groups,
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
	--debug("initial fling entity: "..tostring(current))
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



local forbidden_msg = "Node was marked protected, refusing to throw."
local throw_node = function(pos, user)

	-- protection consideration...
	if user:is_player() then
		local name = user:get_player_name()
		if minetest.is_protected(pos, name) then
			minetest.chat_send_player(name, forbidden_msg)
			minetest.record_protection_violation(pos, name)
			return
		end
	end

	-- yes, this is a bit of a hack... but I need the entity ref!
	local ref = minetest.add_entity(pos, "__builtin:falling_node")
	if ref then
		-- finally, an entity with a sane method interface
		local rpc = ref:get_luaentity()
		rpc:set_node(minetest.get_node(pos), minetest.get_meta(pos):to_table())
		minetest.remove_node(pos)
		--debug("node throw ref: "..tostring(ref))
		hammer_throw(user, ref)
	end
end

minetest.register_craftitem(n, {
	description = "Debug fling hammer (try punching an object/player)",
	inventory_image = "portal_entity_motion_debug_hammer.png",
	on_use = function(item, user, pointed)
		if pointed.type ~= "object" then
			if pointed.type ~= "node" then return nil end
			throw_node(pointed.under, user)
			return
		end
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






-- Test block to be used with player_onstep_hooks:
-- an Aerial Faith Plate.
-- The block requires X, Y, and Z floats set in it's metadata.
-- When these are set, players walking on it are thrown using the above code,
-- with the velocity vector formed out of the loaded XYZ components
minetest.register_node("portal_entity:aerial_faith_plate", {
	description = "Aerial faith plate (needs metadata set)",
	groups = {oddly_breakable_by_hand=1},
	on_stood_on = function(player, pos, node, def)
		local meta = minetest.get_meta(pos)
		-- :get_float() returns 0 anyway if not set...
		local x = meta:get_float("x")
		local y = meta:get_float("y")
		local z = meta:get_float("z")
		local velocity = vec3(x, y, z)

		fling_entity(player, velocity)
	end
})






return i


