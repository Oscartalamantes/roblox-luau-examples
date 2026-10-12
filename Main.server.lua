-- ============================================================================
-- DataStoreDemo (Server)
-- A colorful coin-collector game showcasing DataStore persistence.
--
-- HOW IT WORKS
--   1. This script builds the whole demo world on startup (baseplate, plaza,
--      trees, spawn, coin spawners, reset pad) — no manual setup needed.
--   2. Walk over a coin to collect it: +1 session coin, sparkle burst, and a
--      new coin spawns elsewhere.
--   3. Coins (all-time total) and playtime save to a DataStore, so progress
--      persists across sessions. Autosaves every 30 seconds and on leave.
--   4. The on-screen stats panel shows session coins, all-time coins, and
--      playtime. The red RESET pad wipes a player's save (for testing).
--
-- STUDIO NOTE: DataStores require "Enable Studio Access to API Services"
-- (Game Settings > Security) to work in Play Solo. Without it, the demo
-- falls back to in-memory saves so everything still works for testing.
-- ============================================================================

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local STORE_NAME = "CoinCollector_Save_v1"
local COIN_COUNT = 12
local ARENA_HALF = 42
local SAVE_INTERVAL = 30

-- ----------------------------------------------------------------------------
-- Save storage (DataStore with in-memory fallback for Studio)
-- ----------------------------------------------------------------------------
local store: DataStore? = nil
local storeOk, storeErr = pcall(function()
	store = DataStoreService:GetDataStore(STORE_NAME)
end)
if not storeOk then
	warn("[DataStoreDemo] DataStore unavailable, using memory only: " .. tostring(storeErr))
end

local memory: { [string]: { coins: number, playtime: number } } = {}

-- Per-player session state (declared early; handlers below run at runtime).
-- updateStatsGui is defined further down; forward-declared so coin/reset
-- handlers can call it.
local session: { [Player]: { sessionCoins: number, totalCoins: number, playtime: number, joinTime: number } } = {}
local updateStatsGui: (player: Player) -> ()

local function saveKey(player: Player): string
	return "player_" .. player.UserId
end

local function loadSave(player: Player): { coins: number, playtime: number }
	local key = saveKey(player)
	if store then
		local ok, data = pcall(function()
			return store:GetAsync(key)
		end)
		if ok and type(data) == "table" then
			return {
				coins = tonumber(data.coins) or 0,
				playtime = tonumber(data.playtime) or 0,
			}
		end
	end
	local m = memory[key]
	if m then
		return { coins = m.coins, playtime = m.playtime }
	end
	return { coins = 0, playtime = 0 }
end

local function writeSave(player: Player, data: { coins: number, playtime: number })
	local key = saveKey(player)
	memory[key] = { coins = data.coins, playtime = data.playtime }
	if store then
		pcall(function()
			store:SetAsync(key, { coins = data.coins, playtime = data.playtime })
		end)
	end
end

-- ----------------------------------------------------------------------------
-- Small part factory
-- ----------------------------------------------------------------------------
local function P(className: string, props: { [string]: any }, parent: Instance?): Instance
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- ----------------------------------------------------------------------------
-- World building
-- ----------------------------------------------------------------------------
local world = P("Folder", { Name = "CoinWorld" }, workspace)

-- Baseplate: bright grass
P("Part", {
	Name = "Baseplate",
	Size = Vector3.new(100, 1, 100),
	Position = Vector3.new(0, -0.5, 0),
	Anchored = true,
	Material = Enum.Material.Grass,
	BrickColor = BrickColor.new("Bright green"),
}, world)

-- Central plaza (square slab)
P("Part", {
	Name = "Plaza",
	Size = Vector3.new(24, 1.2, 24),
	Position = Vector3.new(0, 0.1, 0),
	Anchored = true,
	Material = Enum.Material.SmoothPlastic,
	BrickColor = BrickColor.new("Light stone grey"),
}, world)

