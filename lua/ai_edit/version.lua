local M = { range = '>=1.18.21 <2.0.0' }

local function component(value)
  local number = tonumber(value)
  if not number or tostring(number) ~= value then
    return nil
  end
  return number
end

function M.supported(value)
  if type(value) ~= 'string' then
    return false
  end
  local major_text, minor_text, patch_text = value:match '^(%d+)%.(%d+)%.(%d+)$'
  local major = component(major_text)
  local minor = component(minor_text)
  local patch = component(patch_text)
  if not major or not minor or not patch or major ~= 1 then
    return false
  end
  return minor > 18 or (minor == 18 and patch >= 21)
end

return M
