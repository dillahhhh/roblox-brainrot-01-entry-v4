-- Flood.luau
-- Mesin state flood (Pasar Tumpah) + peti hadiah.
-- Ditulis baru dari DESIGN.md bag. 7 dan kontrak bag. 13 — tanpa membaca
-- source lama. Satu-satunya file yang ditulis oleh implementor ini.
--
-- Siklus: Idle -> Warning (10 dtk, spawn dijeda, sirene) -> Flooding
-- (dinding air kaca biru utara -> selatan, ~6 dtk) -> Scramble (60 dtk,
-- peti bisa diklaim) -> Idle. Flood pertama 120 dtk setelah server mulai,
-- lalu tiap 180 dtk (diukur dari awal satu flood ke awal flood berikut).
--
-- Aturan sapu: Brainrot di conveyor dan Brainrot yang dibawa pemain DI LUAR
-- base sendiri tersapu; Brainrot di slot base SELALU AMAN. Tiap yang tersapu
-- -> 1 peti. Kalau tidak ada yang tersapu -> 3 peti fallback. Kalau setelah
-- spawn jumlah peti 0 -> paksa 3 peti fallback. Setiap spawn dibungkus pcall
-- dan kegagalan dicatat dengan warn (tidak pernah ditelan diam-diam).
--
-- Kontrak deps (tabel yang diberikan Main lewat startCycle(deps) / init(deps)).
-- Semua field opsional; kalau tidak ada, modul memakai fallback internal
-- (RemoteEvent FloodEvent, Sound sirene, model peti sederhana). Field yang
-- dikenali Main:
--   config               tabel konfigurasi (kalau ada, menimpa konstanta lokal)
--   broadcastPhase(phase, secondsLeft)   kirim fase ke client (FloodEvent)
--   playSiren() / stopSiren()            bunyikan / hentikan sirene banjir
--   setSpawningPaused(paused)            jeda / lanjutkan spawn Brainrot baru
--   getPlayersState() -> tabel Players Main (key = Player)
--   getConveyorBrainrots() -> array {Uid, Kind, Rarity, ...} di conveyor
--   removeConveyorBrainrot(uid)          hapus Brainrot itu dari conveyor
--   buildCrateVisual(crate) -> Model     bangun model peti (atau nil)
--   removeCrateVisual(crate)             hapus model peti
--   onCrateClaimed(player, crate)        hook setelah klaim sukses
--   onBrainrotWashed(player, carried)    hook saat Brainrot dibawa tersapu
--   clearCarriedVisual(player)           hapus visual bawaan pemain
--   setConveyorReversed(reversed)        beri tahu Main arah conveyor berbalik
--   animateWaterWall(seconds)            animasikan dinding air (atau nil)
--   spawnDebris()                        tebarkan debris (atau nil)
--   notifyPlayer(player, text)           kirim pesan singkat ke pemain
--
-- API publik modul:
--   Flood.Crates            tabel peti aktif, key = crateId:
--                           {Id, Kind, Rarity, Position, Claimed, ...}
--   Flood.Phase             fase aktif: "Idle" | "Warning" | "Flooding"
--                           | "Scramble"
--   Flood.ConveyorReversed  boolean; berbalik (toggle) tiap flood selesai.
--                           Main membaca flag ini untuk membalik arah conveyor.
--   Flood.init(deps)                    simpan deps tanpa memulai siklus
--   Flood.startCycle(deps)              mulai loop siklus flood (sekali saja)
--   Flood.stopCycle()                   hentikan loop siklus dengan sopan
--   Flood.spawnCrates(washed)           spawn peti dari daftar yang tersapu
--   Flood.claimCrate(player, players, crateId)  klaim satu peti
--   Flood.applyFloodEffects()           debris + knockback ringan
--   Flood.collectWashed()               kumpulkan Brainrot yang tersapu

local PlayersService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local DebrisService = game:GetService("Debris")

local Flood = {}

-- ============================================================================
-- Konstanta (nilai dari DESIGN.md bag. 7 & 13; deps.config boleh menimpa)
-- ============================================================================
local DEFAULT_CONFIG = {
	FLOOD_FIRST = 120, -- detik sampai flood pertama setelah server mulai
	FLOOD_INTERVAL = 180, -- detik antar awal flood
	WARNING_TIME = 10, -- detik fase Warning
	FLOOD_TIME = 6, -- detik fase Flooding (dinding air utara -> selatan)
	SCRAMBLE_TIME = 60, -- detik fase Scramble (peti bisa diklaim)
	CRATE_LIFETIME = 60, -- detik peti tak diklaim sebelum dihapus
	SIREN_SOUND_ID = "rbxassetid://792323017", -- "Tornado Siren"
	BASE_X = { -68, 68 },
	BASE_Z = { 90, 25, -40, -105 },
	BASE_HALF_X = 28, -- batas base: +-28 x dari pusat base
	BASE_HALF_Z = 23, -- batas base: +-23 z dari pusat base
	CLAIM_RANGE = 18, -- jarak maks pemain ke peti saat klaim (stud)
	FALLBACK_CRATE_COUNT = 3,
}

