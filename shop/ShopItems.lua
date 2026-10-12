-- ============================================================================
-- ShopItems (Shared): the shop catalog.
-- Both server (purchase validation) and client (UI display) require this,
-- so item data lives in exactly one place.
-- ============================================================================

export type ShopItem = {
	id: string,
	name: string,
	icon: string, -- emoji, no external assets needed
	price: number,
	color: Color3, -- trail color when equipped
}

local ShopItems: { ShopItem } = {
	{ id = "ember", name = "Ember Trail", icon = "🔥", price = 100, color = Color3.fromRGB(255, 110, 20) },
	{ id = "frost", name = "Frost Trail", icon = "❄️", price = 250, color = Color3.fromRGB(90, 200, 255) },
	{ id = "venom", name = "Venom Trail", icon = "☠️", price = 500, color = Color3.fromRGB(80, 220, 80) },
	{ id = "royal", name = "Royal Trail", icon = "👑", price = 1000, color = Color3.fromRGB(170, 80, 255) },
	{ id = "gold", name = "Gold Trail", icon = "⭐", price = 2500, color = Color3.fromRGB(255, 210, 60) },
	{ id = "shadow", name = "Shadow Trail", icon = "🌑", price = 5000, color = Color3.fromRGB(45, 45, 60) },
}

local byId: { [string]: ShopItem } = {}
for _, item in ipairs(ShopItems) do
	byId[item.id] = item
end

-- Look up an item by id. Returns nil for unknown ids (server rejects those).
local function getById(id: string): ShopItem?
	return byId[id]
end

return {
	list = ShopItems,
	getById = getById,
}
