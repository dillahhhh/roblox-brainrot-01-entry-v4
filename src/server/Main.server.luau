-- Main.server.luau
-- SATU-SATUNYA Script server Pasar Brainrot (Steal-a-Brainrot, pasar Nusantara).
-- Composition root (DESIGN.md 16.1): membangun dunia 3D saat runtime, membuat
-- semua RemoteEvent, memiliki tabel state (Players, ConveyorItems, Crates,
-- Remotes, World, FloodState), mendaftarkan lifecycle pemain, dan menjalankan
-- loop utama 1 detik.
--
-- STAGE 1 (DESIGN.md 20.3): kerangka + dunia saja. TANPA modul logika lain:
-- file ini HANYA memakai Config. Economy + DataStore baru masuk Stage 2,
-- Steal Stage 3, Flood Stage 4. Tidak ada pemuatan data pemain di Stage 1:
-- onPlayerAdded membuat PlayerState default dengan LoadStatus "ok",
-- onPlayerRemoving melepas base tanpa menyimpan, BindToClose kosong.
-- Loop 1 detik masih kosong; tick income / lock / flood / peti ditambahkan
-- pada stage-nya masing-masing.
--
-- Ditulis baru dari DESIGN.md + MAIN-SERVER-PLAN.md (prose), di sesi terekam.
-- Semua angka gameplay diambil dari Config (satu-satunya sumber kebenaran);
-- Main tidak meng-hardcode harga, jarak, atau durasi gameplay.

local PlayersService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LightingService = game:GetService("Lighting")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- ============================================================================
-- State milik Main (DESIGN.md 16.1, 16.4)
-- Hanya Main yang membuat dan memiliki tabel-tabel ini. Modul-modul pada
-- stage berikut menerima tabel ini sebagai argumen (dependency injection),
-- tidak pernah membuat state sendiri.
-- ============================================================================

-- Players[player] = PlayerState (bentuk lengkap: DESIGN.md 16.4).
local Players = {}

-- ConveyorItems: array Brainrot yang sedang berjalan di conveyor
-- (REVISI KE-3). Diisi loop spawn Main pada stage berikut; dibaca dan
-- dihapus Flood.sweep saat tersapu; dihapus Main saat mencapai ujung.
-- Stage 1: tabel kosong, belum ada spawn.
local ConveyorItems = {}

-- Crates[crateId] = CrateState (DESIGN.md 16.4). Diisi Flood.spawnCrates
-- pada Stage 4. Stage 1: tabel kosong.
local Crates = {}

-- Remotes[nama] = RemoteEvent di ReplicatedStorage.GameRemotes.
local Remotes = {}

-- World: data hasil build dunia yang dibutuhkan logika.
--   PedestalPos[baseIdx][slotIdx] = Vector3 posisi tiap pedestal.
--   BaseCenter[baseIdx] = Vector3 pusat lantai base.
local World = {
	PedestalPos = {},
	BaseCenter = {},
}

-- BaseVisuals[baseIdx]: referensi instance per base yang harus diubah
-- saat runtime (bukan state gameplay, jadi tidak tinggal di Players).
--   GlassParts  = {Part, ...} dinding + pintu kaca lock.
--   LockBarrier = Part pemicu teleport saat base terkunci.
--   OwnerBoard  = BillboardGui papan nama pemilik.
--   BoardLabel  = TextLabel di dalam OwnerBoard.
--   BoardImage  = ImageLabel foto kepala pemilik di dalam OwnerBoard.
--   Prompts     = {[slotIdx] = ProximityPrompt pedestal}.
--   SlotModels  = {[slotIdx] = Model | nil} visual Brainrot di pedestal.
local BaseVisuals = {}

-- FloodState: SATU tabel status siklus flood (DESIGN.md 16.4).
-- Perubahan tabel ini HANYA dari actions yang diusulkan Flood.tick
-- (Stage 4). Stage 1: diinisialisasi Idle, belum ada siklus.
local serverStart = os.clock()
local FloodState = {
	Phase = "Idle",
	PhaseEndsAt = nil, -- nil saat Idle (KOREKSI LANJUT: number?)
	NextFloodAt = serverStart + Config.FLOOD_FIRST,
	CycleActive = false,
	DebugPending = false,
}

