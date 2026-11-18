-- Main.server.luau
-- SATU-SATUNYA Script server + SATU-SATUNYA composition root Pasar Brainrot.
-- Ditulis baru dari DESIGN.md (bagian 2, 4, 13, 16) + MAIN-SERVER-PLAN.md
-- (Langkah 1-3, 4A, 6 + bagian 3, 5, 6). Tanpa menyalin source lama.
--
-- STAGE 1 (DESIGN.md 20.3): require Config SAJA. TIDAK ADA require
-- modul lain. TIDAK ADA pemanggilan layanan penyimpanan data.
-- Isi Stage 1: createRemotes, buildWorld, assignBase/releaseBase,
-- lifecycle pemain (state default, tanpa load, tanpa save), loop 1 detik
-- kosong. Wiring modul lain masuk Stage 2-4.

local PlayersService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- ============================================================================
-- State milik Main (DESIGN.md 16.1, 16.4; PLAN bagian 5)
-- ============================================================================

-- Players[player] = PlayerState (bentuk di DESIGN.md 16.4).
local Players = {}
-- ConveyorItems: array Brainrot di conveyor (diisi loop spawn, Stage 4).
local ConveyorItems = {}
-- Crates[crateId] = CrateState (diisi Flood.spawnCrates, Stage 4).
local Crates = {}
-- Remotes[nama] = RemoteEvent di ReplicatedStorage.GameRemotes.
local Remotes = {}
-- World: data hasil build dunia yang dibutuhkan logika (Steal, Flood).
local World = {
	PedestalPos = {}, -- [baseIdx][slotIdx] -> Vector3 (permukaan atas pedestal)
	BaseCenter = {}, -- [baseIdx] -> Vector3 (pusat lantai base)
}
-- BaseVisuals[baseIdx] = {GlassParts, LockBarrier, OwnerBoard, SlotModels}.
local BaseVisuals = {}
-- FloodState: SATU tabel status siklus flood (Stage 4; di-Stage 1 hanya
-- diinisialisasi — tidak ada tick flood sebelum Stage 4).
local FloodState = {
	Phase = "Idle",
	PhaseEndsAt = nil, -- nil saat Idle (KOREKSI LANJUT)
	NextFloodAt = os.clock() + Config.FLOOD_FIRST,
	CycleActive = false,
	DebugPending = false,
}
-- Arah gerak conveyor milik Main (KOREKSI LANJUT): 1 = ke +Z, -1 = ke -Z.
-- Dibalik tiap flood saat actions.conveyorFlip == true (Stage 4).
local conveyorDirection = 1

-- ============================================================================
-- newUid — SATU-SATUNYA generator UID di server (DESIGN.md 16.1)
-- ============================================================================

local function newUid()
	return HttpService:GenerateGUID(false)
end

-- ============================================================================
-- createRemotes (PLAN Langkah 2)
-- ============================================================================

local REMOTE_NAMES = {
	"FloodEvent",
	"MoneyUpdate",
	"StealResult",
	"Notify",
	"StealRequest",
	"PlaceRequest",
	"SellRequest",
	"LockRequest",
	"RebirthRequest",
	"ClaimRequest",
	"DebugFlood",
}

local function createRemotes()
	local folder = Instance.new("Folder")
	folder.Name = "GameRemotes"
	folder.Parent = ReplicatedStorage
	for _, name in ipairs(REMOTE_NAMES) do
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = folder
		Remotes[name] = event
	end
	return Remotes
end

-- ============================================================================
-- buildWorld (PLAN Langkah 3; dunia DESIGN.md bagian 2 dan 4)
-- ============================================================================

-- Pembantu: satu Part kotak ber-Anchor di Workspace.
local function newPart(name, size, position, material, color)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Material = material
	part.Color = color
	part.Anchored = true
	part.CanCollide = true
	part.Parent = Workspace
	return part
end

-- Pembantu: satu panel kaca lock (awalnya tersembunyi, tidak menghalangi).
local function newGlassPart(name, size, position)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Material = Enum.Material.Glass
	part.Color = Color3.fromRGB(170, 220, 255)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.Parent = Workspace
	return part
