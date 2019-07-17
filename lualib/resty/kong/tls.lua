-- Copyright 2019 Kong Inc.

-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at

--    http://www.apache.org/licenses/LICENSE-2.0

-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.


local _M = {}


local ffi = require("ffi")
local base = require("resty.core.base")
base.allows_subsystem('http')


ffi.cdef([[
const char *ngx_http_lua_kong_ffi_request_client_certificate(ngx_http_request_t *r);
int ngx_http_lua_kong_ffi_get_full_client_certificate_chain(
    ngx_http_request_t *r, char *buf, size_t *buf_len);
const char *ngx_http_lua_kong_ffi_disable_session_reuse(ngx_http_request_t *r);
int ngx_http_lua_kong_ffi_set_upstream_client_cert_and_key(ngx_http_request_t *r,
    void *_chain, void *_key);
]])


local get_phase = ngx.get_phase
local getfenv = getfenv
local error = error
local C = ffi.C
local ffi_string = ffi.string
local get_string_buf = base.get_string_buf
local size_ptr = base.get_size_ptr()


local DEFAULT_CERT_CHAIN_SIZE = 10240
local NGX_OK = ngx.OK
local NGX_ERROR = ngx.ERROR
local NGX_AGAIN = ngx.AGAIN
local NGX_DONE = ngx.DONE
local NGX_DECLINED = ngx.DECLINED
local NGX_ABORT = -6


local get_request
do
    local ok, exdata = pcall(require, "thread.exdata")
    if ok and exdata then
        function get_request()
            local r = exdata()
            if r ~= nil then
                return r
            end
        end

    else
        local getfenv = getfenv

        function get_request()
            return getfenv(0).__ngx_req
        end
    end
end


function _M.request_client_certificate(no_session_reuse)
    if get_phase() ~= 'ssl_cert' then
        error("API disabled in the current context")
    end

    local r = get_request()
    -- no need to check if r is nil as phase check above
    -- already ensured it

    local errmsg = C.ngx_http_lua_kong_ffi_request_client_certificate(r)
    if errmsg == nil then
        return true
    end

    return nil, ffi_string(errmsg)
end


function _M.disable_session_reuse()
    if get_phase() ~= 'ssl_cert' then
        error("API disabled in the current context")
    end

    local r = get_request()

    local errmsg = C.ngx_http_lua_kong_ffi_disable_session_reuse(r)
    if errmsg == nil then
        return true
    end

    return nil, ffi_string(errmsg)
end


do
    local ALLOWED_PHASES = {
        ['rewrite'] = true,
        ['balancer'] = true,
        ['access'] = true,
        ['content'] = true,
        ['log'] = true,
    }

    function _M.get_full_client_certificate_chain()
        if not ALLOWED_PHASES[get_phase()] then
            error("API disabled in the current context", 2)
        end

        local r = get_request()

        size_ptr[0] = DEFAULT_CERT_CHAIN_SIZE

::again::

        local buf = get_string_buf(size_ptr[0])

        local ret = C.ngx_http_lua_kong_ffi_get_full_client_certificate_chain(
            r, buf, size_ptr)
        if ret == NGX_OK then
            return ffi_string(buf, size_ptr[0])
        end

        if ret == NGX_ERROR then
            return nil, "error while obtaining client certificate chain"
        end

        if ret == NGX_ABORT then
            return nil,
                   "connection is not TLS or TLS support for Nginx not enabled"
        end

        if ret == NGX_DECLINED then
            return nil
        end

        if ret == NGX_AGAIN then
            goto again
        end

        error("unknown return code: " .. tostring(ret))
    end
end


do
    local ALLOWED_PHASES = {
        ['rewrite'] = true,
        ['balancer'] = true,
        ['access'] = true,
    }

    function _M.set_upstream_cert_and_key(chain, key)
        if not ALLOWED_PHASES[get_phase()] then
            error("API disabled in the current context", 2)
        end

        if not chain or not key then
            error("chain and key must not be nil", 2)
        end

        local r = get_request()

        local ret = C.ngx_http_lua_kong_ffi_set_upstream_client_cert_and_key(
            r, chain, key)
        if ret == NGX_OK then
            return true
        end

        if ret == NGX_ERROR then
            return nil, "error while setting upstream client cert and key"
        end

        error("unknown return code: " .. tostring(ret))
    end
end


return _M
