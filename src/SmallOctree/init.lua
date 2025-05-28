-- From https://github.com/howmanysmall/SmallOctree

-- Octree implementation
-- classmod Octree

local GetNeighborsWithinRadius = require(script.GetNeighborsWithinRadius)
local OctreeNode = require(script.OctreeNode)

local EPSILON = 1E-9
local SQRT_3_OVER_2 = math.sqrt(3) / 2
local SUB_REGION_POSITION_OFFSET = {
	{ 0.25, 0.25, -0.25 },
	{ -0.25, 0.25, -0.25 },
	{ 0.25, 0.25, 0.25 },
	{ -0.25, 0.25, 0.25 },
	{ 0.25, -0.25, -0.25 },
	{ -0.25, -0.25, -0.25 },
	{ 0.25, -0.25, 0.25 },
	{ -0.25, -0.25, 0.25 },
}

local Octree = { ClassName = "Octree" }
Octree.__index = Octree

local OctreeNode_new = OctreeNode.new
local null = nil

type Array<Value> = { Value }
type Map<Index, Value> = { [Index]: Value }

export type OctreeNode = typeof(OctreeNode.new())
export type Region = {
	Depth: number,
	LowerBounds: Array<number>,
	NodeCount: number,
	Nodes: Map<OctreeNode, boolean>,
	Parent: Region?,
	ParentIndex: number?,
	Position: Array<number>,
	Size: Array<number>,
	SubRegions: Array<Region>,
	UpperBounds: Array<number>,
}

--[[**
	Creates a new Octree.
	@returns [t:Octree]
**--]]
function Octree.new()
	return setmetatable({
		--- @type integer
		MaxDepth = 4,

		--- @type Array
		MaxRegionSize = table.create(3, 512),
		RegionHashMap = {},
	}, Octree)
end

--[[**
	Clears the nodes of the Octree.
	@returns [t:void]
**--]]
function Octree:ClearNodes()
	self.MaxDepth = 4
	self.MaxRegionSize = table.create(3, 512)
	table.clear(self.RegionHashMap)
end

--[[**
	Gets an array of all the nodes in the Octree.
	@returns [t:array] An array of OctreeNodes.
**--]]
function Octree:GetAllNodes(): Array<OctreeNode>
	local Nodes = {}
	local Length = 0

	for _, RegionList in next, self.RegionHashMap do
		for _, Region in ipairs(RegionList) do
			for Node in next, Region.Nodes do
				Length += 1
				Nodes[Length] = Node
			end
		end
	end

	return Nodes
end

--[[**
	Creates a node at the given position.
	@param [t:Vector3] Position The position of the node.
	@param [t:any] Object The object value for the node.
	@returns [t:OctreeNode]
**--]]
function Octree:CreateNode(Position: Vector3, Object: any)
	if typeof(Position) ~= "Vector3" then
		error("Bad position value")
	end

	if not Object then
		error("Bad object value.")
	end

	local Node = OctreeNode_new(self, Object)
	Node:SetPosition(Position)
	return Node
end

--[[**
	Performs a radius search around the given position with the given radius.
	@param [t:Vector3] Position The position to search around.
	@param [t:number] Radius The radius for the search.
	@returns [t:{any},{number}] Returns the found objects and the distances.
**--]]
function Octree:RadiusSearch(
	Position: Vector3,
	Radius: number
): (Array<any>, Array<number>)
	if typeof(Position) ~= "Vector3" then
		error("Bad position value")
	end

	if type(Radius) ~= "number" then
		error("Bad radius value")
	end

	local PositionX = Position.X
	local PositionY = Position.Y
	local PositionZ = Position.Z

	local ObjectsFound = {}
	local NodeDistances2 = {}
	local ObjectsLength = 0
	local DistancesLength = 0

	local Diameter = self.MaxRegionSize[1]
	local SearchRadius = Radius + SQRT_3_OVER_2 * Diameter
	local SearchRadiusSquared = SearchRadius * SearchRadius + EPSILON
	local MaxDepth = self.MaxDepth

	for _, RegionList in next, self.RegionHashMap do
		for _, Region in ipairs(RegionList) do
			local RegionPosition = Region.Position
			local RegionPositionX = RegionPosition[1]
			local RegionPositionY = RegionPosition[2]
			local RegionPositionZ = RegionPosition[3]

			local OffsetX = PositionX - RegionPositionX
			local OffsetY = PositionY - RegionPositionY
			local OffsetZ = PositionZ - RegionPositionZ
			local Distance2 = OffsetX * OffsetX + OffsetY * OffsetY + OffsetZ * OffsetZ

			if Distance2 <= SearchRadiusSquared then
				ObjectsLength, DistancesLength = GetNeighborsWithinRadius(
					Region,
					Radius,
					PositionX,
					PositionY,
					PositionZ,
					ObjectsFound,
					NodeDistances2,
					MaxDepth,
					ObjectsLength,
					DistancesLength
				)
			end
		end
	end

	return ObjectsFound, NodeDistances2
