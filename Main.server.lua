-- ============================================================================
-- CombatDemo (Server)
-- An arena battler showcasing combat systems: melee sword, enemy AI,
-- overhead health bars, damage numbers, particles, waves, and player HP.
--
-- HOW IT WORKS
--   1. This script builds the whole demo world on startup (arena, walls,
--      pillars, spawn) — no manual setup needed.
--   2. You spawn with a Sword tool. Click to swing: enemies in range take
--      damage, flash red, and pop up damage numbers (yellow crits included).
--   3. Three enemies chase and melee you. They have overhead health bars,
--      die with a particle burst, and respawn per wave.
--   4. Clear all 3 to advance: a "WAVE N" banner appears and tougher enemies
--      spawn. Kill counter and HP bar are on screen; red flash + knockback
--      when you take a hit.
-- ============================================================================

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local ARENA_HALF = 28
local ENEMIES_PER_WAVE = 3
local SWORD_DAMAGE = 30
local SWORD_RANGE = 9
local SWORD_COOLDOWN = 0.45
local CRIT_CHANCE = 0.12
local ENEMY_BASE_HP = 100
local ENEMY_SPEED = 10
local ENEMY_DAMAGE = 10
local ENEMY_ATTACK_RANGE = 5
local ENEMY_SEPARATION_RADIUS = 6 -- enemies push apart within this distance
local ENEMY_SEPARATION_WEIGHT = 1.6 -- how strongly separation steers vs chasing
local PLAYER_MAX_HP = 100

local ENEMY_PALETTE = {
	Color3.fromRGB(235, 70, 70), -- red
	Color3.fromRGB(255, 140, 40), -- orange
	Color3.fromRGB(170, 80, 255), -- purple
	Color3.fromRGB(60, 200, 255), -- cyan
	Color3.fromRGB(120, 255, 120), -- green
}

-- ----------------------------------------------------------------------------
-- Small instance factory
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

-- SwingEvent: server tells the clicking player's client to swing the arm.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local swingEvent = P("RemoteEvent", { Name = "SwingEvent" }, ReplicatedStorage)

-- ----------------------------------------------------------------------------
-- World: arena, walls, pillars, spawn
-- ----------------------------------------------------------------------------
local world = P("Folder", { Name = "ArenaWorld" }, workspace)

P("Part", {
	Name = "Floor",
	Size = Vector3.new(ARENA_HALF * 2 + 8, 1, ARENA_HALF * 2 + 8),
	Position = Vector3.new(0, -0.5, 0),
	Anchored = true,
	Material = Enum.Material.Slate,
	BrickColor = BrickColor.new("Dark stone grey"),
}, world)

-- Neon edge trim (screenshot flair)
local trimColor = BrickColor.new("Bright orange")
for _, spec in ipairs({
	{ Vector3.new((ARENA_HALF * 2 + 8), 0.4, 0.6), Vector3.new(0, 0.2, ARENA_HALF + 4) },
	{ Vector3.new((ARENA_HALF * 2 + 8), 0.4, 0.6), Vector3.new(0, 0.2, -ARENA_HALF - 4) },
	{ Vector3.new(0.6, 0.4, (ARENA_HALF * 2 + 8)), Vector3.new(ARENA_HALF + 4, 0.2, 0) },
	{ Vector3.new(0.6, 0.4, (ARENA_HALF * 2 + 8)), Vector3.new(-ARENA_HALF - 4, 0.2, 0) },
}) do
	P("Part", {
		Size = spec[1],
		Position = spec[2],
		Anchored = true,
		CanCollide = false,
		Material = Enum.Material.Neon,
		BrickColor = trimColor,
	}, world)
end

