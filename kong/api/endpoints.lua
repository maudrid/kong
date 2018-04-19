local Errors       = require "kong.db.errors"
local responses    = require "kong.tools.responses"
local utils        = require "kong.tools.utils"
local arguments    = require "kong.api.arguments"
local app_helpers  = require "lapis.application"


local escape_uri   = ngx.escape_uri
local unescape_uri = ngx.unescape_uri
local null         = ngx.null
local fmt          = string.format


-- error codes http status codes
local ERRORS_HTTP_CODES = {
  [Errors.codes.INVALID_PRIMARY_KEY]   = 400,
  [Errors.codes.SCHEMA_VIOLATION]      = 400,
  [Errors.codes.PRIMARY_KEY_VIOLATION] = 400,
  [Errors.codes.FOREIGN_KEY_VIOLATION] = 400,
  [Errors.codes.UNIQUE_VIOLATION]      = 409,
  [Errors.codes.NOT_FOUND]             = 404,
  [Errors.codes.INVALID_OFFSET]        = 400,
  [Errors.codes.DATABASE_ERROR]        = 500,
}


local function handle_error(err_t)
  local status = ERRORS_HTTP_CODES[err_t.code]
  if not status or status == 500 then
    return app_helpers.yield_error(err_t)
  end

  responses.send(status, err_t)
end


local function select_entity(db, schema, params)
  local dao = db[schema.name]

  local id = unescape_uri(params[schema.name])
  if utils.is_valid_uuid(id) then
    local entity, _, err_t = dao:select({ id = id })
    if entity or err_t then
      return entity, _, err_t
    end
  end

  for name, field in schema:each_field() do
    if field.unique then
      local inferred_value = arguments.infer_value(id, field)
      if schema:validate_field(field, inferred_value) then
        return dao["select_by_" .. name](dao, inferred_value)
      end
    end
  end

  return dao:select({ id = id })
end


-- Generates admin api get collection endpoint functions
--
-- Examples:
--
-- /routes
-- /services/:services/routes
--
-- and
--
-- /services
local function get_collection_endpoint(schema, foreign_schema, foreign_field_name)
  if not foreign_schema then
    return function(self, db, helpers)
      local data, _, err_t, offset = db[schema.name]:page(self.args.size,
                                                          self.args.offset)
      if err_t then
        return handle_error(err_t)
      end

      local next_page = offset and fmt("/%s?offset=%s", schema.name,
                                       escape_uri(offset)) or null

      return helpers.responses.send_HTTP_OK {
        data   = data,
        offset = offset,
        next   = next_page,
      }
    end
  end

  return function(self, db, helpers)
    local parent_entity, _, err_t = select_entity(db, foreign_schema, self.params)
    if err_t then
      return handle_error(err_t)
    end

    if not parent_entity then
      return helpers.responses.send_HTTP_NOT_FOUND()
    end

    local dao = db[schema.name]
    local rows, _, err_t, offset = dao["for_" .. foreign_field_name](dao, { id = parent_entity.id },
                                                                     self.args.size, self.args.offset)
    if err_t then
      return handle_error(err_t)
    end

    local next_page
    if offset then
      next_page = fmt("/%s/%s/%s?offset=%s", foreign_schema.name, escape_uri(parent_entity.id),
                      schema.name, escape_uri(offset))

    else
      next_page = null
    end

    return helpers.responses.send_HTTP_OK {
      data   = rows,
      offset = offset,
      next   = next_page,
    }
  end
end


-- Generates admin api post collection endpoint functions
--
-- Examples:
--
-- /routes
-- /services/:services/routes
--
-- and
--
-- /services
local function post_collection_endpoint(schema, foreign_schema, foreign_field_name)
  return function(self, db, helpers)
    if foreign_schema then
      local parent_entity, _, err_t = select_entity(db, foreign_schema, foreign_schema.name)
      if err_t then
        return handle_error(err_t)
      end

      if not parent_entity then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      self.args.post[foreign_field_name] = { id = parent_entity.id }
    end

    local data, _, err_t = db[schema.name]:insert(self.args.post)
    if err_t then
      return handle_error(err_t)
    end

    return helpers.responses.send_HTTP_CREATED(data)
  end
end


-- Generates admin api get entity endpoint functions
--
-- Examples:
--
-- /routes/:routes
-- /routes/:routes/service
--
-- and
--
-- /services/:services
local function get_entity_endpoint(schema, foreign_schema, foreign_field_name)
  return function(self, db, helpers)
    local entity, _, err_t = select_entity(db, schema, self.params)
    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return helpers.responses.send_HTTP_NOT_FOUND()
    end

    if foreign_schema then
      local id = entity[foreign_field_name]
      if not id or id == null then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      entity, _, err_t = db[foreign_schema.name]:select(id)
      if err_t then
        return handle_error(err_t)
      end

      if not entity then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end
    end

    return helpers.responses.send_HTTP_OK(entity)
  end
