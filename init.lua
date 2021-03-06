local path = "heightmap.dat"
local conf_path = "heightmap.dat.conf"

file = io.open(minetest.get_worldpath() .. "/" .. path)
local conf = Settings(minetest.get_worldpath() .. "/" .. conf_path)

local scale = conf:get("scale") or 40
local remove_delay = 10

local function parse(str, signed) -- little endian
	local bytes = {str:byte(1, -1)}
	local n = 0
	local byte_val = 1
	for _, byte in ipairs(bytes) do
		n = n + (byte * byte_val)
		byte_val = byte_val * 256
	end
	if signed and n >= byte_val / 2 then
		return n - byte_val
	end
	return n
end

if file:read(5) ~= "GEOMG" then
	print('WARNING: file may not be in the appropriate format. Signature "GEOMG" not recognized.')
end

local itemsize_raw = parse(file:read(1))
local signed = false
local itemsize = itemsize_raw
if itemsize >= 16 then
	signed = true
	itemsize = itemsize_raw - 16
end

local frag = parse(file:read(2))
local X = parse(file:read(2))
local Z = parse(file:read(2))
local chunks_x = math.ceil(X / frag)
local chunks_z = math.ceil(Z / frag)

local index_length = parse(file:read(4))
local index_raw = minetest.decompress(file:read(index_length)) -- Called index instead of table to avoid name conflicts
local index = {[0] = 0}
for i=1, #index_raw / 4 do
	index[i] = parse(index_raw:sub(i*4-3, i*4))
end

local offset = file:seek() -- Position of first data chunk

local chunks = {}
local chunks_delay = {}

local data = {}

minetest.register_on_mapgen_init(function(mgparams)
	minetest.set_mapgen_params({mgname="singlenode", flags="nolight"})
end)

local mapgens = 0
local time_sum = 0
local time_sum2 = 0

local function displaytime(time)
	return math.floor(time * 1000000 + 0.5) / 1000 .. " ms"
end

minetest.register_on_generated(function(minp, maxp, seed)
	print("[geo_mapgen] Generating from " .. minetest.pos_to_string(minp) .. " to " .. minetest.pos_to_string(maxp))
	local t0 = os.clock()

	local c_stone = minetest.get_content_id("default:stone")
	local c_dirt = minetest.get_content_id("default:dirt")
	local c_lawn = minetest.get_content_id("default:dirt_with_grass")
	local c_water = minetest.get_content_id("default:water_source")

	local xmin = math.max(minp.x, 0)
	local xmax = math.min(maxp.x, X)
	local zmin = math.max(minp.z, -Z) -- Reverse Z coordinates
	local zmax = math.min(maxp.z, 0)

	local vm, emin, emax = minetest.get_mapgen_object("voxelmanip")
	vm:get_data(data)
	local a = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local ystride = a.ystride

	for x = xmin, xmax do
	for z = zmin, zmax do
		local ivm = a:index(x, minp.y, z)

		local nchunk = math.floor(x / frag) + math.floor(-z / frag) * chunks_x + 1
		if not chunks[nchunk] then
			print("[geo_mapgen]   Loading chunk " .. nchunk)
			local t1 = os.clock()

			local address_min = index[nchunk-1] -- inclusive
			local address_max = index[nchunk] -- exclusive
			local count = address_max - address_min
			file:seek("set", offset + address_min)
			local data_raw = minetest.decompress(file:read(count))
			chunks[nchunk] = data_raw
			chunks_delay[nchunk] = remove_delay
			
			local t2 = os.clock()
			print("[geo_mapgen]   Loaded chunk " .. nchunk .. " in " .. displaytime(t2-t1))
		end

		local xpx = x % frag
		local zpx = -z % frag
		local npx = xpx + zpx * frag + 1

		local h = math.floor(parse(chunks[nchunk]:sub((npx-1)*itemsize + 1, npx*itemsize), signed) / scale)

		for y = minp.y, math.min(math.max(h, 0), maxp.y) do
			local node
			if h - y < 3 then
				if h == y and y >= 0 then
					node = c_lawn
				elseif y > h then
					node = c_water
				else
					node = c_dirt
				end
			else
				node = c_stone
			end
			data[ivm] = node
			ivm = ivm + ystride
		end
	end
	end

	vm:set_data(data)
	vm:set_lighting({day = 0, night = 0})
	vm:calc_lighting()
	vm:update_liquids()
	vm:write_to_map()

	local chunk_count = 0
	-- Decrease delay, remove chunks from cache when time is over
	for n, delay in pairs(chunks_delay) do
		if delay <= 1 then
			chunks[n] = nil
			chunks_delay[n] = nil
		else
			chunks_delay[n] = delay - 1
			chunk_count = chunk_count + 1
		end
	end

	local t3 = os.clock()
	local time = t3 - t0
	print("[geo_mapgen] Mapgen finished in " .. displaytime(time))
	print("[geo_mapgen] Cached chunks: " .. chunk_count)

	mapgens = mapgens + 1
	time_sum = time_sum + time
	time_sum2 = time_sum2 + time ^ 2
end)

minetest.register_on_shutdown(function()
	print("[geo_mapgen] Mapgen calls: " .. mapgens)
	local average = time_sum / mapgens
	print("[geo_mapgen] Average time: " .. displaytime(average))
	local stdev = math.sqrt(time_sum2 / mapgens - average ^ 2)
	print("[geo_mapgen] Standard dev: " .. displaytime(stdev))
end)