-- Low walls to keep everyone in
local wallH, wallT = 4, 1
for _, spec in ipairs({
	{ Vector3.new((ARENA_HALF * 2 + 4), wallH, wallT), Vector3.new(0, wallH / 2, ARENA_HALF + 2) },
	{ Vector3.new((ARENA_HALF * 2 + 4), wallH, wallT), Vector3.new(0, wallH / 2, -ARENA_HALF - 2) },
	{ Vector3.new(wallT, wallH, (ARENA_HALF * 2 + 4)), Vector3.new(ARENA_HALF + 2, wallH / 2, 0) },
	{ Vector3.new(wallT, wallH, (ARENA_HALF * 2 + 4)), Vector3.new(-ARENA_HALF - 2, wallH / 2, 0) },
}) do
	P("Part", {
		Size = spec[1],
		Position = spec[2],
		Anchored = true,
		Material = Enum.Material.SmoothPlastic,
		BrickColor = BrickColor.new("Black"),
		Transparency = 0.35,
	}, world)
end

-- Corner pillars with neon tops
for _, corner in ipairs({
	Vector3.new(ARENA_HALF - 3, 0, ARENA_HALF - 3),
	Vector3.new(-ARENA_HALF + 3, 0, ARENA_HALF - 3),
	Vector3.new(ARENA_HALF - 3, 0, -ARENA_HALF + 3),
	Vector3.new(-ARENA_HALF + 3, 0, -ARENA_HALF + 3),
}) do
	P("Part", {
		Size = Vector3.new(2, 10, 2),
		Position = corner + Vector3.new(0, 5, 0),
		Anchored = true,
		Material = Enum.Material.Concrete,
		BrickColor = BrickColor.new("Dark stone grey"),
	}, world)
	P("Part", {
		Size = Vector3.new(2.4, 1, 2.4),
		Position = corner + Vector3.new(0, 10.5, 0),
		Anchored = true,
		CanCollide = false,
		Material = Enum.Material.Neon,
		BrickColor = BrickColor.new("Cyan"),
	}, world)
end

P("SpawnLocation", {
	Size = Vector3.new(6, 1, 6),
	Position = Vector3.new(0, 0.5, 0),
	Anchored = true,
	Material = Enum.Material.SmoothPlastic,
	BrickColor = BrickColor.new("Bright blue"),
	Neutral = true,
}, world)

-- ----------------------------------------------------------------------------
-- Player GUI: HP bar, kill counter, wave banner, damage flash
-- ----------------------------------------------------------------------------
local function buildPlayerGui(player: Player)
	local gui = P("ScreenGui", { Name = "CombatGui", ResetOnSpawn = false }, player:WaitForChild("PlayerGui"))

	-- HP bar (top center)
	local hpBack = P("Frame", {
		Name = "HpBack",
		Size = UDim2.new(0, 320, 0, 26),
		Position = UDim2.new(0.5, -160, 0, 16),
		BackgroundColor3 = Color3.fromRGB(30, 10, 10),
		BorderSizePixel = 0,
	}, gui)
	P("UICorner", { CornerRadius = UDim.new(0, 13) }, hpBack)
	local hpFill = P("Frame", {
		Name = "HpFill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(60, 220, 90),
		BorderSizePixel = 0,
	}, hpBack)
	P("UICorner", { CornerRadius = UDim.new(0, 13) }, hpFill)
	P("TextLabel", {
		Name = "HpText",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "100 / 100",
		Font = Enum.Font.GothamBlack,
		TextSize = 15,
		TextColor3 = Color3.fromRGB(255, 255, 255),
	}, hpBack)

	-- Kill counter (top right)
	local kills = P("TextLabel", {
		Name = "KillLabel",
		Size = UDim2.new(0, 180, 0, 40),
		Position = UDim2.new(1, -196, 0, 16),
		BackgroundColor3 = Color3.fromRGB(20, 20, 28),
		BackgroundTransparency = 0.15,
		Text = "💀 Kills: 0",
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		TextColor3 = Color3.fromRGB(255, 255, 255),
	}, gui)
	P("UICorner", { CornerRadius = UDim.new(0, 10) }, kills)

	-- Wave label (top left)
	local wave = P("TextLabel", {
		Name = "WaveLabel",
		Size = UDim2.new(0, 180, 0, 40),
		Position = UDim2.new(0, 16, 0, 16),
		BackgroundColor3 = Color3.fromRGB(20, 20, 28),
		BackgroundTransparency = 0.15,
		Text = "🌊 WAVE 1",
		Font = Enum.Font.GothamBlack,
		TextSize = 18,
		TextColor3 = Color3.fromRGB(255, 255, 255),
	}, gui)
	P("UICorner", { CornerRadius = UDim.new(0, 10) }, wave)

	-- Wave banner (center, hidden)
	local banner = P("TextLabel", {
		Name = "WaveBanner",
		Size = UDim2.new(0, 500, 0, 90),
		Position = UDim2.new(0.5, -250, 0.35, -45),
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamBlack,
		TextSize = 64,
		TextColor3 = Color3.fromRGB(255, 180, 60),
		TextStrokeTransparency = 0.2,
		Visible = false,
	}, gui)

	-- Damage flash (full-screen red, hidden)
	local flash = P("Frame", {
		Name = "DamageFlash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(200, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
	}, gui)

	return {
		hpFill = hpFill,
		hpBack = hpBack,
		killLabel = kills,
		waveLabel = wave,
		banner = banner,
		flash = flash,
	}
