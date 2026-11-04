-- config.lua - what romsort sorts, from where, into what. Policy lives here;
-- the engine in lib/ never hardcodes a path or a platform.
--
-- ROMS     root that holds F/, P/ and sorted/  (/srv/roms on bak, /roms/archive
--          inside the romsort container)
-- DATS     libretro-database metadat directory
local ROMS = os.getenv('ROMS') or '/srv/roms'
local DATS = os.getenv('ROMSORT_DATS') or '/mnt/rom-sorting/dats/libretro-database/metadat'

local C = {}

C.roms = ROMS
C.dats = DATS

-- The sorted library is itself a complete LaunchBox root. It must live on the
-- same filesystem as every source so it is built from hardlinks: no extra disk,
-- and the sources are never modified.
C.out = ROMS .. '/sorted/LaunchBox'
C.state = ROMS .. '/sorted/.romsort'

-- The LaunchBox install whose Data/ is mirrored and rewritten.
C.launchbox = ROMS .. '/F/LaunchBox'

-- Windows drive letters seen in LaunchBox paths, tried in order. J:\Games is
-- the LaunchBox Games folder; P:\ is the P drive copied to /srv/roms/P.
C.drives = {
  J = { ROMS .. '/F/LaunchBox', ROMS .. '/F' },
  P = { ROMS .. '/P' },
  F = { ROMS .. '/F' },
}

-- Sources, in precedence order: when two sources hold the same file, or want
-- the same name, the earlier one wins.
--   layout 'launchbox'  root/<Platform>/... is already LaunchBox-shaped: platform
--                       folders keep their names and subfolders keep their paths.
--   layout 'folders'    root/<alias>/... from a handheld card; folders are mapped
--                       through the platform aliases and unknown ones are skipped.
C.sources = {
  { label = 'LB',       root = ROMS .. '/F/LaunchBox/Games',          layout = 'launchbox' },
  { label = 'P',        root = ROMS .. '/P/Games',                    layout = 'launchbox' },
  { label = 'P-unsort', root = ROMS .. '/P/Unsorted',                 layout = 'folders' },
  { label = 'card256',  root = ROMS .. '/F/cards/256gb black/ROMS',   layout = 'folders' },
  { label = 'card128',  root = ROMS .. '/F/cards/128gig black small', layout = 'folders' },
  { label = 'card64',   root = ROMS .. '/F/cards/64gig black',        layout = 'folders' },
  { label = 'amalgam',  root = ROMS .. '/F/cards/amalgam',            layout = 'folders' },
  { label = 'anb-games', root = ROMS .. '/F/cards/Anbernic Games',    layout = 'folders' },
  { label = 'anb-roms', root = ROMS .. '/F/cards/Anbernic Roms',      layout = 'folders' },
  { label = 'unsorted', root = ROMS .. '/F/Unsorted',                 layout = 'folders' },
}

