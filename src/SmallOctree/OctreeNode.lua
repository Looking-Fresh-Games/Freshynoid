-- Basic node interacting with the octree
-- classmod OctreeNode

local OctreeNode = {ClassName = "OctreeNode"}
OctreeNode.__index = OctreeNode

local null = nil

function OctreeNode.new(Octree, Object)
	return setmetatable({
		-- Public
		Object = Object or error("No object");

		-- @type Vector3
		Position = null;

		-- Private
		CurrentLowestRegion = null;
		Octree = Octree or error("No octree");

		-- @type number
		PositionX = null;

		-- @type number
		PositionY = null;

		-- @type number
		PositionZ = null;
	}, OctreeNode)
end

function OctreeNode:KNearestNeighborsSearch(K: number, Radius: number)
	return self.Octree:KNearestNeighborsSearch(self.Position, K, Radius)
end

function OctreeNode:GetObject()
	warn("OctreeNode:GetObject is deprecated.")
	return self.Object
end

function OctreeNode:RadiusSearch(Radius: number)
	return self.Octree:RadiusSearch(self.Position, Radius)
end

function OctreeNode:GetPosition(): Vector3
	warn("OctreeNode:GetPosition is deprecated.")
	return self.Position
end

function OctreeNode:GetRawPosition(): (number, number, number)
	return self.PositionX, self.PositionY, self.PositionZ
end

function OctreeNode:SetPosition(Position: Vector3)
	if self.Position == Position then
		return
	end

	local PositionX = Position.X
	local PositionY = Position.Y
	local PositionZ = Position.Z

	self.PositionX = PositionX
	self.PositionY = PositionY
	self.PositionZ = PositionZ
	self.Position = Position

	if self.CurrentLowestRegion then
		local Region = self.CurrentLowestRegion
		local LowerBounds = Region.LowerBounds
		local UpperBounds = Region.UpperBounds
		if
			PositionX >= LowerBounds[1]
			and PositionX <= UpperBounds[1]
			and PositionY >= LowerBounds[2]
			and PositionY <= UpperBounds[2]
			and PositionZ >= LowerBounds[3]
			and PositionZ <= UpperBounds[3]
		then
			return
		end
	end

	local NewLowestRegion = self.Octree:GetOrCreateLowestSubRegion(PositionX, PositionY, PositionZ)
	if self.CurrentLowestRegion then
		local FromLowest = self.CurrentLowestRegion
		if FromLowest.Depth ~= NewLowestRegion.Depth then
			error("FromLowest.Depth ~= ToLowest.Depth")
		end

		if FromLowest == NewLowestRegion then
			error("FromLowest == ToLowest")
		end

		local CurrentFrom = FromLowest
		local CurrentTo = NewLowestRegion

		while CurrentFrom ~= CurrentTo do
			-- remove from current
			local CurrentFromNodes = CurrentFrom.Nodes
			if not CurrentFromNodes[self] then
				error("CurrentFrom.Nodes doesn't have a node here.")
			end

			local NodeCount = CurrentFrom.NodeCount
			if NodeCount <= 0 then
				error("NodeCount is <= 0.")
			end

			NodeCount -= 1
			CurrentFromNodes[self] = null
			CurrentFrom.NodeCount = NodeCount

			-- remove subregion!
			local ParentIndex = CurrentFrom.ParentIndex
			if NodeCount <= 0 and ParentIndex then
				local Parent = CurrentFrom.Parent
				if not Parent then
					error("CurrentFrom.Parent doesn't exist.")
				end

				local SubRegions = Parent.SubRegions
				if SubRegions[ParentIndex] ~= CurrentFrom then
					error("Failed equality check.")
				end

				SubRegions[ParentIndex] = null
			end

			local CurrentToNodes = CurrentTo.Nodes
			if CurrentToNodes[self] then
				error("CurrentTo.Nodes already has a node here.")
			end

			CurrentToNodes[self] = self
			CurrentTo.NodeCount += 1

			CurrentFrom = CurrentFrom.Parent
			CurrentTo = CurrentTo.Parent
		end
	else
		local Current = NewLowestRegion
		while Current do
			local CurrentNodes = Current.Nodes
			if not CurrentNodes[self] then
				CurrentNodes[self] = self
				Current.NodeCount += 1
			end

			Current = Current.Parent
		end
	end

	self.CurrentLowestRegion = NewLowestRegion
end

function OctreeNode:Destroy()
	local LowestSubregion = self.CurrentLowestRegion
	if LowestSubregion then
		local Current = LowestSubregion

		while Current do
			local CurrentNodes = Current.Nodes
			if not CurrentNodes[self] then
				error("CurrentFrom.Nodes doesn't have a node here.")
			end

			local NodeCount = Current.NodeCount
			if NodeCount <= 0 then
				error("NodeCount is <= 0.")
			end

			NodeCount -= 1
			CurrentNodes[self] = null
			Current.NodeCount = NodeCount

			-- remove subregion!
			local Parent = Current.Parent
			local ParentIndex = Current.ParentIndex
			if NodeCount <= 0 and ParentIndex then
				if not Parent then
					error("Current.Parent doesn't exist.")
				end

				local SubRegions = Parent.SubRegions
				if SubRegions[ParentIndex] ~= Current then
					error("Failed equality check.")
				end

				SubRegions[ParentIndex] = null
			end

			Current = Parent
		end
	end
end

return OctreeNode