-- Roster: nama -> rarity (DESIGN.md bag. 3). Dipakai untuk menentukan kelas
-- peti dari Brainrot yang tersapu dan untuk fallback.
local KIND_TO_RARITY = {
	["Ayam Ikan"] = "Common",
	["Babi Terbang"] = "Uncommon",
	["Anjing Es Teh"] = "Rare",
	["Kucing Rendang"] = "Epic",
	["Beruang Durian"] = "Legendary",
	["Harimau Api"] = "Mythic",
	["Gajah Gamelan"] = "Ultra Rare",
}

-- Urutan rarity dari rendah ke tinggi (untuk peluang naik tingkat).
local RARITY_ORDER = {
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
	"Ultra Rare",
}

-- Warna rarity (DESIGN.md bag. 3).
local RARITY_COLORS = {
	["Common"] = Color3.fromRGB(220, 220, 220),
	["Uncommon"] = Color3.fromRGB(110, 220, 110),
	["Rare"] = Color3.fromRGB(65, 165, 255),
	["Epic"] = Color3.fromRGB(185, 85, 255),
	["Legendary"] = Color3.fromRGB(255, 140, 40),
	["Mythic"] = Color3.fromRGB(255, 65, 65),
	["Ultra Rare"] = Color3.fromRGB(255, 225, 0),
}

-- Kelas peti: nama kelas, warna peti, dan lokasi spawn.
local CRATE_CLASSES = {
	Pasar = {
		DisplayName = "Peti Pasar",
		Color = Color3.fromRGB(110, 220, 110),
	},
	Pedagang = {
		DisplayName = "Peti Pedagang",
		Color = Color3.fromRGB(255, 225, 0),
	},
	Tumpah = {
		DisplayName = "Peti Tumpah",
		Color = Color3.fromRGB(185, 85, 255),
	},
}

-- Peluang naik satu tingkat rarity saat peti dibuat (DESIGN.md bag. 7).
-- Hanya rarity yang disebut di spesifikasi yang punya peluang naik tingkat.
local UPGRADE_CHANCE = {
	["Rare"] = 0.40,
	["Epic"] = 0.25,
	["Legendary"] = 0.50,
}

local FALLBACK_KINDS = { "Ayam Ikan", "Babi Terbang" }

-- ============================================================================
-- State modul
-- ============================================================================
Flood.Crates = {}
Flood.Phase = "Idle"
Flood.ConveyorReversed = false

local _deps = nil
local _running = false
local _crateCounter = 0
local _sirenSound = nil

-- ============================================================================
-- Util kecil
-- ============================================================================
local function getConfig()
	if _deps ~= nil and type(_deps.config) == "table" then
		return _deps.config
	end
	return DEFAULT_CONFIG
end

local function cfg(key)
	local config = getConfig()
	local value = config[key]
	if value == nil then
		value = DEFAULT_CONFIG[key]
	end
	return value
end

local function countCrates()
	local n = 0
	for _ in pairs(Flood.Crates) do
		n = n + 1
	end
	return n
end

local function rarityIndex(rarity)
	for i, name in ipairs(RARITY_ORDER) do
		if name == rarity then
			return i
		end
	end
	return 1
end

local function nextRarity(rarity)
	local i = rarityIndex(rarity)
	if i < #RARITY_ORDER then
		return RARITY_ORDER[i + 1]
	end
	return rarity
end

-- Kelas peti dari rarity: Common/Uncommon -> Pasar; Rare/Epic -> Pedagang;
-- Legendary/Mythic/Ultra Rare -> Tumpah.
local function classForRarity(rarity)
	local i = rarityIndex(rarity)
	if i <= 2 then
		return "Pasar"
	elseif i <= 4 then
		return "Pedagang"
	else
		return "Tumpah"
	end
end

-- Terapkan peluang naik tingkat (DESIGN.md bag. 7). Kembalikan rarity akhir.
-- Asumsi yang dilaporkan: naik tingkat berarti rarity naik satu anak tangga
-- (Rare -> Epic, Epic -> Legendary, Legendary -> Mythic); kelas peti
-- dihitung ulang dari rarity akhir, jadi Epic yang naik menjadi Tumpah.
local function rollUpgrade(rarity)
	local chance = UPGRADE_CHANCE[rarity]
	if chance ~= nil and math.random() < chance then
		return nextRarity(rarity)
	end
	return rarity
end

local function newCrateId()
	_crateCounter = _crateCounter + 1
	return "crate-" .. tostring(_crateCounter) .. "-" .. tostring(math.random(1000, 9999))
end

