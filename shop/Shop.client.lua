-- ============================================================================
-- ShopDemo (Client): builds the entire shop UI in code and talks to the
-- server over RemoteEvents. The server owns coins/ownership; this script
-- only displays the state it receives and forwards button presses.
-- ============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopItems = require(Shared:WaitForChild("ShopItems"))

local buyRemote = ReplicatedStorage:WaitForChild("ShopBuy")
local equipRemote = ReplicatedStorage:WaitForChild("ShopEquip")
local syncRemote = ReplicatedStorage:WaitForChild("ShopSync")

-- Latest authoritative state from the server. Nil until the first sync.
local state: { coins: number, owned: { [string]: boolean }, equipped: string? }? = nil

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

-- ----------------------------------------------------------------------------
-- UI construction
-- ----------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "ShopGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

-- Toggle button (always visible, bottom-right)
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "ShopToggle"
toggleBtn.Size = UDim2.new(0, 150, 0, 56)
toggleBtn.Position = UDim2.new(1, -170, 1, -76)
toggleBtn.BackgroundColor3 = Color3.fromRGB(255, 195, 60)
toggleBtn.Font = Enum.Font.GothamBlack
toggleBtn.TextSize = 24
toggleBtn.TextColor3 = Color3.fromRGB(40, 28, 8)
toggleBtn.Text = "🛒 SHOP"
toggleBtn.AutoButtonColor = true
toggleBtn.Parent = gui
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 14)

-- Dim backdrop behind the shop panel
local backdrop = Instance.new("TextButton")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.new(1, 0, 1, 0)
backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
backdrop.BackgroundTransparency = 0.45
backdrop.Text = ""
backdrop.Visible = false
backdrop.Parent = gui

-- Main panel (CanvasGroup so open/close can fade as one unit)
local panel = Instance.new("CanvasGroup")
panel.Name = "ShopPanel"
panel.Size = UDim2.new(0, 580, 0, 470)
panel.Position = UDim2.new(0.5, -290, 0.5, -235)
panel.BackgroundColor3 = Color3.fromRGB(24, 24, 34)
panel.GroupTransparency = 1
panel.Visible = false
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 16)

local panelScale = Instance.new("UIScale")
panelScale.Scale = 0.92
panelScale.Parent = panel

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 195, 60)
stroke.Thickness = 2
stroke.Transparency = 0.35
stroke.Parent = panel

-- Header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 64)
header.BackgroundTransparency = 1
header.Parent = panel

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -120, 1, 0)
titleLabel.Position = UDim2.new(0, 20, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.GothamBlack
titleLabel.TextSize = 28
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.Text = "🛒  ITEM SHOP"
titleLabel.Parent = header

local coinsLabel = Instance.new("TextLabel")
coinsLabel.Name = "CoinsLabel"
coinsLabel.Size = UDim2.new(0, 200, 1, 0)
coinsLabel.Position = UDim2.new(1, -280, 0, 0)
coinsLabel.BackgroundTransparency = 1
coinsLabel.Font = Enum.Font.GothamBold
coinsLabel.TextSize = 24
coinsLabel.TextXAlignment = Enum.TextXAlignment.Right
coinsLabel.TextColor3 = Color3.fromRGB(255, 205, 90)
coinsLabel.Text = "💰 ..."
coinsLabel.Parent = header

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 44, 0, 44)
closeBtn.Position = UDim2.new(1, -56, 0, 10)
closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
closeBtn.Font = Enum.Font.GothamBlack
closeBtn.TextSize = 22
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.Text = "✕"
closeBtn.Parent = header
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 10)

-- Status line (purchase feedback: "Purchased Ember Trail!")
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -40, 0, 28)
statusLabel.Position = UDim2.new(0, 20, 0, 64)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextSize = 18
statusLabel.TextColor3 = Color3.fromRGB(120, 230, 140)
statusLabel.Text = ""
statusLabel.Parent = panel

-- Item grid
local scroller = Instance.new("ScrollingFrame")
scroller.Size = UDim2.new(1, -40, 1, -120)
scroller.Position = UDim2.new(0, 20, 0, 96)
scroller.BackgroundTransparency = 1
scroller.BorderSizePixel = 0
scroller.ScrollBarThickness = 6
scroller.CanvasSize = UDim2.new(0, 0, 0, 0)
scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroller.Parent = panel

local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.new(0, 164, 0, 196)
grid.CellPadding = UDim2.new(0, 12, 0, 12)
grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
grid.Parent = scroller

-- One card per catalog item; refreshed from server state.
type Card = {
	frame: Frame,
	priceLabel: TextLabel,
	actionBtn: TextButton,
	itemId: string,
}
local cards: { Card } = {}

local function setStatus(text: string, color: Color3)
	statusLabel.Text = text
	statusLabel.TextColor3 = color
	task.delay(2.5, function()
		if statusLabel.Text == text then
			statusLabel.Text = ""
		end
	end)
end

