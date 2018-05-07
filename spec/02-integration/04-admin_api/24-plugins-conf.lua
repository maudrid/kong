local helpers = require "spec.helpers"
local cjson = require "cjson"

describe("Default plugins" , function()

  describe("disables all plugin when 'plugins=off'" , function()
    local client
    setup(function()
      assert(helpers.start_kong({
        plugins = "off",
        custom_plugins = "", -- to override default custom_plugins for tests
      }))
      client = helpers.admin_client()
    end)
    teardown(function()
      if client then
        client:close()
      end
      helpers.stop_kong()
    end)
    it(function()
      local res = assert(client:send {
        method = "GET",
        path = "/",
      })
      local body = assert.res_status(200 , res)
      local json = assert(cjson.decode(body))
      assert.equal(0, #json.plugins.available_on_server)
    end)
  end)

  describe("disables all plugin when 'plugins=off, key-auth'" , function()
    local client
    setup(function()
      assert(helpers.start_kong({
        plugins = "off, key-auth",
        custom_plugins = "", -- to override default custom_plugins for tests
      }))
      client = helpers.admin_client()
    end)
    teardown(function()
      if client then
        client:close()
      end
      helpers.stop_kong()
    end)
    it(function()
      local res = assert(client:send {
        method = "GET",
        path = "/",
      })
      local body = assert.res_status(200 , res)
      local json = assert(cjson.decode(body))
      assert.equal(0, #json.plugins.available_on_server)
    end)
  end)

  describe("does not disable plugins when 'off' is not at the first index" , function()
    local client
    setup(function()
      assert(helpers.start_kong({
        plugins = "key-auth, off, basic-auth",
        custom_plugins = "", -- to override default custom_plugins for tests
      }))
      client = helpers.admin_client()
    end)
    teardown(function()
      if client then
        client:close()
      end
      helpers.stop_kong()
    end)
    it(function()
      local res = assert(client:send {
        method = "GET",
        path = "/",
      })
      local body = assert.res_status(200 , res)
      local json = assert(cjson.decode(body))
      local count = 0
      for i in pairs(json.plugins.available_on_server) do
        count = count + 1
      end
      assert.equal(2, count)
      assert.True(json.plugins.available_on_server["key-auth"])
      assert.True(json.plugins.available_on_server["basic-auth"])
    end)
  end)

  describe("disables plugins not in conf file" , function()
    local client
    setup(function()
      assert(helpers.start_kong({
        plugins = "key-auth, basic-auth"
      }))
      client = helpers.admin_client()
    end)
    teardown(function()
      if client then
        client:close()
      end
      helpers.stop_kong()
    end)
    it("returns 201 for plugins included in the list" , function()
      local res = assert(client:send {
        method = "POST",
        path = "/plugins/",
        body = {
          name = "key-auth"
        },
        headers = { ["Content-Type"] = "application/json" }
      })
      assert.res_status(201 , res)

      local res = assert(client:send {
        method = "POST",
        path = "/plugins/",
        body = {
          name = "basic-auth"
        },
        headers = { ["Content-Type"] = "application/json" }
      })
      assert.res_status(201 , res)
    end)
    it("returns 400 for plugins not included in the list" , function()
      local res = assert(client:send {
        method = "POST",
        path = "/plugins/",
        body = {
          name = "rate-limiting"
        },
        headers = { ["Content-Type"] = "application/json" }
      })
      assert.res_status(400 , res)
    end)
  end)
end)