end

local function setupLighting()
	Lighting.ClockTime = Config.CLOCK_TIME -- 20.5: malam tapi terang
	Lighting.Brightness = Config.LIGHT_BRIGHTNESS -- 2
	Lighting.Ambient = Color3.fromRGB(70, 58, 48) -- hangat redup
	Lighting.OutdoorAmbient = Color3.fromRGB(60, 50, 42)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.GlobalShadows = true
end

local function buildTerrain()
	-- Lantai batu 340 x 2 x 420, permukaan atas y = 0.
	newPart(
		"Terrain",
		Config.TERRAIN_SIZE,
		Config.TERRAIN_POS,
		Enum.Material.Cobblestone,
		Color3.fromRGB(125, 120, 115)
	)
end

local function buildConveyor()
	-- Sabuk kayu 30 x 0.5 x 320, permukaan atas y = 0.55.
	newPart(
		"Conveyor",
		Config.CONVEYOR_SIZE,
		Config.CONVEYOR_POS,
		Enum.Material.WoodPlanks,
		Color3.fromRGB(150, 105, 60)
	)
end

local function buildPlaza()
	-- Plaza selatan 110 x 0.6 x 55 di sekitar z = 155, atas y = 0.6.
	newPart(
		"Plaza",
		Config.PLAZA_SIZE,
		Config.PLAZA_POS,
		Enum.Material.Slate,
		Color3.fromRGB(150, 140, 120)
	)
	-- SpawnLocation 16 x 1 x 16 di (0, 0.8, 168). Neutral agar pemain
	-- dari tim manapun spawn di sini.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnLocation"
	spawn.Size = Config.SPAWN_SIZE
	spawn.Position = Config.SPAWN_POS
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Color = Color3.fromRGB(90, 160, 90)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Parent = Workspace
end