local function buildCards()
	for _, item in ipairs(ShopItems.list) do
		local card = Instance.new("Frame")
		card.Size = UDim2.new(0, 164, 0, 196)
		card.BackgroundColor3 = Color3.fromRGB(36, 36, 50)
		card.Parent = scroller
		Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)

		local icon = Instance.new("TextLabel")
		icon.Size = UDim2.new(1, 0, 0, 84)
		icon.Position = UDim2.new(0, 0, 0, 8)
		icon.BackgroundTransparency = 1
		icon.Font = Enum.Font.GothamBlack
		icon.TextSize = 64
		icon.Text = item.icon
		icon.Parent = card

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, -16, 0, 28)
		nameLabel.Position = UDim2.new(0, 8, 0, 94)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 18
		nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		nameLabel.Text = item.name
		nameLabel.Parent = card

		local priceLabel = Instance.new("TextLabel")
		priceLabel.Size = UDim2.new(1, -16, 0, 24)
		priceLabel.Position = UDim2.new(0, 8, 0, 122)
		priceLabel.BackgroundTransparency = 1
		priceLabel.Font = Enum.Font.Gotham
		priceLabel.TextSize = 17
		priceLabel.TextColor3 = Color3.fromRGB(255, 205, 90)
		priceLabel.Text = ""
		priceLabel.Parent = card

		local actionBtn = Instance.new("TextButton")
		actionBtn.Size = UDim2.new(1, -24, 0, 36)
		actionBtn.Position = UDim2.new(0, 12, 1, -44)
		actionBtn.Font = Enum.Font.GothamBold
		actionBtn.TextSize = 17
		actionBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		actionBtn.Text = "..."
		actionBtn.Parent = card
		Instance.new("UICorner", actionBtn).CornerRadius = UDim.new(0, 8)

		local cardData: Card = { frame = card, priceLabel = priceLabel, actionBtn = actionBtn, itemId = item.id }

		actionBtn.MouseButton1Click:Connect(function()
			if not state then
				return
			end
			if state.owned[item.id] then
				if state.equipped == item.id then
					equipRemote:FireServer("") -- unequip
				else
					equipRemote:FireServer(item.id)
				end
			else
				if state.coins >= item.price then
					buyRemote:FireServer(item.id)
					setStatus("Purchased " .. item.name .. "!", Color3.fromRGB(120, 230, 140))
				else
					setStatus("Not enough coins!", Color3.fromRGB(255, 120, 120))
				end
			end
		end)

		table.insert(cards, cardData)
	end
end

-- Repaint every card from the latest server state.
local function refresh()
	if not state then
		return
	end
	coinsLabel.Text = "💰 " .. formatNumber(state.coins)
	for i, card in ipairs(cards) do
		local item = ShopItems.list[i]
		local btn = card.actionBtn
		if state.owned[item.id] then
			card.priceLabel.Text = "OWNED"
			card.priceLabel.TextColor3 = Color3.fromRGB(120, 230, 140)
			if state.equipped == item.id then
				btn.Text = "EQUIPPED ✓"
				btn.BackgroundColor3 = Color3.fromRGB(90, 140, 90)
			else
				btn.Text = "EQUIP"
				btn.BackgroundColor3 = Color3.fromRGB(70, 120, 200)
			end
		else
			card.priceLabel.Text = "💰 " .. formatNumber(item.price)
			card.priceLabel.TextColor3 = Color3.fromRGB(255, 205, 90)
			if state.coins >= item.price then
				btn.Text = "BUY"
				btn.BackgroundColor3 = Color3.fromRGB(60, 170, 80)
			else
				btn.Text = "BUY"
				btn.BackgroundColor3 = Color3.fromRGB(110, 110, 125)
			end
		end
	end
end

-- ----------------------------------------------------------------------------
-- Open / close with tween animation
-- ----------------------------------------------------------------------------
local isOpen = false
local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	backdrop.Visible = open
	if open then
		panel.Visible = true
		refresh()
		TweenService:Create(panel, tweenInfo, { GroupTransparency = 0 }):Play()
		TweenService:Create(panelScale, tweenInfo, { Scale = 1 }):Play()
	else
		local t1 = TweenService:Create(panel, tweenInfo, { GroupTransparency = 1 })
		TweenService:Create(panelScale, tweenInfo, { Scale = 0.92 }):Play()
		t1:Play()
		t1.Completed:Connect(function()
			if not isOpen then
				panel.Visible = false
			end
		end)
	end
end

toggleBtn.MouseButton1Click:Connect(function()
	setOpen(not isOpen)
end)
closeBtn.MouseButton1Click:Connect(function()
	setOpen(false)
end)
backdrop.MouseButton1Click:Connect(function()
	setOpen(false)
end)

-- ----------------------------------------------------------------------------
-- Server sync
-- ----------------------------------------------------------------------------
syncRemote.OnClientEvent:Connect(function(newState)
	state = newState
	refresh()
end)

buildCards()
print("[ShopDemo] Client ready — press 🛒 SHOP to open the store.")