end

local playerState: { [Player]: {
	hp: number,
	kills: number,
	gui: { [string]: Instance },
	swordCd: number,
	lastHurt: number,
} } = {}

local function refreshHp(player: Player)
	local st = playerState[player]
	if not st then
		return
	end
	local frac = math.clamp(st.hp / PLAYER_MAX_HP, 0, 1)
	local hpFill = st.gui.hpFill :: Frame
	hpFill.Size = UDim2.fromScale(frac, 1)
	hpFill.BackgroundColor3 = if frac > 0.5
		then Color3.fromRGB(60, 220, 90)
		elseif frac > 0.25 then Color3.fromRGB(240, 180, 40)
		else Color3.fromRGB(230, 60, 60)
	local hpText = (st.gui.hpBack :: Frame):FindFirstChild("HpText") :: TextLabel
	hpText.Text = math.max(0, math.floor(st.hp)) .. " / " .. PLAYER_MAX_HP
end

local function damagePlayer(player: Player, amount: number, fromPos: Vector3)
	local st = playerState[player]
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not st or not hrp or st.hp <= 0 then
		return
	end
	st.hp -= amount
	st.lastHurt = os.clock()
	refreshHp(player)

	-- Red flash
	local flash = st.gui.flash :: Frame
	flash.Visible = true
	flash.BackgroundTransparency = 0.45
	TweenService:Create(flash, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
	task.delay(0.45, function()
		flash.Visible = false
	end)

	-- Knockback away from attacker
	local root = hrp :: BasePart
	local dir = (root.Position - fromPos)
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude > 0.01 then
		dir = dir.Unit
		root.AssemblyLinearVelocity = dir * 28 + Vector3.new(0, 12, 0)
	end

	if st.hp <= 0 then
		local hum = character:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.Health = 0
		end
	end
end

-- ----------------------------------------------------------------------------
-- Enemies
-- ----------------------------------------------------------------------------
type Enemy = {
	model: Model,
	hp: number,
	maxHp: number,
	barFill: Frame,
	attackCd: number,
	speed: number,
	dead: boolean,
}

local enemies: { Enemy } = {}
local wave = 1
local waveBannerDebounce = false

local function spawnDamageNumber(adorneePart: BasePart, amount: number, isCrit: boolean)
	local bill = P("BillboardGui", {
		Size = UDim2.new(0, 120, 0, 50),
		StudsOffsetWorldSpace = Vector3.new(math.random(-15, 15) / 10, 2.5, 0),
		Adornee = adorneePart,
		AlwaysOnTop = true,
	}, workspace)
	local label = P("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = (if isCrit then "CRIT " else "") .. tostring(math.floor(amount)),
		Font = Enum.Font.GothamBlack,
		TextSize = if isCrit then 30 else 22,
		TextColor3 = if isCrit then Color3.fromRGB(255, 150, 30) else Color3.fromRGB(255, 255, 255),
		TextStrokeTransparency = 0.1,
	}, bill)
	TweenService:Create(bill, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = bill.StudsOffsetWorldSpace + Vector3.new(0, 2.5, 0),
	}):Play()
	TweenService:Create(label, TweenInfo.new(0.7), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(bill, 0.75)
end

local function buildEnemy(spawnPos: Vector3, hp: number, color: Color3): Enemy
	local model = P("Model", { Name = "Enemy" }, workspace)

	local hrp = P("Part", {
		Name = "HumanoidRootPart",
		Size = Vector3.new(2, 2, 1),
		CFrame = CFrame.new(spawnPos + Vector3.new(0, 3, 0)),
		Anchored = true, -- anchored during construction; released at the end
		CanCollide = false,
		Transparency = 1,
	}, model)

	local function bodyPart(name: string, size: Vector3, offset: Vector3, partColor: Color3): Part
		local part = P("Part", {
			Name = name,
			Size = size,
			CFrame = hrp.CFrame * CFrame.new(offset),
			Anchored = true, -- anchored during construction; released at the end
			CanCollide = false,
			Material = Enum.Material.SmoothPlastic,
			Color = partColor,
		}, model) :: Part
		P("WeldConstraint", { Part0 = hrp, Part1 = part }, part)
		return part
	end

	local dark = color:Lerp(Color3.new(0, 0, 0), 0.25)
	local light = color:Lerp(Color3.new(1, 1, 1), 0.25)
	bodyPart("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 0, 0), color)
	bodyPart("Head", Vector3.new(1.3, 1.2, 1.2), Vector3.new(0, 1.7, 0), light)
	bodyPart("LeftArm", Vector3.new(1, 2, 1), Vector3.new(-1.5, 0, 0), dark)
	bodyPart("RightArm", Vector3.new(1, 2, 1), Vector3.new(1.5, 0, 0), dark)
	bodyPart("LeftLeg", Vector3.new(1, 2, 1), Vector3.new(-0.5, -2, 0), dark)
	bodyPart("RightLeg", Vector3.new(1, 2, 1), Vector3.new(0.5, -2, 0), dark)

	-- Angry eyes (plain text dots — renders reliably on every platform,
	-- no external image assets needed). Duplicated front + back so the face
	-- reads from either side.
	local head = model:WaitForChild("Head") :: Part
	for _, faceId in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local face = P("SurfaceGui", { Face = faceId }, head)
		P("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "●  ●",
			Font = Enum.Font.GothamBlack,
			TextSize = 60,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextStrokeTransparency = 0.5,
		}, face)
	end

	-- Overhead health bar
	local bar = P("BillboardGui", {
		Size = UDim2.new(0, 90, 0, 14),
		StudsOffset = Vector3.new(0, 3.2, 0),
		Adornee = head,
		AlwaysOnTop = true,
	}, model)
	P("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(40, 0, 0),
		BorderSizePixel = 0,
	}, bar)
	local fill = P("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(80, 230, 80),
		BorderSizePixel = 0,
	}, bar) :: Frame

	model:PivotTo(CFrame.new(spawnPos + Vector3.new(0, 3, 0)))
	model.PrimaryPart = hrp

	-- NOTE: enemies stay ANCHORED and use a manual kinematic controller
	-- (see the AI loop). Physics-driven Humanoids proved unreliable here:
	-- parts unanchored during construction fall before the Humanoid takes
	-- over, and joint/Animator conflicts break scripted animation. Manual
	-- control is fully deterministic: Y locked to ground, XZ clamped to
	-- the arena, facing via lookAt. Nothing can sink or clip.
	local speed = ENEMY_SPEED + wave * 0.8

	return {
		model = model,
		hp = hp,
		maxHp = hp,
		barFill = fill,
		attackCd = 0,
		speed = speed,
		dead = false,
	}