local function safeCall(fn, ...)
	if fn == nil then
		return false
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[Flood] deps callback gagal: " .. tostring(err))
	end
	return ok
end

-- ============================================================================
-- Komunikasi ke client / dunia (pakai deps kalau ada, fallback internal)
-- ============================================================================
local function broadcastPhase(phase, secondsLeft)
	Flood.Phase = phase
	if _deps ~= nil and type(_deps.broadcastPhase) == "function" then
		local ok = safeCall(_deps.broadcastPhase, phase, secondsLeft)
		if ok then
			return
		end
	end
	-- Fallback: kirim langsung lewat RemoteEvent FloodEvent.
	local ok, err = pcall(function()
		local remotes = ReplicatedStorage:FindFirstChild("GameRemotes")
		if remotes == nil then
			return
		end
		local event = remotes:FindFirstChild("FloodEvent")
		if event ~= nil then
			event:FireAllClients(phase, secondsLeft)
		end
	end)
	if not ok then
		warn("[Flood] broadcastPhase gagal: " .. tostring(err))
	end
end

local function playSiren()
	if _deps ~= nil and type(_deps.playSiren) == "function" then
		if safeCall(_deps.playSiren) then
			return
		end
	end
	-- Fallback: Sound sirene di Workspace, loop selama Warning.
	local ok, err = pcall(function()
		if _sirenSound ~= nil then
			_sirenSound:Play()
			return
		end
		local sound = Instance.new("Sound")
		sound.Name = "FloodSiren"
		sound.SoundId = cfg("SIREN_SOUND_ID")
		sound.Volume = 0.6
		sound.Looped = true
		sound.Parent = workspace
		sound:Play()
		_sirenSound = sound
	end)
	if not ok then
		warn("[Flood] playSiren gagal: " .. tostring(err))
	end
end

local function stopSiren()
	if _deps ~= nil and type(_deps.stopSiren) == "function" then
		if safeCall(_deps.stopSiren) then
			return
		end
	end
	local ok, err = pcall(function()
		if _sirenSound ~= nil then
			_sirenSound:Stop()
		end
	end)
	if not ok then
		warn("[Flood] stopSiren gagal: " .. tostring(err))
	end
end

local function setSpawningPaused(paused)
	if _deps ~= nil and type(_deps.setSpawningPaused) == "function" then
		safeCall(_deps.setSpawningPaused, paused)
	end
	-- Tanpa deps, tidak ada yang bisa dijeda dari modul ini; Main yang
	-- memiliki loop spawn harus memasang hook setSpawningPaused.
end

local function getPlayersState()
	if _deps ~= nil and type(_deps.getPlayersState) == "function" then
		local ok, result = pcall(_deps.getPlayersState)
		if ok and type(result) == "table" then
			return result
		end
		if not ok then
			warn("[Flood] getPlayersState gagal: " .. tostring(result))
		end
	end
	return nil
end

local function notifyPlayer(player, text)
	if _deps ~= nil and type(_deps.notifyPlayer) == "function" then
		safeCall(_deps.notifyPlayer, player, text)
		return
	end
	local ok, err = pcall(function()
		local remotes = ReplicatedStorage:FindFirstChild("GameRemotes")
		if remotes == nil then
			return
		end
		local event = remotes:FindFirstChild("Notify")
		if event ~= nil then
			event:FireClient(player, text)
		end
	end)
	if not ok then
		warn("[Flood] notifyPlayer gagal: " .. tostring(err))
	end
end

-- ============================================================================
-- Posisi base & peti
-- ============================================================================
-- Pusat base untuk nomor base 1..8. Base 1-4 sisi kiri (x=-68), 5-8 sisi
-- kanan (x=+68); zCenter: 90, 25, -40, -105 (DESIGN.md bag. 2 & 13).
local function baseCenterFor(baseIndex)
	local baseX = cfg("BASE_X")
	local baseZ = cfg("BASE_Z")
	if type(baseIndex) ~= "number" or baseIndex < 1 or baseIndex > 8 then
		return nil
	end
	local side = 1
	local row = baseIndex
	if baseIndex > 4 then
		side = 2
		row = baseIndex - 4
	end
	return Vector3.new(baseX[side], 0, baseZ[row])
end

-- Apakah posisi berada di dalam base sendiri (batas +-28 x, +-23 z)?
local function isInsideOwnBase(position, baseIndex)
	local center = baseCenterFor(baseIndex)
	if center == nil then
		return false
	end
	return math.abs(position.X - center.X) <= cfg("BASE_HALF_X")
		and math.abs(position.Z - center.Z) <= cfg("BASE_HALF_Z")
end

