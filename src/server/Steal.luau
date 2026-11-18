-- Steal.luau
-- Mencuri Brainrot antar pemain, server-authoritative (DESIGN.md bag. 6).
--
-- Modul ini TIDAK menyimpan state sendiri: Main memegang satu tabel Players
-- (key = Player, value = {Money, Rebirths, Base, Slots, Carried, Locked,
-- LastSteal, IncomeMult}) dan meneruskannya ke trySteal. Modul ini juga
-- TIDAK menyentuh visual/HUD langsung: bila berhasil, ia mengembalikan info
-- lengkap (korban, slot, item) agar Main memperbarui visual pedestal,
-- visual carry, dan HUD kedua pemain (serta mengirim StealResult).
--
-- Pemakaian (tanda tangan utama, sesuai tugas):
--   local ok, msg, info = Steal.trySteal(thief, players, baseIdx, slotIdx,
--       pedestalPos, requestedUid)
--   pedestalPos  : Vector3 posisi pedestal korban (opsional; bila tidak
--                  diberikan, posisi dihitung dari layout Config).
--   requestedUid : UID Brainrot yang diminta client (opsional; bila diberikan,
--                  harus sama dengan UID di slot, cegah race condition).
--
-- Bentuk pendek DESIGN.md bag. 13 (trySteal(thief, baseIdx, slotIdx)) juga
-- diterima bila Main sebelumnya memanggil Steal.bind(players); posisi
-- pedestal lalu dihitung dari layout Config dan cek UID dilewati (tidak ada
-- UID yang diminta).
--
-- Urutan validasi (sesuai tugas; cooldown dicek dulu sebagai penjaga spam,
-- lalu keenam syarat DESIGN.md bag. 6 secara berurutan):
--   0. Cooldown: tolak bila LastSteal pencuri < 2 detik lalu.
--   1. Base korban TIDAK terkunci.
--   2. Slot terisi.
--   3. Pencuri bukan pemilik base.
--   4. Tangan pencuri kosong (Carried == nil).
--   5. Jarak pencuri ke pedestal <= 12 stud.
--   6. UID Brainrot di slot cocok dengan UID yang diminta (bila diminta).
-- LastSteal HANYA diperbarui saat pencurian BERHASIL (sesuai tugas); upaya
-- gagal tidak menggerakkan cooldown.
--
-- Bila sukses: item {Uid, Kind} pindah dari slot korban ke Carried pencuri,
-- slot korban dikosongkan, dan dikembalikan (true, pesan, info) dengan
-- info = {thief, victim, baseIdx, slotIdx, item}.
-- Bila gagal: tidak ada perubahan state, dikembalikan (false, alasan, nil).

local Workspace = game:GetService("Workspace")

-- ---------------------------------------------------------------------------
-- Konfigurasi: Config bila ada, fallback DESIGN.md bila belum ada.
-- ---------------------------------------------------------------------------

local function loadConfig()
	local src = script.Parent.Parent
	local shared = src and src:FindFirstChild("Shared")
	local cfgModule = shared and shared:FindFirstChild("Config")
	if not cfgModule then
		return nil
	end
	local ok, mod = pcall(require, cfgModule)
	if ok and type(mod) == "table" then
		return mod
	end
	return nil
end

local Config = loadConfig()

local function cfgNumber(field, fallback)
	if Config and type(Config[field]) == "number" then
		return Config[field]
	end
	return fallback
end

local STEAL_RANGE = cfgNumber("STEAL_RANGE", 12)
local STEAL_COOLDOWN = cfgNumber("STEAL_COOLDOWN", 2)
local SLOT_COUNT = 6

-- Layout base fallback (DESIGN.md bag. 4): 8 base, xCenter -68/+68,
-- zCenter 90/25/-40/-105; slot x {-14,0,14}, z {-9,9}; nomor base 1-4 kiri,
-- 5-8 kanan. Dipakai hanya bila Main tidak mengirim pedestalPos.
local FALLBACK_BASE_X = { -68, -68, -68, -68, 68, 68, 68, 68 }
local FALLBACK_BASE_Z = { 90, 25, -40, -105, 90, 25, -40, -105 }
local FALLBACK_SLOT_OFFSETS_X = { -14, 0, 14 }
local FALLBACK_SLOT_OFFSETS_Z = { -9, 9 }

local function baseLayout()
	local baseX = FALLBACK_BASE_X
	local baseZ = FALLBACK_BASE_Z
	local offX = FALLBACK_SLOT_OFFSETS_X
	local offZ = FALLBACK_SLOT_OFFSETS_Z
	if Config then
		if type(Config.BASE_X) == "table" then
			baseX = Config.BASE_X
		end
		if type(Config.BASE_Z) == "table" then
			baseZ = Config.BASE_Z
		end
		if type(Config.SLOT_OFFSETS_X) == "table" then
			offX = Config.SLOT_OFFSETS_X
		end
		if type(Config.SLOT_OFFSETS_Z) == "table" then
			offZ = Config.SLOT_OFFSETS_Z
		end
	end
	return baseX, baseZ, offX, offZ
end

