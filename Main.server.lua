-- ============================================================================
-- ShopDemo (Server)
-- Working shop backend: coin currency persisted in a DataStore, server-side
-- purchase validation, and trail equipping on the player's character.
--
-- ARCHITECTURE
--   ReplicatedStorage remotes (created here):
--     ShopBuy   (RemoteEvent,  client -> server, itemId: string)
--     ShopEquip (RemoteEvent,  client -> server, itemId: string; "" = unequip)
--     ShopSync  (RemoteEvent,  server -> client, state table)
--   Client never trusts its own copy of coins/ownership — the server is the
--   single source of truth and pushes the full state after every change.
--
-- STUDIO NOTE: like the leaderboard demo, this works in Play Solo without
-- API access via an in-memory fallback.
-- ============================================================================

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopItems = require(Shared:WaitForChild("ShopItems"))

local STORE_NAME = "ShopDemo_v1"
local STARTING_COINS = 250
local COINS_PER_CLICK = 100
local SAVE_THROTTLE_SECONDS = 20

export type PlayerData = {
	coins: number,
	owned: { [string]: boolean },
	equipped: string?, -- item id or nil
}

-- ----------------------------------------------------------------------------
-- Persistence (DataStore with in-memory fallback)
-- ----------------------------------------------------------------------------
local store: DataStore? = nil
local storeOk, storeErr = pcall(function()
	store = DataStoreService:GetDataStore(STORE_NAME)
end)
if not storeOk then
	warn("[ShopDemo] DataStore unavailable, using memory only: " .. tostring(storeErr))
end

local data: { [number]: PlayerData } = {} -- [userId] = PlayerData
local lastSave: { [number]: number } = {}

local function defaultData(): PlayerData
	return { coins = STARTING_COINS, owned = {}, equipped = nil }
end

local function loadData(player: Player): PlayerData
	local key = "p_" .. player.UserId
	local loaded: PlayerData? = nil
	if store then
		pcall(function()
			loaded = store:GetAsync(key)
		end)
	end
	local d = loaded or defaultData()
	-- Sanitize anything that came back from the store.
	d.coins = math.max(0, math.floor(tonumber(d.coins) or STARTING_COINS))
	d.owned = if typeof(d.owned) == "table" then d.owned else {}
	if d.equipped ~= nil and not ShopItems.getById(d.equipped) then
		d.equipped = nil
	end
	-- Drop owned flags for items that no longer exist in the catalog.
	for id in pairs(d.owned) do
		if not ShopItems.getById(id) then
			d.owned[id] = nil
		end
	end
	data[player.UserId] = d
	return d
end

local function saveData(player: Player, force: boolean)
	local d = data[player.UserId]
	if not d or not store then
		return
	end
	local now = os.clock()
	if not force and (lastSave[player.UserId] or 0) + SAVE_THROTTLE_SECONDS > now then
		return
	end
	lastSave[player.UserId] = now
	pcall(function()
		store:SetAsync("p_" .. player.UserId, d)
	end)
end

