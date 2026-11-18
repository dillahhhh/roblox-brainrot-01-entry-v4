-- Config.luau
-- Satu-satunya sumber kebenaran untuk Pasar Brainrot.
-- Roster Brainrot, konstanta gameplay, layout base, dan posisi dunia.
-- Ditulis baru dari DESIGN.md (bagian 2, 3, 13). Tidak menyalin source lama.
-- Semua ukuran dalam stud Roblox; semua uang dalam dolar game ($).

local Config = {}

-- ============================================================================
-- Ekonomi & gameplay umum
-- ============================================================================
Config.START_MONEY = 200          -- Uang awal pemain baru
Config.SELL_RATE = 0.5            -- Jual Brainrot = 50% harga beli
Config.SPAWN_INTERVAL = 3.5       -- Brainrot baru muncul tiap 3,5 detik
Config.CONVEYOR_SPEED = 16        -- Kecepatan Brainrot di conveyor (stud/detik)
Config.REBIRTH_BASE = 100000      -- Biaya rebirth = REBIRTH_BASE * 2^Rebirths
Config.REBIRTH_RESET_MONEY = 100  -- Uang setelah rebirth
Config.LOCK_DURATION = 30         -- Lock base aktif 30 detik per aktivasi
Config.STEAL_RANGE = 12           -- Jarak maksimum pencuri ke pedestal (stud)
Config.CLAIM_RANGE = 12           -- Jarak maksimum klaim peti (stud)
Config.STEAL_COOLDOWN = 5         -- Cooldown sukses antar pencurian (detik)
Config.STEAL_ATTEMPT_COOLDOWN = 1 -- Rate limit percobaan steal (detik)

-- ============================================================================
-- Flood Event (Pasar Tumpah)
-- ============================================================================
Config.FLOOD_FIRST = 120          -- Flood pertama 120 detik setelah server mulai
Config.FLOOD_INTERVAL = 180       -- Flood berikutnya tiap 180 detik
Config.WARNING_TIME = 10          -- Fase Warning: 10 detik (spawn dijeda)
Config.FLOOD_TRAVEL_TIME = 6      -- Dinding air bergerak utara -> selatan (~6 detik)
Config.SCRAMBLE_TIME = 60         -- Fase Scramble: 60 detik
Config.CRATE_LIFETIME = 60        -- Peti yang tidak diklaim dihapus setelah 60 detik
Config.CRATE_FALLBACK_COUNT = 3   -- Peti fallback kalau tidak ada yang tersapu
Config.CRATE_OPEN_TIME = 0.5      -- Tahan ProximityPrompt peti 0,5 detik
Config.CRATE_UPGRADE = {          -- Peluang peti naik satu tingkat
	Rare = 0.40,
	Epic = 0.25,
	Legendary = 0.50,
}

-- ============================================================================
-- DataStore
-- Konstanta revisi ke-3 (DESIGN.md 16.3, 17): versi schema, retry load/save, batas sanity validasi.
-- ============================================================================
Config.DATA_VERSION = 1
Config.DATASTORE_NAME = "PasarNusantara_V5"
Config.LOAD_MAX_ATTEMPTS = 3       -- Retry GetAsync maksimal 3 kali
Config.LOAD_RETRY_DELAY = 2        -- Jeda antar percobaan load/save (detik)
Config.SAVE_MAX_ATTEMPTS = 2       -- Retry UpdateAsync maksimal 2 kali
Config.MAX_MONEY = 1000000000000   -- Batas sanity uang saat validasi load (1e12)
Config.MAX_REBIRTHS = 100          -- Batas sanity jumlah rebirth saat validasi load

-- ============================================================================
-- Roster Brainrot (7 tingkat, urut dari termurah)
-- SpawnMax = batas atas kumulatif roll 1-1000 (lihat DESIGN bagian 3).
-- Sell dihitung server sebagai Price * SELL_RATE; dicantumkan di sini
-- sebagai angka eksplisit agar HUD/client tidak perlu menghitung.
-- ============================================================================
Config.Brainrots = {
	{
		Tier = "Common",
		Name = "Ayam Ikan",
		Price = 50,
		Income = 5,
		Sell = 25,
		Color = Color3.fromRGB(220, 220, 220),
		SpawnMax = 450,
	},
	{
		Tier = "Uncommon",
		Name = "Babi Terbang",
		Price = 150,
		Income = 15,
		Sell = 75,
		Color = Color3.fromRGB(110, 220, 110),
		SpawnMax = 700,
	},
	{
		Tier = "Rare",
		Name = "Anjing Es Teh",
		Price = 400,
		Income = 40,
		Sell = 200,
		Color = Color3.fromRGB(65, 165, 255),
		SpawnMax = 880,
	},
	{
		Tier = "Epic",
		Name = "Kucing Rendang",
		Price = 1000,
		Income = 100,
		Sell = 500,
		Color = Color3.fromRGB(185, 85, 255),
		SpawnMax = 960,
	},
	{
		Tier = "Legendary",
		Name = "Beruang Durian",
		Price = 3000,
		Income = 300,
		Sell = 1500,
		Color = Color3.fromRGB(255, 140, 40),
		SpawnMax = 988,
	},
	{
		Tier = "Mythic",
		Name = "Harimau Api",
		Price = 12000,
		Income = 1200,
		Sell = 6000,
		Color = Color3.fromRGB(255, 65, 65),
		SpawnMax = 998,
	},
	{
		Tier = "Ultra Rare",
		Name = "Gajah Gamelan",
		Price = 50000,
		Income = 10000,
		Sell = 25000,
		Color = Color3.fromRGB(255, 225, 0),
		SpawnMax = 1000,
	},
}

