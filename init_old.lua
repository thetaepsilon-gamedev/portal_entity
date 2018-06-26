--[[
Portal entity:
objects close enough to it are teleported through it,
appearing at a given point with an offset opposite of the offset upon stepping in.
Currently doesnt do anything to manipulate velocity.
]]

--[[
The way teleportation is achieved goes like the following:
for each entity within a certain maximum poll radius,
the entity's current position is taken (point A),
as well as it's current velocity.
The velocity is used to guess where the entity will be in the next tick (B).
Then, the nearest point on the line from A to B is taken (C),
and the distance from that to the portal's position (P) is taken;
this is to work out if the entity's path clips the "event horizon".
If it does (i.e. distance from P to C < some critical value),
the entity is marked for teleport.

Teleportation for said entities then just looks at the relative position from P to C,
inverts it, adds that to the target position, and warps the entity there.
]]
local m_closest = mtrequire("ds2.minetest.vectorextras.closest_line_point")
local closest = m_closest.raw
local unwrap = mtrequire("ds2.minetest.vectorextras.unwrap")
local wrap = mtrequire("ds2.minetest.vectorextras.wrap")
local m_subtract = mtrequire("ds2.minetest.vectorextras.subtract")
local diff = m_subtract.raw
local m_magnitude = mtrequire("ds2.minetest.vectorextras.magnitude")
local length = m_magnitude.raw

local poll_radius = 20	-- objects moving at more than 200m/s... come on now
local ev_radius = 0.6

local get_vel = function(ent)
	return (ent:is_player() and ent:get_player_velocity() or ent:get_velocity())
end

local does_entity_intersect = function(p, ent)
	local a = ent:get_pos()
	-- effing players different API mumble
	local vel = get_vel(ent)
	local b = vector.add(a, vector.multiply(vel, 0.1))

	local px, py, pz = unwrap(p)
	local ax, ay, az = unwrap(a)
	local bx, by, bz = unwrap(b)

	-- closest point to the portal's location
	local cx, cy, cz = closest(ax, ay, az, bx, by, bz, px, py, pz)

	-- now work out the relative position of the closest point and how far away it is.
	local crx, cry, crz = diff(cx, cy, cz, px, py, pz)
	local l = length(crx, cry, crz)
	if (l < ev_radius) then
		-- inside event horizon: return it, and it's relative position.
		local rx, ry, rz = diff(ax, ay, az, px, py, pz)
		return {
			ent = ent,
			relpos = wrap(rx, ry, rz),
		}
	else
		return nil
	end
end

local find_intersecting_entities = function(bpos, tbpos)
	local polled = minetest.get_objects_inside_radius(bpos, poll_radius)
	for i, ent in ipairs(polled) do
		local intersecting = does_entity_intersect(bpos, ent)
		if intersecting then
			-- TODO: target position
			local rpos = vector.multiply(intersecting.relpos, -1.1)
			local tpos = vector.add(tbpos, rpos)
			intersecting.ent:set_pos(tpos)
		end
	end
end
local on_step = function(self, dtime)
	-- only run poll if we have somewhere to teleport to.
	local target = self.targetpos
	if (target == nil) then return end
	return find_intersecting_entities(self.object:get_pos(), target)
end


local n = "portal_entity:portal"
minetest.register_entity(n, {
	visual = "sprite",
	textures = { "portal_entity_sprite.png" },
	on_step = on_step,
})

