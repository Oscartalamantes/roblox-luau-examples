-- ============================================================================
-- LeaderboardDemo (Server)
-- A clean, self-contained global top-10 leaderboard using OrderedDataStore.
--
-- HOW IT WORKS
--   1. This script builds the whole demo world on startup (baseplate, spawn,
--      leaderboard board, points pad) — no manual setup needed.
--   2. Clicking the green pad awards +10 points and saves to an
--      OrderedDataStore, so scores persist and are shared across servers.
--   3. The board refreshes live after every score change and every 20 seconds.
--
-- STUDIO NOTE: DataStores require "Enable Studio Access to API Services"
-- (Game Settings > Security) to work in Play Solo. Without it, the demo
-- falls back to in-memory scores so everything still works for testing.
-- ============================================================================

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local STORE_NAME = "LeaderboardDemo_Scores"
local POINTS_PER_CLICK = 10
local BOARD_REFRESH_SECONDS = 20
local TOP_COUNT = 10

-- ----------------------------------------------------------------------------
-- Score storage (OrderedDataStore with in-memory fallback for Studio)
-- ----------------------------------------------------------------------------
local store: OrderedDataStore? = nil
local storeOk, storeErr = pcall(function()
	store = DataStoreService:GetOrderedDataStore(STORE_NAME)
end)
if not storeOk then
	warn("[LeaderboardDemo] OrderedDataStore unavailable, using memory only: " .. tostring(storeErr))
end

local memory: { [number]: { name: string, score: number } } = {}

local function formatNumber(n: number): string
	n = math.floor(n)
	local s = tostring(n)
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return s .. out
end

-- Add points to a player's total (accumulates across sessions via DataStore).
-- refreshBoard is defined further below; forward-declared so this stays clean.
local refreshBoard: () -> ()

local function addPoints(player: Player, amount: number)
	local id = player.UserId
	local entry = memory[id] or { name = player.DisplayName, score = 0 }
	entry.name = player.DisplayName
	entry.score += amount
	memory[id] = entry

	if store then
		pcall(function()
			store:UpdateAsync(tostring(id), function(old)
				return (old or 0) + amount
			end)
		end)
	end
	refreshBoard()
end

-- Fetch the top N entries, highest score first.
local function getTop(count: number): { { name: string, score: number } }
	if store then
		local ok, pages = pcall(function()
			return store:GetSortedAsync(false, count)
		end)
		if ok and pages then
			local rows = {}
			for _, entry in ipairs(pages:GetCurrentPage()) do
				local userId = tonumber(entry.key) or 0
				local cached = memory[userId]
				local name = if cached then cached.name else ("Player " .. tostring(userId))
				table.insert(rows, { name = name, score = entry.value })
			end
			return rows
		end
	end
	-- Fallback: sort the in-memory table.
	local rows = {}
	for _, e in pairs(memory) do
		table.insert(rows, { name = e.name, score = e.score })
	end
	table.sort(rows, function(a, b) return a.score > b.score end)
	while #rows > count do
		table.remove(rows)
	end
	return rows
end

-- ----------------------------------------------------------------------------
-- World building
-- ----------------------------------------------------------------------------
local boardRows: { TextLabel } = {}

local function makeLabel(text: string, size: number, color: Color3, parent: Instance): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, size + 14)
	label.Font = Enum.Font.GothamBold
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Parent = parent
	return label
end