-- Posisi spawn peti menurut kelasnya (DESIGN.md bag. 7).
local function pickCratePosition(className)
	if className == "Pasar" then
		-- Dekat pintu base: pilih satu base acak, di sisi pintunya.
		-- Pintu di sisi dalam (menghadap conveyor): DoorX = xCenter + 27
		-- (base kiri) atau xCenter - 27 (base kanan).
		local baseX = cfg("BASE_X")
		local baseZ = cfg("BASE_Z")
		local side = math.random(1, 2)
		local row = math.random(1, 4)
		local xCenter = baseX[side]
		local doorX = xCenter + 27
		if side == 2 then
			doorX = xCenter - 27
		end
		local z = baseZ[row] + math.random(-10, 10)
		return Vector3.new(doorX, 1, z)
	elseif className == "Tumpah" then
		-- Utara jauh (ujung utara map, jauh dari plaza).
		return Vector3.new(math.random(-40, 40), 1, math.random(-190, -160))
	else
		-- Pedagang: tengah plaza (plaza selatan, sekitar z=155).
		return Vector3.new(math.random(-40, 40), 1, math.random(130, 170))
	end
end

-- ============================================================================
-- Visual peti (fallback internal; Main boleh menimpa lewat buildCrateVisual)
-- ============================================================================
local function getCratesFolder()
	local folder = workspace:FindFirstChild("Crates")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "Crates"
		folder.Parent = workspace
	end
	return folder
end

-- Bangun model peti sederhana: kotak + tutup + label + ProximityPrompt
-- "Buka Peti" (tahan 0,5 detik) + model Brainrot di atasnya (skala 1,6).
-- Dipakai hanya kalau Main tidak menyediakan buildCrateVisual.
local function buildCrateModel(crate)
	local classInfo = CRATE_CLASSES[crate.Class] or CRATE_CLASSES.Pasar
	local rarityColor = RARITY_COLORS[crate.Rarity] or RARITY_COLORS.Common

	local model = Instance.new("Model")
	model.Name = crate.Id

	local base = Instance.new("Part")
	base.Name = "Chest"
	base.Size = Vector3.new(4, 2.4, 3)
	base.Position = crate.Position + Vector3.new(0, 1.2, 0)
	base.Anchored = true
	base.CanCollide = true
	base.Material = Enum.Material.WoodPlanks
	base.Color = classInfo.Color
	base.Parent = model

	local lid = Instance.new("Part")
	lid.Name = "Lid"
	lid.Size = Vector3.new(4.2, 0.8, 3.2)
	lid.Position = crate.Position + Vector3.new(0, 2.8, 0)
	lid.Anchored = true
	lid.CanCollide = false
	lid.Material = Enum.Material.Metal
	lid.Color = classInfo.Color
	lid.Parent = model

	-- Cahaya emas untuk Peti Tumpah (ungu + cahaya emas).
	if crate.Class == "Tumpah" then
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 225, 0)
		light.Range = 16
		light.Brightness = 2
		light.Parent = base
	end

	-- Model Brainrot di atas peti (skala 1,6): bola berwarna rarity.
	local display = Instance.new("Part")
	display.Name = "BrainrotDisplay"
	display.Shape = Enum.PartType.Ball
	display.Size = Vector3.new(1.6, 1.6, 1.6)
	display.Position = crate.Position + Vector3.new(0, 4.2, 0)
	display.Anchored = true
	display.CanCollide = false
	display.Material = Enum.Material.SmoothPlastic
	display.Color = rarityColor
	display.Parent = model

	local gui = Instance.new("BillboardGui")
	gui.Name = "CrateLabel"
	gui.Size = UDim2.new(0, 160, 0, 50)
	gui.StudsOffset = Vector3.new(0, 3.5, 0)
	gui.AlwaysOnTop = true
	gui.Parent = display

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = classInfo.DisplayName .. "\n" .. crate.Kind .. " (" .. crate.Rarity .. ")"
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Font = Enum.Font.SourceSansBold
	label.Parent = gui

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Buka Peti"
	prompt.ObjectText = classInfo.DisplayName
	prompt.HoldDuration = 0.5
	prompt.RequiresLineOfSight = false
	prompt.Parent = base
	prompt.Triggered:Connect(function(player)
		Flood.claimCrate(player, nil, crate.Id)
	end)

	model.Parent = getCratesFolder()
	return model
end

local function removeCrateVisual(crate)
	if _deps ~= nil and type(_deps.removeCrateVisual) == "function" then
		if safeCall(_deps.removeCrateVisual, crate) then
			return
		end
	end
	local ok, err = pcall(function()
		if crate.Model ~= nil then
			crate.Model:Destroy()
			crate.Model = nil
			return
		end
		local folder = workspace:FindFirstChild("Crates")
		if folder ~= nil then
			local model = folder:FindFirstChild(crate.Id)
			if model ~= nil then
				model:Destroy()
			end
		end
	end)
	if not ok then
		warn("[Flood] removeCrateVisual gagal untuk " .. tostring(crate.Id) .. ": " .. tostring(err))
	end
end

