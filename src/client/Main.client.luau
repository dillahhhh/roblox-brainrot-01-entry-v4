-- Main.client.luau
-- Client Pasar Brainrot (rebuild v4, ditulis dari DESIGN.md).
-- SATU-SATUNYA LocalScript client. Tugasnya HANYA:
--   * membangun seluruh UI (uang, bawaan, banner banjir, tombol lock/rebirth),
--   * mendengarkan RemoteEvent dari server (FloodEvent, MoneyUpdate,
--     StealResult, Notify) dan menampilkan hasilnya,
--   * mengatur teks ProximityPrompt lalu mengirim permintaan ke server
--     HANYA lewat RemoteEvent (StealRequest, PlaceRequest, SellRequest,
--     LockRequest, RebirthRequest, ClaimRequest),
--   * memutar BGM Lo-fi Chill A (asset 9043887091) + watchdog replay.
-- Client TIDAK PERNAH mengubah uang, slot, atau state game apa pun.
-- Semua angka ekonomi di sini hanya untuk TAMPILAN (harga rebirth dll);
-- kebenaran mutlak ada di server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Konstanta tampilan (cerminan DESIGN.md bag. 3 & 5; server yang berwenang)
--------------------------------------------------------------------------------
local REBIRTH_BASE_COST = 100000
local BGM_ASSET_ID = "rbxassetid://9043887091"
local BGM_VOLUME = 0.5
local BGM_WATCHDOG_SECONDS = 3

-- Warna rarity (DESIGN.md bag. 3) dipakai untuk label CarryPanel.
local RARITY_COLORS = {
	Common = Color3.fromRGB(220, 220, 220),
	Uncommon = Color3.fromRGB(110, 220, 110),
	Rare = Color3.fromRGB(65, 165, 255),
	Epic = Color3.fromRGB(185, 85, 255),
	Legendary = Color3.fromRGB(255, 140, 40),
	Mythic = Color3.fromRGB(255, 65, 65),
	["Ultra Rare"] = Color3.fromRGB(255, 225, 0),
}

--------------------------------------------------------------------------------
-- RemoteEvent (kontrak DESIGN.md bag. 13 — nama harus sama persis)
--------------------------------------------------------------------------------
local remotesFolder = ReplicatedStorage:WaitForChild("GameRemotes", 30)
if not remotesFolder then
	warn("[Client] GameRemotes tidak ditemukan setelah 30 detik; UI jalan tanpa server.")
end

local function getRemote(name)
	if not remotesFolder then
		return nil
	end
	local remote = remotesFolder:FindFirstChild(name)
	if not remote then
		warn("[Client] RemoteEvent hilang: " .. name)
	end
	return remote
end

local FloodEvent = getRemote("FloodEvent")
local MoneyUpdate = getRemote("MoneyUpdate")
local StealResult = getRemote("StealResult")
local NotifyEvent = getRemote("Notify")
local StealRequest = getRemote("StealRequest")
local PlaceRequest = getRemote("PlaceRequest")
local SellRequest = getRemote("SellRequest")
local LockRequest = getRemote("LockRequest")
local RebirthRequest = getRemote("RebirthRequest")
local ClaimRequest = getRemote("ClaimRequest")

--------------------------------------------------------------------------------
-- State lokal (tampilan saja, bukan kebenaran game)
--------------------------------------------------------------------------------
local locked = false -- status kunci base menurut client (server yang memutuskan)
local rebirths = 0 -- jumlah rebirth menurut client, untuk hitung biaya tampil
local carryingName = nil -- nama Brainrot yang dibawa (nil = tangan kosong)
local muted = false
local rebirthArmedUntil = 0 -- waktu (os.clock) sampai konfirmasi rebirth kedaluwarsa

--------------------------------------------------------------------------------
-- Util
--------------------------------------------------------------------------------
local function clamp(value, low, high)
	if value < low then
		return low
	elseif value > high then
		return high
	end
	return value
end

-- Format uang: 1234567 -> "$1,234,567"
local function formatMoney(amount)
	local n = math.floor(amount or 0)
	local negative = n < 0
	n = math.abs(n)
	local text = tostring(n)
	local out = ""
	while #text > 3 do
		out = "," .. string.sub(text, -3) .. out
		text = string.sub(text, 1, -4)
	end
	out = text .. out
	if negative then
		return "-$" .. out
	end
	return "$" .. out
end

local function rebirthCost()
	return REBIRTH_BASE_COST * (2 ^ rebirths)
end

