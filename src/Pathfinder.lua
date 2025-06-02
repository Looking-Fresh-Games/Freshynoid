--[[
    Pathfinder.lua
    Author: Zach Curtis (InfinityDesign)

    Description: Path finding object.
]]

--!strict

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

local function getAgentParams(agentParams: AgentParameters): AgentParameters
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

-- Class
local Pathfinder = {}
Pathfinder.__index = Pathfinder

export type FallbackPoint = {
	Position: Vector3,
	Action: Enum.PathWaypointAction?,
	Label: string?,
}

export type Pathfinder = typeof(setmetatable(
	{} :: {
		AgentParameters: AgentParameters,
		Path: Path,
		BackupGraph: any?,
		BackupOctree: any,

		Waypoints: { PathWaypoint },
		CurrentIndex: number,
		LastTarget: Vector3,
		UsingFallback: boolean,

		FallbackPoints: { FallbackPoint }?,

		_blocked: RBXScriptConnection?,
	},
	Pathfinder
))

function Pathfinder.new(agentParameters: AgentParameters, backupGraph: any?): Pathfinder
	local self = setmetatable({
		-- Refs
		AgentParameters = getAgentParams(agentParameters),
		Path = PathfindingService:CreatePath(agentParameters),
		BackupGraph = backupGraph,
		BackupOctree = SmallOctree.new(),

		-- State
		Waypoints = {},
		CurrentIndex = 1,
		LastTarget = Vector3.zero,
		UsingFallback = false,
	}, Pathfinder) :: Pathfinder

	return self
end

function Pathfinder.PathToPoint(
	self: Pathfinder,
	startPoint: Vector3,
	targetPoint: Vector3
): boolean
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

function Pathfinder.GetNextWaypoint(
	self: Pathfinder
): (Vector3?, Enum.PathWaypointAction?, string?)
	if self.UsingFallback then
		if not self.FallbackPoints or #self.FallbackPoints == 0 then
			return nil
		end

		-- Save the first point before removing it
		local point = self.FallbackPoints[1]

		table.remove(self.FallbackPoints, 1)

		return point.Position, point.Action, point.Label
	end

	if not self.Waypoints or #self.Waypoints == 0 then
		return nil
	end

	-- Save the first point before removing it
	local waypoint: PathWaypoint = self.Waypoints[1]

	table.remove(self.Waypoints, 1)

	return waypoint.Position, waypoint.Action, waypoint.Label
end

function Pathfinder.Destroy(self: Pathfinder)
	if self._blocked and self._blocked.Connected then
		self._blocked:Disconnect()
	end
end

function Pathfinder._bindPathEvents(self: Pathfinder, path: Path)
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

function Pathfinder._getNearestNodeFromTree(self: Pathfinder, point, radius)
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