-- Hapus peti dari tabel + visual (dipakai saat kedaluwarsa).
local function removeCrate(crateId)
	local crate = Flood.Crates[crateId]
	if crate == nil then
		return
	end
	Flood.Crates[crateId] = nil
	removeCrateVisual(crate)
end

-- ============================================================================
-- spawnCrates(washed)
-- ============================================================================
-- washed: array item yang tersapu, tiap item {Kind = string, Rarity = string}
-- (Rarity boleh kosong — ditebak dari nama Kind; item string polos juga
-- diterima dan dianggap Kind). Kembalikan array id peti yang berhasil dibuat.
local function normalizeWashedItem(item)
	if type(item) == "string" then
		return { Kind = item, Rarity = KIND_TO_RARITY[item] or "Common" }
	end
	if type(item) ~= "table" then
		return nil
	end
	local kind = item.Kind or item.Name
	if type(kind) ~= "string" or kind == "" then
		return nil
	end
	local rarity = item.Rarity
	if type(rarity) ~= "string" or rarity == "" then
		rarity = KIND_TO_RARITY[kind] or "Common"
	end
	return { Kind = kind, Rarity = rarity }
end

local function createOneCrate(kind, rarity)
	-- Peluang naik tingkat dulu, baru tentukan kelas dari rarity akhir.
	local finalRarity = rollUpgrade(rarity)
	local className = classForRarity(finalRarity)
	local classInfo = CRATE_CLASSES[className] or CRATE_CLASSES.Pasar

	local crateId = newCrateId()
	local crate = {
		Id = crateId,
		Kind = kind,
		Rarity = finalRarity,
		Position = pickCratePosition(className),
		Claimed = false,
		Class = className,
		ClassName = classInfo.DisplayName,
		BrainrotUid = HttpService:GenerateGUID(false),
		CreatedAt = os.clock(),
		Model = nil,
	}

	Flood.Crates[crateId] = crate

	-- Visual: utamakan builder Main; kalau gagal / tidak ada, fallback internal.
	-- Kegagalan visual dicatat tapi peti tetap ada (masih bisa diklaim lewat
	-- ClaimRequest) — jangan biarkan satu peti gagal membatalkan yang lain.
	local visualOk = false
	if _deps ~= nil and type(_deps.buildCrateVisual) == "function" then
		local ok, model = pcall(_deps.buildCrateVisual, crate)
		if ok then
			crate.Model = model
			visualOk = true
		else
			warn("[Flood] buildCrateVisual gagal untuk " .. crateId .. ": " .. tostring(model))
		end
	end
	if not visualOk then
		local ok, model = pcall(buildCrateModel, crate)
		if ok then
			crate.Model = model
		else
			warn("[Flood] buildCrateModel gagal untuk " .. crateId .. ": " .. tostring(model))
		end
	end

	-- Peti yang tidak diklaim dihapus setelah CRATE_LIFETIME detik.
	local lifetime = cfg("CRATE_LIFETIME")
	task.delay(lifetime, function()
		local current = Flood.Crates[crateId]
		if current ~= nil and not current.Claimed then
			removeCrate(crateId)
		end
	end)

	return crateId
end