-- Decorative trees (trunk + leaf ball)
local treeSpots = {
	Vector3.new(-30, 0, -30), Vector3.new(30, 0, -30),
	Vector3.new(-30, 0, 30), Vector3.new(30, 0, 30),
	Vector3.new(0, 0, -38), Vector3.new(0, 0, 38),
}
for _, spot in ipairs(treeSpots) do
	P("Part", {
		Size = Vector3.new(1.5, 6, 1.5),
		Position = spot + Vector3.new(0, 3, 0),
		Anchored = true,
		Material = Enum.Material.Wood,
		BrickColor = BrickColor.new("Reddish brown"),
	}, world)
	P("Part", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(7, 7, 7),
		CFrame = CFrame.new(spot + Vector3.new(0, 8.5, 0)),
		Anchored = true,
		Material = Enum.Material.Grass,
		BrickColor = BrickColor.new("Dark green"),
	}, world)
end

-- Spawn
P("SpawnLocation", {
	Size = Vector3.new(6, 1, 6),
	Position = Vector3.new(0, 0.5, 0),
	Anchored = true,
	Material = Enum.Material.SmoothPlastic,
	BrickColor = BrickColor.new("Bright blue"),
	Neutral = true,
}, world)

-- ----------------------------------------------------------------------------
-- Coins
-- ----------------------------------------------------------------------------
local coinFolder = P("Folder", { Name = "Coins" }, world)

local function randomSpot(): Vector3
	return Vector3.new(
		math.random(-ARENA_HALF, ARENA_HALF),
		2.2,
		math.random(-ARENA_HALF, ARENA_HALF)
	)
end

local function spawnCoin()
	local coin = P("Part", {
		Name = "Coin",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 2.4, 2.4),
		CFrame = CFrame.new(randomSpot()) * CFrame.Angles(0, 0, math.pi / 2),
		Anchored = true,
		CanCollide = false,
		Material = Enum.Material.Neon,
		BrickColor = BrickColor.new("Bright yellow"),
	}, coinFolder)

	-- Sparkle particles for screenshot pop
	P("ParticleEmitter", {
		Rate = 12,
		Lifetime = NumberRange.new(0.6, 1.1),
		Speed = NumberRange.new(1, 3),
		Size = NumberSequence.new(0.35),
		Transparency = NumberSequence.new(0.2),
		Color = ColorSequence.new(Color3.fromRGB(255, 230, 120)),
		LightEmission = 1,
	}, coin)

	-- Gentle spin so coins catch the eye
	task.spawn(function()
		while coin.Parent do
			coin.CFrame *= CFrame.Angles(0, math.rad(3), 0)
			task.wait()
		end
	end)

	local debounce = false
	coin.Touched:Connect(function(hit)
		if debounce then
			return
		end
		local character = hit.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		if not player then
			return
		end
		debounce = true

		local data = session[player]
		if data then
			data.sessionCoins += 1
			data.totalCoins += 1
			updateStatsGui(player)
		end

		-- Collect burst
		local burst = P("ParticleEmitter", {
			Rate = 0,
			Lifetime = NumberRange.new(0.4, 0.8),
			Speed = NumberRange.new(6, 12),
			Size = NumberSequence.new(0.5),
			Transparency = NumberSequence.new(0.1),
			Color = ColorSequence.new(Color3.fromRGB(255, 220, 80)),
			LightEmission = 1,
		}, coin)
		burst:Emit(24)

		coin.Transparency = 1
		task.wait(0.15)
		coin:Destroy()
		task.wait(1.5)
		spawnCoin()
	end)
end

for _ = 1, COIN_COUNT do
	spawnCoin()
end

-- ----------------------------------------------------------------------------
-- Reset pad (red, labeled)
-- ----------------------------------------------------------------------------
local resetPad = P("Part", {
	Name = "ResetPad",
	Size = Vector3.new(8, 1, 8),
	Position = Vector3.new(0, 0.5, 30),
	Anchored = true,
	Material = Enum.Material.Neon,
	BrickColor = BrickColor.new("Bright red"),
}, world)

local resetLabel = P("SurfaceGui", {
	Face = Enum.NormalId.Top,
}, resetPad)
P("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "RESET DATA",
	Font = Enum.Font.GothamBlack,
	TextSize = 28,
	TextColor3 = Color3.fromRGB(255, 255, 255),
}, resetLabel)