-- Arah gerak conveyor milik Main (KOREKSI LANJUT): 1 = bergerak ke +Z
-- (spawn di -CONVEYOR_END_Z, hapus di +CONVEYOR_END_Z); -1 = sebaliknya.
-- Dibalik tiap flood saat actions.conveyorFlip == true (Stage 4).
local conveyorDirection = 1

-- sessionId: string unik per server, dibuat SEKALI saat start.
-- Disuntikkan ke saveData pada Stage 2 (DESIGN.md 17.6).
local sessionId = HttpService:GenerateGUID(false)

-- Folder penampung semua part dunia (supaya Explorer tetap rapi).
local WorldFolder = Instance.new("Folder")
WorldFolder.Name = "World"
WorldFolder.Parent = workspace

-- ============================================================================
-- Generator UID tunggal + helper kecil
-- ============================================================================

-- newUid: SATU-SATUNYA sumber UID di server (DESIGN.md 16.1).
-- Disuntikkan ke modul yang membutuhkan UID baru (spawn conveyor,
-- spawnCrates, claimCrate). Modul tidak pernah membuat UID sendiri.
local function newUid()
	return HttpService:GenerateGUID(false)
end

-- Buat satu Part berlabuh di dunia dengan properti dasar yang sama.
local function makePart(name, size, position, material, color)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Material = material
	part.Color = color
	part.Anchored = true
	part.CanCollide = true
	part.Parent = WorldFolder
	return part
end

-- Buat satu Part tak terlihat (jangkar untuk BillboardGui / PointLight).
local function makeAnchor(name, position)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(1, 1, 1)
	part.Position = position
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Parent = WorldFolder
	return part
end

-- Tempel PointLight hangat ke sebuah part.
local function addPointLight(parent, range, color, brightness)
	local light = Instance.new("PointLight")
	light.Range = range
	light.Color = color
	light.Brightness = brightness
	light.Parent = parent
	return light
end

-- ============================================================================
-- Akses state pemain
-- ============================================================================

-- Kembalikan PlayerState pemain, atau nil kalau pemain belum punya state.
local function getPlayerState(player)
	return Players[player]
end

-- True jika state pemain ada dan load-nya sudah siap ("ok" / "new").
-- Dipakai semua handler gameplay SEBELUM meneruskan ke modul.
-- MULAI Stage 2. Di Stage 1 fungsi ini belum dipakai (tidak ada load;
-- LoadStatus selalu "ok" sejak onPlayerAdded).
local function isLoadReady(player)
	local state = Players[player]
	if state == nil then
		return false
	end
	return state.LoadStatus == "ok" or state.LoadStatus == "new"
end

-- True jika base pemain sedang terkunci (DESIGN.md 19.1):
-- Locked == true, LockExpiresAt ada, dan timer belum lewat.
local function isLocked(player, now)
	local state = Players[player]
	if state == nil then
		return false
	end
	if state.Locked ~= true then
		return false
	end
	if state.LockExpiresAt == nil then
		return false
	end
	return now < state.LockExpiresAt
end

-- Kembalikan posisi pedestal (Vector3) untuk base + slot tertentu.
local function getPedestalPos(baseIdx, slotIdx)
	local byBase = World.PedestalPos[baseIdx]
	if byBase == nil then
		return nil
	end
	return byBase[slotIdx]
end

-- ============================================================================
-- createRemotes (PLAN Langkah 2)
-- Buat Folder GameRemotes + 11 RemoteEvent (DESIGN.md 13). HANYA Main yang
-- membuat RemoteEvent; modul tidak pernah membuat.
-- ============================================================================