local function spawnFallbackCrates(count)
	local made = {}
	for _ = 1, count do
		local kind = FALLBACK_KINDS[math.random(1, #FALLBACK_KINDS)]
		local ok, crateId = pcall(createOneCrate, kind, KIND_TO_RARITY[kind])
		if ok and crateId ~= nil then
			table.insert(made, crateId)
		else
			warn("[Flood] spawn peti fallback gagal (" .. kind .. "): " .. tostring(crateId))
		end
	end
	return made
end

function Flood.spawnCrates(washed)
	local made = {}

	if washed ~= nil and type(washed) == "table" then
		for _, rawItem in ipairs(washed) do
			local item = normalizeWashedItem(rawItem)
			if item == nil then
				warn("[Flood] spawnCrates: item tersapu tidak valid, dilewati")
			else
				-- Satu kegagalan tidak boleh menggagalkan peti lain.
				local ok, crateId = pcall(createOneCrate, item.Kind, item.Rarity)
				if ok and crateId ~= nil then
					table.insert(made, crateId)
				else
					warn("[Flood] spawnCrates gagal untuk "
						.. tostring(item.Kind)
						.. " ("
						.. tostring(item.Rarity)
						.. "): "
						.. tostring(crateId))
				end
			end
		end
	end

	-- JAMINAN: kalau tidak ada yang tersapu, tetap spawn 3 peti fallback.
	if #made == 0 then
		local fallback = spawnFallbackCrates(cfg("FALLBACK_CRATE_COUNT"))
		for _, crateId in ipairs(fallback) do
			table.insert(made, crateId)
		end
	end

	-- JAMINAN kedua: kalau setelah spawn jumlah peti 0 (mis. semua gagal
	-- lalu fallback ikut gagal), paksa spawn 3 peti fallback sekali lagi.
	if countCrates() == 0 then
		warn("[Flood] spawnCrates: jumlah peti 0 setelah spawn, paksa 3 fallback")
		local fallback = spawnFallbackCrates(cfg("FALLBACK_CRATE_COUNT"))
		for _, crateId in ipairs(fallback) do
			table.insert(made, crateId)
		end
	end

	if countCrates() == 0 then
		warn("[Flood] spawnCrates: GAGAL TOTAL — tidak ada peti yang muncul")
	end

	return made
end

-- ============================================================================
-- claimCrate(player, players, crateId)
-- ============================================================================
-- Validasi: peti ada, belum diklaim, tangan pemain kosong. Kalau lolos:
-- tandai Claimed, beri Brainrot ke Carried pemain, hapus peti.
-- Kembalikan (sukses:boolean, pesan:string).
-- players boleh nil (dipakai state dari deps) atau berupa tabel Players Main.
-- Bentuk lama claimCrate(player, crateId) juga diterima: kalau argumen
-- kedua berupa string dan ketiga nil, argumen kedua dianggap crateId.
function Flood.claimCrate(player, players, crateId)
	if type(players) == "string" and crateId == nil then
		crateId = players
		players = nil
	end

	if type(player) ~= "userdata" and type(player) ~= "table" then
		return false, "Pemain tidak valid."
	end
	if type(crateId) ~= "string" or crateId == "" then
		return false, "Peti tidak valid."
	end

	local crate = Flood.Crates[crateId]
	if crate == nil then
		return false, "Peti tidak ditemukan."
	end
	if crate.Claimed then
		return false, "Peti sudah diklaim pemain lain."
	end

	-- Tangan pemain harus kosong.
	local states = players
	if states == nil then
		states = getPlayersState()
	end
	local state = nil
	if type(states) == "table" then
		state = states[player]
	end
	if state ~= nil and state.Carried ~= nil then
		return false, "Tanganmu penuh — taruh dulu Brainrot yang kamu bawa."
	end

	-- Jarak: pemain harus cukup dekat dengan peti (prompt sudah membatasi
	-- jarak, ini lapisan server-authoritative untuk ClaimRequest).
	local okDistance, distanceErr = pcall(function()
		local character = player.Character
		if character == nil then
			error("karakter tidak ada")
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil then
			error("HumanoidRootPart tidak ada")
		end
		if (root.Position - crate.Position).Magnitude > cfg("CLAIM_RANGE") then
			error("terlalu jauh")
		end
	end)
	if not okDistance then
		if tostring(distanceErr):find("terlalu jauh") ~= nil then
			return false, "Terlalu jauh dari peti."
		end
		-- Karakter belum ada: tolak dengan pesan yang jelas, bukan diam-diam.
		return false, "Karaktermu belum siap."
	end

	-- Lolos semua validasi: klaim atomik di server.
	crate.Claimed = true
	local claimOk, claimErr = pcall(function()
		if state ~= nil then
			state.Carried = { Uid = crate.BrainrotUid, Kind = crate.Kind }
		end
		Flood.Crates[crateId] = nil
		removeCrateVisual(crate)
	end)
	if not claimOk then
		crate.Claimed = false
		Flood.Crates[crateId] = crate
		warn("[Flood] claimCrate gagal saat menerapkan klaim " .. crateId .. ": " .. tostring(claimErr))
		return false, "Gagal membuka peti, coba lagi."
	end

	safeCall(_deps and _deps.onCrateClaimed, player, crate)
	notifyPlayer(player, "Kamu mendapatkan " .. crate.Kind .. " (" .. crate.Rarity .. ")!")
	return true, "Kamu mendapatkan " .. crate.Kind .. " (" .. crate.Rarity .. ")!"
end

-- ============================================================================
-- applyFloodEffects() — debris + knockback ringan
-- ============================================================================
-- Debris: 14 item (baju/pintu/jendela) beterbangan saat flood. Knockback:
-- pemain di luar base sendiri terdorong ringan. Dipanggil Main saat Flooding
-- (atau dari dalam startCycle kalau deps tidak menyediakannya sendiri).
function Flood.applyFloodEffects()
	-- 1) Debris.
	if _deps ~= nil and type(_deps.spawnDebris) == "function" then
		safeCall(_deps.spawnDebris)
	else
		local ok, err = pcall(function()
			local debrisColors = {
				Color3.fromRGB(255, 100, 100), -- baju merah
				Color3.fromRGB(100, 150, 255), -- baju biru
				Color3.fromRGB(255, 220, 120), -- baju kuning
				Color3.fromRGB(150, 90, 40), -- pintu kayu
				Color3.fromRGB(180, 220, 255), -- jendela kaca
			}
			for _ = 1, 14 do
				local part = Instance.new("Part")
				part.Name = "FloodDebris"
				part.Size = Vector3.new(math.random(1, 2), math.random(1, 2), 0.4)
				part.Position = Vector3.new(math.random(-50, 50), math.random(6, 14), math.random(-120, 120))
				part.Anchored = false
				part.CanCollide = false
				part.Material = Enum.Material.SmoothPlastic
				part.Color = debrisColors[math.random(1, #debrisColors)]
				part.AssemblyLinearVelocity = Vector3.new(math.random(-14, 14), math.random(2, 10), math.random(-20, -6))
				part.AssemblyAngularVelocity = Vector3.new(math.random(-6, 6), math.random(-6, 6), math.random(-6, 6))
				part.Parent = workspace
				DebrisService:AddItem(part, 8)
			end
		end)
		if not ok then
			warn("[Flood] applyFloodEffects debris gagal: " .. tostring(err))
		end
	end

	-- 2) Knockback ringan untuk pemain di luar base sendiri.
	local states = getPlayersState()
	for _, player in ipairs(PlayersService:GetPlayers()) do
		local ok, err = pcall(function()
			local character = player.Character
			if character == nil then
				return
			end
			local root = character:FindFirstChild("HumanoidRootPart")
			if root == nil then
				return
			end
			-- Pemain di dalam base sendiri tidak kena knockback.
			if states ~= nil and states[player] ~= nil and states[player].Base ~= nil then
				if isInsideOwnBase(root.Position, states[player].Base) then
					return
				end
			end
			-- Dorongan ringan ke selatan (searah air) + sedikit ke atas.
			root.AssemblyLinearVelocity = root.AssemblyLinearVelocity
				+ Vector3.new(math.random(-4, 4), 4, math.random(4, 9))
		end)
		if not ok then
			warn("[Flood] applyFloodEffects knockback gagal untuk "
				.. tostring(player.Name)
				.. ": "
				.. tostring(err))
		end
	end

	return true
end

-- ============================================================================
-- Dinding air (fallback internal; Main boleh menimpa lewat animateWaterWall)
-- ============================================================================
local function animateWaterWallInternal(seconds)
	local ok, err = pcall(function()
		local wall = Instance.new("Part")
		wall.Name = "FloodWall"
		wall.Size = Vector3.new(40, 14, 2)
		wall.Material = Enum.Material.Glass
		wall.Color = Color3.fromRGB(65, 165, 255)
		wall.Transparency = 0.4
		wall.Anchored = true
		wall.CanCollide = false
		wall.Position = Vector3.new(0, 7, -170)
		wall.Parent = workspace
		DebrisService:AddItem(wall, seconds + 2)

		-- Bergerak utara -> selatan selama `seconds` detik.
		local steps = 30
		local stepTime = seconds / steps
		local startZ = -170
		local endZ = 170
		for i = 1, steps do
			local t = i / steps
			wall.Position = Vector3.new(0, 7, startZ + (endZ - startZ) * t)
			task.wait(stepTime)
		end
	end)
	if not ok then
		warn("[Flood] animateWaterWall gagal: " .. tostring(err))
	end
end

-- ============================================================================
-- collectWashed() — Brainrot yang tersapu flood
-- ============================================================================
-- Conveyor: semua Brainrot di conveyor tersapu. Dibawa pemain: hanya yang
-- dibawa DI LUAR base sendiri (di luar +-28 x, +-23 z dari pusat base).
-- Brainrot di slot base SELALU AMAN (tidak pernah disentuh di sini).
-- Kembalikan array {Kind, Rarity}.
function Flood.collectWashed()
	local washed = {}

	-- 1) Brainrot di conveyor.
	if _deps ~= nil and type(_deps.getConveyorBrainrots) == "function" then
		local ok, list = pcall(_deps.getConveyorBrainrots)
		if ok and type(list) == "table" then
			for _, item in ipairs(list) do
				local normalized = normalizeWashedItem(item)
				if normalized ~= nil then
					table.insert(washed, normalized)
					if type(_deps.removeConveyorBrainrot) == "function" then
						local uid = item.Uid or item.Uid
						safeCall(_deps.removeConveyorBrainrot, uid)
					end
				end
			end
		elseif not ok then
			warn("[Flood] collectWashed: getConveyorBrainrots gagal: " .. tostring(list))
		end
	end

	-- 2) Brainrot yang dibawa pemain di luar base sendiri.
	local states = getPlayersState()
	if states ~= nil then
		for _, player in ipairs(PlayersService:GetPlayers()) do
			local ok, err = pcall(function()
				local state = states[player]
				if state == nil or state.Carried == nil then
					return
				end
				local character = player.Character
				local root = nil
				if character ~= nil then
					root = character:FindFirstChild("HumanoidRootPart")
				end
				-- Tanpa posisi karakter, anggap pemain di luar base (tidak aman).
				local insideBase = false
				if root ~= nil and state.Base ~= nil then
					insideBase = isInsideOwnBase(root.Position, state.Base)
				end
				if insideBase then
					return -- di dalam base sendiri: AMAN, tidak tersapu.
				end
				local carried = state.Carried
				local kind = carried.Kind
				if type(kind) ~= "string" then
					return
				end
				table.insert(washed, {
					Kind = kind,
					Rarity = KIND_TO_RARITY[kind] or "Common",
				})
				state.Carried = nil
				if _deps ~= nil and type(_deps.clearCarriedVisual) == "function" then
					safeCall(_deps.clearCarriedVisual, player)
				end
				safeCall(_deps and _deps.onBrainrotWashed, player, carried)
			end)
			if not ok then
				warn("[Flood] collectWashed: pemain "
					.. tostring(player.Name)
					.. " gagal diproses: "
					.. tostring(err))
			end
		end
	end

	return washed
