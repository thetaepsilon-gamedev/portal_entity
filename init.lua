--[[
Portal entity:
objects close enough to it are teleported through it,
appearing at a given point with an offset opposite of the offset upon stepping in.
Currently doesnt do anything to manipulate velocity.
]]
-- register some requisites first
local mp = minetest.get_modpath("portal_entity") .. "/"
local i = {}
i.motion = dofile(mp.."motion_entity.lua")

--[[
The way teleportation is achieved goes like the following:
Vector difference and basis transforms (from vectorextras)
are utilised to retrieve coordinates of entities relative to the portal
(taking into account the portal's rotation, if any).
Then (again in portal coordinate space) if the entity's predicted motion
(their current pos plus speed) crosses the Z=0 plane (the portal itself)
and it's X/Y components are within the portal hitbox,
then the entity is marked for sending to the other portal.
There, the entity's positioning and velocity are transformed back into world terms,
by utilising the target portal positioning and orientation.
]]
local unwrap = mtrequire("ds2.minetest.vectorextras.unwrap")
local m_subtract = mtrequire("ds2.minetest.vectorextras.subtract")
local diff = m_subtract.raw
local m_scalar = mtrequire("ds2.minetest.vectorextras.scalar_multiply")
local mult = m_scalar.raw
local m_add = mtrequire("ds2.minetest.vectorextras.add")
local add = m_add.raw
local m_basis = mtrequire("ds2.minetest.vectorextras.basis_vector_transform")
local basis_transform_ = m_basis.raw_



local get_vel = function(ent)
	return (ent:is_player() and ent:get_player_velocity() or ent:get_velocity())
end
-- get velocity scaled for one tick's worth of movement.
-- note: it's possible that in future hardcoding the tick speed may not work.
local get_scaled_velocity = function(ent)
	local v = get_vel(ent)
	local vx, vy, vz = unwrap(v)
	return mult(0.1, vx, vy, vz)
end

local inbounds = function(lower, x, higher)
	return (lower <= x) and (x <= higher)
end



local ydebug = print
local ndebug = function() end
local debug = ndebug
local does_entity_intersect = function(self, ent, rotator, bx, by, bz)
	--debug("--- portal@"..tostring(self.object)..": polled entity: "..tostring(ent))
	local currentp_ws = ent:get_pos()
	local offset_predicted = get_vel(ent)

	-- translate to relative space but still world aligned
	local cwx, cwy, cwz = unwrap(currentp_ws)
	--debug("world space", cwx, cwy, cwz)
	local crx, cry, crz = diff(cwx, cwy, cwz, bx, by, bz)
	--debug("relative space currentpos", crx, cry, crz)
	-- also relative space offset, no origin translation needed for offsets.
	local orx, ory, orz = get_scaled_velocity(ent)
	--debug("relative space velocity offset", orx, ory, orz)
	-- rotate current position and offset into portal space
	local cpx, cpy, cpz = rotator(crx, cry, crz)
	local opx, opy, opz = rotator(orx, ory, orz)
	--debug("portal space currentpos", cpx, cpy, cpz)
	--debug("portal space offset", opx, opy, opz)


	-- firstly, if the entity starts *behind* the portal, ignore it
	if cpz < 0 then
		debug("! start point behind portal")
		return false
	end
	-- predict next position in portal space using velocity offset.
	-- if this new position crosses the Z=0 plane in portal space,
	-- then we must check the portal hitbox.
	if cpz + opz > 0 then
		-- offset Z should be going down to cross the portal.
		-- to cross it, it must go across the Z=0 boundary
		debug("! next position doesn't cross portal")
		return false
	end

	-- work out the precise point at which it will intersect.
	-- do that by scaling the X and and Y offsets by the -Z offset,
	-- so that the vector's endpoint touches the Z-plane.
	-- (gah, I need DIAGRAMS)
	local scale = 1 / (-opz)	-- we know opz must be negative here
	local scaledx = opx * scale
	local scaledy = opy * scale
	local planex = cpx + scaledx
	local planey = cpy + scaledy
	--debug("scaled plane intersection point (X/Y)", planex, planey)

	local isinbounds = inbounds(self.minplanex, planex, self.maxplanex) and
		inbounds(self.minplaney, planey, self.maxplaney)
	debug("! isinbounds", isinbounds)

	-- TODO: returning entity velocity in portal space
	return isinbounds
end



-- prepare rotation via partial application;
-- mostly useful in the event that the portal watches multiple entities.
local get_rotator = function(self)
	-- north and east are "up" and right when looking straight down at the portal
	local ax, ay, az = unwrap(self.axis_east)
	local bx, by, bz = unwrap(self.axis_north)
	-- the C component (Z in rotated vectors)
	-- is used to indicate coming "out" of the portal
	-- (right-hand coordinate system).
	local cx, cy, cz = unwrap(self.axis_out)
	return basis_transform_(ax, ay, az, bx, by, bz, cx, cy, cz)
end

local find_intersecting_entities = function(self)
	local poll_radius = self.poll_radius or 20
	local bpos = self.object:get_pos()
	local rotator = get_rotator(self)
	local bx, by, bz = unwrap(bpos)
	local polled = minetest.get_objects_inside_radius(bpos, poll_radius)
	local target = self.targetpos
	for i, ent in ipairs(polled) do
		-- lua, lack of continue... why
		if ent ~= self.object then
			local intersecting = does_entity_intersect(self, ent, rotator, bx, by, bz)
			if intersecting then
				-- TODO: giving entities a mild offset out the portal?
				ent:set_pos(target)
			end
		end
	end
end
local on_step = function(self, dtime)
	-- only run if we're enabled
	-- correct properties on entity must be set if this is enabled
	-- needed vars:
	--[[
	self.minplanex
	self.maxplanex
	self.minplaney
	self.maxplaney
	self.axis_out
	self.axis_north
	self.axis_east
	self.targetpos
	]]
	if not self.enabled then return end
	return find_intersecting_entities(self)
end
local saveprops = {
	"minplanex",
	"maxplanex",
	"minplaney",
	"maxplaney",
	"axis_out",
	"axis_north",
	"axis_east",
	"targetpos",
	"enabled",
}
local flatten = minetest.serialize
local mksave = function(props)
	-- apparently "self" is userdata so one cannot pass it to serialize(),
	-- otherwise minetest will have a fatal lua abort.
	local save = {}
	return function(self)
		for i, k in ipairs(props) do
			save[k] = self[k]
		end
		return flatten(save)
	end
end




local n = "portal_entity:portal"
local msg = n .. " failed to load due to corrupt staticdata, KO'ing self: "
local restore_deserial = function(self, staticdata)
	if staticdata == "" then return end
	local data, err = minetest.deserialize(staticdata)
	if not data then
		minetest.log("warning", msg .. err)
		self.object:remove()
		return
	end
	for k, v in pairs(data) do
		self[k] = v
	end
end





minetest.register_entity(n, {
	visual = "sprite",
	textures = { "portal_entity_sprite.png" },
	on_step = on_step,
	get_staticdata = mksave(saveprops),
	on_activate = restore_deserial,
})

-- export helpers interface
portal_entity = i