--------------------------------------------------------------------------------
-- UI root + UIScale responsif (DESIGN.md bag. 9)
-- skala = clamp(min(lebar/1100, tinggi/700), 0.55, 1)
--------------------------------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PasarBrainrotUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true -- banner y=8 benar-benar di atas layar
screenGui.DisplayOrder = 10
screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local uiScale = Instance.new("UIScale")
uiScale.Parent = screenGui

local function updateScale()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local size = camera.ViewportSize
	local scale = math.min(size.X / 1100, size.Y / 700)
	uiScale.Scale = clamp(scale, 0.55, 1)
end

-- ViewportSize berubah saat resize/rotasi HP; pantau lewat kamera.
task.spawn(function()
	while true do
		updateScale()
		task.wait(0.5)
	end
end)

local function makeFrame(name, parent, size, position, anchor)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = anchor or Vector2.new(0, 0)
	frame.BackgroundColor3 = Color3.fromRGB(20, 16, 28)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 200, 90)
	stroke.Thickness = 2
	stroke.Transparency = 0.35
	stroke.Parent = frame
	return frame
end

local function makeLabel(parent, name, text, textSize, color, bold)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Position = UDim2.new(0, 0, 0, 0)
	label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.TextSize = textSize
	label.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	label.Text = text
	label.TextWrapped = true
	label.Parent = parent
	return label
end

local function makeButton(parent, name, text, size, position, anchor)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.Position = position
	button.AnchorPoint = anchor or Vector2.new(0, 0)
	button.BackgroundColor3 = Color3.fromRGB(40, 30, 60)
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.TextColor3 = Color3.fromRGB(255, 240, 200)
	button.Text = text
	button.TextWrapped = true
	button.AutoButtonColor = true
	button.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 200, 90)
	stroke.Thickness = 2
	stroke.Transparency = 0.4
	stroke.Parent = button
	return button
end

--------------------------------------------------------------------------------
-- FloodBanner: atas-tengah, y=8, 520x44, tidak menutupi pojok kiri atas
--------------------------------------------------------------------------------
local floodBanner = makeFrame(
	"FloodBanner",
	screenGui,
	UDim2.new(0, 520, 0, 44),
	UDim2.new(0.5, 0, 0, 8),
	Vector2.new(0.5, 0)
)
local floodLabel = makeLabel(floodBanner, "FloodText", "Pasar Tenang", 20, Color3.fromRGB(220, 255, 220), true)

local FLOOD_TEXT = {
	Idle = "Pasar Tenang",
	Warning = "PERINGATAN BANJIR!",
	Flooding = "BANJIR! Pasar Tumpah!",
	Scramble = "Perebutan Peti!",
}
local FLOOD_COLORS = {
	Idle = Color3.fromRGB(30, 90, 50),
	Warning = Color3.fromRGB(140, 70, 0),
	Flooding = Color3.fromRGB(20, 60, 140),
	Scramble = Color3.fromRGB(90, 30, 130),
}

local function setFloodBanner(phase, secondsLeft)
	local base = FLOOD_TEXT[phase] or "Pasar Tenang"
	if secondsLeft and secondsLeft > 0 then
		if phase == "Warning" then
			floodLabel.Text = base .. " — " .. math.ceil(secondsLeft) .. " dtk"
		elseif phase == "Flooding" then
			floodLabel.Text = base .. " — berlindung di base!"
		elseif phase == "Scramble" then
			floodLabel.Text = base .. " — sisa " .. math.ceil(secondsLeft) .. " dtk"
		else
			floodLabel.Text = base
		end
	else
		floodLabel.Text = base
	end
	floodBanner.BackgroundColor3 = FLOOD_COLORS[phase] or FLOOD_COLORS.Idle
end

--------------------------------------------------------------------------------
-- MoneyPanel: bawah-tengah (uang besar + income/detik)
--------------------------------------------------------------------------------
local moneyPanel = makeFrame(
	"MoneyPanel",
	screenGui,
	UDim2.new(0, 300, 0, 76),
	UDim2.new(0.5, 0, 1, -12),
	Vector2.new(0.5, 1)
)
local moneyLabel = makeLabel(moneyPanel, "MoneyText", "$200", 34, Color3.fromRGB(255, 225, 90), true)
moneyLabel.Size = UDim2.new(1, 0, 0, 44)
moneyLabel.Position = UDim2.new(0, 0, 0, 4)
local incomeLabel = makeLabel(moneyPanel, "IncomeText", "+$0/detik", 16, Color3.fromRGB(170, 255, 170), false)
incomeLabel.Size = UDim2.new(1, 0, 0, 22)
incomeLabel.Position = UDim2.new(0, 0, 0, 48)

