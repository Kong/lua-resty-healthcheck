-- HTTP/2 library routines for HTTP/2 healthchecks

local ffi = require("ffi")
local bit = require "bit"
local band = bit.band

----------------------------------------------------------------------
-- Low-level routines for accessing HTTP/2 frame headers
----------------------------------------------------------------------

local http2_frame_t = ffi.typeof[[
struct {
  uint8_t length[3];
  uint8_t type;
  uint8_t flags;
  int32_t id;
} __attribute__((packed))
]]

local function frame_payload_length(f)
  return f.length[0]*2^16 + f.length[1]*2^8 + f.length[2]
end

local function frame_id(f)
  return bit.bswap(f.id)
end

local http2_frame_ptr_t = ffi.typeof("$*", http2_frame_t)

local prefix = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'

-- Return the binary representation of an annotated ascii hex dump.
-- (See usage below for examples.)
local function hex(str)
   str = str:gsub("#[^\n]+", "") -- remove comments
   str = str:gsub("[^%x]", "")   -- hex only
   return str:gsub("%x%x",       -- hex to binary
                   function(hex) return string.char(tonumber(hex, 16)) end)
end

-- Return a string representing <n> as a <bytes>-long big endian value.
local function bigendian(n, bytes)
  if bytes == 0 then
    return ''
  else
    return bigendian(bit.rshift(n,8), bytes-1)..(string.format('%02x', (n%256)))
  end
end

local function be(n, bytes)
   return (hex(bigendian(n, bytes)))
end

local function stream_id(id)
  return be(id, 4)
end

local function length(len)
  return be(len, 3)
end

------------------------------------------------------------------------
-- Client routines
------------------------------------------------------------------------

local function client_settings_window()
   local fhdr = hex [[
     04 # Type = Settings
     00 # Flags = (none)
   ]]
   local settings = hex [[
     00 04        # Initial window size
     7f ff ff ff  # 2GB
   ]]
   return length(#settings)..fhdr..stream_id(0)..settings
end

local function client_settings_ack()
   local fhdr = hex [[
     04 # Type = Settings
     01 # Flags = ACK
   ]]
   return length(0)..fhdr..stream_id(0)
end

local function literal(str)
  assert(#str < 127)
  return "\x00"..string.char(#str)..str
end

local function header(key, value)
   return literal(key)..(string.char(#value)..value)
end

local function client_headers(id, path, ctype)
   local fhdr = hex [[
     01 # Type = Headers
     04 # Flags = End Headers
   ]]
   local ok = hex [[
     86 # :scheme http
     82 # :method GET
   ]]

   local path = header(":path", path)
   local ctype = header("content-type", ctype or "text/plain")
   local host = header("host", "127.0.0.1")
   local headers = ok..path..host..ctype
   return length(#headers)..fhdr..stream_id(id)..headers
end

local function client_data(id, str)
   local fhdr = hex [[
     00 # Type = Data
     00 # Flags = (none)
   ]]
   return length(#str)..fhdr..stream_id(id)..str
end

local function client_handshake(socket, stream_id, path)
  socket:send(prefix..client_settings_window()..client_settings_ack())
  socket:send(client_headers(stream_id, path))
end

local function send_request(socket, stream_id, str)
  socket:send(client_data(stream_id, str))
end

-- Read a HTTP2 reply on the client-side of the connection.
-- TODO this only reads response headers for now
local function read_client_reply(socket)
   while true do
      local data = assert(socket:receive(ffi.sizeof(http2_frame_t)))
      local frame = ffi.cast(http2_frame_ptr_t, data)
      local payload = assert(socket:receive(frame_payload_length(frame)))
      if frame.type == 1 then -- headers
         local stream_id = frame_id(frame)
         return payload
      end
   end
end

-------------------------------------------------------------------------
-- Client interface
------------------------------------------------------------------------

local status_table = { -- :status portion of the header static table
  [8]  = "200",
  [9]  = "204",
  [10] = "206",
  [11] = "304",
  [12] = "400",
  [13] = "404",
  [14] = "500",
}

local function check_status(index)
  return index >= 8 and index <= 14 and status_table[index]
end

--
-- Functions `decode_integer` and `decode_status` were adapted from
-- https://github.com/daurnimator/lua-http, licensed under the MIT
-- license, Copyright (c) 2015-2019 Daurnimator
--

local function decode_integer(str, prefix_len, pos)
  pos = pos or 1
  local prefix_mask = 2^prefix_len-1
  if pos > #str then return end
  local I = band(prefix_mask, str:byte(pos, pos))
  if I == prefix_mask then
    local M = 0
    repeat
      pos = pos + 1
      if pos > #str then return end
      local B = str:byte(pos, pos)
      I = I + band(B, 127) * 2^M
      M = M + 7
    until band(B, 128) ~= 128
  end
  return I, pos+1
end

local function decode_status(payload)
  local pos = 1
  while pos <= #payload do
    -- rfc7540, 8.1.2.1: All pseudo-header fields MUST appear
    -- in the header block before regular header fields.
    -- rfc7540, 8.1.2.4: For HTTP/2 responses, a single ":status"
    -- pseudo-header field is defined that carries the HTTP status
    -- code field
    local first_byte = payload:byte(pos, pos)
    if band(first_byte, 0x80) ~= 0 then -- rfc7541, 6.1, indexed header
      local index, newpos = decode_integer(payload, 7, pos)
      if index == nil then break end
      pos = newpos
      return check_status(index)
    end
  end
end

-------------

local ClientStream = {}

function ClientStream:new(path, host, port, headers)
  local o = setmetatable({}, {__index = ClientStream})
  o:connect(path, host, port, headers)
  return o
end

function ClientStream:connect(path, host, port, headers)
  assert(headers == nil, "NYI: User-specified HTTP2 headers.")
  self.path = path
  self.stream_id = 1 -- TODO stream id hardcoded 1
  self.socket = ngx.socket.tcp()
  assert(self.socket:connect(host, port))
  client_handshake(self.socket, self.stream_id, self.path)
  return self
end

function ClientStream:request()
  -- write request - no body
  send_request(self.socket, self.stream_id, "") -- TODO body

  local resp = read_client_reply(self.socket)
  local status = decode_status(resp)
  return status
end

function ClientStream:close()
  return self.socket:close()
end

return ClientStream

