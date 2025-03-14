-- used when muted
local disableUpdates = false
local isListenerEnabled = false
local plyCoords = GetEntityCoords(cache.ped)
proximity = MumbleGetTalkerProximity()
currentTargets = {}

-- a list of all the players the current client us listening to
-- the value will be set to false if we didn't actually start listening to them (in situations where their channel didn't exist)
-- TODO: PR a native to let us get if we're listening to a certain channel.
local listeners = {}

function orig_addProximityCheck(ply)
	local tgtPed = GetPlayerPed(ply)
	local voiceRange = GetConvar('voice_useNativeAudio', 'false') == 'true' and proximity * 3 or proximity
	local distance = #(plyCoords - GetEntityCoords(tgtPed))
	return distance < voiceRange, distance
end

local addProximityCheck = orig_addProximityCheck

exports("overrideProximityCheck", function(fn)
	addProximityCheck = fn
end)

exports("resetProximityCheck", function()
	addProximityCheck = orig_addProximityCheck
end)

function addNearbyPlayers()
	if disableUpdates then return end
	-- update here so we don't have to update every call of addProximityCheck
	plyCoords = GetEntityCoords(cache.ped)
	proximity = MumbleGetTalkerProximity()
	currentTargets = {}
	MumbleClearVoiceTargetChannels(voiceTarget)
	if LocalPlayer.state.disableProximity then return end
	MumbleAddVoiceChannelListen(LocalPlayer.state.assignedChannel)
	MumbleAddVoiceTargetChannel(voiceTarget, LocalPlayer.state.assignedChannel)
	for source, _ in pairs(callData) do
		if source ~= playerServerId then
			local channel = MumbleGetVoiceChannelFromServerId(source)
			if channel ~= -1 then
				MumbleAddVoiceTargetChannel(voiceTarget, channel)
			end
		end
	end

	local players = GetActivePlayers()
	for i = 1, #players do
		local ply = players[i]
		local serverId = GetPlayerServerId(ply)
		local shouldAdd, distance = addProximityCheck(ply)
		if shouldAdd then
			-- if distance then
			-- 	currentTargets[serverId] = distance
			-- else
			-- 	-- backwards compat, maybe remove in v7
			-- 	currentTargets[serverId] = 15.0
			-- end
			-- logger.verbose('Added %s as a voice target', serverId)
			local channel = MumbleGetVoiceChannelFromServerId(serverId)
			if channel ~= -1 then
				MumbleAddVoiceTargetChannel(voiceTarget, channel)
			end
		end
	end
end

function addChannelListener(serverId)
	-- not in the documentation, but this will return -1 whenever the client isn't in a channel
	local channel = MumbleGetVoiceChannelFromServerId(serverId)
	if channel ~= -1 then
		MumbleAddVoiceChannelListen(channel)
		logger.verbose("Adding %s to listen table", serverId)
	end
	listeners[serverId] = channel ~= -1
end

function removeChannelListener(serverId)
	if listeners[serverId] then
		local channel = MumbleGetVoiceChannelFromServerId(serverId)
		if channel ~= -1 then
			MumbleRemoveVoiceChannelListen(channel)
		end
		logger.verbose("Removing %s from listen table", serverId)
	end
	-- remove the listener if they exist
	listeners[serverId] = nil
end

function setSpectatorMode(enabled)
	logger.info('Setting spectate mode to %s', enabled)
	isListenerEnabled = enabled
	local players = GetActivePlayers()
	if isListenerEnabled then
		for i = 1, #players do
			local ply = players[i]
			local serverId = GetPlayerServerId(ply)
			if serverId == playerServerId then goto skip_loop end
			addChannelListener(serverId)
			::skip_loop::
		end
	else
		for i = 1, #players do
			local ply = players[i]
			local serverId = GetPlayerServerId(ply)
			if serverId == playerServerId then goto skip_loop end
			removeChannelListener(serverId)
			::skip_loop::
		end

		-- cleanup table if we stop listening
		listeners = {}
	end
end

function tryListeningToFailedListeners()
	for src, isListening in pairs(listeners) do
		-- if we failed to listen before we'll be set to false
		if not isListening then
			addChannelListener(src)
		end
	end
end