local function setMoney(money, incomePerSec)
	moneyLabel.Text = formatMoney(money)
	incomeLabel.Text = "+" .. formatMoney(incomePerSec or 0) .. "/detik"
end

--------------------------------------------------------------------------------
-- CarryPanel: di atas MoneyPanel, info Brainrot yang dibawa
--------------------------------------------------------------------------------
local carryPanel = makeFrame(
	"CarryPanel",
	screenGui,
	UDim2.new(0, 300, 0, 40),
	UDim2.new(0.5, 0, 1, -100),
	Vector2.new(0.5, 1)
)
local carryLabel = makeLabel(carryPanel, "CarryText", "Tangan kosong", 17, Color3.fromRGB(230, 230, 230), false)

local function setCarry(name, rarity)
	if name and name ~= "" then
		carryingName = name
		carryLabel.Text = "Membawa: " .. name
		carryLabel.TextColor3 = RARITY_COLORS[rarity] or Color3.fromRGB(255, 255, 255)
	else
		carryingName = nil
		carryLabel.Text = "Tangan kosong"
		carryLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
	end
end

-- Deteksi bawaan dari karakter: server menempelkan model Brainrot yang dibawa
-- ke karakter; model itu membawa atribut BrainrotKind (nama) / BrainrotRarity.
-- Kalau server tidak memberi atribut itu, panel tetap diperbarui lewat
-- StealResult/Notify di bawah (optimistis), jadi UI tidak pernah macet.
local function scanCarriedFromCharacter()
	local character = LocalPlayer.Character
	if not character then
		return
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Model") or descendant:IsA("BasePart") then
			local kind = nil
			local ok, value = pcall(function()
				return descendant:GetAttribute("BrainrotKind")
			end)
			if ok and value and value ~= "" then
				kind = value
			end
			if not kind and descendant.Name == "CarriedBrainrot" then
				kind = "Brainrot"
			end
			if kind then
				local rarity = nil
				local ok2, value2 = pcall(function()
					return descendant:GetAttribute("BrainrotRarity")
				end)
				if ok2 then
					rarity = value2
				end
				setCarry(kind, rarity)
				return
			end
		end
	end
	-- Tidak ada model bawaan terdeteksi: hanya kosongkan kalau kita tidak
	-- sedang menunggu konfirmasi server (StealResult sudah menandai membawa).
	if carryingName == nil then
		setCarry(nil, nil)
	end
end

--------------------------------------------------------------------------------
-- Tombol Lock / Rebirth / Mute (kanan layar, jauh dari pojok kiri atas)
--------------------------------------------------------------------------------
local lockButton = makeButton(
	screenGui,
	"LockButton",
	"Kunci Base",
	UDim2.new(0, 160, 0, 44),
	UDim2.new(1, -12, 0.5, -56),
	Vector2.new(1, 0)
)
local rebirthButton = makeButton(
	screenGui,
	"RebirthButton",
	"Rebirth ($100,000)",
	UDim2.new(0, 160, 0, 44),
	UDim2.new(1, -12, 0.5, 0),
	Vector2.new(1, 0)
)
local muteButton = makeButton(
	screenGui,
	"MuteButton",
	"Suara: ON",
	UDim2.new(0, 110, 0, 36),
	UDim2.new(1, -12, 0, 64),
	Vector2.new(1, 0)
)
muteButton.TextSize = 14

local function refreshLockButton()
	if locked then
		lockButton.Text = "Buka Base"
		lockButton.BackgroundColor3 = Color3.fromRGB(90, 30, 30)
	else
		lockButton.Text = "Kunci Base"
		lockButton.BackgroundColor3 = Color3.fromRGB(40, 30, 60)
	end
end

local function refreshRebirthButton()
	rebirthButton.Text = "Rebirth (" .. formatMoney(rebirthCost()) .. ")"
end

lockButton.MouseButton1Click:Connect(function()
	locked = not locked
	refreshLockButton()
	if LockRequest then
		LockRequest:FireServer(locked)
	end
end)

-- Rebirth: klik pertama = konfirmasi biaya (5 detik), klik kedua = kirim.
rebirthButton.MouseButton1Click:Connect(function()
	local now = os.clock()
	if now < rebirthArmedUntil then
		rebirthArmedUntil = 0
		refreshRebirthButton()
		if RebirthRequest then
			RebirthRequest:FireServer()
		end
	else
		rebirthArmedUntil = now + 5
		rebirthButton.Text = "Yakin? " .. formatMoney(rebirthCost())
		task.delay(5, function()
			if os.clock() >= rebirthArmedUntil then
				refreshRebirthButton()
			end
		end)
	end
end)

