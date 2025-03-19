--[[
    Pathfinder.lua
    Author: Zach Curtis (InfinityDesign)

    Description: Path finding object.
]]--

--Constants
local RETRY_DELAY = .075 -- Seconds between retrying a ComputeAsync()
local RETRY_COUNT = 5 -- How many times to retry solving the same path

-- Types
export type AgentParameters = {
    AgentRadius: number?,
    AgentHeight: number?,
    AgentCanJump: boolean?,
    AgentCanClimb: boolean?,
    WaypointSpacing: number?,
    Costs: {[string]: number}?
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
    self.Waypoints = {} :: {PathWaypoint}
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
    until (status == true and self.Path.Status == Enum.PathStatus.Success) or attempts > RETRY_COUNT or self.BackupGraph ~= nil
    
    if self.Path.Status and self.Path.Status == Enum.PathStatus.Success then
        self.CurrentIndex = 1
        self.Waypoints = self.Path:GetWaypoints()

        return true
    elseif self.BackupGraph ~= nil then
        self.UsingFallback = true

        -- Regen the octree
        self.BackupOctree:ClearNodes()
        for _, node in self.BackupGraph.Nodes do
            self.BackupOctree:CreateNode(node.Data.Position, node)
        end

        -- Get the start and end nodes
        local fallbackStart = self:_getNearestNodeFromTree(startPoint, 80)
        local fallbackEnd = self:_getNearestNodeFromTree(targetPoint, 80)

        self.FallbackPoints = Dijkstra(self.BackupGraph, fallbackStart, fallbackEnd)

        return true
    elseif RunService:IsStudio() then
        warn(`Pathfind failed: {self.Path.Status.Name}`)
        return false
    else
        return false
    end
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
        AgentCanJump = true,
        AgentCanClimb = false,
        WaypointSpacing = 4,
        Costs = nil
    }

    for key, value in defaultAgentParameters do
        if agentParams[key] == nil then
            agentParams[key] = value
        end
    end

    return agentParams
end

function Pathfinder:_getNearestNodeFromTree(point, radius)
    local lowestMag, nearestNode = math.huge, nil

    local foundNodes = self.GraphTree:RadiusSearch(point, radius)
    for node, mag in foundNodes do
        if lowestMag > mag then
            lowestMag = mag
            nearestNode = node
        end
    end

    return nearestNode
end

return Pathfinder