end

-- ============================================================================
-- Mesin state: startCycle(deps)
-- ============================================================================
function Flood.init(deps)
	if type(deps) == "table" then
		_deps = deps
	end
	return Flood
end

function Flood.stopCycle()
	_running = false
	stopSiren()
	broadcastPhase("Idle", 0)
	return true
end

function Flood.startCycle(deps)
	if _running then
		warn("[Flood] startCycle: siklus sudah berjalan")
		return false
	end
	if type(deps) == "table" then
		_deps = deps
	end
	_running = true

	task.spawn(function()
		-- Flood pertama 2 menit setelah server mulai.
		task.wait(cfg("FLOOD_FIRST"))

		while _running do
			local cycleStart = os.clock()

			-- ---- Warning (10 detik): spawn dijeda, sirene berbunyi. ----
			local warningOk, warningErr = pcall(function()
				setSpawningPaused(true)
				playSiren()
				local remaining = cfg("WARNING_TIME")
				while remaining > 0 and _running do
					broadcastPhase("Warning", remaining)
					task.wait(1)
					remaining = remaining - 1
				end
				broadcastPhase("Warning", 0)
			end)
			if not warningOk then
				warn("[Flood] fase Warning gagal: " .. tostring(warningErr))
			end
			if not _running then
				break
			end

			-- ---- Flooding (~6 detik): dinding air, sapu, peti, balik arah. ----
			local floodOk, floodErr = pcall(function()
				stopSiren()
				broadcastPhase("Flooding", cfg("FLOOD_TIME"))

				-- Dinding air bergerak utara -> selatan (animasi di thread
				-- sendiri supaya sapu + peti tidak menunggu animasi selesai).
				if _deps ~= nil and type(_deps.animateWaterWall) == "function" then
					task.spawn(function()
						safeCall(_deps.animateWaterWall, cfg("FLOOD_TIME"))
					end)
				else
					task.spawn(function()
						animateWaterWallInternal(cfg("FLOOD_TIME"))
					end)
				end

				-- Tentukan yang tersapu, spawn peti, lalu efek debris/knockback.
				local washed = Flood.collectWashed()
				Flood.spawnCrates(washed)
				Flood.applyFloodEffects()

				-- Arah conveyor berbalik tiap flood. Flag dikembalikan ke
				-- Main (lewat field ini + callback) agar Main membalik arah.
				Flood.ConveyorReversed = not Flood.ConveyorReversed
				if _deps ~= nil and type(_deps.setConveyorReversed) == "function" then
					safeCall(_deps.setConveyorReversed, Flood.ConveyorReversed)
				end

				task.wait(cfg("FLOOD_TIME"))
			end)
			if not floodOk then
				warn("[Flood] fase Flooding gagal: " .. tostring(floodErr))
				stopSiren()
			end
			if not _running then
				break
			end

			-- ---- Scramble (60 detik): peti bisa diklaim, spawn jalan lagi. ----
			local scrambleOk, scrambleErr = pcall(function()
				setSpawningPaused(false)
				local remaining = cfg("SCRAMBLE_TIME")
				while remaining > 0 and _running do
					broadcastPhase("Scramble", remaining)
					task.wait(1)
					remaining = remaining - 1
				end
				broadcastPhase("Scramble", 0)
			end)
			if not scrambleOk then
				warn("[Flood] fase Scramble gagal: " .. tostring(scrambleErr))
				setSpawningPaused(false)
			end
			if not _running then
				break
			end

			-- ---- Idle sampai total interval 180 detik sejak awal siklus. ----
			broadcastPhase("Idle", 0)
			local elapsed = os.clock() - cycleStart
			local idleWait = cfg("FLOOD_INTERVAL") - elapsed
			if idleWait > 0 then
				task.wait(idleWait)
			end
		end

		-- Loop berhenti (stopCycle): pastikan sirene mati + fase Idle.
		stopSiren()
		broadcastPhase("Idle", 0)
	end)

	return true
end

return Flood