local REMOTE_NAMES = {
	-- server -> client
	"FloodEvent", -- fase flood (string) + sisa detik
	"MoneyUpdate", -- money, incomePerSec
	"StealResult", -- sukses (boolean), pesan (string)
	"Notify", -- teks pesan singkat
	-- client -> server
	"StealRequest", -- baseIdx, slotIdx
	"PlaceRequest", -- slotIdx
	"SellRequest", -- slotIdx
	"LockRequest", -- locked (boolean)
	"RebirthRequest", -- (tanpa argumen)
	"ClaimRequest", -- crateId (string)
	"DebugFlood", -- (tanpa argumen; pengujian Studio, Stage 4)
}

local function createRemotes()
	local folder = Instance.new("Folder")
	folder.Name = "GameRemotes"
	folder.Parent = ReplicatedStorage
	for _, name in ipairs(REMOTE_NAMES) do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		Remotes[name] = remote
	end
	return Remotes
end

-- ============================================================================
-- buildWorld (PLAN Langkah 3)
-- Urutan: setupLighting -> buildTerrain -> buildConveyor -> buildPlaza +
-- SpawnLocation -> buildBases -> buildGates -> buildCity -> buildTrees ->
-- buildLamps. Sambil membangun, isi World.PedestalPos + World.BaseCenter
-- dan simpan referensi visual per base di BaseVisuals.
-- ============================================================================

-- Pencahayaan malam tapi terang (DESIGN.md 2): ClockTime 20.5,
-- Brightness 2, Ambient hangat redup.
local function setupLighting()
	local lighting = LightingService
	lighting.ClockTime = Config.CLOCK_TIME
	lighting.Brightness = Config.LIGHT_BRIGHTNESS
	lighting.Ambient = Color3.fromRGB(80, 70, 60)
	lighting.OutdoorAmbient = Color3.fromRGB(60, 55, 70)
	lighting.EnvironmentDiffuseScale = 0.6
	lighting.GlobalShadows = true
	lighting.FogEnd = 900
end

-- Lantai batu utama: 340 x 2 x 420, permukaan atas y = 0 (DESIGN.md 2).
local function buildTerrain()
	local terrain = makePart(
		"Terrain",
		Config.TERRAIN_SIZE,
		Config.TERRAIN_POS,
		Enum.Material.Cobblestone,
		Color3.fromRGB(120, 115, 105)
	)
	terrain.Name = "Terrain"
end

