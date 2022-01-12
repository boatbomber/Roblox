-- Standard saving of data stores
-- The key you provide to DataStore2 is the name of the store with GetDataStore
-- GetAsync/UpdateAsync are then called based on the user ID
local DataStoreServiceRetriever = require(script.Parent.Parent.DataStoreServiceRetriever)
local Promise = require(script.Parent.Parent.Promise)
local Serializer = require(script.Parent.Parent.Serializer)

local Standard = {}
Standard.__index = Standard

function Standard:Get()
	return Promise.async(function(resolve)
		local value = self.dataStore:GetAsync(self.userId)
		local success, deserialized =  pcall(Serializer.Deserialize, Serializer, value)
		resolve(if success then deserialized else value)
	end)
end

function Standard:Set(value)
	return Promise.async(function(resolve)
		local success, serialized =  pcall(Serializer.Serialize, Serializer, value)
		self.dataStore:UpdateAsync(self.userId, function()
			return if success then serialized else value
		end)

		resolve()
	end)
end

function Standard.new(dataStore2)
	return setmetatable({
		dataStore = DataStoreServiceRetriever.Get():GetDataStore(dataStore2.Name),
		userId = dataStore2.UserId,
	}, Standard)
end

return Standard