-- Posisi pedestal dari nomor base + nomor slot (slot 1-3 baris z pertama,
-- slot 4-6 baris z kedua; kolom x berurutan -14, 0, 14).
local function pedestalPositionFromLayout(baseIdx, slotIdx)
	local baseX, baseZ, offX, offZ = baseLayout()
	local xCenter = baseX[baseIdx]
	local zCenter = baseZ[baseIdx]
	if type(xCenter) ~= "number" or type(zCenter) ~= "number" then
		return nil
	end
	local col = ((slotIdx - 1) % 3) + 1
	local row = math.floor((slotIdx - 1) / 3) + 1
	local xOff = offX[col]
	local zOff = offZ[row]
	if type(xOff) ~= "number" or type(zOff) ~= "number" then
		return nil
	end
	-- Permukaan atas pedestal y=1,7 (DESIGN.md bag. 4).
	return Vector3.new(xCenter + xOff, 1.7, zCenter + zOff)
end

-- ---------------------------------------------------------------------------

local Steal = {}

-- Konteks opsional untuk bentuk pemanggilan pendek DESIGN.md bag. 13.
local boundPlayers = nil

function Steal.bind(players)
	boundPlayers = players
end

local function now()
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	if ok and type(t) == "number" then
		return t
	end
	return os.clock()
end

local function findOwner(players, baseIdx)
	for player, state in pairs(players) do
		if typeof(player) == "Instance"
			and player:IsA("Player")
			and type(state) == "table"
			and state.Base == baseIdx then
			return player, state
		end
	end
	return nil, nil
end

-- ---------------------------------------------------------------------------
-- trySteal(thief, players, baseIdx, slotIdx [, pedestalPos [, requestedUid]])
-- Mengembalikan (sukses, pesan, info). Info hanya ada bila sukses.
-- ---------------------------------------------------------------------------

function Steal.trySteal(thief, players, baseIdx, slotIdx, pedestalPos, requestedUid)
	-- Bentuk pendek DESIGN.md bag. 13: trySteal(thief, baseIdx, slotIdx).
	if type(players) == "number" then
		slotIdx = baseIdx
		baseIdx = players
		players = boundPlayers
		pedestalPos = nil
		requestedUid = nil
	end

	if typeof(thief) ~= "Instance" or not thief:IsA("Player") then
		return false, "Pencuri tidak valid."
	end
	if type(players) ~= "table" then
		return false, "Data pemain tidak ditemukan."
	end
	if type(baseIdx) ~= "number" or type(slotIdx) ~= "number"
		or slotIdx < 1 or slotIdx > SLOT_COUNT
		or math.floor(slotIdx) ~= slotIdx then
		return false, "Base atau slot tidak valid."
	end

	local thiefState = players[thief]
	if type(thiefState) ~= "table" then
		return false, "Data pencuri tidak ditemukan."
	end

	local victim, victimState = findOwner(players, baseIdx)
	if not victim or not victimState then
		return false, "Base itu kosong, tidak ada yang bisa dicuri."
	end

	-- 0. Cooldown per pencuri (hanya bergerak saat berhasil, lihat bawah).
	local lastSteal = thiefState.LastSteal
	if type(lastSteal) == "number" and (now() - lastSteal) < STEAL_COOLDOWN then
		return false, "Tunggu sebentar sebelum mencuri lagi."
	end

	-- 1. Base korban tidak terkunci.
	if victimState.Locked then
		return false, "Base korban terkunci."
	end

	-- 2. Slot terisi.
	local slots = victimState.Slots
	if type(slots) ~= "table" then
		return false, "Slot tidak ditemukan."
	end
	local item = slots[slotIdx]
	if type(item) ~= "table" or item.Uid == nil or type(item.Kind) ~= "string" then
		return false, "Slot itu sudah kosong."
	end

	-- 3. Pencuri bukan pemilik base.
	if thief == victim or thiefState.Base == baseIdx then
		return false, "Tidak bisa mencuri dari base sendiri."
	end

	-- 4. Tangan pencuri kosong.
	if thiefState.Carried ~= nil then
		return false, "Tanganmu penuh, taruh dulu Brainrot yang kamu bawa."
	end

	-- 5. Jarak pencuri ke pedestal <= 12 stud.
	local targetPos = pedestalPos
	if typeof(targetPos) ~= "Vector3" then
		targetPos = pedestalPositionFromLayout(baseIdx, slotIdx)
	end
	if typeof(targetPos) == "Vector3" then
		local character = thief.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "Karakter pencuri tidak ditemukan."
		end
		if (root.Position - targetPos).Magnitude > STEAL_RANGE then
			return false, "Terlalu jauh dari pedestal."
		end
	end

	-- 6. UID Brainrot cocok (bila client mengirim UID yang diminta).
	if requestedUid ~= nil and requestedUid ~= item.Uid then
		return false, "Brainrot itu sudah tidak ada di slot."
	end

	-- Semua syarat lolos: pindahkan item secara atomik di server.
	local stolen = { Uid = item.Uid, Kind = item.Kind }
	slots[slotIdx] = nil
	thiefState.Carried = stolen
	thiefState.LastSteal = now()

	return true, "Berhasil mencuri " .. stolen.Kind .. "!", {
		thief = thief,
		victim = victim,
		baseIdx = baseIdx,
		slotIdx = slotIdx,
		item = stolen,
	}
end

return Steal
