return function(mod)
  -- Install from GitHub Releases (launcher auto-update uses the zip asset).
  -- https://github.com/jtfresh90/Kanto-Life-Mod/releases/tag/0.7.0
  -- Asset: kanto-life-0_7_0.zip  (contains full main.lua + manifest.json)
  mod.log:error(
    "Kanto Life: use the release zip from " ..
    "https://github.com/jtfresh90/Kanto-Life-Mod/releases " ..
    "(kanto-life-0_7_0.zip). The launcher Update button installs that asset."
  )
end