-- Conveyor (sabuk berjalan): 30 x 0.5 x 320, permukaan atas y = 0.55,
-- material WoodPlanks, di tengah map (DESIGN.md 2).
local function buildConveyor()
	local conveyor = makePart(
		"Conveyor",
		Config.CONVEYOR_SIZE,
		Config.CONVEYOR_POS,
		Enum.Material.WoodPlanks,
		Color3.fromRGB(150, 110, 60)
	)
	conveyor.Name = "Conveyor"
	-- Garis tengah sabuk (pembatas dua jalur) supaya jalur terlihat.
	local divider = makePart(
		"ConveyorDivider",
		Vector3.new(0.6, 0.1, 320),
		Vector3.new(0, 0.6, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(90, 65, 35)
	)
	divider.CanCollide = false
end

-- Plaza selatan: area spawn pemain, 110 x 0.6 x 55 di sekitar z = 155,
-- plus SpawnLocation 16 x 1 x 16 di (0, 0.8, 168) (DESIGN.md 2).
local function buildPlaza()
	local plaza = makePart(
		"Plaza",
		Config.PLAZA_SIZE,
		Config.PLAZA_POS,
		Enum.Material.Cobblestone,
		Color3.fromRGB(140, 130, 115)
	)
	plaza.Name = "Plaza"

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnLocation"
	spawn.Size = Config.SPAWN_SIZE
	spawn.Position = Config.SPAWN_POS
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Color = Color3.fromRGB(90, 200, 120)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.AllowTeamChangeOnTouch = false
	spawn.Parent = WorldFolder
end

-- Satu pedestal silinder + ProximityPrompt-nya (DESIGN.md 4).
-- Pedestal: silinder diameter 6, tinggi 0,9, permukaan atas y = 1,7.
-- Prompt membawa atribut server (DESIGN.md 13): PromptKind, OwnerUserId,
-- SlotFilled, BaseIdx, SlotIdx. ActionText awal "Taruh"; client
-- menyesuaikan tampilan per penonton pada Stage 5.
local function buildPedestal(baseIdx, slotIdx, position)
	local center = Vector3.new(position.X, 1.25, position.Z)
	local pedestal = Instance.new("Part")
	pedestal.Name = "Pedestal" .. tostring(slotIdx)
	pedestal.Shape = Enum.PartType.Cylinder
	pedestal.Size = Vector3.new(0.9, 6, 6)
	pedestal.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
	pedestal.Material = Enum.Material.SmoothPlastic
	pedestal.Color = Color3.fromRGB(200, 185, 150)
	pedestal.Anchored = true
	pedestal.Parent = WorldFolder

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Taruh"
	prompt.ObjectText = ""
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.STEAL_RANGE
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("PromptKind", "Place")
	prompt:SetAttribute("OwnerUserId", 0)
	prompt:SetAttribute("SlotFilled", false)
	prompt:SetAttribute("BaseIdx", baseIdx)
	prompt:SetAttribute("SlotIdx", slotIdx)
	prompt.Parent = pedestal
	return prompt
end

-- Papan nama pemilik di atas base (DESIGN.md 4): BillboardGui 200x110
-- di y = 20,5, menampilkan nama pemilik atau "BASE n" kalau kosong,
-- plus foto kepala pemilik. Teks diisi refreshOwnerBoard.
local function buildOwnerBoard(baseIdx, xCenter, zCenter)
	local anchor = makeAnchor(
		"OwnerBoardAnchor" .. tostring(baseIdx),
		Vector3.new(xCenter, 20.5, zCenter)
	)
	local board = Instance.new("BillboardGui")
	board.Name = "OwnerBoard"
	board.Size = UDim2.fromOffset(200, 110)
	board.AlwaysOnTop = false
	board.LightInfluence = 0
	board.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Name = "OwnerName"
	label.Size = UDim2.new(1, 0, 0.6, 0)
	label.Position = UDim2.new(0, 0, 0.4, 0)
	label.BackgroundTransparency = 0.3
	label.BackgroundColor3 = Color3.fromRGB(30, 25, 20)
	label.TextColor3 = Color3.fromRGB(255, 240, 200)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = "BASE " .. tostring(baseIdx)
	label.Parent = board

	local image = Instance.new("ImageLabel")
	image.Name = "OwnerHeadshot"
	image.Size = UDim2.new(0.4, 0, 0.4, 0)
	image.Position = UDim2.new(0.3, 0, 0, 0)
	image.BackgroundTransparency = 1
	image.Image = ""
	image.Parent = board

	return board, label, image
end

-- Papan "make.fun" sebagai identitas kompetisi (DESIGN.md 4, 9):
-- papan berdiri di tepi utara base dengan tulisan make.fun.
local function buildMakeFunBoard(baseIdx, xCenter, zCenter)
	local sign = makePart(
		"MakeFunBoard" .. tostring(baseIdx),
		Vector3.new(12, 4, 0.5),
		Vector3.new(xCenter, 4, zCenter - 25),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(40, 35, 30)
	)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 210, 80)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = "make.fun"
	label.Parent = gui
	return sign
end

-- Dinding + pintu kaca lock (DESIGN.md 4, 19.1). Saat terkunci, kaca
-- muncul (Transparency 0,5, CanCollide); saat terbuka, kaca tersembunyi
-- (Transparency 1, CanCollide false). Semua bagian disimpan di GlassParts
-- dan diubah setLockVisual. Pintu berada di sisi dalam (menghadap conveyor).
local function buildLockGlass(xCenter, zCenter, doorX, isLeft)
	local glass = {}
	local glassColor = Color3.fromRGB(170, 210, 255)
	local function glassPart(name, size, position)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.Position = position
		part.Material = Enum.Material.Glass
		part.Color = glassColor
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.Parent = WorldFolder
		table.insert(glass, part)
		return part
	end
	-- Dinding sisi pintu: dua segmen yang mengapit bukaan pintu (lebar 6).
	glassPart("GlassDoorSideA", Vector3.new(0.5, 6, 20), Vector3.new(doorX, 3.8, zCenter - 13))
	glassPart("GlassDoorSideB", Vector3.new(0.5, 6, 20), Vector3.new(doorX, 3.8, zCenter + 13))
	-- Dinding sisi luar (berlawanan dengan pintu).
	local farX = xCenter + (isLeft and -28 or 28)
	glassPart("GlassFarWall", Vector3.new(0.5, 6, 46), Vector3.new(farX, 3.8, zCenter))
	-- Dinding utara + selatan.
	glassPart("GlassNorthWall", Vector3.new(56, 6, 0.5), Vector3.new(xCenter, 3.8, zCenter - 23))
	glassPart("GlassSouthWall", Vector3.new(56, 6, 0.5), Vector3.new(xCenter, 3.8, zCenter + 23))
	-- Pintu kaca (menutup saat terkunci).
	glassPart("GlassDoor", Vector3.new(0.5, 6, 6), Vector3.new(doorX, 3.8, zCenter))
	return glass
