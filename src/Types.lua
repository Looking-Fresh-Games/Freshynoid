--[[
    Types.luau
    Author: Zach Curtis (InfinityDesign)

    Description: Type declaration file for Freshynoid.
]]--

-- Services
local StarterPlayer = game:GetService("StarterPlayer")


-- Modules
local NodeGraph = require(script.Parent.Packages.NodeGraph)
local Pathfinder = require(script.Parent.Pathfinder)


-- Default states, analogous to HumanoidStateType's. This can be overwritten, or joined.
export type DefaultStates = "Paused" | "Idle" | "Running" | "Swimming" | "Falling" | "Climbing" | "Dead"


export type FreshynoidConfiguration = {
    -- Optional pathfinding overrides; uses defaults if not set
    AgentParameters: Pathfinder.AgentParameters,

    -- Defaults to StarterPlayer.CharacterWalkSpeed.
    WalkSpeed: number?,

    RootPartName: string?,
    RootAttachment: Attachment?,
    BackupGraph: NodeGraph.NodeGraph?,
}

-- Default config used for fields not passed
local defaultConfiguration: FreshynoidConfiguration = {
    AgentParameters = {},
    WalkSpeed = StarterPlayer.CharacterWalkSpeed,
    RootPartName = "HumanoidRootPart",
    RootAttachment = false,
}


return {
    DefaultConfiguration = defaultConfiguration
}