local function buildOneBase(baseIdx, xCenter, zCenter)
	-- Lantai base 56 x 0.8 x 46, permukaan atas y = 0.8.
	newPart(
		"BaseFloor" .. tostring(baseIdx),
		Vector3.new(56, 0.8, 46),
		Vector3.new(xCenter, 0.4, zCenter),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(170, 140, 100)
	)
	World.BaseCenter[baseIdx] = Vector3.new(xCenter, 0.8, zCenter)
	World.PedestalPos[baseIdx] = {}

	-- 6 pedestal silinder (2 baris x 3 kolom), permukaan atas y = 1.7.
	-- Silinder Roblox memanjang sepanjang sumbu X, jadi diputar 90 derajat
	-- pada sumbu Z agar berdiri tegak; tinggi 0.9 dari lantai (0.8 -> 1.7).
	for slotIdx = 1, Config.SLOT_COUNT do
		local pedestalPos = Config.slotPosition(xCenter, zCenter, slotIdx)
		World.PedestalPos[baseIdx][slotIdx] = pedestalPos
		local pedestal = Instance.new("Part")
		pedestal.Name = "Pedestal" .. tostring(slotIdx)
		pedestal.Shape = Enum.PartType.Cylinder
		pedestal.Size = Vector3.new(0.9, 3, 3)
		pedestal.CFrame = CFrame.new(pedestalPos.X, 1.25, pedestalPos.Z)
			* CFrame.Angles(0, 0, math.pi / 2)
		pedestal.Material = Enum.Material.SmoothPlastic
		pedestal.Color = Color3.fromRGB(200, 195, 185)
		pedestal.Anchored = true
		pedestal.CanCollide = true
		pedestal.Parent = Workspace
		-- ProximityPrompt pedestal; atribut WAJIB server (DESIGN.md 13).
		-- ActionText/ObjectText rinci (Taruh/Jual/Curi) diatur Stage 2-3
		-- saat prompt dipakai; Stage 1 hanya memasang prompt + atribut.
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Brainrot"
		prompt.ObjectText = "Pedestal"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt:SetAttribute("PromptKind", "Empty")
		prompt:SetAttribute("OwnerUserId", 0)
		prompt:SetAttribute("SlotFilled", false)
		prompt:SetAttribute("BaseIdx", baseIdx)
		prompt:SetAttribute("SlotIdx", slotIdx)
		prompt.Parent = pedestal
	end

	-- Papan nama pemilik: BillboardGui 200 x 110 di (xCenter, 20.5, zCenter).
	local boardAnchor = Instance.new("Part")
	boardAnchor.Name = "OwnerBoardAnchor" .. tostring(baseIdx)
	boardAnchor.Size = Vector3.new(1, 1, 1)
	boardAnchor.Position = Vector3.new(xCenter, 20.5, zCenter)
	boardAnchor.Transparency = 1
	boardAnchor.Anchored = true
	boardAnchor.CanCollide = false
	boardAnchor.Parent = Workspace
	local board = Instance.new("BillboardGui")
	board.Name = "OwnerBoard"
	board.Adornee = boardAnchor
	board.Size = UDim2.new(0, 200, 0, 110)
	board.AlwaysOnTop = false
	board.Parent = boardAnchor
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.Size = UDim2.new(1, 0, 0, 40)
	nameLabel.Position = UDim2.new(0, 0, 0, 0)
	nameLabel.BackgroundColor3 = Color3.fromRGB(30, 25, 20)
	nameLabel.BackgroundTransparency = 0.3
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextScaled = true
	nameLabel.Font = Enum.Font.SourceSansBold
	nameLabel.Text = "BASE " .. tostring(baseIdx)
	nameLabel.Parent = board
	-- Placeholder headshot pemilik (kosong saat base belum berpenghuni;
	-- diisi foto kepala pemilik saat base terisi, Stage 2+).
	local headshot = Instance.new("ImageLabel")
	headshot.Name = "Headshot"
	headshot.Size = UDim2.new(0, 60, 0, 60)
	headshot.Position = UDim2.new(0, 10, 0, 45)
	headshot.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
	headshot.Image = ""
	headshot.Parent = board

	-- Papan "make.fun" sebagai identitas kompetisi.
	local signAnchor = Instance.new("Part")
	signAnchor.Name = "MakeFunAnchor" .. tostring(baseIdx)
	signAnchor.Size = Vector3.new(1, 1, 1)
	signAnchor.Position = Vector3.new(xCenter, 8, zCenter)
	signAnchor.Transparency = 1
	signAnchor.Anchored = true
	signAnchor.CanCollide = false
	signAnchor.Parent = Workspace
	local sign = Instance.new("BillboardGui")
	sign.Name = "MakeFunBoard"
	sign.Adornee = signAnchor
	sign.Size = UDim2.new(0, 160, 0, 36)
	sign.AlwaysOnTop = false
	sign.Parent = signAnchor
	local signLabel = Instance.new("TextLabel")
	signLabel.Name = "SignLabel"
	signLabel.Size = UDim2.new(1, 0, 1, 0)
	signLabel.BackgroundTransparency = 1
	signLabel.TextColor3 = Color3.fromRGB(255, 210, 60)
	signLabel.TextScaled = true
	signLabel.Font = Enum.Font.SourceSansBold
	signLabel.Text = "make.fun"
	signLabel.Parent = sign

	-- Kaca lock: 3 dinding sisi + pintu kaca di sisi dalam (DoorX).
	-- Awalnya tersembunyi (Transparency 1, CanCollide false); muncul saat
	-- base terkunci (setLockVisual, Stage 3).
	local doorX = Config.doorX(xCenter)
	local glassParts = {}
	local outerX = xCenter
	if xCenter < 0 then
		outerX = xCenter - 27.75
	else
		outerX = xCenter + 27.75
	end
	table.insert(glassParts, newGlassPart(
		"GlassWallOuter" .. tostring(baseIdx),
		Vector3.new(0.5, 12, 46),
		Vector3.new(outerX, 6, zCenter)
	))
	table.insert(glassParts, newGlassPart(
		"GlassWallNorth" .. tostring(baseIdx),
		Vector3.new(56, 12, 0.5),
		Vector3.new(xCenter, 6, zCenter - 22.75)
	))
	table.insert(glassParts, newGlassPart(
		"GlassWallSouth" .. tostring(baseIdx),
		Vector3.new(56, 12, 0.5),
		Vector3.new(xCenter, 6, zCenter + 22.75)
	))
	-- Pintu kaca 1.5 x 12 x 42 di (DoorX, 6, zCenter) — sekaligus
	-- LockBarrier: pemain bukan pemilik yang menyentuhnya saat base
	-- terkunci di-teleport keluar (Stage 3, DESIGN.md 19.1).
	local lockBarrier = newGlassPart(
		"LockBarrier" .. tostring(baseIdx),
		Vector3.new(1.5, 12, 42),
		Vector3.new(doorX, 6, zCenter)
	)
	table.insert(glassParts, lockBarrier)

	-- Lampu tiap base: PointLight hangat, Range 30.
	local lampPart = Instance.new("Part")
	lampPart.Name = "BaseLight" .. tostring(baseIdx)
	lampPart.Size = Vector3.new(0.5, 0.5, 0.5)
	lampPart.Position = Vector3.new(xCenter, 6, zCenter)
	lampPart.Transparency = 1
	lampPart.Anchored = true
	lampPart.CanCollide = false
	lampPart.Parent = Workspace
	local baseLight = Instance.new("PointLight")
	baseLight.Name = "BaseLight"
	baseLight.Color = Color3.fromRGB(255, 200, 120)
	baseLight.Range = 30
	baseLight.Brightness = 1
	baseLight.Parent = lampPart

	BaseVisuals[baseIdx] = {
		GlassParts = glassParts,
		LockBarrier = lockBarrier,
		OwnerBoard = board,
		SlotModels = {},
	}