end

local function NearestNeighborSort(A, B)
	return A.Distance2 < B.Distance2
end

--[[**
	Performs a k-nearest neighbors search around the given position with the given radius.
	@param [t:Vector3] Position The position to search around.
	@param [t:number] K The k value in k-nearest neighbors.
	@param [t:number] Radius The radius for the search.
	@returns [t:{any},{number}] Returns the found objects and the distances.
**--]]
function Octree:KNearestNeighborsSearch(
	Position: Vector3,
	K: number,
	Radius: number
): (Array<any>, Array<number>)
	if typeof(Position) ~= "Vector3" then
		error("Bad position value")
	end

	if type(Radius) ~= "number" then
		error("Bad radius value")
	end

	local PositionX = Position.X
	local PositionY = Position.Y
	local PositionZ = Position.Z

	local Objects = {}
	local NodeDistances2 = {}
	local ObjectsLength = 0
	local DistancesLength = 0

	local Diameter = self.MaxRegionSize[1]
	local SearchRadius = Radius + SQRT_3_OVER_2 * Diameter
	local SearchRadiusSquared = SearchRadius * SearchRadius + EPSILON
	local MaxDepth = self.MaxDepth

	for _, RegionList in next, self.RegionHashMap do
		for _, Region in ipairs(RegionList) do
			local RegionPosition = Region.Position
			local RegionPositionX = RegionPosition[1]
			local RegionPositionY = RegionPosition[2]
			local RegionPositionZ = RegionPosition[3]

			local OffsetX = PositionX - RegionPositionX
			local OffsetY = PositionY - RegionPositionY
			local OffsetZ = PositionZ - RegionPositionZ
			local Distance2 = OffsetX * OffsetX + OffsetY * OffsetY + OffsetZ * OffsetZ

			if Distance2 <= SearchRadiusSquared then
				ObjectsLength, DistancesLength = GetNeighborsWithinRadius(
					Region,
					Radius,
					PositionX,
					PositionY,
					PositionZ,
					Objects,
					NodeDistances2,
					MaxDepth,
					ObjectsLength,
					DistancesLength
				)
			end
		end
	end

	local Sortable = table.create(DistancesLength)
	for Index, Distance2 in ipairs(NodeDistances2) do
		Sortable[Index] = {
			Distance2 = Distance2,
			Index = Index,
		}
	end

	table.sort(Sortable, NearestNeighborSort)

	local ArrayLength = math.min(DistancesLength, K)
	local KNearest = table.create(ArrayLength)
	local KNearestDistance2 = table.create(ArrayLength)

	for Index = 1, ArrayLength do
		local Sorted = Sortable[Index]
		KNearestDistance2[Index] = Sorted.Distance2
		KNearest[Index] = Objects[Sorted.Index]
	end

	return KNearest, KNearestDistance2
end

