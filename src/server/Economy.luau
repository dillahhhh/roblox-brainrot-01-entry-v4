-- Economy.luau
-- Ekonomi server-side untuk "Pasar Brainrot" (rebuild dari DESIGN.md).
--
-- Modul ini TIDAK menyimpan state sendiri: Main memegang satu tabel Players
-- (key = Player, value = {Money, Rebirths, Base, Slots, Carried, Locked,
-- LastSteal, IncomeMult}) dan meneruskannya ke setiap fungsi di sini.
-- Semua perhitungan uang dilakukan server; client tidak pernah mengirim nilai.
--
-- Pemakaian (tanda tangan utama, sesuai tugas):
--   Economy.addIncome(players)                    -- dipanggil tiap detik oleh Main
--   Economy.sellSlot(player, players, slotIdx, clearSlotVisual)
--   Economy.rebirth(player, players)
--
-- Bentuk pendek DESIGN.md bag. 13 (sellSlot(player, slotIdx) dsb.) juga
-- diterima bila Main sebelumnya memanggil Economy.bind(players, remotes);
-- tanpa bind, bentuk pendek mengembalikan (false, pesan) karena state
-- tidak dapat ditemukan.
--
-- RemoteEvent yang dipakai (dibuat Main di ReplicatedStorage.GameRemotes):
--   MoneyUpdate : FireClient(player, money, incomePerSec)
--   Notify      : FireClient(player, teks)
-- Bila tabel remotes diteruskan sebagai argumen terakhir (opsional), tabel
-- itu dipakai; bila tidak, modul mencari ReplicatedStorage.GameRemotes.
-- Bila remote tidak ditemukan, uang tetap dihitung, pengiriman dilewati.
--
-- Nilai roster/konstanta diambil dari src/shared/Config bila modul itu sudah
-- ada; bila belum ada, dipakai nilai fallback yang sama persis dengan
-- DESIGN.md bag. 3 & 5 (harga/income roster, START_MONEY 200, SELL_RATE 0.5,
-- REBIRTH_BASE 100000, uang reset rebirth 100).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local FALLBACK_ROSTER = {
	["Ayam Ikan"] = { Price = 50, Income = 5 },
	["Babi Terbang"] = { Price = 150, Income = 15 },
	["Anjing Es Teh"] = { Price = 400, Income = 40 },
	["Kucing Rendang"] = { Price = 1000, Income = 100 },
	["Beruang Durian"] = { Price = 3000, Income = 300 },
	["Harimau Api"] = { Price = 12000, Income = 1200 },
	["Gajah Gamelan"] = { Price = 50000, Income = 10000 },
}

local function cfgNumber(field, fallback)
	if Config and type(Config[field]) == "number" then
		return Config[field]
	end
	return fallback
end

local START_MONEY = cfgNumber("START_MONEY", 200)
local SELL_RATE = cfgNumber("SELL_RATE", 0.5)
local REBIRTH_BASE = cfgNumber("REBIRTH_BASE", 100000)
local REBIRTH_RESET_MONEY = 100 -- DESIGN.md bag. 5: uang direset ke $100
local SLOT_COUNT = 6

-- ---------------------------------------------------------------------------
-- Util roster: dukung Config.Roster sebagai dict {["Nama"] = {...}} maupun
-- array {{Name = ..., Price = ..., Income = ...}, ...}.
-- ---------------------------------------------------------------------------

local function rosterEntry(kind)
	if type(kind) ~= "string" then
		return nil
	end
	local roster = Config and Config.Roster
	if type(roster) == "table" then
		local entry = roster[kind]
		if type(entry) == "table" then
			return entry
		end
		for _, candidate in ipairs(roster) do
			if type(candidate) == "table"
				and (candidate.Name == kind or candidate.Kind == kind) then
				return candidate
			end
		end
	end
	return FALLBACK_ROSTER[kind]
end

local function rosterPrice(kind)
	local entry = rosterEntry(kind)
	if not entry then
		return nil
	end
	local price = entry.Price or entry.Cost or entry.BuyPrice
	if type(price) == "number" then
		return price
	end
	return nil
end

local function rosterIncome(kind)
	local entry = rosterEntry(kind)
	if not entry then
		return nil
	end
	local income = entry.Income or entry.IncomePerSec
	if type(income) == "number" then
		return income
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- State / remote helpers
-- ---------------------------------------------------------------------------

local Economy = {}