end


-- Generates admin api patch entity endpoint functions
--
-- Examples:
--
-- /routes/:routes
-- /routes/:routes/service
--
-- and
--
-- /services/:services
local function patch_entity_endpoint(schema, foreign_schema, foreign_field_name)
  return function(self, db, helpers)
    local entity, _, err_t = select_entity(db, schema, self.params)
    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return helpers.responses.send_HTTP_NOT_FOUND()
    end

    if not foreign_schema then
      entity, _, err_t = db[schema.name]:update({ id = entity.id }, self.args.post)

    else
      local id = entity[foreign_field_name]
      if not id or id == null then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      entity, _, err_t = db[foreign_schema.name]:update(id, self.args.post)
    end

    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return helpers.responses.send_HTTP_NOT_FOUND()
    end

    return helpers.responses.send_HTTP_OK(entity)
  end
end


-- Generates admin api delete entity endpoint functions
--
-- Examples:
--
-- /routes/:routes
-- /routes/:routes/service
--
-- and
--
-- /services/:services
local function delete_entity_endpoint(schema, foreign_schema, foreign_field_name)
  return function(self, db, helpers)
    local entity, _, err_t = select_entity(db, schema, self.params)
    if err_t then
      return handle_error(err_t)
    end

    if not foreign_schema then
      if not entity then
        return helpers.responses.send_HTTP_NO_CONTENT()
      end

      _, _, err_t = db[schema.name]:delete({ id = entity.id })
      if err_t then
        return handle_error(err_t)
      end

      return helpers.responses.send_HTTP_NO_CONTENT()

    else
      local id = entity and entity[foreign_field_name]
      if not id or id == null then
        return helpers.responses.send_HTTP_NOT_FOUND()
      end

      return helpers.responses.send_HTTP_METHOD_NOT_ALLOWED()
    end
  end
end


local function generate_collection_endpoints(endpoints, schema, foreign_schema, foreign_field_name)
  local collection_path
  if foreign_schema then
    collection_path = fmt("/%s/:%s/%s", foreign_schema.name, foreign_schema.name, schema.name)

  else
    collection_path = fmt("/%s", schema.name)
  end

  endpoints[collection_path] = {
    schema  = schema,
    methods = {
      --OPTIONS = method_not_allowed,
      --HEAD    = method_not_allowed,
      GET     = get_collection_endpoint(schema, foreign_schema, foreign_field_name),
      POST    = post_collection_endpoint(schema, foreign_schema, foreign_field_name),
      --PUT     = method_not_allowed,
      --PATCH   = method_not_allowed,
      --DELETE  = method_not_allowed,
    },
  }
end


local function generate_entity_endpoints(endpoints, schema, foreign_schema, foreign_field_name)
  local entity_path
  if foreign_schema then
    entity_path = fmt("/%s/:%s/%s", schema.name, schema.name, foreign_field_name)

  else
    entity_path = fmt("/%s/:%s", schema.name, schema.name)
  end

  endpoints[entity_path] = {
    schema  = foreign_schema or schema,
    methods = {
      --OPTIONS = method_not_allowed,
      --HEAD    = method_not_allowed,
      GET     = get_entity_endpoint(schema, foreign_schema, foreign_field_name),
      --POST    = method_not_allowed,
      --PUT     = method_not_allowed,
      PATCH   = patch_entity_endpoint(schema, foreign_schema, foreign_field_name),
      DELETE  = delete_entity_endpoint(schema, foreign_schema, foreign_field_name),
    },
  }
end


-- Generates admin api endpoint functions
--
-- Examples:
--
-- /routes
-- /routes/:routes
-- /routes/:routes/service
-- /services/:services/routes
--
-- and
--
-- /services
-- /services/:services
local function generate_endpoints(schema, endpoints)
  -- e.g. /routes
  generate_collection_endpoints(endpoints, schema)

  -- e.g. /routes/:routes
  generate_entity_endpoints(endpoints, schema)

  for foreign_field_name, foreign_field in schema:each_field() do
    if foreign_field.type == "foreign" then
      -- e.g. /routes/:routes/service
      generate_entity_endpoints(endpoints, schema, foreign_field.schema, foreign_field_name)

      -- e.g. /services/:services/routes
      generate_collection_endpoints(endpoints, schema, foreign_field.schema, foreign_field_name)
    end
  end

  return endpoints
end


local Endpoints = { handle_error = handle_error }


function Endpoints.new(schema, endpoints)
  return generate_endpoints(schema, endpoints)
end


return Endpoints
