--[[
    Freshynoid.lua
    Author: Zach Curtis (InfinityDesign)

    Description: AI NPC object. Uses a finite state machine to run ControllerManager instances. Pathfinds to a given target position.
]]

local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Pathfinder = require(script.Pathfinder)
local Signal = require(script.Signal)

local DEBUG = false
local UNSTUCK_TIME = 0.9
local MIN_AGENT_RADIUS = 2
local AGENT_RADIUS_PADDING = 1 -- Padding to prevent getting stuck on walls

local function debugPrint(...)
	if DEBUG then
		print(...)
	end
end

local function debugWarn(...)
	if DEBUG then
		warn(...)
	end
end

-- Default states, analogous to HumanoidStateType's. This can be overwritten, or joined.
export type DefaultStates =
	"Paused"
	| "Idle"
	| "Running"
	| "Swimming"
	| "Falling"
	| "Climbing"
	| "Dead"
export type FreshynoidConfiguration = {
	-- Optional pathfinding overrides; uses defaults if not set
	AgentParameters: Pathfinder.AgentParameters,

	-- Defaults to StarterPlayer.CharacterWalkSpeed.
	WalkSpeed: number?,
	WalkCycleSpeed: number?, -- The WalkSpeed that the walk cycle animations playback at when animation speed is 1.

	RootPartName: string?,
	RootAttachment: Attachment?,
	BackupGraph: any?,
}

-- Default config used for fields not passed
local DefaultConfiguration: FreshynoidConfiguration = {
	AgentParameters = {},
	WalkSpeed = StarterPlayer.CharacterWalkSpeed,
	RootPartName = "HumanoidRootPart",
	RootAttachment = false,
}

-- Refs
local rand = Random.new()

-- Class
local Freshynoid = {}
Freshynoid.__index = Freshynoid

function Freshynoid.new(character: Model, configuration: FreshynoidConfiguration)
	local self = setmetatable({}, Freshynoid)

	-- Events
	self.StateChanged = Signal.new()
	self.MoveToComplete = Signal.new() -- :: Signal.Signal<boolean>
	self.Stuck = Signal.new()

	-- Refs
	self.Character = character
	self.Configuration = self:_formatConfig(configuration) :: FreshynoidConfiguration
	self.Pathfinder =
		Pathfinder.new(self.Configuration.AgentParameters, self.Configuration.BackupGraph)
	self.AnimationTracks = {}
	self._thread = nil

	self.lastStuckAt = Workspace:GetServerTimeNow() - UNSTUCK_TIME -- When we last got stuck

	-- State
	self.FreshyState = "Paused" :: DefaultStates
	self.PlayingTrack = nil :: AnimationTrack?

	self.noPathAttempts = 0
	self.lastNoPathAt = 0

	self.lastPosition = Vector3.zero -- Last target position

	-- Setup
	self:_makeCharacterRefs()
	self:_bindAnimationSpeed()
	self:SetState("Idle")

	-- Connections
	self._stepped = nil :: RBXScriptConnection?

	return self
end

function Freshynoid:RegisterAnimations(stateName: string, Animations: { Animation })
	-- Don't double load
	if self.AnimationTracks[stateName] then
		return
	end

	self.AnimationTracks[stateName] = {}

	-- Get Animator to load tracks from
	local animator = self.Character:FindFirstChild("Animator", true) :: Animator?
	if not animator then
		return
	end

	-- Load the tracks
	for _, animation in Animations do
		table.insert(self.AnimationTracks[stateName], animator:LoadAnimation(animation))
	end
end