end

local function killEnemy(enemy: Enemy, idx: number)
	if enemy.dead then
		return
	end
	enemy.dead = true
	table.remove(enemies, idx)

	-- Particle burst at death position
	local pos = (enemy.model.PrimaryPart :: BasePart).Position
	local burst = P("ParticleEmitter", {
		Rate = 0,
		Lifetime = NumberRange.new(0.5, 1),
		Speed = NumberRange.new(8, 16),
		Size = NumberSequence.new(0.6),
		Transparency = NumberSequence.new(0.1),
		Color = ColorSequence.new(Color3.fromRGB(255, 120, 60)),
		LightEmission = 1,
	}, workspace.Terrain)
	burst:Emit(30)
	Debris:AddItem(burst, 1.2)

	enemy.model:Destroy()

	-- Credit every player (demo has one player; keep it simple and global)
	for player, st in pairs(playerState) do
		st.kills += 1
		local killLabel = st.gui.killLabel :: TextLabel
		killLabel.Text = "💀 Kills: " .. st.kills
	end

	-- Next wave when cleared
	if #enemies == 0 then
		task.delay(2, function()
			if #enemies == 0 then
				startWave(wave + 1)
			end
		end)
	end
end

local function damageEnemy(enemy: Enemy, idx: number, amount: number)
	if enemy.dead then
		return
	end
	enemy.hp -= amount
	local frac = math.clamp(enemy.hp / enemy.maxHp, 0, 1)
	enemy.barFill.Size = UDim2.fromScale(math.max(frac, 0.001), 1)
	enemy.barFill.BackgroundColor3 = if frac > 0.5
		then Color3.fromRGB(80, 230, 80)
		elseif frac > 0.25 then Color3.fromRGB(240, 180, 40)
		else Color3.fromRGB(230, 60, 60)

	-- Red hit-flash on all body parts
	for _, part in ipairs(enemy.model:GetChildren()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			local original = part.Color
			part.Color = Color3.fromRGB(255, 40, 40)
			task.delay(0.12, function()
				if part.Parent then
					part.Color = original
				end
			end)
		end
	end

	if enemy.hp <= 0 then
		killEnemy(enemy, idx)
	end
end

function startWave(n: number)
	wave = n
	local hp = math.floor(ENEMY_BASE_HP * (1 + 0.3 * (n - 1)))
	local color = ENEMY_PALETTE[((n - 1) % #ENEMY_PALETTE) + 1]
	local spots = {
		Vector3.new(-18, 0, -18),
		Vector3.new(18, 0, -18),
		Vector3.new(0, 0, 20),
	}
	for _, spot in ipairs(spots) do
		table.insert(enemies, buildEnemy(spot, hp, color))
	end

	-- Banner for every player
	for _, st in pairs(playerState) do
		(st.gui.waveLabel :: TextLabel).Text = "🌊 WAVE " .. n
		local banner = st.gui.banner :: TextLabel
		banner.Text = "WAVE " .. n
		banner.Visible = true
		banner.TextTransparency = 0
		banner.TextSize = 40
		TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Back), { TextSize = 64 }):Play()
		task.delay(1.6, function()
			TweenService:Create(banner, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
			task.delay(0.45, function()
				banner.Visible = false
			end)
		end)
	end
	print("[CombatDemo] Wave " .. n .. " started (" .. hp .. " HP each).")
end

-- Enemy AI loop: chase nearest player, melee in range
task.spawn(function()
	while true do
		task.wait(0.12)
		for idx = #enemies, 1, -1 do
			local enemy = enemies[idx]
			if enemy.dead then
				continue
			end
			-- Nearest alive player
			local target, targetPos: Vector3? = nil, nil
			local best = math.huge
			for player, st in pairs(playerState) do
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if hrp and st.hp > 0 then
					local d = ((hrp :: BasePart).Position - (enemy.model.PrimaryPart :: BasePart).Position).Magnitude
					if d < best then
						best = d
						target = player
						targetPos = (hrp :: BasePart).Position
					end
				end
			end
			if not target or not targetPos then
				continue
			end

			local ePos = (enemy.model.PrimaryPart :: BasePart).Position
			local flat = Vector3.new(targetPos.X - ePos.X, 0, targetPos.Z - ePos.Z)
			-- Separation steering: push away from nearby enemies so they
			-- spread out instead of stacking on the same point.
			local sep = Vector3.zero
			for _, other in ipairs(enemies) do
				if other ~= enemy and not other.dead then
					local oPos = (other.model.PrimaryPart :: BasePart).Position
					local diff = Vector3.new(ePos.X - oPos.X, 0, ePos.Z - oPos.Z)
					local d = diff.Magnitude
					if d > 0.01 and d < ENEMY_SEPARATION_RADIUS then
						sep += diff.Unit * (1 - d / ENEMY_SEPARATION_RADIUS)
					end
				end
			end
			local chaseDir = flat.Magnitude > 0.01 and flat.Unit or Vector3.zero
			local moveDir = chaseDir + sep * ENEMY_SEPARATION_WEIGHT
			if moveDir.Magnitude < 0.01 then
				moveDir = chaseDir
			end
			if flat.Magnitude > ENEMY_ATTACK_RANGE then
				-- Manual kinematic chase: step toward the steered direction,
				-- then hard-clamp to the ground plane and arena bounds.
				-- Fully deterministic — no physics, no sinking, no clipping.
				local step = moveDir.Unit * enemy.speed * 0.12
				local newPos = ePos + step
				-- Ground: root center rides 3 studs up (leg bottoms touch Y=0)
				-- Walls: stay inside the arena
				local lim = ARENA_HALF - 1
				newPos = Vector3.new(
					math.clamp(newPos.X, -lim, lim),
					3,
					math.clamp(newPos.Z, -lim, lim)
				)
				enemy.model:PivotTo(CFrame.lookAt(newPos, newPos + moveDir))
			elseif flat.Magnitude > 0.1 then
				-- Hold ground and face the player while attacking
				local facePos = Vector3.new(ePos.X, 3, ePos.Z)
				enemy.model:PivotTo(CFrame.lookAt(facePos, Vector3.new(targetPos.X, 3, targetPos.Z)))
				enemy.attackCd -= 0.12
				if enemy.attackCd <= 0 then
					enemy.attackCd = 1.1
					damagePlayer(target, ENEMY_DAMAGE, ePos)
				end
			end
		end
	end
end)

-- ----------------------------------------------------------------------------
-- Sword: built unparented; armPlayer puts it straight into the character
-- (a Tool parented to the character IS equipped — no Backpack/EquipTool
-- timing races, no silent unequipped state where clicks do nothing).
-- ----------------------------------------------------------------------------
local function buildSwordTool(player: Player): Tool
	local tool = P("Tool", {
		Name = "Sword",
		RequiresHandle = true,
		CanBeDropped = false,
	}, nil)

	-- Grip the handle near the guard so it doesn't poke through the hand
	tool.GripPos = Vector3.new(0, -1.1, 0)
	tool.GripForward = Vector3.new(0, 0, -1)
	tool.GripUp = Vector3.new(0, 1, 0)

	local handle = P("Part", {
		Name = "Handle",
		Size = Vector3.new(0.35, 3.6, 0.7),
		Material = Enum.Material.Metal,
		BrickColor = BrickColor.new("Medium stone grey"),
	}, tool)

	-- Gold guard
	P("Part", {
		Name = "Guard",
		Size = Vector3.new(1.2, 0.3, 1),
		CFrame = handle.CFrame * CFrame.new(0, -1.4, 0),
		Material = Enum.Material.Neon,
		BrickColor = BrickColor.new("Bright yellow"),
		CanCollide = false,
	}, tool)

	-- Weld guard to handle
	P("WeldConstraint", { Part0 = handle, Part1 = tool:WaitForChild("Guard") }, handle)

	-- Blade trail: renders a visible swoosh whenever the sword moves.
	-- This is what makes the swing readable.
	local tipAtt = P("Attachment", { Name = "TipAttachment", Position = Vector3.new(0, 1.8, 0) }, handle)
	local baseAtt = P("Attachment", { Name = "BaseAttachment", Position = Vector3.new(0, -1.2, 0) }, handle)
	P("Trail", {
		Attachment0 = tipAtt,
		Attachment1 = baseAtt,
		Color = ColorSequence.new(Color3.fromRGB(160, 240, 255)),
		Transparency = NumberSequence.new(0.1, 1),
		Lifetime = 0.25,
		MinLength = 0.1,
		Enabled = true,
	}, handle)

	tool.Activated:Connect(function()
		local st = playerState[player]
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not st or not hrp or os.clock() - st.swordCd < SWORD_COOLDOWN then
			return
		end
		st.swordCd = os.clock()

		-- Trigger the client's arm swing visual
		swingEvent:FireClient(player)

		-- Swing visual: a wrist flick driving the blade Trail, which renders
		-- the motion as a visible slash swoosh. Near-180° sweep with a
		-- diagonal tilt — a full, realistic sword arc.
		task.spawn(function()
			local baseF = tool.GripForward
			local baseU = tool.GripUp
			local dur = 0.25
			local t0 = os.clock()
			while true do
				local t = (os.clock() - t0) / dur
				if t >= 1 or not tool.Parent then
					break
				end
				local rot = CFrame.Angles(math.rad(-15 + 35 * t), 0, math.rad(85 - 170 * t))
				tool.GripForward = rot * baseF
				tool.GripUp = rot * baseU
				task.wait()
			end
			if tool.Parent then
				tool.GripForward = baseF
				tool.GripUp = baseU
			end
		end)

		-- Damage enemies in range
		local origin = (hrp :: BasePart).Position
		for idx = #enemies, 1, -1 do
			local enemy = enemies[idx]
			if not enemy.dead then
				local ePos = (enemy.model.PrimaryPart :: BasePart).Position
				if (ePos - origin).Magnitude <= SWORD_RANGE then
					local isCrit = math.random() < CRIT_CHANCE
					local dmg = SWORD_DAMAGE * (if isCrit then 2 else 1)
					local head = enemy.model:FindFirstChild("Head") :: BasePart
					if head then
						spawnDamageNumber(head, dmg, isCrit)
					end
					damageEnemy(enemy, idx, dmg)
				end
			end
		end
	end)

	-- Tool is returned unparented; armPlayer decides where it goes.
	return tool
end

-- Arms the player: puts a fresh sword directly into the character model.
-- A Tool parented to the character is equipped by definition, so there is
-- no Backpack/EquipTool timing window where clicks silently do nothing.
-- Also sweeps any stale swords (e.g. unequipped into the Backpack).
local function armPlayer(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local hum = character:WaitForChild("Humanoid", 5)
	if not hum then
		return
	end
	for _, container in ipairs({ character, player:FindFirstChild("Backpack") }) do
		if container then
			local old = container:FindFirstChild("Sword")
			if old then
				old:Destroy()
			end
		end
	end
	local sword = buildSwordTool(player)
	sword.Parent = character
end

-- ----------------------------------------------------------------------------
-- Player lifecycle
-- ----------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	playerState[player] = {
		hp = PLAYER_MAX_HP,
		kills = 0,
		gui = buildPlayerGui(player),
		swordCd = 0,
		lastHurt = 0,
	}
	refreshHp(player)

	-- Arm on spawn; re-arm on every respawn. A monitor also re-arms if the
	-- sword ever leaves the character (e.g. player unequips it).
	local function ensureArmed()
		task.spawn(function()
			for _ = 1, 12 do
				if not playerState[player] then
					return
				end
				local character = player.Character
				if character and character:FindFirstChild("Sword") then
					return -- sword in hand, done
				end
				armPlayer(player)
				task.wait(0.5)
			end
		end)
	end
	ensureArmed()

	player.CharacterAdded:Connect(function(_character)
		local st = playerState[player]
		if st then
			st.hp = PLAYER_MAX_HP
			refreshHp(player)
		end
		ensureArmed()
	end)

	-- Gentle HP regen out of combat
	task.spawn(function()
		while playerState[player] do
			task.wait(1)
			local st = playerState[player]
			if st and st.hp > 0 and st.hp < PLAYER_MAX_HP and os.clock() - st.lastHurt > 4 then
				st.hp = math.min(PLAYER_MAX_HP, st.hp + 6)
				refreshHp(player)
			end
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	playerState[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- First wave starts shortly after server boot so the player sees action fast
task.delay(3, function()
	if #enemies == 0 then
		startWave(1)
	end
end)

print("[CombatDemo] Ready — grab your sword and fight.")