local function buildWorld()
	-- Baseplate
	local baseplate = Instance.new("Part")
	baseplate.Name = "Baseplate"
	baseplate.Size = Vector3.new(120, 2, 120)
	baseplate.Position = Vector3.new(0, -1, 0)
	baseplate.Anchored = true
	baseplate.Color = Color3.fromRGB(32, 34, 46)
	baseplate.Material = Enum.Material.SmoothPlastic
	baseplate.Parent = workspace

	-- Spawn
	local spawn = Instance.new("SpawnLocation")
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = Vector3.new(0, 0.5, 12)
	spawn.Anchored = true
	spawn.BrickColor = BrickColor.new("Medium stone grey")
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Parent = workspace

	-- Leaderboard board (faces the spawn; Front face = +Z toward the player)
	local board = Instance.new("Part")
	board.Name = "LeaderboardBoard"
	board.Size = Vector3.new(22, 15, 1)
	board.Position = Vector3.new(0, 9, -12)
	board.Anchored = true
	board.Color = Color3.fromRGB(18, 18, 26)
	board.Material = Enum.Material.SmoothPlastic
	board.Parent = workspace

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
	frame.BorderSizePixel = 0
	frame.Parent = board

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(1000, 680)
	gui.Parent = board
	frame.Parent = gui

	local title = makeLabel("🏆  GLOBAL LEADERBOARD", 52, Color3.fromRGB(255, 205, 90), frame)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Size = UDim2.new(1, 0, 0, 90)

	local goldBar = Instance.new("Frame")
	goldBar.Size = UDim2.new(1, 0, 0, 6)
	goldBar.BackgroundColor3 = Color3.fromRGB(255, 205, 90)
	goldBar.BorderSizePixel = 0
	goldBar.Parent = frame

	local list = Instance.new("Frame")
	list.Size = UDim2.new(1, -40, 1, -130)
	list.Position = UDim2.new(0, 20, 0, 110)
	list.BackgroundTransparency = 1
	list.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.Parent = list

	for i = 1, TOP_COUNT do
		local row = makeLabel("", 34, Color3.fromRGB(235, 235, 245), list)
		table.insert(boardRows, row)
	end

	-- Points pad: click it to earn points
	local pad = Instance.new("Part")
	pad.Name = "PointsPad"
	pad.Size = Vector3.new(8, 1, 8)
	pad.Position = Vector3.new(12, 0.5, 12)
	pad.Anchored = true
	pad.Color = Color3.fromRGB(40, 200, 90)
	pad.Material = Enum.Material.Neon
	pad.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 320, 0, 60)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.Adornee = pad
	billboard.Parent = pad

	local padLabel = Instance.new("TextLabel")
	padLabel.Size = UDim2.new(1, 0, 1, 0)
	padLabel.BackgroundTransparency = 1
	padLabel.Font = Enum.Font.GothamBlack
	padLabel.TextSize = 30
	padLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	padLabel.TextStrokeTransparency = 0.4
	padLabel.Text = "CLICK  +10 POINTS"
	padLabel.Parent = billboard

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 20
	click.Parent = pad

	local debounce: { [number]: number } = {}
	click.MouseClick:Connect(function(player)
		local now = os.clock()
		if (debounce[player.UserId] or 0) + 0.4 > now then
			return
		end
		debounce[player.UserId] = now
		addPoints(player, POINTS_PER_CLICK)
	end)
end

-- ----------------------------------------------------------------------------
-- Board refresh
-- ----------------------------------------------------------------------------
refreshBoard = function()
	local rows = getTop(TOP_COUNT)
	for i, rowLabel in ipairs(boardRows) do
		local row = rows[i]
		if row then
			local medal = if i == 1 then "🥇 " elseif i == 2 then "🥈 " elseif i == 3 then "🥉 " else ""
			rowLabel.Text = string.format("  %d.  %s%s   —   %s", i, medal, row.name, formatNumber(row.score))
			rowLabel.TextColor3 = if i <= 3 then Color3.fromRGB(255, 205, 90) else Color3.fromRGB(235, 235, 245)
		else
			rowLabel.Text = string.format("  %d.  ---", i)
			rowLabel.TextColor3 = Color3.fromRGB(120, 120, 140)
		end
	end
end

-- ----------------------------------------------------------------------------
-- Startup
-- ----------------------------------------------------------------------------
buildWorld()
refreshBoard()

Players.PlayerAdded:Connect(function()
	task.delay(1, refreshBoard)
end)
Players.PlayerRemoving:Connect(function()
	task.delay(1, refreshBoard)
end)

task.spawn(function()
	while true do
		task.wait(BOARD_REFRESH_SECONDS)
		pcall(refreshBoard)
	end
end)

print("[LeaderboardDemo] Ready — click the green pad to earn points.")
