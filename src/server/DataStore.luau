-- DataStore.luau
-- Penyimpanan pemain untuk "Pasar Brainrot" (DESIGN.md bag. 8).
--
-- DataStore: "PasarNusantara_V5" (atau Config.DATASTORE_NAME bila Config ada).
-- Kunci per pemain: "Player_<UserId>".
-- Yang disimpan per pemain: Money, Rebirths, isi tiap slot (Uid + Kind),
-- dan Brainrot yang sedang dibawa (Carried). Kunci slot memakai STRING
-- "1".."6" agar konsisten saat save/load (DESIGN.md bag. 8).
--
-- loadData(player) -> (data, status)
--   status "new"     : belum pernah ada data -> data berisi nilai awal
--                      (Money = START_MONEY 200, Rebirths 0, slot kosong).
--   status "ok"      : data berhasil dibaca + lolos validasi struktur.
--   status "failed"  : GetAsync gagal setelah 2x retry (total 3 percobaan).
--                      Data yang dikembalikan NIL -- JANGAN pernah memakai
--                      default seolah-olah itu data baru; Main harus retry
--                      atau menahan pemain sampai load berhasil.
--   status "corrupt" : data ada tapi struktur tidak valid -> NIL juga,
--                      jangan dipakai mentah-mentah.
--
-- saveData(player, state) -> (sukses, error)
--   Menyimpan state yang diberikan apa adanya via SetAsync (pcall + 1 retry).
--   Modul ini TIDAK PERNAH menimpa data lama dengan default: Main wajib
--   memanggil saveData hanya dengan state yang load-nya berhasil ("ok" /
--   "new"), dan TIDAK PERNAH memanggilnya dengan state default saat load
--   berstatus "failed". Urutan saat pemain keluar (DESIGN.md bag. 8):
--   SIMPAN DULU, baru bersihkan base.
--
-- Validasi struktur saat load: data harus tabel; Money number >= 0;
-- Rebirths number >= 0; Slots tabel (tiap entri nil atau {Uid, Kind});
-- Carried nil atau {Uid, Kind}. Slot dinormalisasi kembali ke array
-- numerik 1..6 (save memakai kunci string, state live memakai angka).

local DataStoreService = game:GetService("DataStoreService")

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

local DATASTORE_NAME = "PasarNusantara_V5"
if Config and type(Config.DATASTORE_NAME) == "string" and Config.DATASTORE_NAME ~= "" then
	DATASTORE_NAME = Config.DATASTORE_NAME
end

local START_MONEY = 200
if Config and type(Config.START_MONEY) == "number" then
	START_MONEY = Config.START_MONEY
end

local SLOT_COUNT = 6
local GET_ATTEMPTS = 3 -- percobaan pertama + 2x retry
local SET_ATTEMPTS = 2 -- percobaan pertama + 1x retry
local RETRY_WAIT = 1 -- detik antar percobaan

-- ---------------------------------------------------------------------------

local DataStore = {}

local cachedStore = nil
local storeFailed = false

local function getStore()
	if cachedStore then
		return cachedStore, nil
	end
	if storeFailed then
		return nil, "DataStore tidak tersedia"
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok and store then
		cachedStore = store
		return store, nil
	end
	storeFailed = true
	return nil, "GetDataStore gagal"
end

local function defaultData()
	return {
		Money = START_MONEY,
		Rebirths = 0,
		Slots = {},
		Carried = nil,
		IncomeMult = 1,
	}
end