end

local function buildBases()
	-- 8 base: 4 kiri (xCenter -68), 4 kanan (xCenter +68);
	-- zCenter 90, 25, -40, -105. Nomor base 1-4 kiri, 5-8 kanan.
	local baseIdx = 0
	for _, xCenter in ipairs(Config.BASE_X) do
		for _, zCenter in ipairs(Config.BASE_Z) do
			baseIdx = baseIdx + 1
			buildOneBase(baseIdx, xCenter, zCenter)
		end
	end
end

local function buildGates()
	-- Gapura utara (z = -195) dan selatan (z = +195): 2 pilar + balok atas.
	for _, gateZ in ipairs({ -195, 195 }) do
		local gateName = "GateSouth"
		if gateZ < 0 then
			gateName = "GateNorth"
		end
		newPart(
			gateName .. "PillarLeft",
			Vector3.new(2, 12, 2),
			Vector3.new(-8, 6, gateZ),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(170, 60, 50)
		)
		newPart(
			gateName .. "PillarRight",
			Vector3.new(2, 12, 2),
			Vector3.new(8, 6, gateZ),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(170, 60, 50)
		)
		newPart(
			gateName .. "Beam",
			Vector3.new(20, 2, 2),
			Vector3.new(0, 13, gateZ),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(170, 60, 50)
		)
	end
end