end

-- Satu base lengkap (DESIGN.md 2, 4): lantai 56 x 0,8 x 46 (atas y = 0,8),
-- 6 pedestal, papan nama, papan make.fun, kaca lock, LockBarrier, lampu base.
-- Mengisi World.PedestalPos[baseIdx], World.BaseCenter[baseIdx],
-- dan BaseVisuals[baseIdx].
local function buildBase(baseIdx, xCenter, zCenter)
	local isLeft = xCenter < 0
	local doorX = Config.doorX(xCenter)

	local floor = makePart(
		"BaseFloor" .. tostring(baseIdx),
		Vector3.new(56, 0.8, 46),
		Vector3.new(xCenter, 0.4, zCenter),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(170, 150, 120)
	)
	floor.Name = "BaseFloor" .. tostring(baseIdx)

	World.BaseCenter[baseIdx] = Vector3.new(xCenter, 0.8, zCenter)
	World.PedestalPos[baseIdx] = {}

	local prompts = {}
	local slotModels = {}
	for slotIdx = 1, Config.SLOT_COUNT do
		local pos = Config.slotPosition(xCenter, zCenter, slotIdx)
		World.PedestalPos[baseIdx][slotIdx] = pos
		prompts[slotIdx] = buildPedestal(baseIdx, slotIdx, pos)
		slotModels[slotIdx] = nil
	end

	local board, boardLabel, boardImage = buildOwnerBoard(baseIdx, xCenter, zCenter)
	local makeFunBoard = buildMakeFunBoard(baseIdx, xCenter, zCenter)
	local glassParts = buildLockGlass(xCenter, zCenter, doorX, isLeft)

	-- LockBarrier (DESIGN.md 19.1): volume pemicu di pintu, 1,5 x 12 x 42.
	-- Tersembunyi dan tidak menghalangi saat tidak terkunci; pemain yang
	-- bukan pemilik dan menyentuhnya saat base terkunci di-teleport keluar
	-- (wiring Touched masuk bersama penanganan lock, Stage 3).
	local barrier = Instance.new("Part")
	barrier.Name = "LockBarrier" .. tostring(baseIdx)
	barrier.Size = Vector3.new(1.5, 12, 42)
	barrier.Position = Vector3.new(doorX, 6, zCenter)
	barrier.Material = Enum.Material.SmoothPlastic
	barrier.Color = Color3.fromRGB(255, 80, 80)
	barrier.Transparency = 1
	barrier.Anchored = true
	barrier.CanCollide = false
	barrier.CanQuery = true
	barrier.Parent = WorldFolder

	-- Lampu base sendiri: PointLight Range 30 (DESIGN.md 2).
	local lampAnchor = makeAnchor(
		"BaseLight" .. tostring(baseIdx),
		Vector3.new(xCenter, 10, zCenter)
	)
	addPointLight(lampAnchor, 30, Color3.fromRGB(255, 200, 120), 2)

	BaseVisuals[baseIdx] = {
		Floor = floor,
		GlassParts = glassParts,
		LockBarrier = barrier,
		OwnerBoard = board,
		BoardLabel = boardLabel,
		BoardImage = boardImage,
		MakeFunBoard = makeFunBoard,
		Prompts = prompts,
		SlotModels = slotModels,
	}
