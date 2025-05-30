-- closure scoping reimplement of https://github.com/LPGhatguy/lemur/blob/master/lib/Signal.lua
local Signal = {}

local function listInsert(list, ...)
	local args = { ... }
	local newList = {}
	local listLen = #list

	for i = 1, listLen do
		newList[i] = list[i]
	end

	for i = 1, #args do
		newList[listLen + i] = args[i]
	end

	return newList
end

local function listValueRemove(list, value)
	local newList = {}

	for i = 1, #list do
		if list[i] ~= value then
			table.insert(newList, list[i])
		end
	end

	return newList
end

function Signal.new()
	local self = setmetatable({}, Signal)

	local boundCallbacks = {}
	local connections = {}

	function self:Connect(cb)
		boundCallbacks = listInsert(boundCallbacks, cb)

		local newConnection = { Disconnect = nil, Connected = true }

		local function disconnect()
			boundCallbacks = listValueRemove(boundCallbacks, cb)
			newConnection.Connected = false
		end

		newConnection.Disconnect = disconnect

		connections = listInsert(connections, newConnection)

		return newConnection
	end

	function self:Fire(...)
		for _index, callback in boundCallbacks do
			callback(...)
		end
	end

	function self:Destroy()
		for _, connection in connections do
			connection:Disconnect()
		end
	end

	function self:Wait()
		local thread: thread = coroutine.running()

		local connection

		connection = self:Connect(function(...)
			connection:Disconnect()
			coroutine.resume(thread, ...)
		end)

		return coroutine.yield()
	end

	return self
end

return Signal