-- Platforms use LaunchBox's own names, so the sorted Games/ folders are what
-- LaunchBox would have created. `rename = false` keeps original filenames
-- (arcade emulators find a set by its zip name). `dats` are relative to DATS.
C.platforms = {
  { name = 'Nintendo Entertainment System', aliases = { 'NES', 'FC', 'famicom' },
    dats = { 'no-intro/Nintendo - Nintendo Entertainment System.dat' } },
  { name = 'Nintendo Famicom Disk System', aliases = { 'FDS' },
    dats = { 'no-intro/Nintendo - Family Computer Disk System.dat' } },
  { name = 'Super Nintendo Entertainment System', aliases = { 'SNES', 'SFC' },
    dats = { 'no-intro/Nintendo - Super Nintendo Entertainment System.dat' } },
  { name = 'Nintendo Game Boy', aliases = { 'Game Boy', 'GB', 'gb2players' },
    dats = { 'no-intro/Nintendo - Game Boy.dat' } },
  { name = 'Nintendo Game Boy Color', aliases = { 'Game Boy Color', 'GBC', 'gbc2players' },
    dats = { 'no-intro/Nintendo - Game Boy Color.dat' } },
  { name = 'Nintendo Game Boy Advance', aliases = { 'Game Boy Advance', 'GBA' },
    dats = { 'no-intro/Nintendo - Game Boy Advance.dat' } },
  { name = 'Nintendo DS', aliases = { 'NDS' },
    dats = { 'no-intro/Nintendo - Nintendo DS.dat', 'no-intro/Nintendo - Nintendo DSi.dat' } },
  { name = 'Nintendo 3DS', aliases = { '3DS' },
    dats = { 'no-intro/Nintendo - Nintendo 3DS.dat', 'no-intro/Nintendo - New Nintendo 3DS.dat' } },
  { name = 'Nintendo 64', aliases = { 'N64' }, dats = { 'no-intro/Nintendo - Nintendo 64.dat' } },
  { name = 'Nintendo 64DD', aliases = { 'n64dd' }, dats = { 'no-intro/Nintendo - Nintendo 64DD.dat' } },
  { name = 'Nintendo Virtual Boy', aliases = { 'virtualboy', 'VB' },
    dats = { 'no-intro/Nintendo - Virtual Boy.dat' } },
  { name = 'Nintendo Pokemon Mini', aliases = { 'Pokemini', 'POKE' },
    dats = { 'no-intro/Nintendo - Pokemon Mini.dat' } },
  { name = 'Nintendo Game & Watch', aliases = { 'GW', 'gameandwatch' }, rename = false },
  { name = 'Nintendo GameCube', aliases = { 'gc', 'ngc', 'wii&ngc' },
    dats = { 'redump/Nintendo - GameCube.dat' } },
  { name = 'Nintendo Wii', aliases = { 'wii' }, dats = { 'redump/Nintendo - Wii.dat' } },
  { name = 'Nintendo Wii U', aliases = {} },
  { name = 'Nintendo Switch', aliases = {} },
  { name = 'Sega Genesis', aliases = { 'Sega Genesis', 'MD', 'megadrive', 'genesis' },
    dats = { 'no-intro/Sega - Mega Drive - Genesis.dat' } },
  { name = 'Sega CD', aliases = { 'MDCD', 'segacd', 'megacd' },
    dats = { 'redump/Sega - Mega-CD - Sega CD.dat' } },
  { name = 'Sega 32X', aliases = { '32x', 'sega32x' }, dats = { 'no-intro/Sega - 32X.dat' } },
  { name = 'Sega Master System', aliases = { 'Sega Master System', 'mastersystem', 'SMS' },
    dats = { 'no-intro/Sega - Master System - Mark III.dat' } },
  { name = 'Sega Game Gear', aliases = { 'Game Gear', 'GG', 'gamegear' },
    dats = { 'no-intro/Sega - Game Gear.dat' } },
  { name = 'Sega SG-1000', aliases = { 'sg1000', 'sg-1000' }, dats = { 'no-intro/Sega - SG-1000.dat' } },
  { name = 'Sega Pico', aliases = { 'pico-md' }, dats = { 'no-intro/Sega - PICO.dat' } },
  { name = 'Sega Saturn', aliases = { 'saturn' }, dats = { 'redump/Sega - Saturn.dat' } },
  { name = 'Sega Dreamcast', aliases = { 'dreamcast', 'dc' }, dats = { 'redump/Sega - Dreamcast.dat' } },
  { name = 'Sega Naomi', aliases = { 'naomi' }, rename = false },
  { name = 'Sammy Atomiswave', aliases = { 'atomiswave' }, rename = false },
  { name = 'NEC TurboGrafx-16', aliases = { 'PCE-TurboGrafx', 'PCE', 'PCENGINE', 'tg16' },
    dats = { 'no-intro/NEC - PC Engine - TurboGrafx 16.dat', 'no-intro/NEC - PC Engine SuperGrafx.dat' } },
  { name = 'NEC TurboGrafx-CD', aliases = { 'pcenginecd', 'tgcd' },
    dats = { 'redump/NEC - PC Engine CD - TurboGrafx-CD.dat' } },
  { name = 'NEC PC-FX', aliases = { 'PCFX' }, dats = { 'redump/NEC - PC-FX.dat' } },
  { name = 'SNK Neo Geo Pocket Color', aliases = { 'Neo Geo Pocket', 'NGP', 'NGPC' },
    dats = { 'no-intro/SNK - Neo Geo Pocket.dat', 'no-intro/SNK - Neo Geo Pocket Color.dat' } },
  { name = 'SNK Neo Geo CD', aliases = { 'neogeocd' }, dats = { 'redump/SNK - Neo Geo CD.dat' } },
  { name = 'WonderSwan Color', aliases = { 'WonderSwan', 'wswanc', 'wswan', 'WS', 'WSC' },
    dats = { 'no-intro/Bandai - WonderSwan.dat', 'no-intro/Bandai - WonderSwan Color.dat' } },
  { name = 'Atari Lynx', aliases = { 'Atari lynx', 'LYNX' },
    dats = { 'no-intro/Atari - Lynx.dat', 'headered/Atari - Lynx.dat' } },
  { name = 'Atari 2600', aliases = { 'atari2600', 'ATARI' }, dats = { 'no-intro/Atari - 2600.dat' } },
  { name = 'Atari 5200', aliases = { 'atari5200', 'FIFTYTWOHUNDRED' }, dats = { 'no-intro/Atari - 5200.dat' } },
  { name = 'Atari 7800', aliases = { 'atari7800', 'SEVENTYEIGHTHUNDRED' },
    dats = { 'no-intro/Atari - 7800.dat', 'headered/Atari - 7800.dat' } },
  { name = 'Atari 800', aliases = { 'atari800' }, dats = { 'no-intro/Atari - 8-bit Family.dat' } },
  { name = 'Atari ST', aliases = { 'ATARIST' }, dats = { 'no-intro/Atari - ST.dat' } },
  { name = 'Microsoft MSX', aliases = { 'MSX', 'msx1' }, dats = { 'no-intro/Microsoft - MSX.dat' } },
  { name = 'Microsoft MSX2', aliases = { 'msx2', 'msx2+' }, dats = { 'no-intro/Microsoft - MSX2.dat' } },
  { name = 'Commodore 64', aliases = { 'C64' }, dats = { 'no-intro/Commodore - 64.dat' } },
  { name = 'Commodore Amiga', aliases = { 'amiga500', 'amiga1200' }, dats = { 'no-intro/Commodore - Amiga.dat' } },
  { name = 'Commodore Amiga CD32', aliases = { 'amigacd32' }, dats = { 'redump/Commodore - CD32.dat' } },
  { name = 'Commodore VIC-20', aliases = { 'c20' }, dats = { 'no-intro/Commodore - VIC-20.dat' } },
  { name = 'Coleco ColecoVision', aliases = { 'colecovision' }, dats = { 'no-intro/Coleco - ColecoVision.dat' } },
  { name = 'Mattel Intellivision', aliases = { 'INTELLIVISION' }, dats = { 'no-intro/Mattel - Intellivision.dat' } },
  { name = 'Magnavox Odyssey 2', aliases = { 'o2em' }, dats = { 'no-intro/Magnavox - Odyssey2.dat' } },
  { name = 'Fairchild Channel F', aliases = { 'channelf' }, dats = { 'no-intro/Fairchild - Channel F.dat' } },
  { name = '3DO Interactive Multiplayer', aliases = { '3do' }, dats = { 'redump/The 3DO Company - 3DO.dat' } },
  { name = 'Sony Playstation', aliases = { 'PS1', 'PS', 'psx', 'Playstation', 'Sony Playstation' },
    dats = { 'redump/Sony - PlayStation.dat' } },
  { name = 'Sony Playstation 2', aliases = { 'ps2', 'Sony Playstation 2' },
    dats = { 'redump/Sony - PlayStation 2.dat' } },
  { name = 'Sony Playstation 3', aliases = { 'ps3', 'Sony Playstation 3' } },
  { name = 'Sony PSP', aliases = { 'psp', 'Sony PSP' },
    dats = { 'redump/Sony - PlayStation Portable.dat', 'no-intro/Sony - PlayStation Portable.dat' } },
  { name = 'PICO-8', aliases = { 'Pico8', 'PICO' }, rename = false },
  -- Arcade: sets are found by zip name, so never rename; dedupe only.
  { name = 'Arcade', aliases = { 'Arcade', 'mame', 'fbneo', 'CPS', 'CPS1', 'CPS2', 'CPS3',
      'HBMAME', 'FBAHACK', 'NEOGEO', 'varcade', 'daphne', 'model3', 'lightgun' }, rename = false },
  { name = 'OpenBOR', aliases = { 'openbor' }, rename = false, keep_tree = true },
  { name = 'Ports', aliases = { 'PORTS', 'ports' }, rename = false, keep_tree = true },
}