end

-- 8 base: 4 di sisi kiri (xCenter = -68), 4 di sisi kanan (xCenter = +68);
-- zCenter tiap base: 90, 25, -40, -105 (DESIGN.md 2).
-- Nomor base: 1-4 kiri, 5-8 kanan.
local function buildBases()
	for sideIdx, xCenter in ipairs(Config.BASE_X) do
		for zIdx, zCenter in ipairs(Config.BASE_Z) do
			local baseIdx = (sideIdx - 1) * 4 + zIdx
			buildBase(baseIdx, xCenter, zCenter)
		end
	end
end

-- Gapura/gerbang di utara dan selatan map (DESIGN.md 2).
local function buildGate(zCenter, label)
	local pillarColor = Color3.fromRGB(150, 60, 50)
	makePart("GatePillarL", Vector3.new(4, 14, 4), Vector3.new(-10, 7, zCenter), Enum.Material.SmoothPlastic, pillarColor)
	makePart("GatePillarR", Vector3.new(4, 14, 4), Vector3.new(10, 7, zCenter), Enum.Material.SmoothPlastic, pillarColor)
	local beam = makePart("GateBeam", Vector3.new(26, 3, 4), Vector3.new(0, 15.5, zCenter), Enum.Material.WoodPlanks, Color3.fromRGB(120, 80, 40))
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.Parent = beam
	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.TextColor3 = Color3.fromRGB(255, 220, 130)
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.Text = label
	text.Parent = gui
end

local function buildGates()
	buildGate(195, "PASAR BRAINROT")
	buildGate(-195, "PASAR BRAINROT")
end

