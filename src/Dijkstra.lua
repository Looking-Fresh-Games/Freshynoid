--[[
    Dijkstra.lua
    Author: Zach (InfinityDesign)

    Description: Dijkstra's pathfinding applied to a weighted graph
]]--

-- Modules
local NodeGraph = require(script.Parent.Packages.NodeGraph)

-- Types
type DistanceHashmap = {[any]: number}

-- Utl Functions
local function getRecordLength(record: {[unknown]: unknown}, predicate: (unknown, unknown) -> boolean): number
    local len = 0

    for key, value in record do
        if predicate(key, value) then
            len += 1
        end
    end

    return len
end

local function filterHashmap<K, V>(t: {[K]: V}, predicate: (K, V) -> boolean): {[K]: V}
    local newT = {}

    for key, value in t do
        if predicate(key, value) then
            newT[key] = value
        end
    end

    return newT
end

local function getLowestKey(t: {})
    local lowestKey, lowestValue = nil, math.huge

    for key, value in t do
        if value < lowestValue then
            lowestValue = value
            lowestKey = key
        end
    end

    return lowestKey
end



-- Dijsktra's Algorithm

-- https://www.youtube.com/watch?v=GazC3A4OQTE
---@TODO: add comments documenting all this
local function dijkstra(graph: NodeGraph.NodeGraph, start: any, target: any)
    if start == target then
        return {{
            Node = start,
            Position = start.Data.Position
        }}
    end

    local distance: DistanceHashmap = {}
    local shortestPathNode = {}
    local unvisited: {[any]: boolean} = {}
    local finished: {[any]: boolean} = {}
    local currentNode = start

    for _, node in graph.Nodes do
        distance[node] = math.huge
        unvisited[node] = true
    end

    distance[start] = 0

    local function getUnvisitedNeighbors(node: any): {[number]: {Node: any, Weight: number}}
        local unvisitedNeighbors = {}
        local edges = graph:GetEdgesForNode(node)

        for _, edge in edges do
            local otherNode = edge.Node0

            if otherNode == node then
                otherNode = edge.Node1
            end

            if finished[otherNode] == true then
                continue
            end

            if unvisited[otherNode] == true then
                table.insert(unvisitedNeighbors, {
                    Node = otherNode,
                    Weight = edge.Weight
                })
            end
        end
        
        return unvisitedNeighbors
    end

    local function recursiveStepGraph()
        local culledDistance: DistanceHashmap = filterHashmap(distance, function(key, _value)
            return finished[key] ~= true
        end)

        currentNode = getLowestKey(culledDistance)

        if not currentNode then
            warn("no nodes were found that weren't in the finished hashmap")
            return table.clone(distance)

        elseif currentNode == target then
            return table.clone(distance)
        end

        local currentDistance = distance[currentNode]
        
        -- Remove this node from unvisted nodes
        unvisited[currentNode] = false

        local unvistedNeighbors = getUnvisitedNeighbors(currentNode) :: {[number]: {Node: any, Weight: number}}

        for _, neighbor in unvistedNeighbors do
            local newNeighborDistance = currentDistance + neighbor.Weight

            if distance[neighbor.Node] > newNeighborDistance then
                distance[neighbor.Node] = newNeighborDistance
                shortestPathNode[neighbor.Node] = currentNode
            end
        end

        finished[currentNode] = true
        
        local len = getRecordLength(unvisited, function(_key, value)
            return value
        end)
        
        if len > 0 then
            return recursiveStepGraph()
        else
            return table.clone(distance)
        end
    end

    -- Solve for final distance record
    local finalDistance = recursiveStepGraph()
    local currentReverseNode = target
    local reversePath = {target}

    local function recursivePopulateReversePath()
        local targetEdges = graph:GetEdgesForNode(currentReverseNode)
        local targetAdjacent = {} 
    
        for _, edge in targetEdges do
            if edge.Node0 == currentReverseNode then
                targetAdjacent[edge.Node1] = finalDistance[edge.Node1]
            else
                targetAdjacent[edge.Node0] = finalDistance[edge.Node0]
            end
        end

        currentReverseNode = getLowestKey(targetAdjacent)
        
        if not currentReverseNode then
            warn(`getLowestKeyWithIncludeList() returned no closest key!!!`)
            print(targetAdjacent)
            print(finalDistance)

            ---@TODO: toggle a path failed state?
        end
        
        table.insert(reversePath, currentReverseNode)

        if currentReverseNode ~= start then
            recursivePopulateReversePath()
        end
    end

    recursivePopulateReversePath()

    local waypoints = {}

    for i = #reversePath, 1, -1 do
        local waypoint = {
            Node = reversePath[i],
            Position = reversePath[i].Data.Position,
            Edge = i > 1 and graph:GetEdgeForNodes(reversePath[i], reversePath[i - 1]) or false
        }

        table.insert(waypoints, waypoint)
    end

    return waypoints
end

return dijkstra