P("ClickDetector", { MaxActivationDistance = 12 }, resetPad).MouseClick:Connect(function(player)
	local data = session[player]
	if data then
		data.sessionCoins = 0
		data.totalCoins = 0
		data.playtime = 0
		data.joinTime = os.clock()
		writeSave(player, { coins = 0, playtime = 0 })
		updateStatsGui(player)
	end
end)

-- ----------------------------------------------------------------------------
-- Per-player session + stats GUI
-- (session table and updateStatsGui forward-declared near the top)

local function formatTime(sec: number): string
	sec = math.floor(sec)
	local m = math.floor(sec / 60)
	local s = sec % 60
	return string.format("%02d:%02d", m, s)
end

updateStatsGui = function(player: Player)
	local data = session[player]
	local playerGui = player:FindFirstChild("PlayerGui")
	local gui = playerGui and playerGui:FindFirstChild("StatsGui")
	if not data or not gui then
		return
	end
	local main = (gui :: any).Main
	main.SessionLabel.Text = "🪙 Session: " .. data.sessionCoins
	main.TotalLabel.Text = "💰 Total: " .. data.totalCoins
	main.TimeLabel.Text = "⏱️ Playtime: " .. formatTime(data.playtime + (os.clock() - data.joinTime))
end

local function buildStatsGui(player: Player)
	local gui = P("ScreenGui", { Name = "StatsGui", ResetOnSpawn = false }, player:WaitForChild("PlayerGui"))

	local main = P("Frame", {
		Name = "Main",
		Size = UDim2.new(0, 230, 0, 150),
		Position = UDim2.new(0, 16, 0, 16),
		BackgroundColor3 = Color3.fromRGB(20, 20, 28),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
	}, gui)
	P("UICorner", { CornerRadius = UDim.new(0, 12) }, main)
	P("UIStroke", {
		Color = Color3.fromRGB(255, 200, 60),
		Thickness = 2,
		Transparency = 0.3,
	}, main)

	P("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundTransparency = 1,
		Text = "💰 COIN COLLECTOR",
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		TextColor3 = Color3.fromRGB(255, 210, 90),
	}, main)

	P("TextLabel", {
		Name = "SessionLabel",
		Size = UDim2.new(1, -20, 0, 30),
		Position = UDim2.new(0, 10, 0, 38),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🪙 Session: 0",
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		TextColor3 = Color3.fromRGB(255, 255, 255),
	}, main)

	P("TextLabel", {
		Name = "TotalLabel",
		Size = UDim2.new(1, -20, 0, 30),
		Position = UDim2.new(0, 10, 0, 70),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "💰 Total: 0",
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		TextColor3 = Color3.fromRGB(255, 255, 255),
	}, main)

	P("TextLabel", {
		Name = "TimeLabel",
		Size = UDim2.new(1, -20, 0, 30),
		Position = UDim2.new(0, 10, 0, 102),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "⏱️ Playtime: 00:00",
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		TextColor3 = Color3.fromRGB(255, 255, 255),
	}, main)

	-- "Saved ✓" indicator
	P("TextLabel", {
		Name = "SavedLabel",
		Size = UDim2.new(0, 230, 0, 24),
		Position = UDim2.new(0, 16, 0, 172),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "✓ progress auto-saves",
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(120, 220, 120),
	}, gui)
end

-- ----------------------------------------------------------------------------
-- Player lifecycle
-- ----------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	local save = loadSave(player)
	session[player] = {
		sessionCoins = 0,
		totalCoins = save.coins,
		playtime = save.playtime,
		joinTime = os.clock(),
	}
	buildStatsGui(player)
	updateStatsGui(player)

	-- Tick the playtime display + periodic autosave
	task.spawn(function()
		while session[player] do
			task.wait(1)
			if session[player] then
				updateStatsGui(player)
			end
		end
	end)
end

local function persistPlayer(player: Player)
	local data = session[player]
	if not data then
		return
	end
	local total = data.playtime + (os.clock() - data.joinTime)
	writeSave(player, { coins = data.totalCoins, playtime = math.floor(total) })
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	persistPlayer(player)
	session[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- Autosave loop
task.spawn(function()
	while true do
		task.wait(SAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			persistPlayer(player)
		end
	end
end)

print("[DataStoreDemo] Ready — collect coins, watch them persist.")