local function GetOrCreateRegion(
	self,
	PositionX: number,
	PositionY: number,
	PositionZ: number
)
	local RegionHashMap = self.RegionHashMap
	local MaxRegionSize = self.MaxRegionSize
	local X = MaxRegionSize[1]
	local Y = MaxRegionSize[2]
	local Z = MaxRegionSize[3]

	local CX = math.floor(PositionX / X + 0.5)
	local CY = math.floor(PositionY / Y + 0.5)
	local CZ = math.floor(PositionZ / Z + 0.5)

	local Hash = CX * 73_856_093 + CY * 19_351_301 + CZ * 83_492_791

	local RegionList = RegionHashMap[Hash]
	if not RegionList then
		RegionList = {}
		RegionHashMap[Hash] = RegionList
	end

	local RegionPositionX = X * CX
	local RegionPositionY = Y * CY
	local RegionPositionZ = Z * CZ

	for _, Region in ipairs(RegionList) do
		local Position = Region.Position
		if
			Position[1] == RegionPositionX
			and Position[2] == RegionPositionY
			and Position[3] == RegionPositionZ
		then
			return Region
		end
	end

	local HalfSizeX = X / 2
	local HalfSizeY = Y / 2
	local HalfSizeZ = Z / 2

	local Region = {
		Depth = 1,
		LowerBounds = {
			RegionPositionX - HalfSizeX,
			RegionPositionY - HalfSizeY,
			RegionPositionZ - HalfSizeZ,
		},
		NodeCount = 0,
		Nodes = {}, -- [node] = true (contains subchild nodes too)
		Parent = null,
		ParentIndex = null,
		Position = { RegionPositionX, RegionPositionY, RegionPositionZ },
		Size = { X, Y, Z },
		SubRegions = {},
		UpperBounds = {
			RegionPositionX + HalfSizeX,
			RegionPositionY + HalfSizeY,
			RegionPositionZ + HalfSizeZ,
		},
	}

	table.insert(RegionList, Region)
	return Region
end

--[[**
	Gets or creates the lowest subregion.
	@param [t:number] PositionX The x-coordinate.
	@param [t:number] PositionY The y-coordinate.
	@param [t:number] PositionZ The z-coordinate.
	@returns [t:Region] Returns the lowest subregion.
**--]]
function Octree:GetOrCreateLowestSubRegion(
	PositionX: number,
	PositionY: number,
	PositionZ: number
): Region
	local Region = GetOrCreateRegion(self, PositionX, PositionY, PositionZ)
	local MaxDepth = self.MaxDepth
	local Current = Region

	for _ = Region.Depth, MaxDepth do
		local Position = Current.Position
		local CurrentX = Position[1]
		local CurrentY = Position[2]
		local CurrentZ = Position[3]

		local Index = PositionX > CurrentX and 1 or 2
		if PositionY <= CurrentY then
			Index += 4
		end

		if PositionZ >= CurrentZ then
			Index += 2
		end

		local SubRegions = Current.SubRegions
		local Next = SubRegions[Index]

		-- construct
		if not Next then
			local Size = Current.Size
			local Multiplier = SUB_REGION_POSITION_OFFSET[Index]

			local X = Size[1]
			local Y = Size[2]
			local Z = Size[3]

			local CurrentPositionX = CurrentX + Multiplier[1] * X
			local CurrentPositionY = CurrentY + Multiplier[2] * Y
			local CurrentPositionZ = CurrentZ + Multiplier[3] * Z

			local SizeX = X / 2
			local SizeY = Y / 2
			local SizeZ = Z / 2

			local HalfSizeX = SizeX / 2
			local HalfSizeY = SizeY / 2
			local HalfSizeZ = SizeZ / 2

			Next = {
				Depth = Current and Current.Depth + 1 or 1,
				LowerBounds = {
					CurrentPositionX - HalfSizeX,
					CurrentPositionY - HalfSizeY,
					CurrentPositionZ - HalfSizeZ,
				},
				NodeCount = 0,
				Nodes = {}, -- [node] = true (contains subchild nodes too)
				Parent = Current,
				ParentIndex = Index,
				Position = { CurrentPositionX, CurrentPositionY, CurrentPositionZ },
				Size = { SizeX, SizeY, SizeZ },
				SubRegions = {},
				UpperBounds = {
					CurrentPositionX + HalfSizeX,
					CurrentPositionY + HalfSizeY,
					CurrentPositionZ + HalfSizeZ,
				},
			}

			SubRegions[Index] = Next
		end

		-- iterate
		Current = Next
	end

	return Current
end

return Octree