-- Deretan bangunan kota di kejauhan sebagai latar (DESIGN.md 2):
-- dua baris di x = +/-162 dan dua baris di z = +/-202. Tinggi dan warna
-- bervariasi mengikuti indeks supaya skyline tidak monoton.
local function buildCity()
	local palette = {
		Color3.fromRGB(70, 65, 80),
		Color3.fromRGB(85, 70, 60),
		Color3.fromRGB(60, 75, 70),
		Color3.fromRGB(90, 80, 70),
	}
	local function building(name, x, z, height, color)
		makePart(name, Vector3.new(18, height, 18), Vector3.new(x, height / 2, z), Enum.Material.SmoothPlastic, color)
	end
	for side = 1, 2 do
		local x = side == 1 and -162 or 162
		for i = 0, 10 do
			local z = -200 + i * 40
			local height = 20 + ((i * 13) % 35)
			building("CityBuilding", x, z, height, palette[(i % #palette) + 1])
		end
	end
	for side = 1, 2 do
		local z = side == 1 and -202 or 202
		for i = 0, 10 do
			local x = -150 + i * 30
			local height = 18 + ((i * 11) % 30)
			building("CityBuilding", x, z, height, palette[((i + 2) % #palette) + 1])
		end
	end
end

-- Pepohonan di tepi conveyor: 48 pohon (DESIGN.md 2), x = +/-20,
-- z dari -184 sampai 184 tiap 16 stud. Batang + tajuk bola.
local function buildTrees()
	for side = 1, 2 do
		local x = side == 1 and -20 or 20
		for i = 0, 23 do
			local z = -184 + i * 16
			makePart("TreeTrunk", Vector3.new(1.5, 6, 1.5), Vector3.new(x, 3, z), Enum.Material.WoodPlanks, Color3.fromRGB(110, 75, 40))
			local leaves = Instance.new("Part")
			leaves.Name = "TreeLeaves"
			leaves.Shape = Enum.PartType.Ball
			leaves.Size = Vector3.new(5.5, 5.5, 5.5)
			leaves.Position = Vector3.new(x, 8, z)
			leaves.Material = Enum.Material.SmoothPlastic
			leaves.Color = Color3.fromRGB(50, 140, 70)
			leaves.Anchored = true
			leaves.Parent = WorldFolder
		end
	end
end

-- 14 lampu jalan (DESIGN.md 2): tiang + bola Neon + PointLight hangat
-- Range 22. 12 di sepanjang conveyor, 2 di plaza selatan.
local function buildLamps()
	local lampPositions = {}
	for _, z in ipairs({ -150, -90, -30, 30, 90, 150 }) do
		table.insert(lampPositions, Vector3.new(-20, 0, z))
		table.insert(lampPositions, Vector3.new(20, 0, z))
	end
	table.insert(lampPositions, Vector3.new(-40, 0, 155))
	table.insert(lampPositions, Vector3.new(40, 0, 155))
	for _, base in ipairs(lampPositions) do
		makePart("LampPole", Vector3.new(0.6, 8, 0.6), Vector3.new(base.X, 4, base.Z), Enum.Material.SmoothPlastic, Color3.fromRGB(50, 50, 55))
		local head = makePart("LampHead", Vector3.new(2, 2, 2), Vector3.new(base.X, 8.3, base.Z), Enum.Material.Neon, Color3.fromRGB(255, 200, 100))
		head.Shape = Enum.PartType.Ball
		addPointLight(head, 22, Color3.fromRGB(255, 200, 120), 2)
	end
end

-- Bangun seluruh dunia dalam urutan PLAN Langkah 3.
local function buildWorld()
	setupLighting()
	buildTerrain()
	buildConveyor()
	buildPlaza()
	buildBases()
	buildGates()
	buildCity()
	buildTrees()
	buildLamps()
end

-- ============================================================================
-- Visual per base (milik Main)
-- ============================================================================

-- Tampilkan / sembunyikan kaca lock base (DESIGN.md 19.1):
-- terkunci -> Transparency 0,5 + CanCollide; terbuka -> Transparency 1
-- + CanCollide false. Dipanggil handler LockRequest + auto-unlock (Stage 3).
local function setLockVisual(baseIdx, locked)
	local visuals = BaseVisuals[baseIdx]
	if visuals == nil then
		return
	end
	for _, glass in ipairs(visuals.GlassParts) do
		glass.Transparency = locked and 0.5 or 1
		glass.CanCollide = locked
	end
end

-- Perbarui papan nama base (DESIGN.md 4): nama pemilik + foto kepala,
-- atau "BASE n" kalau kosong. Dipanggil assignBase / releaseBase.
local function refreshOwnerBoard(baseIdx)
	local visuals = BaseVisuals[baseIdx]
	if visuals == nil then
		return
	end
	local owner = nil
	for player, state in pairs(Players) do
		if state.Base == baseIdx then
			owner = player
			break
		end
	end
	if owner ~= nil then
		visuals.BoardLabel.Text = owner.DisplayName
		local ok, thumbnail = pcall(function()
			return PlayersService:GetUserThumbnailAsync(
				owner.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size100x100
			)
		end)
		if ok and typeof(thumbnail) == "string" then
			visuals.BoardImage.Image = thumbnail
		else
			visuals.BoardImage.Image = ""
		end
	else
		visuals.BoardLabel.Text = "BASE " .. tostring(baseIdx)
		visuals.BoardImage.Image = ""
	end
end

-- Perbarui visual pedestal setelah slot berubah (DESIGN.md 4):
-- atribut prompt (SlotFilled, OwnerUserId, PromptKind, ActionText)
-- disesuaikan isi slot; model Brainrot di pedestal dihapus kalau slot
-- kosong. Pembuatan model Brainrot untuk slot terisi masuk bersama
-- wiring taruh / curi (Stage 2-3).
local function refreshSlotVisual(baseIdx, slotIdx)
	local visuals = BaseVisuals[baseIdx]
	if visuals == nil then
		return
	end
	local owner = nil
	local ownerState = nil
	for player, state in pairs(Players) do
		if state.Base == baseIdx then
			owner = player
			ownerState = state
			break
		end
	end
	local slot = nil
	if ownerState ~= nil then
		slot = ownerState.Slots[slotIdx]
	end
	local prompt = visuals.Prompts[slotIdx]
	if prompt ~= nil then
		prompt:SetAttribute("SlotFilled", slot ~= nil)
		prompt:SetAttribute("OwnerUserId", owner ~= nil and owner.UserId or 0)
		if slot ~= nil then
			prompt:SetAttribute("PromptKind", "Sell")
			prompt.ActionText = "Jual"
		else
			prompt:SetAttribute("PromptKind", "Place")
			prompt.ActionText = "Taruh"
		end
	end
	if slot == nil then
		local model = visuals.SlotModels[slotIdx]
		if model ~= nil then
			model:Destroy()
			visuals.SlotModels[slotIdx] = nil
		end
	end
end

-- ============================================================================
-- assignBase / releaseBase (PLAN Langkah 4)
-- ============================================================================

-- Beri base kosong pertama kepada pemain; kembalikan nomor base atau nil
-- kalau semua base penuh. Memperbarui state.Base + papan nama + prompt.
local function assignBase(player)
	local state = Players[player]
	if state == nil then
		return nil
	end
	for baseIdx = 1, 8 do
		local taken = false
		for _, otherState in pairs(Players) do
			if otherState.Base == baseIdx then
				taken = true
				break
			end
		end
		if not taken then
			state.Base = baseIdx
			refreshOwnerBoard(baseIdx)
			for slotIdx = 1, Config.SLOT_COUNT do
				refreshSlotVisual(baseIdx, slotIdx)
			end
			return baseIdx
		end
	end
	return nil
end

-- Bersihkan base milik pemain: slot + carried dihapus dari state, kaca
-- lock disembunyikan, papan nama kembali "BASE n", state.Base = nil.
-- Dipanggil onPlayerRemoving SEBELUM entri Players dihapus.
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
	state.Locked = false
	state.LockExpiresAt = nil
	setLockVisual(baseIdx, false)
	state.Base = nil
	refreshOwnerBoard(baseIdx)
	for slotIdx = 1, Config.SLOT_COUNT do
		refreshSlotVisual(baseIdx, slotIdx)
	end
end

-- ============================================================================
-- Lifecycle pemain, STAGE 1 (PLAN Langkah 4A — tanpa pemuatan data)
-- ============================================================================

-- Saat pemain masuk: buat PlayerState default dengan LoadStatus "ok"
-- (TIDAK ADA load, TIDAK ADA LoadToken, TIDAK ADA load gating di Stage 1),
-- lalu tetapkan base kosong pertama.
local function onPlayerAdded(player)
	local state = {
		Money = Config.START_MONEY,
		Rebirths = 0,
		IncomeMult = 1,
		Base = nil,
		Slots = {},
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
	Players[player] = state
	local baseIdx = assignBase(player)
	if baseIdx == nil then
		warn("PasarBrainrot: tidak ada base kosong untuk " .. player.Name)
	end
end

-- Saat pemain keluar (Stage 1): lepas base + hapus entri Players.
-- TANPA save — belum ada penyimpanan di Stage 1.
local function onPlayerRemoving(player)
	releaseBase(player)
	Players[player] = nil
end

-- Saat server tutup (Stage 1): tidak melakukan apa pun.
-- Penyimpanan semua pemain online baru masuk pada Stage 2.
local function onBindToClose()
end

-- ============================================================================
-- Loop utama 1 detik (PLAN Langkah 6 — SATU-SATUNYA loop, milik Main)
-- Stage 1: loop KOSONG (kerangka saja). Tick ditambahkan per stage:
-- Stage 2 income, Stage 3 lock expiry, Stage 4 flood + crate expiry.
-- ============================================================================

local function startMainLoop()
	task.spawn(function()
		while true do
			task.wait(1)
			-- Stage 1: belum ada tick apa pun.
		end
	end)
end

-- ============================================================================
-- Startup
-- ============================================================================

createRemotes()
buildWorld()

PlayersService.PlayerAdded:Connect(onPlayerAdded)
PlayersService.PlayerRemoving:Connect(onPlayerRemoving)
game:BindToClose(onBindToClose)

-- Tangkap pemain yang sudah ada sebelum script ini jalan (Studio).
for _, player in ipairs(PlayersService:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

startMainLoop()
