--[[
	DataStore2: A wrapper for data stores that caches, saves player's data, and uses berezaa's method of saving data.
	Use require(1936396537) to have an updated version of DataStore2.

	DataStore2(dataStoreName, player) - Returns a DataStore2 DataStore

	DataStore2 DataStore:
	- Get([defaultValue])
	- Set(value)
	- Update(updateFunc)
	- Increment(value, defaultValue)
	- BeforeInitialGet(modifier)
	- BeforeSave(modifier)
	- Save()
	- SaveAsync()
	- OnUpdate(callback)
	- BindToClose(callback)

	local coinStore = DataStore2("Coins", player)

	To give a player coins:

	coinStore:Increment(50)

	To get the current player's coins:

	coinStore:Get()
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Constants = require(script.Constants)
local Promise = require(script.Promise)
local SavingMethods = require(script.SavingMethods)
local TableUtil = require(script.TableUtil)
local Verifier = require(script.Verifier)

local SaveInStudioObject = ServerStorage:FindFirstChild("SaveInStudio")
local SaveInStudio = SaveInStudioObject and SaveInStudioObject.Value

local function clone(value)
	if typeof(value) == "table" then
		return TableUtil.clone(value)
	else
		return value
	end
end

--DataStore object
local DataStore = {}

--Internal functions
function DataStore:Debug(...)
	if self.debug then
		print(...)
	end
end

function DataStore:_GetRaw()
	if self.getRawPromise then
		return self.getRawPromise
	end

	self.getRawPromise = self.savingMethod:Get():andThen(function(value)
		self.value = value
		self:Debug("value received")
		self.haveValue = true
	end):finally(function()
		self.getting = false
	end)

	return self.getRawPromise
end

function DataStore:_Update(dontCallOnUpdate)
	if not dontCallOnUpdate then
		for _,callback in pairs(self.callbacks) do
			callback(self.value, self)
		end
	end

	self.haveValue = true
	self.valueUpdated = true
end

--Public functions

--[[**
	<description>
	Gets the result from the data store. Will yield the first time it is called.
	</description>

	<parameter name = "defaultValue">
	The default result if there is no result in the data store.
	</parameter>

	<parameter name = "dontAttemptGet">
	If there is no cached result, just return nil.
	</parameter>

	<returns>
	The value in the data store if there is no cached result. The cached result otherwise.
	</returns>
**--]]
function DataStore:Get(defaultValue, dontAttemptGet)
	if dontAttemptGet then
		return self.value
	end

	local backupCount = 0

	if not self.haveValue then
		while not self.haveValue do
			local success, error = self:_GetRaw():await()

			if not success then
				if self.backupRetries then
					backupCount = backupCount + 1

					if backupCount >= self.backupRetries then
						self.backup = true
						self.haveValue = true
						self.value = self.backupValue
						break
					end
				end

				self:Debug("Get returned error:", error)
			end
		end

		if self.value ~= nil then
			for _,modifier in pairs(self.beforeInitialGet) do
				self.value = modifier(self.value, self)
			end
		end
	end

	local value

	if self.value == nil and defaultValue ~= nil then --not using "not" because false is a possible value
		value = defaultValue
	else
		value = self.value
	end

	value = clone(value)

	self.value = value

	return value
end

function DataStore:GetAsync(...)
	local args = { ... }
	return Promise.async(function(resolve)
		resolve(self:Get(unpack(args)))
	end)
end

--[[**
	<description>
	The same as :Get only it'll check to make sure all keys in the default data provided
	exist. If not, will pass in the default value only for that key.
	This is recommended for tables in case you want to add new entries to the table.
	Note this is not required for tables, it only provides an extra functionality.
	</description>

	<parameter name = "defaultValue">
	A table that will have its keys compared to that of the actual data received.
	</parameter>

	<returns>
	The value in the data store will all keys from the default value provided.
	</returns>
**--]]
function DataStore:GetTable(default, ...)
	local success, result = self:GetTableAsync(default, ...):await()
	if not success then
		error(result)
	end
	return result
end

function DataStore:GetTableAsync(default, ...)
	assert(default ~= nil, "You must provide a default value.")

	return self:GetAsync(default, ...):andThen(function(result)
		local changed = false
		assert(
			typeof(result) == "table",
			":GetTable/:GetTableAsync was used when the value in the data store isn't a table."
		)

		for defaultKey, defaultValue in pairs(default) do
			if result[defaultKey] == nil then
				result[defaultKey] = defaultValue
				changed = true
			end
		end

		if changed then
			self:Set(result)
		end

		return result
	end)
end

--[[**
	<description>
	Sets the cached result to the value provided
	</description>

	<parameter name = "value">
	The value
	</parameter>
**--]]
function DataStore:Set(value, _dontCallOnUpdate)
	self.value = clone(value)
	self:_Update(_dontCallOnUpdate)
end

--[[**
	<description>
	Calls the function provided and sets the cached result.
	</description>

	<parameter name = "updateFunc">
	The function
	</parameter>
**--]]
function DataStore:Update(updateFunc)
	self.value = updateFunc(self.value)
	self:_Update()
end

--[[**
	<description>
	Increment the cached result by value.
	</description>

	<parameter name = "value">
	The value to increment by.
	</parameter>

	<parameter name = "defaultValue">
	If there is no cached result, set it to this before incrementing.
	</parameter>
**--]]
function DataStore:Increment(value, defaultValue)
	self:Set(self:Get(defaultValue) + value)
end

function DataStore:IncrementAsync(add, defaultValue)
	self:GetAsync(defaultValue):andThen(function(value)
		self:Set(value + add)
	end)
end

--[[**
	<description>
	Takes a function to be called whenever the cached result updates.
	</description>

	<parameter name = "callback">
	The function to call.
	</parameter>
**--]]
function DataStore:OnUpdate(callback)
	table.insert(self.callbacks, callback)
end

--[[**
	<description>
	Takes a function to be called when :Get() is first called and there is a value in the data store.
	This function must return a value to set to. Used for deserializing.
	</description>

	<parameter name = "modifier">
	The modifier function.
	</parameter>
**--]]
function DataStore:BeforeInitialGet(modifier)
	table.insert(self.beforeInitialGet, modifier)
end

--[[**
	<description>
	Takes a function to be called before :Save(). This function must return a value
	that will be saved in the data store. Used for serializing.
	</description>

	<parameter name = "modifier">
	The modifier function.
	</parameter>
**--]]
function DataStore:BeforeSave(modifier)
	self.beforeSave = modifier
end

--[[**
	<description>
	Takes a function to be called after :Save().
	</description>

	<parameter name = "callback">
	The callback function.
	</parameter>
**--]]
function DataStore:AfterSave(callback)
	table.insert(self.afterSave, callback)
end

--[[**
	<description>
	Adds a backup to the data store if :Get() fails a specified amount of times.
	Will return the value provided (if the value is nil, then the default value of :Get() will be returned)
	and mark the data store as a backup store, and attempts to :Save() will not truly save.
	</description>

	<parameter name = "retries">
	Number of retries before the backup will be used.
	</parameter>

	<parameter name = "value">
	The value to return to :Get() in the case of a failure.
	You can keep this blank and the default value you provided with :Get() will be used instead.
	</parameter>
**--]]
function DataStore:SetBackup(retries, value)
	self.backupRetries = retries
	self.backupValue = value
end

--[[**
	<description>
	Unmark the data store as a backup data store and tell :Get() and reset values to nil.
	</description>
**--]]
function DataStore:ClearBackup()
	self.backup = nil
	self.haveValue = false
	self.value = nil
end

--[[**
	<returns>
	Whether or not the data store is a backup data store and thus won't save during :Save() or call :AfterSave().
	</returns>
**--]]
function DataStore:IsBackup()
	return self.backup ~= nil --some people haven't learned if x then yet, and will do if x == false then.
end

--[[**
	<description>
	Saves the data to the data store. Called when a player leaves.
	</description>
**--]]
function DataStore:Save()
	local success, result = self:SaveAsync():await()

	if success then
		print("saved " .. self.Name)
	else
		error(result)
	end
end

--[[**
	<description>
	Asynchronously saves the data to the data store.
	</description>
**--]]
function DataStore:SaveAsync()
	return Promise.async(function(resolve, reject)
		if not self.valueUpdated then
			warn(("Data store %s was not saved as it was not updated."):format(self.Name))
			resolve(false)
			return
		end

		if RunService:IsStudio() and not SaveInStudio then
			warn(("Data store %s attempted to save in studio while SaveInStudio is false."):format(self.Name))
			if not SaveInStudioObject then
				warn("You can set the value of this by creating a BoolValue named SaveInStudio in ServerStorage.")
			end
			resolve(false)
			return
		end

		if self.backup then
			warn("This data store is a backup store, and thus will not be saved.")
			resolve(false)
			return
		end

		if self.value ~= nil then
			local save = clone(self.value)

			if self.beforeSave then
				local success, result = pcall(self.beforeSave, save, self)

				if success then
					save = result
				else
					reject(result, Constants.BeforeSaveError)
					return
				end
			end

			local problem = Verifier.testValidity(save)
			if problem then
				reject(problem, Constants.InvalidData)
				return
			end

			return self.savingMethod:Set(save):andThen(function()
				resolve(true, save)
			end)
		end
	end):andThen(function(saved, save)
		if saved then
			for _, afterSave in pairs(self.afterSave) do
				local success, err = pcall(afterSave, save, self)

				if not success then
					warn("Error on AfterSave: "..err)
				end
			end

			self.valueUpdated = false
		end
	end)
end

--[[**
	<description>
	Add a function to be called before the game closes. Fired with the player and value of the data store.
	</description>

	<parameter name = "callback">
	The callback function.
	</parameter>
**--]]
function DataStore:BindToClose(callback)
	table.insert(self.bindToClose, callback)
end

--[[**
	<description>
	Gets the value of the cached result indexed by key. Does not attempt to get the current value in the data store.
	</description>

	<parameter name = "key">
	The key you're indexing by.
	</parameter>

	<returns>
	The value indexed.
	</returns>
**--]]
function DataStore:GetKeyValue(key)
	return (self.value or {})[key]
end

--[[**
	<description>
	Sets the value of the result in the database with the key and the new value.
	Attempts to get the value from the data store. Does not call functions fired on update.
	</description>

	<parameter name = "key">
	The key to set.
	</parameter>

	<parameter name = "newValue">
	The value to set.
	</parameter>
**--]]
function DataStore:SetKeyValue(key, newValue)
	if not self.value then
		self.value = self:Get({})
	end

	self.value[key] = newValue
end

local CombinedDataStore = {}

do
	function CombinedDataStore:BeforeInitialGet(modifier)
		self.combinedBeforeInitialGet = modifier
	end

	function CombinedDataStore:BeforeSave(modifier)
		self.combinedBeforeSave = modifier
	end

	function CombinedDataStore:Get(defaultValue, dontAttemptGet)
		local tableResult = self.combinedStore:Get({})
		local tableValue = tableResult[self.combinedName]

		if not dontAttemptGet then
			if tableValue == nil then
				tableValue = defaultValue
			else
				if self.combinedBeforeInitialGet and not self.combinedInitialGot then
					tableValue = self.combinedBeforeInitialGet(tableValue)
				end
			end
		end

		self.combinedInitialGot = true
		tableResult[self.combinedName] = clone(tableValue)
		self.combinedStore:Set(tableResult, true)
		return clone(tableValue)
	end

	function CombinedDataStore:Set(value, dontCallOnUpdate)
		local tableResult = self.combinedStore:GetTable({})
		tableResult[self.combinedName] = value
		self.combinedStore:Set(tableResult, dontCallOnUpdate)
		self:_Update(dontCallOnUpdate)
	end

	function CombinedDataStore:Update(updateFunc)
		self:Set(updateFunc(self:Get()))
		self:_Update()
	end

	function CombinedDataStore:Save()
		self.combinedStore:Save()
	end

	function CombinedDataStore:OnUpdate(callback)
		if not self.onUpdateCallbacks then
			self.onUpdateCallbacks = { callback }
		else
			self.onUpdateCallbacks[#self.onUpdateCallbacks + 1] = callback
		end
	end

	function CombinedDataStore:_Update(dontCallOnUpdate)
		if not dontCallOnUpdate then
			for _, callback in pairs(self.onUpdateCallbacks or {}) do
				callback(self:Get(), self)
			end
		end

		self.combinedStore:_Update(true)
	end

	function CombinedDataStore:SetBackup(retries)
		self.combinedStore:SetBackup(retries)
	end
end

local DataStoreMetatable = {}

DataStoreMetatable.__index = DataStore

--Library
local DataStoreCache = {}

local DataStore2 = {}
local combinedDataStoreInfo = {}

--[[**
	<description>
	Run this once to combine all keys provided into one "main key".
	Internally, this means that data will be stored in a table with the key mainKey.
	This is used to get around the 2-DataStore2 reliability caveat.
	</description>

	<parameter name = "mainKey">
	The key that will be used to house the table.
	</parameter>

	<parameter name = "...">
	All the keys to combine under one table.
	</parameter>
**--]]
function DataStore2.Combine(mainKey, ...)
	for _, name in pairs({...}) do
		combinedDataStoreInfo[name] = mainKey
	end
end

function DataStore2.ClearCache()
	DataStoreCache = {}
end

function DataStore2.SaveAll(player)
	if DataStoreCache[player] then
		for _, dataStore in pairs(DataStoreCache[player]) do
			if dataStore.combinedStore == nil then
				dataStore:Save()
			end
		end
	end
end

function DataStore2.__call(_, dataStoreName, player)
	assert(
		typeof(dataStoreName) == "string" and typeof(player) == "Instance",
		("DataStore2() API call expected {string dataStoreName, Instance player}, got {%s, %s}")
		:format(
			typeof(dataStoreName),
			typeof(player)
		)
	)

	if DataStoreCache[player] and DataStoreCache[player][dataStoreName] then
		return DataStoreCache[player][dataStoreName]
	elseif combinedDataStoreInfo[dataStoreName] then
		local dataStore = DataStore2(combinedDataStoreInfo[dataStoreName], player)

		dataStore:BeforeSave(function(combinedData)
			for key in pairs(combinedData) do
				if combinedDataStoreInfo[key] then
					local combinedStore = DataStore2(key, player)
					local value = combinedStore:Get(nil, true)
					if value ~= nil then
						if combinedStore.combinedBeforeSave then
							value = combinedStore.combinedBeforeSave(clone(value))
						end
						combinedData[key] = value
					end
				end
			end

			return combinedData
		end)

		local combinedStore = setmetatable({
			combinedName = dataStoreName,
			combinedStore = dataStore,
		}, {
			__index = function(_, key)
				return CombinedDataStore[key] or dataStore[key]
			end
		})

		if not DataStoreCache[player] then
			DataStoreCache[player] = {}
		end

		DataStoreCache[player][dataStoreName] = combinedStore
		return combinedStore
	end

	local dataStore = {}

	dataStore.Name = dataStoreName
	dataStore.UserId = player.UserId

	dataStore.callbacks = {}
	dataStore.beforeInitialGet = {}
	dataStore.afterSave = {}
	dataStore.bindToClose = {}
	dataStore.savingMethod = SavingMethods.OrderedBackups.new(dataStore)

	setmetatable(dataStore, DataStoreMetatable)

	local event, fired = Instance.new("BindableEvent"), false

	game:BindToClose(function()
		if not fired then
			spawn(function()
				player.Parent = nil -- Forces AncestryChanged to fire and save the data
			end)

			event.Event:wait()
		end

		local value = dataStore:Get(nil, true)

		for _, bindToClose in pairs(dataStore.bindToClose) do
			bindToClose(player, value)
		end
	end)

	local playerLeavingConnection
	playerLeavingConnection = player.AncestryChanged:Connect(function()
		if player:IsDescendantOf(game) then return end
		playerLeavingConnection:Disconnect()
		dataStore:SaveAsync():catch(function(error)
			-- TODO: Something more elegant
			warn("error when player left! " .. error)
		end):finally(function()
			event:Fire()
			fired = true
		end)

		delay(40, function() --Give a long delay for people who haven't figured out the cache :^(
			DataStoreCache[player] = nil
		end)
	end)

	if not DataStoreCache[player] then
		DataStoreCache[player] = {}
	end

	DataStoreCache[player][dataStoreName] = dataStore

	return dataStore
end

DataStore2.Constants = Constants

return setmetatable(DataStore2, DataStore2)