-- Konteks opsional untuk bentuk pemanggilan pendek DESIGN.md bag. 13.
local boundPlayers = nil
local boundRemotes = nil

function Economy.bind(players, remotes)
	boundPlayers = players
	boundRemotes = remotes
end

local function resolvePlayers(players)
	if type(players) == "table" then
		return players
	end
	return boundPlayers
end

local function resolveRemotes(explicit)
	if type(explicit) == "table" then
		return explicit
	end
	if type(boundRemotes) == "table" then
		return boundRemotes
	end
	local ok, folder = pcall(function()
		return ReplicatedStorage:FindFirstChild("GameRemotes")
	end)
	if ok and folder then
		return folder
	end
	return nil
end

local function findRemote(remotes, name)
	if not remotes then
		return nil
	end
	local ok, remote = pcall(function()
		return remotes:FindFirstChild(name)
	end)
	if ok then
		return remote
	end
	return nil
end

local function resolveState(player, players)
	local tableRef = resolvePlayers(players)
	if not tableRef then
		return nil
	end
	local state = tableRef[player]
	if type(state) ~= "table" then
		return nil
	end
	return state
end

local function incomeMultOf(state)
	if type(state.IncomeMult) == "number" then
		return state.IncomeMult
	end
	local rebirths = state.Rebirths
	if type(rebirths) ~= "number" then
		rebirths = 0
	end
	return 1 + rebirths * 0.5
end

-- Income per detik dari semua slot terisi (roster x IncomeMult).
local function incomePerSecOf(state)
	local total = 0
	local mult = incomeMultOf(state)
	local slots = state.Slots
	if type(slots) == "table" then
		for i = 1, SLOT_COUNT do
			local slot = slots[i]
			if type(slot) == "table" and type(slot.Kind) == "string" then
				local income = rosterIncome(slot.Kind)
				if income then
					total = total + income * mult
				end
			end
		end
	end
	return total
end

local function sendMoneyUpdate(player, state, remotes, incomePerSec)
	local remote = findRemote(remotes, "MoneyUpdate")
	if not remote then
		return
	end
	pcall(function()
		remote:FireClient(player, state.Money, incomePerSec)
	end)
end

local function sendNotify(player, text, remotes)
	local remote = findRemote(remotes, "Notify")
	if not remote then
		return
	end
	pcall(function()
		remote:FireClient(player, text)
	end)
end

local function validSlotIndex(slotIdx)
	return type(slotIdx) == "number"
		and slotIdx >= 1
		and slotIdx <= SLOT_COUNT
		and math.floor(slotIdx) == slotIdx
end

-- ---------------------------------------------------------------------------
-- addIncome(players [, remotes])
-- Untuk tiap pemain: jumlahkan income semua slot terisi (roster x
-- IncomeMult), tambahkan ke Money, kirim MoneyUpdate (money, incomePerSec).
-- Mengembalikan total uang yang dibayarkan ke semua pemain pada tick ini.
-- ---------------------------------------------------------------------------

function Economy.addIncome(players, remotes)
	local tableRef = resolvePlayers(players)
	if not tableRef then
		return 0
	end
	local remotesRef = resolveRemotes(remotes)
	local totalPaid = 0
	for player, state in pairs(tableRef) do
		if typeof(player) == "Instance"
			and player:IsA("Player")
			and type(state) == "table"
			and type(state.Money) == "number" then
			local rate = incomePerSecOf(state)
			state.Money = state.Money + rate
			totalPaid = totalPaid + rate
			sendMoneyUpdate(player, state, remotesRef, rate)
		end
	end
	return totalPaid
end

-- ---------------------------------------------------------------------------
-- sellSlot(player, players, slotIdx [, clearSlotVisual [, remotes]])
-- Jual Brainrot di satu slot seharga 50% harga beli. Validasi: pemain punya
-- state, nomor slot sah, slot terisi, pemain pemilik base (state.Base ada).
-- Visual pedestal dibersihkan lewat callback clearSlotVisual(player, slotIdx)
-- bila diberikan; bila tidak, Main membersihkannya dari nilai kembalian
-- {slotIdx, kind, uid, price}. Mengirim MoneyUpdate + Notify.
-- Mengembalikan (sukses, pesan, info) -- info nil bila gagal.
-- ---------------------------------------------------------------------------

