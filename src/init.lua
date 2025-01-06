--[[
    Freshynoid.lua
    Author: Zach Curtis (InfinityDesign)

    Description: AI NPC object. Uses a finite state machine to run ControllerManager instances. Pathfinds to a given target position. 
]]--

-- Constants
local DEBUG_PATH = false
local UNSTUCK_TIME = .9

-- Services
local RunService = game:GetService("RunService")

-- Modules
local Pathfinder = require(script.Pathfinder)
local Signal = require(script.Signal)
local TypeDefs = require(script:WaitForChild("Types"))

-- Refs
local rand = Random.new()

-- Class
local Freshynoid = {}
Freshynoid.__index = Freshynoid

function Freshynoid.new(character: Model, configuration: TypeDefs.FreshynoidConfiguration)
    local self = setmetatable({}, Freshynoid)

    -- Events
    self.StateChanged = Signal.new()
    self.MoveToComplete = Signal.new()

    -- Refs
    self.Character = character
    self.Configuration = self:_getConfiguration(configuration) :: TypeDefs.FreshynoidConfiguration
    self.Pathfinder = Pathfinder.new({AgentCanJump = false, AgentCanClimb = false})
    self.AnimationTracks = {}
    self._thread = nil
    self.UnstuckTimestamp = workspace:GetServerTimeNow() - UNSTUCK_TIME

    -- State
    self.FreshyState = "Paused"
    self.PlayingTrack = nil :: AnimationTrack?

    -- Setup
    self:_makeCharacterRefs()
    self:SetState("Idle")

    -- Connections
    self._stepped = nil :: RBXScriptConnection?

    return self
end

function Freshynoid:RegisterAnimations(stateName: string, Animations: {Animation})
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
function Freshynoid:SetState(newState: string & TypeDefs.DefaultStates)
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

-- Given a point in world space, walk to it, with optional pathfinding
function Freshynoid:WalkToPoint(point: Vector3, shouldPathfind: boolean)    
    if not self.Manager then
        return
    end

    self:_stopStepping(false)

    if self.FreshyState ~= "Running" and self.FreshyState ~= "Paused" then
        self:SetState("Running")
    end

    -- Just turn that direction and start moving
    if shouldPathfind == false then
        local direction = point - self.RootPart.Position
        self._stepped = RunService.Heartbeat:Connect(function()
            -- Check to make sure we're still running
            if self.FreshyState ~= "Running" then
                self:_stopStepping(false)
                return
            end

            local newDirection = point - self.RootPart.Position

            -- In range to advance to the next waypoint
            if newDirection.Magnitude <= 5 then
                self:_stopStepping(false)
                self.MoveToComplete:Fire()
            end
        end)

        self:WalkInDirection(direction, true)

        return
    end

    if self._thread and coroutine.status(self._thread) == "suspended" then
        task.cancel(self._thread)
        self._thread = nil
    end

    -- Solve the path
    local makePath = self.Pathfinder:PathToPoint(self.RootPart.Position, point)
    if makePath == false then
        self:WalkInDirection(self.Manager.MovingDirection * -1, false)
        
        self._thread = task.delay(.2, function()
            self:WalkToPoint(point, true)
        end)
        return
    end

    -- For debugging path
    if DEBUG_PATH == true then
        for _, waypoint: PathWaypoint in self.Pathfinder.Waypoints do
            local part = Instance.new("Part")
            part.Anchored = true
            part.CanCollide = false
            part.Shape = Enum.PartType.Ball
            part.Color = Color3.new(1, 0, 0)
            part.CFrame = CFrame.new(waypoint.Position)

            local pathModifier = Instance.new("PathfindingModifier")
            pathModifier.PassThrough = true
            pathModifier.Parent = part

            part.Parent = workspace
        end
    end

    -- Hoisted above the stepped
    local nextWayPos, _nextAction, _nextLabel = self.Pathfinder:GetNextWaypoint()
    if not nextWayPos then
        self:WalkInDirection(self.Manager.MovingDirection * -1, false)

        self._thread = task.delay(.2, function()
            self:WalkToPoint(point, true)
        end)
        return
    end

    -- Update loop
    self._stepped = RunService.Heartbeat:Connect(function()
        if workspace:GetServerTimeNow() - self.UnstuckTimestamp <= UNSTUCK_TIME then
            return
        end

        -- Check to make sure we're still running
        if self.FreshyState ~= "Running" or nextWayPos == nil then
            self:_stopStepping(true)
            if self._thread and coroutine.status(self._thread) == "suspended" then
                task.cancel(self._thread)
                self._thread = nil
            end
            return
        end


        local direction = Vector3.new(nextWayPos.X, self.RootPart.Position.Y, nextWayPos.Z) - self.RootPart.Position
        local velocity = self.RootPart.AssemblyLinearVelocity.Magnitude

        if velocity < 1.1920928955078125e-07 then
            self.UnstuckTimestamp = workspace:GetServerTimeNow()
            self:WalkInDirection(-direction, true)
            return
        end

        -- In range to advance to the next waypoint
        if direction.Magnitude <= self.Pathfinder.AgentParameters.WaypointSpacing * .8 then
            -- Updated hoisted targets
            nextWayPos, _nextAction, _nextLabel = self.Pathfinder:GetNextWaypoint()
            if not nextWayPos then
                self:_stopStepping(false)
                self.MoveToComplete:Fire()
                
                return
            end
        end

        -- Head that way
        local newDirection = Vector3.new(nextWayPos.X, self.RootPart.Position.Y, nextWayPos.Z) - self.RootPart.Position
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
        self:_stopStepping(false)
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
    self:_stopStepping(true)

    self.FreshyState = "Dead"

    self.Pathfinder:Destroy()  
end

-- Disconnects the stepped event
function Freshynoid:_stopStepping(resetState: boolean)
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
function Freshynoid:_getConfiguration(configuration: TypeDefs.FreshynoidConfiguration?)
    if not configuration then
       return table.clone(TypeDefs.DefaultConfiguration)
    end

    -- Shallow copy filling in any omitted fields
    local newConfig = {}

    for key, value in TypeDefs.DefaultConfiguration do
        if configuration[key] ~= nil then
            newConfig[key] = configuration[key]
        else
            newConfig[key] = value
        end
    end

    return newConfig
end

-- Makes refs to character instances
function Freshynoid:_makeCharacterRefs()
    if not self.Character then
        return
    end

    -- Standard rig root part
    self.RootPart = self.Character:WaitForChild(self.Configuration.RootPartName or "HumanoidRootPart")
 
    -- Controller manager stuff
    -- https://create.roblox.com/docs/physics/character-controllers
    self.Manager = self.Character:FindFirstChild("ControllerManager", true) :: ControllerManager?
    self.GroundController = self.Character:FindFirstChild("GroundController", true) :: GroundController?

    if self.Manager then
        self.Manager.BaseMoveSpeed = self.Configuration.WalkSpeed

        -- Don't have them all awkwardly spin north on spawn
        self.Manager.FacingDirection = self.RootPart.CFrame.LookVector
    end
end

return Freshynoid