RegisterNetEvent('onPlayerJoining', function(serverId)
	if isListenerEnabled then
		addChannelListener(serverId)
	end
end)

RegisterNetEvent('onPlayerDropped', function(serverId)
	if isListenerEnabled then
		removeChannelListener(serverId)
	end
end)

local listenerOverride = false
exports("setListenerOverride", function(enabled)
	type_check({ enabled, "boolean" })
	listenerOverride = enabled
end)

-- cache talking status so we only send a nui message when its not the same as what it was before
local lastTalkingStatus = false
local lastRadioStatus = false
local voiceState = "proximity"
CreateThread(function()
	TriggerEvent('chat:addSuggestion', '/muteply', 'Mutes the player with the specified id', {
		{ name = "player id", help = "the player to toggle mute" },
		{ name = "duration",  help = "(opt) the duration the mute in seconds (default: 900)" }
	})
	while true do
		-- wait for mumble to reconnect
		while not MumbleIsConnected() or not isInitialized do
			Wait(100)
		end
		-- Leave the check here as we don't want to do any of this logic
		if GetConvarInt('voice_enableUi', 1) == 1 then
			local curTalkingStatus = MumbleIsPlayerTalking(cache.playerId) == 1
			if lastRadioStatus ~= radioPressed or lastTalkingStatus ~= curTalkingStatus then
				lastRadioStatus = radioPressed
				lastTalkingStatus = curTalkingStatus
				sendUIMessage({
					usingRadio = lastRadioStatus,
					talking = lastTalkingStatus
				})
			end
		end
		if voiceState == "proximity" then
			addNearbyPlayers()
			-- What a name, wowza
			local cam = GetConvarInt("voice_disableAutomaticListenerOnCamera", 0) ~= 1 and GetRenderingCam() or -1
			local isSpectating = NetworkIsInSpectatorMode() or cam ~= -1
			if not isListenerEnabled and (isSpectating or listenerOverride) then
				setSpectatorMode(true)
			elseif isListenerEnabled and not isSpectating and not listenerOverride then
				setSpectatorMode(false)
			end
			tryListeningToFailedListeners()
		end
		Wait(GetConvarInt('voice_refreshRate', 200))
	end
end)

exports("setVoiceState", function(_voiceState, channel)
	if _voiceState ~= "proximity" and _voiceState ~= "channel" then
		logger.error("Didn't get a proper voice state, expected proximity or channel, got %s", _voiceState)
	end
	voiceState = _voiceState
	if voiceState == "channel" then
		type_check({ channel, "number" })
		-- 65535 is the highest a client id can go, so we add that to the base channel so we don't manage to get onto a players channel
		channel = channel + 65535
		MumbleSetVoiceChannel(channel)
		while MumbleGetVoiceChannelFromServerId(playerServerId) ~= channel do
			Wait(250)
		end
		MumbleAddVoiceTargetChannel(voiceTarget, channel)
	elseif voiceState == "proximity" then
		handleInitialState()
	end
end)

AddEventHandler("onClientResourceStop", function(resource)
	if type(addProximityCheck) == "table" then
		local proximityCheckRef = addProximityCheck.__cfx_functionReference
		if proximityCheckRef then
			local isResource = string.match(proximityCheckRef, resource)
			if isResource then
				addProximityCheck = orig_addProximityCheck
				logger.warn('Reset proximity check to default, the original resource [%s] which provided the function restarted', resource)
			end
		end
	end
end)

exports("addVoiceMode", function(distance, name)
	for i = 1, #Cfg.voiceModes do
		local voiceMode = Cfg.voiceModes[i]
		if voiceMode[2] == name then
			logger.verbose("Already had %s, overwritting instead", name)
			voiceMode[1] = distance
			return
		end
	end
	Cfg.voiceModes[#Cfg.voiceModes + 1] = { distance, name }
end)

exports("removeVoiceMode", function(name)
	for i = 1, #Cfg.voiceModes do
		local voiceMode = Cfg.voiceModes[i]
		if voiceMode[2] == name then
			table.remove(Cfg.voiceModes, i)
			-- Reset our current range if we had it
			if mode == i then
				local newMode = Cfg.voiceModes[1]
				mode = 1
				setProximityState(newMode[mode], false)
			end
			return true
		end
	end
	return false
end)