--------------------------------------------------------------------------------
-- Toast pesan singkat (tengah layar, hilang sendiri)
--------------------------------------------------------------------------------
local toastFrame = makeFrame(
	"Toast",
	screenGui,
	UDim2.new(0, 420, 0, 40),
	UDim2.new(0.5, 0, 0.5, -120),
	Vector2.new(0.5, 0.5)
)
toastFrame.Visible = false
local toastLabel = makeLabel(toastFrame, "ToastText", "", 17, Color3.fromRGB(255, 255, 255), true)
local toastToken = 0

local function showToast(text, good)
	toastToken = toastToken + 1
	local myToken = toastToken
	toastLabel.Text = text
	toastLabel.TextColor3 = good and Color3.fromRGB(150, 255, 150) or Color3.fromRGB(255, 170, 170)
	toastFrame.Visible = true
	task.delay(3, function()
		if myToken == toastToken then
			toastFrame.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------
-- BGM Lo-fi Chill A + watchdog (DESIGN.md bag. 2 & 9)
--------------------------------------------------------------------------------
local bgm = Instance.new("Sound")
bgm.Name = "BGM_LofiChillA"
bgm.SoundId = BGM_ASSET_ID
bgm.Looped = true
bgm.Volume = BGM_VOLUME
bgm.Parent = SoundService

local lastPlayingAt = os.clock()

local function startBgm()
	if muted then
		return
	end
	if not bgm.IsPlaying then
		bgm:Play()
	end
	lastPlayingAt = os.clock()
end

startBgm()

muteButton.MouseButton1Click:Connect(function()
	muted = not muted
	if muted then
		bgm.Volume = 0
		bgm:Pause()
		muteButton.Text = "Suara: OFF"
	else
		bgm.Volume = BGM_VOLUME
		muteButton.Text = "Suara: ON"
		startBgm()
	end
end)

-- Watchdog: kalau BGM berhenti >3 detik padahal tidak dimute, putar ulang.
task.spawn(function()
	while true do
		task.wait(1)
		if not muted then
			if bgm.IsPlaying then
				lastPlayingAt = os.clock()
			elseif os.clock() - lastPlayingAt > BGM_WATCHDOG_SECONDS then
				startBgm()
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Mendengarkan server (server -> client)
--------------------------------------------------------------------------------
if FloodEvent then
	FloodEvent.OnClientEvent:Connect(function(phase, secondsLeft)
		setFloodBanner(phase, secondsLeft)
	end)
end

if MoneyUpdate then
	MoneyUpdate.OnClientEvent:Connect(function(money, incomePerSec)
		setMoney(money, incomePerSec)
	end)
end

if StealResult then
	StealResult.OnClientEvent:Connect(function(success, message)
		showToast(message or (success and "Berhasil!" or "Gagal!"), success)
		if success then
			-- Optimistis: tangan kini membawa Brainrot; nama pastinya
			-- dikonfirmasi pemindaian karakter di bawah.
			if carryingName == nil then
				setCarry("Brainrot", nil)
			end
		end
	end)
end

if NotifyEvent then
	NotifyEvent.OnClientEvent:Connect(function(text)
		if text and text ~= "" then
			showToast(text, true)
			local lower = string.lower(text)
			if string.find(lower, "rebirth", 1, true) then
				rebirths = rebirths + 1
				setCarry(nil, nil)
				refreshRebirthButton()
			elseif string.find(lower, "ditaruh", 1, true)
				or string.find(lower, "dijual", 1, true)
				or string.find(lower, "terjual", 1, true) then
				setCarry(nil, nil)
			end
		end
	end)
end

-- Pemindaian bawaan berkala + saat karakter respawn.
task.spawn(function()
	while true do
		scanCarriedFromCharacter()
		task.wait(0.5)
	end
end)

LocalPlayer.CharacterAdded:Connect(function(character)
	setCarry(nil, nil)
	task.wait(1)
	scanCarriedFromCharacter()
	character.DescendantAdded:Connect(function()
		scanCarriedFromCharacter()
	end)
	character.DescendantRemoving:Connect(function()
		task.delay(0.2, scanCarriedFromCharacter)
	end)
end)

--------------------------------------------------------------------------------
-- ProximityPrompt: atur teks + kirim permintaan ke server
-- Server memberi atribut pada prompt (kontrak kerja dengan server):
--   PromptKind: "Pedestal" | "Crate"
--   OwnerUserId (number), SlotFilled (boolean), BaseIdx (number),
--   SlotIdx (number), CrateId (string)
-- Kalau atribut belum ada (server lama), fallback ke nama prompt.
--------------------------------------------------------------------------------
local promptActions = {} -- [prompt] = {action, baseIdx, slotIdx, crateId}

local function readNumberAttribute(instance, name)
	local ok, value = pcall(function()
		return instance:GetAttribute(name)
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return nil
end

local function readStringAttribute(instance, name)
	local ok, value = pcall(function()
		return instance:GetAttribute(name)
	end)
	if ok and typeof(value) == "string" then
		return value
	end
	return nil
end

local function readBoolAttribute(instance, name)
	local ok, value = pcall(function()
		return instance:GetAttribute(name)
	end)
	if ok and typeof(value) == "boolean" then
		return value
	end
	return nil
end

-- Cari atribut dengan menelusuri prompt lalu leluhurnya (pedestal/base/peti).
local function findAttribute(prompt, name, reader)
	local current = prompt
	while current do
		local value = reader(current, name)
		if value ~= nil then
			return value
		end
		current = current.Parent
	end
	return nil
end

ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
	local kind = findAttribute(prompt, "PromptKind", readStringAttribute)
		or findAttribute(prompt, "Kind", readStringAttribute)
	local ownerUserId = findAttribute(prompt, "OwnerUserId", readNumberAttribute)
	local slotFilled = findAttribute(prompt, "SlotFilled", readBoolAttribute)
	local baseIdx = findAttribute(prompt, "BaseIdx", readNumberAttribute)
	local slotIdx = findAttribute(prompt, "SlotIdx", readNumberAttribute)
	local crateId = findAttribute(prompt, "CrateId", readStringAttribute)

	-- Fallback dari nama: prompt peti biasanya bernama "CratePrompt" dsb.
	if not kind then
		local haystack = string.lower(prompt.Name .. " " .. (prompt.Parent and prompt.Parent.Name or ""))
		if string.find(haystack, "crate", 1, true) or string.find(haystack, "peti", 1, true) then
			kind = "Crate"
		else
			kind = "Pedestal"
		end
	end

	if kind == "Crate" then
		prompt.ActionText = "Buka Peti"
		prompt.ObjectText = "Peti Pasar Tumpah"
		promptActions[prompt] = { action = "Claim", crateId = crateId }
		return
	end

	-- Pedestal.
	local isOwner = ownerUserId ~= nil and ownerUserId == LocalPlayer.UserId
	if isOwner then
		if slotFilled then
			prompt.ActionText = "Jual"
			prompt.ObjectText = "Jual Brainrot (50%)"
			promptActions[prompt] = { action = "Sell", baseIdx = baseIdx, slotIdx = slotIdx }
		else
			prompt.ActionText = "Taruh"
			prompt.ObjectText = "Taruh Brainrot di sini"
			promptActions[prompt] = { action = "Place", baseIdx = baseIdx, slotIdx = slotIdx }
		end
	else
		if slotFilled == false then
			-- Pedestal kosong milik orang lain: tidak ada yang bisa dicuri.
			-- Sembunyikan prompt lokal; PromptHidden nanti mengembalikannya.
			prompt.Enabled = false
			promptActions[prompt] = nil
		else
			prompt.ActionText = "Curi Brainrot"
			prompt.ObjectText = "Ambil Brainrot ini"
			promptActions[prompt] = { action = "Steal", baseIdx = baseIdx, slotIdx = slotIdx }
		end
	end
end)

ProximityPromptService.PromptHidden:Connect(function(prompt)
	-- Kembalikan prompt yang sempat kami nonaktifkan (pedestal kosong).
	if not prompt.Enabled then
		prompt.Enabled = true
	end
	promptActions[prompt] = nil
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
	if player ~= LocalPlayer then
		return
	end
	local plan = promptActions[prompt]
	if not plan then
		return
	end
	if plan.action == "Steal" and StealRequest then
		StealRequest:FireServer(plan.baseIdx, plan.slotIdx)
	elseif plan.action == "Place" and PlaceRequest then
		PlaceRequest:FireServer(plan.slotIdx)
	elseif plan.action == "Sell" and SellRequest then
		SellRequest:FireServer(plan.slotIdx)
	elseif plan.action == "Claim" and ClaimRequest then
		ClaimRequest:FireServer(plan.crateId)
	end
end)

-- State awal.
setMoney(200, 0)
setFloodBanner("Idle", 0)
refreshLockButton()
refreshRebirthButton()
updateScale()