local function buildFences()
	-- Pagar pembatas di tepi terrain (x = +-168, z = +-208), tinggi 3.
	newPart(
		"FenceNorth",
		Vector3.new(340, 3, 1),
		Vector3.new(0, 1.5, -208),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(80, 75, 70)
	)
	newPart(
		"FenceSouth",
		Vector3.new(340, 3, 1),
		Vector3.new(0, 1.5, 208),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(80, 75, 70)
	)
	newPart(
		"FenceWest",
		Vector3.new(1, 3, 416),
		Vector3.new(-168, 1.5, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(80, 75, 70)
	)
	newPart(
		"FenceEast",
		Vector3.new(1, 3, 416),
		Vector3.new(168, 1.5, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(80, 75, 70)
	)
end

local function buildCity()
	-- Bangunan kota latar di kejauhan (sekitar x = +-162, z = +-202).
	-- Seed tetap agar skyline sama setiap server start.
	math.randomseed(20261118)
	local function buildOneCityBuilding(name, x, z)
		local height = 25 + math.random(0, 35)
		newPart(
			name,
			Vector3.new(18, height, 18),
			Vector3.new(x, height / 2, z),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(45 + math.random(0, 15), 50 + math.random(0, 15), 70 + math.random(0, 20))
		)
	end
	local buildingIdx = 0
	for _, sideX in ipairs({ -162, 162 }) do
		for z = -180, 180, 36 do
			buildingIdx = buildingIdx + 1
			buildOneCityBuilding("CityBuilding" .. tostring(buildingIdx), sideX, z)
		end
	end
	for _, sideZ in ipairs({ -202, 202 }) do
		for x = -140, 140, 40 do
			buildingIdx = buildingIdx + 1
			buildOneCityBuilding("CityBuilding" .. tostring(buildingIdx), x, sideZ)
		end
	end
end

local function buildTrees()
	-- 48 pohon di tepi conveyor: 24 per sisi (x = +-20),
	-- z dari -149.5 sampai 149.5 langkah 13.
	for _, treeX in ipairs({ -20, 20 }) do
		for i = 0, 23 do
			local z = -149.5 + i * 13
			local trunk = newPart(
				"TreeTrunk",
				Vector3.new(1, 4, 1),
				Vector3.new(treeX, 2, z),
				Enum.Material.Wood,
				Color3.fromRGB(120, 80, 40)
			)
			trunk.CanCollide = true
			local leaves = Instance.new("Part")
			leaves.Name = "TreeLeaves"
			leaves.Shape = Enum.PartType.Ball
			leaves.Size = Vector3.new(5, 5, 5)
			leaves.Position = Vector3.new(treeX, 6, z)
			leaves.Material = Enum.Material.SmoothPlastic
			leaves.Color = Color3.fromRGB(60, 160, 60)
			leaves.Anchored = true
			leaves.CanCollide = false
			leaves.Parent = Workspace
		end
	end
end

local function buildLamps()
	-- 14 lampu jalan: 7 per sisi (x = +-12), z -120..120 langkah 40.
	-- Bola Neon + PointLight hangat, Range 22.
	for _, lampX in ipairs({ -12, 12 }) do
		for i = 0, 6 do
			local z = -120 + i * 40
			newPart(
				"LampPole",
				Vector3.new(0.5, 6, 0.5),
				Vector3.new(lampX, 3, z),
				Enum.Material.SmoothPlastic,
				Color3.fromRGB(60, 60, 65)
			)
			local head = Instance.new("Part")
			head.Name = "LampHead"
			head.Shape = Enum.PartType.Ball
			head.Size = Vector3.new(1.5, 1.5, 1.5)
			head.Position = Vector3.new(lampX, 6.3, z)
			head.Material = Enum.Material.Neon
			head.Color = Color3.fromRGB(255, 220, 130)
			head.Anchored = true
			head.CanCollide = false
			head.Parent = Workspace
			local lampLight = Instance.new("PointLight")
			lampLight.Name = "StreetLight"
			lampLight.Color = Color3.fromRGB(255, 200, 120)
			lampLight.Range = 22
			lampLight.Brightness = 1
			lampLight.Parent = head
		end
	end
end

local function buildWorld()
	setupLighting()
	buildTerrain()
	buildConveyor()
	buildPlaza()
	buildBases()
	buildGates()
	buildFences()
	buildCity()
	buildTrees()
	buildLamps()
end

-- ============================================================================
-- Visual base milik Main (dipakai assignBase / releaseBase)
-- ============================================================================

-- Perbarui papan nama base: nama pemilik, atau "BASE n" kalau kosong.
local function refreshOwnerBoard(baseIdx)
	local visuals = BaseVisuals[baseIdx]
	if visuals == nil or visuals.OwnerBoard == nil then
		return
	end
	local ownerName = "BASE " .. tostring(baseIdx)
	for player, state in pairs(Players) do
		if state.Base == baseIdx then
			ownerName = player.Name
			break
		end
	end
	local nameLabel = visuals.OwnerBoard:FindFirstChild("NameLabel")
	if nameLabel ~= nil then
		nameLabel.Text = ownerName
	end
end

-- Tampilkan/sembunyikan kaca lock base (dipakai Stage 3; Stage 1 hanya
-- dipakai releaseBase untuk memastikan kaca tersembunyi saat base lepas).
local function setLockVisual(baseIdx, locked)
	local visuals = BaseVisuals[baseIdx]
	if visuals == nil then
		return
	end
	for _, part in ipairs(visuals.GlassParts) do
		if locked then
			part.Transparency = 0.5
			part.CanCollide = true
		else
			part.Transparency = 1
			part.CanCollide = false
		end
	end
end

-- ============================================================================
-- assignBase / releaseBase / akses state (PLAN bagian 3)
-- ============================================================================

local function getPlayerState(player)
	return Players[player]
end

local function getPedestalPos(baseIdx, slotIdx)
	local basePedestals = World.PedestalPos[baseIdx]
	if basePedestals == nil then
		return nil
	end
	return basePedestals[slotIdx]
end

-- Beri pemain base kosong pertama; kembalikan nomor base atau nil kalau penuh.
local function assignBase(player)
	local state = Players[player]
	if state == nil then
		return nil
	end
	local taken = {}
	for _, otherState in pairs(Players) do
		if otherState.Base ~= nil then
			taken[otherState.Base] = true
		end
	end
	for baseIdx = 1, 8 do
		if not taken[baseIdx] then
			state.Base = baseIdx
			refreshOwnerBoard(baseIdx)
			return baseIdx
		end
	end
	return nil
end

-- Lepas base pemain: bersihkan slot + visual, papan kembali "BASE n".
local function releaseBase(player)
	local state = Players[player]
	if state == nil then
		return
	end
	local baseIdx = state.Base
	if baseIdx == nil then
		return
	end
	for slotIdx = 1, Config.SLOT_COUNT do
		state.Slots[slotIdx] = nil
	end
	state.Carried = nil
	local visuals = BaseVisuals[baseIdx]
	if visuals ~= nil then
		for slotIdx, model in pairs(visuals.SlotModels) do
			if model ~= nil then
				model:Destroy()
			end
			visuals.SlotModels[slotIdx] = nil
		end
	end
	state.Base = nil
	state.Locked = false
	state.LockExpiresAt = nil
	setLockVisual(baseIdx, false)
	refreshOwnerBoard(baseIdx)
end

-- ============================================================================
-- Lifecycle pemain, STAGE 1 (PLAN Langkah 4A; DESIGN.md 20.3)
-- TANPA load, TANPA LoadToken, TANPA load gating, TANPA save.
-- ============================================================================

local function onPlayerAdded(player)
	local slots = {}
	for slotIdx = 1, Config.SLOT_COUNT do
		slots[slotIdx] = nil
	end
	Players[player] = {
		Money = Config.START_MONEY,
		Rebirths = 0,
		IncomeMult = 1,
		Base = nil,
		Slots = slots,
		Carried = nil,
		Locked = false,
		LockExpiresAt = nil,
		LastStealAt = 0,
		LastStealAttemptAt = 0,
		LoadStatus = "ok",
		LoadedDataVersion = nil,
		LoadedRevision = nil,
		LoadToken = nil,
	}
	assignBase(player)
end

local function onPlayerRemoving(player)
	releaseBase(player)
	Players[player] = nil
end

local function onBindToClose()
	-- Stage 1: tidak melakukan apa pun (tidak ada penyimpanan, tidak ada save).
end

-- ============================================================================
-- Start server
-- ============================================================================

createRemotes()
buildWorld()

PlayersService.PlayerAdded:Connect(onPlayerAdded)
PlayersService.PlayerRemoving:Connect(onPlayerRemoving)
game:BindToClose(onBindToClose)

-- Pemain yang sudah ada sebelum script jalan (misal Studio solo test).
for _, player in ipairs(PlayersService:GetPlayers()) do
	onPlayerAdded(player)
end

-- Loop 1 detik (SATU-SATUNYA loop; milik Main). Stage 1: kerangka kosong —
-- belum ada tick apa pun. Income (Stage 2), lock expiry (Stage 3),
-- flood + crate expiry (Stage 4) ditambahkan pada stage-nya.
task.spawn(function()
	while true do
		task.wait(1)
	end
end)
