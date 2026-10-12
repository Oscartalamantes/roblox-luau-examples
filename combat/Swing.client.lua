-- Swing.client.lua
-- Client-side arm swing, triggered by the server via SwingEvent.
-- Uses BindToRenderStep at Last priority so our joint offsets apply
-- AFTER the Animator evaluates each frame.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local swingEvent = ReplicatedStorage:WaitForChild("SwingEvent")

local swinging = false

local function getShoulder(character: Model): Motor6D?
	local rUpperArm = character:FindFirstChild("RightUpperArm")
	if rUpperArm then
		local s = rUpperArm:FindFirstChild("RightShoulder")
		if s and s:IsA("Motor6D") then
			return s :: Motor6D
		end
	end
	local torso = character:FindFirstChild("Torso")
	if torso then
		local s2 = torso:FindFirstChild("Right Shoulder")
		if s2 and s2:IsA("Motor6D") then
			return s2 :: Motor6D
		end
	end
	return nil
end

local function playSwing()
	if swinging then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local shoulder = getShoulder(character)
	if not shoulder then
		return
	end
	swinging = true

	local m = shoulder :: Motor6D
	local dur = 0.3
	local t0 = os.clock()

	RunService:BindToRenderStep("SwordSwing", Enum.RenderPriority.Last.Value, function()
		local t = (os.clock() - t0) / dur
		if t >= 1 or not m.Parent then
			RunService:UnbindFromRenderStep("SwordSwing")
			if m.Parent then
				m.Transform = CFrame.new()
			end
			swinging = false
			return
		end
		-- Big arm swing: wind up high, slash down through
		local ang: number
		if t < 0.35 then
			ang = math.rad(-150 * (t / 0.35))
		else
			local st = (t - 0.35) / 0.65
			ang = math.rad(-150 + 195 * st * st)
		end
		m.Transform = CFrame.Angles(ang, 0, 0)
	end)
end

(swingEvent :: RemoteEvent).OnClientEvent:Connect(playSwing)