-- Jumlah slot pedestal per base.
Config.SLOT_COUNT = 6

-- ============================================================================
-- Layout base & posisi dunia
-- ============================================================================
Config.BASE_X = { -68, 68 }                 -- xCenter base kiri / kanan
Config.BASE_Z = { 90, 25, -40, -105 }       -- zCenter keempat base tiap sisi
Config.SLOT_OFFSETS_X = { -14, 0, 14 }      -- kolom pedestal (relatif xCenter)
Config.SLOT_OFFSETS_Z = { -9, 9 }           -- baris pedestal (relatif zCenter)

Config.TERRAIN_SIZE = Vector3.new(340, 2, 420)   -- lantai batu, atas y = 0
Config.TERRAIN_POS = Vector3.new(0, -1, 0)

Config.CONVEYOR_SIZE = Vector3.new(30, 0.5, 320) -- sabuk kayu, atas y = 0.55
Config.CONVEYOR_POS = Vector3.new(0, 0.3, 0)
Config.CONVEYOR_LANES = { -7.5, 7.5 }            -- 2 jalur conveyor (sumbu x)
-- Ujung conveyor (KOREKSI LANJUT): setengah panjang conveyor 320; dipakai
-- bersama oleh spawn, gerak, pemeriksaan ujung, dan pembersihan.
Config.CONVEYOR_END_Z = 160

Config.PLAZA_SIZE = Vector3.new(110, 0.6, 55)    -- plaza selatan, sekitar z = 155
Config.PLAZA_POS = Vector3.new(0, 0.3, 155)

Config.SPAWN_POS = Vector3.new(0, 0.8, 168)      -- SpawnLocation 16x1x16
Config.SPAWN_SIZE = Vector3.new(16, 1, 16)

-- Batas base untuk aturan flood ("di luar base sendiri"):
-- pemain di luar +-28 x / +-23 z dari pusat base-nya dianggap di luar base.
Config.BASE_HALF_X = 28
Config.BASE_HALF_Z = 23
Config.SAFE_HALF_X = 28
Config.SAFE_HALF_Z = 23

-- Skala visual Brainrot.
Config.SCALE_PEDESTAL = 2.0   -- di pedestal / conveyor
Config.SCALE_CARRIED = 1.4    -- saat dibawa pemain
Config.SCALE_CRATE = 1.6      -- di atas peti

-- ============================================================================
-- Suasana: pencahayaan, musik, sirene
-- ============================================================================
Config.CLOCK_TIME = 20.5        -- malam tapi terang (lampu-lampu)
Config.LIGHT_BRIGHTNESS = 2
Config.MUSIC_ASSET_ID = 9043887091   -- Lo-fi Chill A (loop)
Config.SIREN_ASSET_ID = 792323017    -- Tornado Siren (loop saat warning)
Config.SIREN_VOLUME = 0.6

-- ============================================================================
-- Helper kecil (pure, tanpa state)
-- ============================================================================

-- Cari entri roster berdasarkan nama Brainrot. Mengembalikan nil kalau tidak ada.
function Config.findBrainrot(name)
	for _, entry in ipairs(Config.Brainrots) do
		if entry.Name == name then
			return entry
		end
	end
	return nil
end

-- Roll rarity spawn: lempar 1-1000, kembalikan entri roster yang cocok.
function Config.rollBrainrot()
	local roll = math.random(1, 1000)
	for _, entry in ipairs(Config.Brainrots) do
		if roll <= entry.SpawnMax then
			return entry
		end
	end
	return Config.Brainrots[#Config.Brainrots]
end

-- Biaya rebirth berikutnya untuk jumlah rebirth saat ini.
function Config.rebirthCost(rebirths)
	return Config.REBIRTH_BASE * (2 ^ rebirths)
end

-- Pengali income setelah rebirth: 1 + Rebirths * 0,5.
function Config.incomeMultiplier(rebirths)
	return 1 + rebirths * 0.5
end

-- Posisi pedestal ke-i (1..6) pada base dengan pusat (xCenter, zCenter).
-- Urutan slot: baris z = -9 dulu (slot 1-3), lalu z = +9 (slot 4-6).
function Config.slotPosition(xCenter, zCenter, slotIndex)
	local col = ((slotIndex - 1) % 3) + 1
	local row = math.floor((slotIndex - 1) / 3) + 1
	return Vector3.new(
		xCenter + Config.SLOT_OFFSETS_X[col],
		1.7,
		zCenter + Config.SLOT_OFFSETS_Z[row]
	)
end

-- Posisi pintu base (sisi dalam, menghadap conveyor).
function Config.doorX(xCenter)
	if xCenter < 0 then
		return xCenter + 27
	else
		return xCenter - 27
	end
end

return Config
