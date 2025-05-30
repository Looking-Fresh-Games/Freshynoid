--[[
    Pathfinder.lua
    Author: Zach Curtis (InfinityDesign)

    Description: Path finding object.
]]
--

--Constants
local RETRY_DELAY = 0.075 -- Seconds between retrying a ComputeAsync()
local RETRY_COUNT = 5 -- How many times to retry solving the same path
local USE_DIJKSTRA = true -- Use Dijkstra for the backup pathfinding

-- Types
export type AgentParameters = {
	AgentRadius: number?,
	AgentHeight: number?,
	AgentCanJump: boolean?,
	AgentCanClimb: boolean?,
	WaypointSpacing: number?,
	Costs: { [string]: number }?,
}

-- Services
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local Dijkstra = require(script.Parent.Dijkstra)
local SmallOctree = require(script.Parent.SmallOctree)

-- Class
local Pathfinder = {}
Pathfinder.__index = Pathfinder

function Pathfinder.new(agentParameters: AgentParameters, backupGraph: any?)
	local self = setmetatable({}, Pathfinder)

	-- Refs
	self.AgentParameters = self:_getAgentParams(agentParameters)
	self.Path = PathfindingService:CreatePath(agentParameters)
	self.BackupGraph = backupGraph
	self.BackupOctree = SmallOctree.new()

	-- State
	self.Waypoints = {} :: { PathWaypoint }
	self.CurrentIndex = 1
	self.LastTarget = Vector3.zero
	self.UsingFallback = false

	return self
end

function Pathfinder:PathToPoint(startPoint: Vector3, targetPoint: Vector3): boolean
	self.LastTarget = targetPoint
	self.UsingFallback = false

	local attempts = 0
	local status, err

	repeat
		status, err = pcall(function()
			return self.Path:ComputeAsync(startPoint, targetPoint)
		end)

		attempts += 1

		if status == false then
			-- Only log in studio
			if RunService:IsStudio() then
				print(err)
			end

			task.wait(RETRY_DELAY)
		end
	until (
			status == true
			and self.Path
			and self.Path.Status == Enum.PathStatus.Success
		) or attempts > RETRY_COUNT
	-- or self.BackupGraph ~= nil

	-- print(`attempts to compute path: {attempts}`)

	local waypoints = self.Path:GetWaypoints()

	if
		self.Path
		and self.Path.Status
		and self.Path.Status == Enum.PathStatus.Success
		and #waypoints > 0
	then
		self.CurrentIndex = 1
		self.Waypoints = waypoints

		return true
	elseif self.BackupGraph ~= nil then
		self.UsingFallback = true

		-- Regen the octree
		if USE_DIJKSTRA then
			self.BackupOctree:ClearNodes()
			for _, node in self.BackupGraph.Nodes do
				self.BackupOctree:CreateNode(node.Data.Position, node)
			end
		end

		-- Get the start and end nodes
		local fallbackStart = USE_DIJKSTRA
			and self:_getNearestNodeFromTree(startPoint, 80)
		local fallbackEnd = fallbackStart
			and self:_getNearestNodeFromTree(targetPoint, 80)

		if fallbackStart and fallbackEnd then
			self.FallbackPoints = Dijkstra(self.BackupGraph, fallbackStart, fallbackEnd)
		else
			self.FallbackPoints = {
				{
					Position = startPoint,
					Action = Enum.PathWaypointAction.Jump,
					Label = "Fallback Start",
				},
				{
					Position = targetPoint,
					Action = Enum.PathWaypointAction.Jump,
					Label = "Fallback End",
				},
			}
		end

		return true
	end

	return false
end

function Pathfinder:GetNextWaypoint(): (Vector3?, Enum.PathWaypointAction?, string?)
	if #self.Waypoints == 0 or self.UsingFallback and #self.FallbackPoints == 0 then
		return nil
	end

	-- Increment the path
	self.CurrentIndex += 1

	if self.UsingFallback == true then
		if self.CurrentIndex > #self.FallbackPoints then
			return nil
		end

		return self.FallbackPoints[self.CurrentIndex].Position
	else
		if self.CurrentIndex > #self.Waypoints then
			return nil
		end

		local waypoint = self.Waypoints[self.CurrentIndex] :: PathWaypoint

		return waypoint.Position, waypoint.Action, waypoint.Label
	end
end

function Pathfinder:Destroy()
	if self._blocked and self._blocked.Connected then
		self._blocked:Disconnect()
	end

	self.Path = nil
	self.Waypoints = nil
end

function Pathfinder:_bindPathEvents(path: Path)
	if self._blocked and self._blocked.Connected then
		self._blocked:Disconnect()
	end

	self._blocked = path.Blocked:Connect(function(blockedIndex: number)
		-- Skip path blocks behind us
		if blockedIndex < self.CurrentIndex then
			return
		end

		-- Try to move from the next position to our original target
		local nextPoint = self:GetNextWaypoint()
		if nextPoint then
			self:PathToPoint(nextPoint, self.LastTarget)
		end
	end)
end

function Pathfinder:_getAgentParams(agentParams: AgentParameters)
	local defaultAgentParameters = {
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = false,
		AgentCanClimb = false,
		WaypointSpacing = 4,
		Costs = nil,
	}

	for key, value in defaultAgentParameters do
		if agentParams[key] == nil then
			agentParams[key] = value
		end
	end

	return agentParams
end

function Pathfinder:_getNearestNodeFromTree(point, radius)
	local lowestMagnitude, nearestNode = math.huge, nil

	local foundNodes = self.BackupOctree:RadiusSearch(point, radius)

	for _, node in foundNodes do
		local mag = (node.Data.Position - point).Magnitude
		if lowestMagnitude > mag then
			lowestMagnitude = mag
			nearestNode = node
		end
	end

	return nearestNode
end

return Pathfinder