-- Set the current Freshynoid state. Fires a state changed event
function Freshynoid:SetState(newState: string & DefaultStates)
	-- Don't double set
	if self.FreshyState == newState then
		return
	end

	local oldState = self.FreshyState
	self.FreshyState = newState

	-- Stop the old track
	if self.PlayingTrack then
		self.PlayingTrack:Stop()
		self.PlayingTrack = nil
	end

	-- Play one or random animations
	if self.AnimationTracks[newState] then
		if #self.AnimationTracks[newState] == 1 then
			self.PlayingTrack = self.AnimationTracks[newState][1]
			self.PlayingTrack:Play()
		elseif #self.AnimationTracks[newState] > 1 then
			local index = rand:NextInteger(1, #self.AnimationTracks[newState])
			self.PlayingTrack = self.AnimationTracks[newState][index]
			self.PlayingTrack:Play()
		end
	end

	-- Tell the world
	self.StateChanged:Fire(oldState, newState)
end

-- Getter for uniformity
function Freshynoid:GetState()
	return self.FreshyState
end

-- Allows switching between a RootPart or RootAttachment for pathfinding position
function Freshynoid:GetRootPosition()
	if self.RootAttachment then
		return self.RootAttachment.WorldCFrame.Position
	else
		return self.RootPart.Position
	end
end

local testParts = {}

-- Given a point in world space, walk to it, with optional pathfinding
function Freshynoid:WalkToPoint(
	point: Vector3,
	shouldPathfind: boolean,
	automatedCall: boolean?
)
	if not automatedCall then
		self.noPathAttempts = 0
		self.lastNoPathAt = 0
	end

	debugWarn("moved 1", shouldPathfind, automatedCall)

	-- Track the last WalkToPoint call to prevent concurrent calls
	self._walkToPointToken = (self._walkToPointToken or 0) + 1
	local walkToken = self._walkToPointToken

	if not self.Manager then
		return
	end

	self:_stopStepping(false, 1)

	if self.FreshyState ~= "Running" and self.FreshyState ~= "Paused" then
		self:SetState("Running")
	end

	local currentPosition = self:GetRootPosition()
	local travelTime: number = (currentPosition - point).Magnitude
		/ (self.Configuration.WalkSpeed or 16)
	local startTime = os.clock()

	debugPrint("expected travel time:", travelTime)

	local startDirection = point - currentPosition

	if startDirection.Magnitude < 1 then
		debugPrint("point is too close, considering it reached")
		self.MoveToComplete:Fire()
		self.lastPosition = point -- Track last target position
		self.noPathAttempts = 0 -- Reset attempts only when target reached
		return
	end

	-- Just turn that direction and start moving
	if shouldPathfind == false then
		self._stepped = RunService.Heartbeat:Connect(function()
			if walkToken ~= self._walkToPointToken then
				self:_stopStepping(false, 2)
				return
			end
			-- Check to make sure we're still running
			if self.FreshyState ~= "Running" then
				self:_stopStepping(false, 3)
				return
			end

			local newDirection = point - self:GetRootPosition()

			-- Check for travelTime timeout
			if os.clock() - startTime > travelTime then
				self.Manager.MovingDirection = Vector3.zero
				debugPrint("estimated travel time exceeded, continuing")

				debugWarn("moved 2")

				-- Attempt to walk to the point again with pathfinding
				return self:WalkToPoint(point, true, true)
			end

			-- In range to advance to the next waypoint
			if newDirection.Magnitude <= 5 then
				-- Only stop if we're actually at the target point
				if newDirection.Magnitude <= 1 then
					self:_stopStepping(false, 5)
					self.MoveToComplete:Fire()
					self.lastPosition = point -- Track last target position
					self.noPathAttempts = 0 -- Reset attempts only when target reached
					return
				end
			end

			self:WalkInDirection(newDirection, true)

			return
		end)

		self:WalkInDirection(startDirection, true)

		return
	end

	if self._thread and coroutine.status(self._thread) == "suspended" then
		task.cancel(self._thread)
		self._thread = nil
	end

	-- Solve the path
	local madePath = self.Pathfinder:PathToPoint(currentPosition, point)

	if madePath == false then
		-- Teleport to the point if pathfinding fails
		local magnitude = (point - currentPosition).Magnitude

		if magnitude > 100 then
			debugPrint(
				"monster is out of bounds, teleporting to point",
				tostring(point),
				"current pos:",
				tostring(currentPosition)
			)
			self.Character:PivotTo(CFrame.new(point))
			self.MoveToComplete:Fire()
			return
		end

		debugPrint("could not find path to point", point)
		local now = os.clock()

		self.lastNoPathAt = now
		self.noPathAttempts += 1 -- Increment attempts on each failure

		debugPrint("no path attempts 1: ", self.noPathAttempts)

		if self.noPathAttempts > 2 then
			self.Stuck:Fire()
			debugPrint("STUCK")
			return
		end

		debugPrint("no path attempts 2:", self.noPathAttempts)

		debugWarn("walking backwards 000")
		self:WalkInDirection(self.Manager.MovingDirection * -1, false)

		self._thread = task.delay(0.2, function()
			if walkToken ~= self._walkToPointToken then
				return
			end
			self:WalkToPoint(point, false, true)
		end)

		return
	end

	-- For debugging path
	if DEBUG == true then
		for _, testPart in testParts do
			testPart:Destroy()
		end

		for _, waypoint: PathWaypoint in self.Pathfinder.Waypoints do
			local testPart = Instance.new("Part")
			testPart.Anchored = true
			testPart.CanCollide = false
			testPart.CanQuery = false
			testPart.CanTouch = false
			testPart.Shape = Enum.PartType.Ball
			testPart.Size = Vector3.new(1, 1, 1) * 0.4
			testPart.Color = Color3.new(1, 0, 0)
			testPart.CFrame = CFrame.new(waypoint.Position)

			local pathModifier = Instance.new("PathfindingModifier")
			pathModifier.PassThrough = true
			pathModifier.Parent = testPart

			testPart.Parent = Workspace

			table.insert(testParts, testPart)
		end
	end

	-- Hoisted above the stepped
	local nextWayPos, _nextAction, _nextLabel = self.Pathfinder:GetNextWaypoint()
	if not nextWayPos then
		debugPrint("walking backwards")
		-- self:WalkInDirection(self.Manager.MovingDirection * -1, false)

		-- self._thread = task.delay(0.2, function()
		-- 	if walkToken ~= self._walkToPointToken then
		-- 		return
		-- 	end
		-- 	self:WalkToPoint(point, false, true)
		-- end)
		self:_stopStepping(false, 19)
		self.MoveToComplete:Fire()
		self.lastPosition = point -- Track last target position
		self.noPathAttempts = 0 -- Reset attempts only when target reached
		return
	end

	-- Update loop
	if self._stepped and self._stepped.Connected then
		self._stepped:Disconnect()
		self._stepped = nil
	end

	self._stepped = RunService.Stepped:Connect(function()
		local _currentPosition = self:GetRootPosition()

		if walkToken ~= self._walkToPointToken then
			-- self:_stopStepping(true, 6)
			debugWarn("step 6 triggered")
			return
		end
		local now = Workspace:GetServerTimeNow()

		if now - self.lastStuckAt <= UNSTUCK_TIME then
			return
		end

		-- Check to make sure we're still running
		if self.FreshyState ~= "Running" or nextWayPos == nil then
			self:_stopStepping(true, 8)
			if self._thread and coroutine.status(self._thread) == "suspended" then
				task.cancel(self._thread)
				self._thread = nil
			end
			return
		end

		-- Timeout check
		if os.clock() - startTime > travelTime then
			self:_stopStepping(true, 7)
			self.MoveToComplete:Fire(true)
			self.lastPosition = point -- Track last target position
			self.noPathAttempts = 0 -- Reset attempts only when target reached
			return
		end

		-- In range to advance to the next waypoint
		if (_currentPosition - point).Magnitude <= 5 then
			self:_stopStepping(false, 20)
			self.MoveToComplete:Fire()
			self.lastPosition = point -- Track last target position
			self.noPathAttempts = 0 -- Reset attempts when advancing to next waypoint
			return
		end

		local direction = Vector3.new(nextWayPos.X, _currentPosition.Y, nextWayPos.Z)
			- _currentPosition
		local velocity = self.RootPart.AssemblyLinearVelocity.Magnitude

		if velocity < 1.1920928955078125e-07 then
			debugWarn("stuck!!!")
			self.lastStuckAt = now -- Reset unstuck timer
			self:WalkInDirection(-direction, true)
			return
		end

		-- In range to advance to the next waypoint
		-- Or if stuck, attempt to advance anyway
		if
			direction.Magnitude
			<= self.Pathfinder.AgentParameters.WaypointSpacing * 0.8
		then
			-- Updated hoisted targets
			nextWayPos, _nextAction, _nextLabel = self.Pathfinder:GetNextWaypoint()
			if not nextWayPos then
				self:_stopStepping(false, 9)
				self.MoveToComplete:Fire()
				self.lastPosition = point -- Track last target position
				self.noPathAttempts = 0 -- Reset attempts only when target reached
				return
			end
			self.noPathAttempts = 0 -- Reset attempts when advancing to next waypoint
		end

		debugWarn("moved 3")

		-- Head that way
		local newDirection = Vector3.new(nextWayPos.X, _currentPosition.Y, nextWayPos.Z)
			- _currentPosition
		self:WalkInDirection(newDirection, true)
	end)
end

-- Given a direction vector, walk the direction it points
function Freshynoid:WalkInDirection(direction: Vector3, keepWalking: boolean?)
	if direction.Magnitude > 1 then
		direction = direction.Unit
	end

	if not self.Manager then
		return
	end

	if self.FreshyState ~= "Running" then
		return
	end

	-- Stop moving first
	if not keepWalking then
		self:_stopStepping(false, 10)
	end

	-- Walk that way
	self.Manager.MovingDirection = direction

	-- Turn that direction
	if direction.Magnitude ~= 0 then
		self.Manager.FacingDirection = direction
	end
end

-- Cleanup
function Freshynoid:Destroy()
	-- Stop moving first
	self:_stopStepping(true, 11)

	if self._walkStepped and self._walkStepped.Connected then
		self._walkStepped:Disconnect()
		self._walkStepped = nil
	end

	self.FreshyState = "Dead"

	self.Pathfinder:Destroy()
end

-- Updates the walk cycle animation based on the current velocity
function Freshynoid:_bindAnimationSpeed()
	if not self.Configuration.WalkCycleSpeed then
		return
	end

	-- Helper utility to remove the Y component from velocity
	local function getHorizontalVelocity(velocity: Vector3): Vector3
		return Vector3.new(velocity.X, 0, velocity.Y)
	end

	-- Bind to heartbeat, shouldn't unbind until the class is destroyed
	self._walkStepped = RunService.Heartbeat:Connect(function(_deltaTime: number)
		if self.FreshyState ~= "Running" or self.PlayingTrack == nil then
			return
		end

		-- Remove y component from velocity then scale animation playback by the speed at which the animation foot plants
		local flatVelc =
			getHorizontalVelocity(self.RootPart.AssemblyLinearVelocity).Magnitude
		self.PlayingTrack:AdjustSpeed(flatVelc / self.Configuration.WalkCycleSpeed)
	end)
end

-- Disconnects the stepped event
function Freshynoid:_stopStepping(resetState: boolean, step)
	debugPrint("stopping at step:", step)
	if self._stepped and self._stepped.Connected then
		self._stepped:Disconnect()
		self._stepped = nil
	end

	if resetState and self.Manager and self.FreshyState == "Running" then
		self:SetState("Idle")
		self.Manager.MovingDirection = Vector3.zero
	end
end

-- Adds default values to config table
function Freshynoid:_formatConfig(configuration: FreshynoidConfiguration?)
	if not configuration then
		return table.clone(DefaultConfiguration)
	end

	-- Shallow copy filling in any omitted fields
	local newConfig = {}

	for key, value in DefaultConfiguration do
		if configuration[key] ~= nil then
			newConfig[key] = configuration[key]
		else
			newConfig[key] = value
		end
	end

	newConfig.BackupGraph = configuration.BackupGraph
	newConfig.WalkCycleSpeed = configuration.WalkCycleSpeed

	newConfig.AgentRadius = math.max(
		newConfig.AgentParameters.AgentRadius or 0,
		MIN_AGENT_RADIUS
	) * AGENT_RADIUS_PADDING

	return newConfig
end

-- Makes refs to character instances
function Freshynoid:_makeCharacterRefs()
	if not self.Character then
		return
	end

	-- Standard rig root part
	self.RootPart = self.Character:WaitForChild(self.Configuration.RootPartName)
	self.RootAttachment = self.Configuration.RootAttachment

	-- Controller manager stuff
	-- https://create.roblox.com/docs/physics/character-controllers
	self.Manager =
		self.Character:FindFirstChild("ControllerManager", true) :: ControllerManager?
	self.GroundController =
		self.Character:FindFirstChild("GroundController", true) :: GroundController?

	if self.Manager then
		self.Manager.BaseMoveSpeed = self.Configuration.WalkSpeed

		-- Don't have them all awkwardly spin north on spawn
		self.Manager.FacingDirection = self.RootPart.CFrame.LookVector
	end
end

return Freshynoid