-- ----------------------------------------------------------------------------
-- Remotes
-- ----------------------------------------------------------------------------
local function getOrCreateRemote(name: string, className: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then
		return existing :: RemoteEvent
	end
	local r = Instance.new(className)
	r.Name = name
	r.Parent = ReplicatedStorage
	return r :: RemoteEvent
end

local buyRemote = getOrCreateRemote("ShopBuy", "RemoteEvent")
local equipRemote = getOrCreateRemote("ShopEquip", "RemoteEvent")
local syncRemote = getOrCreateRemote("ShopSync", "RemoteEvent")

-- Push the authoritative state to one client.
local function sync(player: Player)
	local d = data[player.UserId]
	if d then
		syncRemote:FireClient(player, {
			coins = d.coins,
			owned = d.owned,
			equipped = d.equipped,
		})
	end
end

-- ----------------------------------------------------------------------------
-- Trail equipping (cosmetic applied to the character)
-- ----------------------------------------------------------------------------
local function clearTrail(character: Model)
	local old = character:FindFirstChild("ShopTrail")
	if old then
		old:Destroy()
	end
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("Attachment") and (desc.Name == "ShopA0" or desc.Name == "ShopA1") then
			desc:Destroy()
		end
	end
end

local function applyTrail(player: Player)
	local d = data[player.UserId]
	local character = player.Character
	if not d or not character then
		return
	end
	clearTrail(character)
	if not d.equipped then
		return
	end
	local item = ShopItems.getById(d.equipped)
	local head = character:FindFirstChild("Head")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not item or not head or not root then
		return
	end

	local a0 = Instance.new("Attachment")
	a0.Name = "ShopA0"
	a0.Position = Vector3.new(0, 1, 0)
	a0.Parent = head

	local a1 = Instance.new("Attachment")
	a1.Name = "ShopA1"
	a1.Position = Vector3.new(0, 0, 0)
	a1.Parent = root

	local trail = Instance.new("Trail")
	trail.Name = "ShopTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(item.color)
	trail.Transparency = NumberSequence.new(0.2)
	trail.Lifetime = 0.6
	trail.WidthScale = NumberSequence.new(1)
	trail.FaceCamera = true
	trail.Parent = head
end

-- ----------------------------------------------------------------------------
-- Purchase / equip handlers (all validation happens here, never on client)
-- ----------------------------------------------------------------------------
buyRemote.OnServerEvent:Connect(function(player: Player, itemId: any)
	if typeof(itemId) ~= "string" then
		return
	end
	local item = ShopItems.getById(itemId)
	local d = data[player.UserId]
	if not item or not d then
		return
	end
	if d.owned[itemId] then
		return -- already owned, nothing to do
	end
	if d.coins < item.price then
		return -- can't afford it
	end
	d.coins -= item.price
	d.owned[itemId] = true
	saveData(player, true)
	sync(player)
end)

equipRemote.OnServerEvent:Connect(function(player: Player, itemId: any)
	if typeof(itemId) ~= "string" then
		return
	end
	local d = data[player.UserId]
	if not d then
		return
	end
	if itemId == "" then
		d.equipped = nil -- unequip
	else
		local item = ShopItems.getById(itemId)
		if not item or not d.owned[itemId] then
			return -- can't equip what you don't own
		end
		d.equipped = itemId
	end
	applyTrail(player)
	saveData(player, true)
	sync(player)
end)

-- ----------------------------------------------------------------------------
-- World building
-- ----------------------------------------------------------------------------
local function buildWorld()
	local baseplate = Instance.new("Part")
	baseplate.Name = "Baseplate"
	baseplate.Size = Vector3.new(120, 2, 120)
	baseplate.Position = Vector3.new(0, -1, 0)
	baseplate.Anchored = true
	baseplate.Color = Color3.fromRGB(32, 34, 46)
	baseplate.Material = Enum.Material.SmoothPlastic
	baseplate.Parent = workspace

	local spawn = Instance.new("SpawnLocation")
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = Vector3.new(0, 0.5, 12)
	spawn.Anchored = true
	spawn.BrickColor = BrickColor.new("Medium stone grey")
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Parent = workspace

	-- Coin pad: click to earn coins for testing purchases
	local pad = Instance.new("Part")
	pad.Name = "CoinPad"
	pad.Size = Vector3.new(8, 1, 8)
	pad.Position = Vector3.new(12, 0.5, 12)
	pad.Anchored = true
	pad.Color = Color3.fromRGB(255, 195, 60)
	pad.Material = Enum.Material.Neon
	pad.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 340, 0, 60)
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
	padLabel.Text = "CLICK  +100 COINS"
	padLabel.Parent = billboard

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 20
	click.Parent = pad

	local debounce: { [number]: number } = {}
	click.MouseClick:Connect(function(player)
		local now = os.clock()
		if (debounce[player.UserId] or 0) + 0.5 > now then
			return
		end
		debounce[player.UserId] = now
		local d = data[player.UserId]
		if d then
			d.coins += COINS_PER_CLICK
			saveData(player, false)
			sync(player)
		end
	end)
end

-- ----------------------------------------------------------------------------
-- Player lifecycle
-- ----------------------------------------------------------------------------
Players.PlayerAdded:Connect(function(player)
	loadData(player)
	player.CharacterAdded:Connect(function()
		task.delay(0.5, function()
			applyTrail(player)
		end)
	end)
	task.delay(1, function()
		sync(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	saveData(player, true)
	data[player.UserId] = nil
	lastSave[player.UserId] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		saveData(player, true)
	end
end)

buildWorld()
print("[ShopDemo] Ready — click the gold pad for coins, then open the shop.")