function Economy.sellSlot(player, players, slotIdx, clearSlotVisual, remotes)
	-- Bentuk pendek DESIGN.md bag. 13: sellSlot(player, slotIdx).
	if type(players) == "number" then
		slotIdx = players
		players = boundPlayers
		clearSlotVisual = nil
		remotes = nil
	end

	local state = resolveState(player, players)
	if not state then
		return false, "Data pemain tidak ditemukan."
	end
	if not validSlotIndex(slotIdx) then
		return false, "Nomor slot tidak valid."
	end
	-- Pemain harus pemilik base (slot yang dijual adalah slot base sendiri).
	if state.Base == nil then
		return false, "Kamu belum memiliki base."
	end
	local slots = state.Slots
	if type(slots) ~= "table" then
		return false, "Slot tidak ditemukan."
	end
	local item = slots[slotIdx]
	if type(item) ~= "table" or type(item.Kind) ~= "string" then
		return false, "Slot sudah kosong."
	end

	local price = rosterPrice(item.Kind)
	if not price then
		return false, "Harga Brainrot tidak dikenal."
	end
	local sellPrice = math.floor(price * SELL_RATE)
	if sellPrice < 0 then
		sellPrice = 0
	end

	slots[slotIdx] = nil
	state.Money = state.Money + sellPrice

	-- Bersihkan visual pedestal lewat callback; bila tidak ada callback,
	-- Main membersihkan dari info yang dikembalikan.
	if type(clearSlotVisual) == "function" then
		pcall(clearSlotVisual, player, slotIdx)
	end

	local remotesRef = resolveRemotes(remotes)
	sendMoneyUpdate(player, state, remotesRef, incomePerSecOf(state))
	sendNotify(player, "Terjual " .. item.Kind .. " seharga $" .. tostring(sellPrice) .. ".", remotesRef)

	return true, "Terjual " .. item.Kind .. " seharga $" .. tostring(sellPrice) .. ".", {
		slotIdx = slotIdx,
		kind = item.Kind,
		uid = item.Uid,
		price = sellPrice,
	}
end

-- ---------------------------------------------------------------------------
-- rebirth(player [, players [, remotes]])
-- Biaya = REBIRTH_BASE x 2^Rebirths saat ini. Validasi: uang cukup.
-- Saat berhasil: uang direset ke $100, semua slot + Carried dihapus,
-- Rebirths +1, IncomeMult = 1 + Rebirths x 0,5. Mengirim MoneyUpdate + Notify.
-- Info kembalian memuat slot yang dikosongkan + carried lama agar Main bisa
-- membersihkan visual pedestal dan visual carry.
-- Mengembalikan (sukses, pesan, info) -- info nil bila gagal.
-- ---------------------------------------------------------------------------

function Economy.rebirth(player, players, remotes)
	local state = resolveState(player, players)
	if not state then
		return false, "Data pemain tidak ditemukan."
	end
	if type(state.Money) ~= "number" then
		state.Money = START_MONEY
	end
	local rebirths = state.Rebirths
	if type(rebirths) ~= "number" or rebirths < 0 then
		rebirths = 0
		state.Rebirths = 0
	end

	local cost = REBIRTH_BASE * (2 ^ rebirths)
	if state.Money < cost then
		return false, "Uang tidak cukup untuk rebirth. Butuh $" .. tostring(cost) .. "."
	end

	-- Catat dulu apa yang dihapus, supaya Main bisa membersihkan visualnya.
	local clearedSlots = {}
	local slots = state.Slots
	if type(slots) == "table" then
		for i = 1, SLOT_COUNT do
			if type(slots[i]) == "table" then
				clearedSlots[#clearedSlots + 1] = i
				slots[i] = nil
			end
		end
	end
	local carriedWas = state.Carried
	state.Carried = nil

	state.Money = REBIRTH_RESET_MONEY
	state.Rebirths = rebirths + 1
	state.IncomeMult = 1 + state.Rebirths * 0.5

	local remotesRef = resolveRemotes(remotes)
	sendMoneyUpdate(player, state, remotesRef, 0)
	sendNotify(
		player,
		"Rebirth ke-" .. tostring(state.Rebirths)
			.. "! Pengali income sekarang x" .. tostring(state.IncomeMult) .. ".",
		remotesRef
	)

	return true, "Rebirth berhasil! Pengali income x" .. tostring(state.IncomeMult) .. ".", {
		cost = cost,
		rebirths = state.Rebirths,
		incomeMult = state.IncomeMult,
		clearedSlots = clearedSlots,
		carriedWas = carriedWas,
	}
end

return Economy