-- Folders on cards that are frontend furniture, not games.
C.skip_dirs = { 'Imgs', 'images', 'image', 'media', 'mame2003-plus', '.sdlretro', 'saves',
  'save', 'states', 'bios', 'BIOS', 'Movies', 'Music', 'trash' }
-- Extensions that are never placed from 'folders' sources (thumbnails, saves).
C.skip_ext = { 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'db', 'srm', 'sav', 'state', 'xml', 'txt',
  'fkcfg', 'ini', 'cfg', 'quicksave' }

-- Files that belong to a multi-file disc image: renaming one breaks the others,
-- so neither they nor anything sharing their folder is ever renamed.
C.multi_ext = { 'cue', 'bin', 'img', 'sub', 'ccd', 'gdi', 'raw', 'm3u', 'mds', 'mdf', 'toc', 'iso.part' }

-- Files under the mirrored LaunchBox root that are copied, not hardlinked,
-- because LaunchBox or an emulator may rewrite them in place.
C.copy_ext = { 'xml', 'cfg', 'ini', 'json', 'opt', 'srm', 'sav', 'state', 'mcr', 'mcd', 'eep',
  'nv', 'db', 'sqlite', 'txt', 'log', 'dat' }
C.copy_dirs = { 'Data' }

-- LaunchBox XML tags that hold file or folder paths.
C.path_tag = function(tag) return tag:match('Path$') or tag:match('Folder$') end

-- Commands that can list .7z/.rar archives, tried in order. bak keeps 7-Zip
-- (with its RAR codec) in the romsort-tools Incus container, which mounts
-- /srv/roms read-only at the same path. If none works, zips are still matched
-- and the 7z/rar files are listed on the next run that has one.
C.seven_zip = { '7zz', '7z', 'incus exec --project default -n romsort-tools --user 1000 -- 7z' }

C.jobs = tonumber(os.getenv('ROMSORT_JOBS') or '4')

return C
