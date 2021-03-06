local BasePlugin = require "kong.plugins.base_plugin"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local constants = require "kong.constants"

local req_set_header = ngx.req.set_header
local ngx_re_gmatch = ngx.re.gmatch
local req_clear_header = ngx.req.clear_header

local HTTP_INTERNAL_SERVER_ERROR = 500
local HTTP_UNAUTHORIZED = 401
local JwtClaimsHeadersHandler = BasePlugin:extend()
-- See https://docs.konghq.com/2.0.x/plugin-development/custom-logic/#plugins-execution-order
-- Must execute before the request-transformer plugin because it sets variables in the shared context
JwtClaimsHeadersHandler.PRIORITY = 970

local function retrieve_token(request, conf)
  local uri_parameters = request.get_uri_args()

  for _, v in ipairs(conf.uri_param_names) do
    if uri_parameters[v] then
      return uri_parameters[v]
    end
  end

  local ngx_var = ngx.var
  for _, v in ipairs(conf.cookie_names) do
    local jwt_cookie = ngx_var["cookie_" .. v]
    if jwt_cookie and jwt_cookie ~= "" then
      return jwt_cookie
    end
  end

  local authorization_header = request.get_headers()["authorization"]
  if authorization_header then
    local iterator, iter_err = ngx_re_gmatch(authorization_header, "\\s*[Bb]earer\\s+(.+)")
    if not iterator then
      return nil, iter_err
    end

    local m, err = iterator()
    if err then
      return nil, err
    end

    if m and #m > 0 then
      return m[1]
    end
  end
end

function JwtClaimsHeadersHandler:new()
  JwtClaimsHeadersHandler.super.new(self, "jwt-claims-headers")
end

function JwtClaimsHeadersHandler:access(conf)
  JwtClaimsHeadersHandler.super.access(self)
  local continue_on_error = conf.continue_on_error
  req_clear_header("X-user_id")

  local token, err = retrieve_token(ngx.req, conf)
  
  local ttype = type(token)
  if ttype ~= "string" then
    if ttype == "nil" and continue_on_error then
      return
    end
  end

  if err and not continue_on_error then
    kong.log.err("error retrieving token: ", tostring(err))
    return kong.response.exit(HTTP_INTERNAL_SERVER_ERROR, {
      message = "An unexpected error occurred"
    })
  end

  if not token and not continue_on_error then
    return kong.response.exit(HTTP_UNAUTHORIZED, "Not authorized")
  end

  local jwt, err = jwt_decoder:new(token)
  if err and not continue_on_error then
    kong.log.err("error decoding token: ", tostring(err))
    return kong.response.exit(HTTP_INTERNAL_SERVER_ERROR, {
      message = "An unexpected error occurred"
    })
  end

  ngx.ctx.jwt_logged_in = true
  ngx.ctx.jwt_claims = {}
  kong.ctx.shared.jwt_claims = {}
  kong.ctx.shared.jwt_token = token

  local anonymous_consumer = kong.request.get_headers()[constants.HEADERS.ANONYMOUS]
  -- Kong JWT plugin makes sure this header can't be spoofed: https://github.com/Kong/kong/blob/ea40d9bc8af59d4d1623eb5464b3b996f5bd007d/kong/plugins/jwt/handler.lua#L111
  if anonymous_consumer == "true" then
    return
  end

  local claims = jwt.claims
  for claim_key,claim_value in pairs(claims) do
    for _,claim_pattern in pairs(conf.claims_to_include) do
      if string.match(claim_key, "^"..claim_pattern.."$") then
        ngx.ctx.jwt_claims[claim_key] = claim_value
        kong.ctx.shared.jwt_claims[claim_key] = claim_value
        req_set_header("X-"..claim_key, claim_value)
      end
    end
  end
end

function JwtClaimsHeadersHandler:header_filter(conf)
  JwtClaimsHeadersHandler.super.header_filter(self)
  local params = "Max-Age=15; Secure;"

  if ngx.ctx.jwt_logged_in then
    kong.response.add_header('Set-Cookie', string.format('unsafe_logged_in=1; %s', params))
  end

  if ngx.ctx.jwt_claims and ngx.ctx.jwt_claims['user_id'] ~= nil then
    kong.response.add_header('Set-Cookie', string.format('unsafe_user_id=%s; %s', ngx.ctx.jwt_claims['user_id'], params))
  end
end

return JwtClaimsHeadersHandler