local function isFiniteNumber(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

local function validItem(item)
	if item == nil then
		return true
	end
	if type(item) ~= "table" then
		return false
	end
	if item.Uid == nil then
		return false
	end
	if type(item.Uid) ~= "string" and type(item.Uid) ~= "number" then
		return false
	end
	if type(item.Kind) ~= "string" or item.Kind == "" then
		return false
	end
	return true
end

-- Validasi + normalisasi data mentah dari DataStore. Mengembalikan
-- (dataTernormalisasi, true) bila valid, (nil, false) bila rusak.
local function validateAndNormalize(raw)
	if type(raw) ~= "table" then
		return nil, false
	end
	if not isFiniteNumber(raw.Money) or raw.Money < 0 then
		return nil, false
	end
	if not isFiniteNumber(raw.Rebirths) or raw.Rebirths < 0
		or math.floor(raw.Rebirths) ~= raw.Rebirths then
		return nil, false
	end
	if type(raw.Slots) ~= "table" then
		return nil, false
	end
	if not validItem(raw.Carried) then
		return nil, false
	end

	local slots = {}
	for i = 1, SLOT_COUNT do
		local entry = raw.Slots[tostring(i)]
		if entry == nil then
			entry = raw.Slots[i]
		end
		if entry ~= nil then
			if not validItem(entry) then
				return nil, false
			end
			slots[i] = { Uid = entry.Uid, Kind = entry.Kind }
		end
	end

	local carried = nil
	if raw.Carried ~= nil then
		carried = { Uid = raw.Carried.Uid, Kind = raw.Carried.Kind }
	end

	local rebirths = raw.Rebirths
	return {
		Money = raw.Money,
		Rebirths = rebirths,
		Slots = slots,
		Carried = carried,
		IncomeMult = 1 + rebirths * 0.5,
	}, true
end

-- ---------------------------------------------------------------------------
-- loadData(player) -> (data, status)
-- ---------------------------------------------------------------------------

function DataStore.loadData(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil, "failed"
	end

	local store, storeErr = getStore()
	if not store then
		warn("[DataStore] " .. tostring(storeErr) .. " untuk " .. player.Name)
		return nil, "failed"
	end

	local key = "Player_" .. tostring(player.UserId)
	local ok = false
	local raw = nil
	local lastErr = nil
	for attempt = 1, GET_ATTEMPTS do
		ok, raw = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			break
		end
		lastErr = raw
		if attempt < GET_ATTEMPTS then
			task.wait(RETRY_WAIT)
		end
	end
	if not ok then
		warn("[DataStore] GetAsync gagal untuk " .. player.Name
			.. " setelah " .. tostring(GET_ATTEMPTS) .. " percobaan: "
			.. tostring(lastErr))
		return nil, "failed"
	end

	-- Tidak ada data tersimpan: pemain baru.
	if raw == nil then
		return defaultData(), "new"
	end

	local data, valid = validateAndNormalize(raw)
	if not valid then
		warn("[DataStore] Data rusak untuk " .. player.Name .. ", tidak dipakai.")
		return nil, "corrupt"
	end
	return data, "ok"
end

-- ---------------------------------------------------------------------------
-- saveData(player, state) -> (sukses, error)
-- Hanya menyimpan state yang diberikan Main. JANGAN panggil dengan state
-- default bila loadData sebelumnya berstatus "failed" -- itu akan menimpa
-- data lama pemain dengan angka awal.
-- ---------------------------------------------------------------------------

function DataStore.saveData(player, state)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "player tidak valid"
	end
	if type(state) ~= "table" then
		return false, "state tidak valid"
	end
	if not isFiniteNumber(state.Money) or state.Money < 0 then
		return false, "Money pada state tidak valid"
	end
	if type(state.Rebirths) ~= "number" or state.Rebirths < 0 then
		return false, "Rebirths pada state tidak valid"
	end

	local store, storeErr = getStore()
	if not store then
		return false, tostring(storeErr)
	end

	local payload = {
		Money = state.Money,
		Rebirths = state.Rebirths,
		Slots = {},
		Carried = nil,
	}
	local slots = state.Slots
	if type(slots) == "table" then
		for i = 1, SLOT_COUNT do
			local entry = slots[i]
			if entry ~= nil then
				if not validItem(entry) then
					return false, "slot " .. tostring(i) .. " tidak valid"
				end
				payload.Slots[tostring(i)] = { Uid = entry.Uid, Kind = entry.Kind }
			end
		end
	end
	if state.Carried ~= nil then
		if not validItem(state.Carried) then
			return false, "Carried tidak valid"
		end
		payload.Carried = { Uid = state.Carried.Uid, Kind = state.Carried.Kind }
	end

	local key = "Player_" .. tostring(player.UserId)
	local ok = false
	local lastErr = nil
	for attempt = 1, SET_ATTEMPTS do
		ok, lastErr = pcall(function()
			store:SetAsync(key, payload)
		end)
		if ok then
			break
		end
		if attempt < SET_ATTEMPTS then
			task.wait(RETRY_WAIT)
		end
	end
	if not ok then
		warn("[DataStore] SetAsync gagal untuk " .. player.Name .. ": " .. tostring(lastErr))
		return false, tostring(lastErr)
	end
	return true, nil
end

return DataStore
